import Foundation
import UnfCrypto
import TolerantZip
import Gunzip
import UniFiBSON
import BackupStream
import UniFiModel
import Diagnostics
import Redaction

/// The top-level object the UI holds. Produced by `Backup.open(url:)`.
public struct Backup: Sendable {
    public let sourceURL: URL?
    public let identity: Identity
    public let model: ModelMapper.MappedModel
    public let tree: [TreeNode]
    public let diagnostics: [Diagnostic]
    public let warnings: [String]
    public let entryNames: [String]
    public let rawEntries: [String: Data]
    public let statsLoaded: Bool

    /// File sizes of ZIP entries — for the statistics preview in the UI.
    public let entrySizes: [String: Int]

    /// Secrets inventory (field-path → count).
    public let secretInventory: [String: Int]

    /// Load a `.unf` file into a fully-parsed `Backup`.
    ///
    /// - Parameters:
    ///   - url: URL pointing to a `.unf` file on disk.
    ///   - loadStatistics: If `true`, decompresses and parses `db_stat.gz`
    ///                     too. Default: `false` — the UI should show an opt-
    ///                     in affordance and call `loadingStatistics()` on a
    ///                     loaded backup to upgrade it.
    public static func open(
        url: URL,
        loadStatistics: Bool = false
    ) throws -> Backup {
        let ciphertext = try Data(contentsOf: url)
        return try load(
            sourceURL: url,
            ciphertext: ciphertext,
            loadStatistics: loadStatistics
        )
    }

    /// Load from in-memory ciphertext. Used by tests.
    public static func load(
        sourceURL: URL? = nil,
        ciphertext: Data,
        loadStatistics: Bool = false
    ) throws -> Backup {
        let diagnostics = DiagnosticSink()

        // 1. AES-128-CBC NoPadding.
        let plaintext = try UnfCipher.decrypt(ciphertext)

        // 2. Tolerant ZIP read.
        let zip = try TolerantZipReader(plaintext)
        for d in zip.diagnostics { diagnostics.emit(d) }

        // Collect convenience maps.
        var entries: [String: Data] = [:]
        var sizes: [String: Int] = [:]
        for (name, entry) in zip.entries {
            entries[name] = entry.data
            sizes[name] = entry.data.count
        }

        guard let dbgz = entries["db.gz"] else {
            throw FatalBackupError.configurationDatabaseMissing(
                detail: "db.gz not present in decrypted ZIP (entries: \(entries.keys.sorted().joined(separator: ", ")))"
            )
        }

        // 3. Gunzip + walk the BSON stream for `ace`.
        let dbBytes: Data
        do {
            dbBytes = try Gunzip.decompress(dbgz)
        } catch {
            throw FatalBackupError.configurationDatabaseMissing(
                detail: "db.gz could not be gunzipped: \(error)"
            )
        }
        let aceOutput = CollectionStream.readAll(dbBytes, diagnostics: diagnostics)

        var warnings: [String] = []

        // 4. Optionally load statistics.
        var combinedOutput = aceOutput
        var statsLoaded = false
        if loadStatistics, let statsBytes = entries["db_stat.gz"] {
            do {
                let decompressed = try Gunzip.decompress(statsBytes)
                let statsOutput = CollectionStream.readAll(decompressed, diagnostics: diagnostics)
                for (k, v) in statsOutput.recordsByCollection {
                    combinedOutput.recordsByCollection[k, default: []].append(contentsOf: v)
                }
                for name in statsOutput.orderedCollectionNames
                where !combinedOutput.orderedCollectionNames.contains(name) {
                    combinedOutput.orderedCollectionNames.append(name)
                }
                statsLoaded = true
            } catch {
                diagnostics.emit(
                    .warning,
                    .truncatedStatsStream,
                    "Could not parse db_stat.gz (\(error)); statistics unavailable, configuration is fine."
                )
                warnings.append("Statistics could not be loaded: \(error)")
            }
        }

        // 5. Map to strongly-typed model + opaque fallback.
        let mapper = ModelMapper(diagnostics: diagnostics)
        let model = mapper.map(combinedOutput)

        // 6. Identity derivation.
        let identity = Identity.parse(
            entries: entries,
            collectionNames: Set(combinedOutput.orderedCollectionNames),
            diagnostics: diagnostics
        )

        // 7. Tree.
        let tree = TreeBuilder.build(model)

        // 8. Secret inventory.
        let inventory = SecretVault.inventory(model: model)

        return Backup(
            sourceURL: sourceURL,
            identity: identity,
            model: model,
            tree: tree,
            diagnostics: diagnostics.snapshot(),
            warnings: warnings,
            entryNames: entries.keys.sorted(),
            rawEntries: entries,
            statsLoaded: statsLoaded,
            entrySizes: sizes,
            secretInventory: inventory
        )
    }

    /// Returns a copy of this backup with `ace_stat` now loaded. Cheap to
    /// re-call from the UI when the user clicks "Load statistics…".
    public func loadingStatistics() throws -> Backup {
        guard let ciphertext = sourceURL.flatMap({ try? Data(contentsOf: $0) }) else {
            return self
        }
        return try Backup.load(sourceURL: sourceURL, ciphertext: ciphertext, loadStatistics: true)
    }
}
