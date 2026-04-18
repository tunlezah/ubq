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
    public let entrySizes: [String: Int]
    public let secretInventory: [String: Int]
    /// True when this backup was extracted from a `.unifi` superset container.
    public let isUnifiOSBackup: Bool

    // MARK: - Public API

    /// Load a `.unf` or `.unifi` file into a fully-parsed `Backup`.
    public static func open(
        url: URL,
        loadStatistics: Bool = false
    ) throws -> Backup {
        let raw = try Data(contentsOf: url)
        return try load(sourceURL: url, rawFileData: raw, loadStatistics: loadStatistics)
    }

    /// Load from in-memory bytes. Handles both `.unf` (AES-encrypted from
    /// byte 0) and `.unifi` (plain ZIP — either wrapping an AES `.unf` or
    /// shipping the Network payload inline).
    public static func load(
        sourceURL: URL? = nil,
        rawFileData: Data,
        loadStatistics: Bool = false
    ) throws -> Backup {
        // Detect whether the file is a .unifi (plain ZIP) or .unf (AES blob).
        if isPlainZip(rawFileData) {
            return try loadUnifiOS(
                sourceURL: sourceURL,
                outerZipData: rawFileData,
                loadStatistics: loadStatistics
            )
        } else {
            return try loadUnf(
                sourceURL: sourceURL,
                ciphertext: rawFileData,
                loadStatistics: loadStatistics,
                isUnifiOSBackup: false
            )
        }
    }

    /// Legacy entry point kept for existing tests that pass pre-encrypted data.
    public static func load(
        sourceURL: URL? = nil,
        ciphertext: Data,
        loadStatistics: Bool = false
    ) throws -> Backup {
        try loadUnf(
            sourceURL: sourceURL,
            ciphertext: ciphertext,
            loadStatistics: loadStatistics,
            isUnifiOSBackup: false
        )
    }

    /// Returns a copy with statistics loaded.
    public func loadingStatistics() throws -> Backup {
        guard let url = sourceURL, let raw = try? Data(contentsOf: url) else { return self }
        return try Backup.load(sourceURL: url, rawFileData: raw, loadStatistics: true)
    }

    // MARK: - .unifi (UniFi OS System Config Backup)

    /// `.unifi` files are **plain (unencrypted) ZIPs**. Two shapes exist in the wild:
    ///
    ///   1. Older UniFi OS builds wrap a nested AES-encrypted `.unf` plus
    ///      UCore Postgres + per-app configs.
    ///   2. Newer UniFi OS builds (2025+) inline the Network payload directly:
    ///      the outer ZIP contains `db.gz`, `version`, `format`, `timestamp`,
    ///      `system.properties`, and optionally `backup.json` — the same
    ///      entries that would appear *inside* a decrypted `.unf`. No
    ///      encryption layer at all.
    ///
    /// We try the embedded `.unf` path first; if nothing AES-shaped is
    /// present but the outer entries themselves look like a decrypted
    /// Network backup, we parse them directly.
    private static func loadUnifiOS(
        sourceURL: URL?,
        outerZipData: Data,
        loadStatistics: Bool
    ) throws -> Backup {
        let diagnostics = DiagnosticSink()
        diagnostics.emit(.info, .other, "Detected UniFi OS System Config Backup (.unifi container).")

        let outerZip = try TolerantZipReader(outerZipData)
        for d in outerZip.diagnostics { diagnostics.emit(d) }

        var outerEntries: [String: Data] = [:]
        for (name, entry) in outerZip.entries {
            outerEntries[name] = entry.data
        }

        diagnostics.emit(
            .info, .other,
            "Outer ZIP entries: \(outerEntries.keys.sorted().joined(separator: ", "))"
        )

        // Strategy A: locate an embedded AES-encrypted `.unf` blob and decrypt it.
        if let unfData = findEmbeddedUnf(in: outerEntries, diagnostics: diagnostics) {
            diagnostics.emit(
                .info, .other,
                "Found embedded Network backup (\(unfData.count) bytes). Decrypting."
            )
            return try loadUnf(
                sourceURL: sourceURL,
                ciphertext: unfData,
                loadStatistics: loadStatistics,
                isUnifiOSBackup: true,
                extraDiagnostics: diagnostics
            )
        }

        // Strategy B: the outer ZIP itself IS the decrypted Network payload
        // (newer UniFi OS builds ship it unencrypted). Detect by presence of
        // db.gz (legacy layout) or per-collection .bson files.
        if isDecryptedBackupLayout(outerEntries) {
            diagnostics.emit(
                .info, .other,
                "Outer ZIP contains an unencrypted Network payload; parsing in-place."
            )
            return try parseDecryptedZip(
                sourceURL: sourceURL,
                entries: outerEntries,
                loadStatistics: loadStatistics,
                isUnifiOSBackup: true,
                diagnostics: diagnostics
            )
        }

        throw FatalBackupError.notAUniFiNetworkBackup(
            detail: "This is a UniFi OS System Config Backup, but no Network payload was found. Outer entries: \(outerEntries.keys.sorted().joined(separator: ", "))"
        )
    }

    /// True if a flat set of ZIP entries looks like the inside of a decrypted
    /// `.unf`: either `db.gz` (legacy layout) or one-or-more `.bson` files.
    private static func isDecryptedBackupLayout(_ entries: [String: Data]) -> Bool {
        if entries["db.gz"] != nil { return true }
        let hasBson = entries.keys.contains {
            $0.hasSuffix(".bson") && !$0.hasPrefix("__MACOSX")
        }
        return hasBson
    }

    /// Heuristically locates the AES-encrypted `.unf` blob inside a `.unifi`
    /// outer ZIP.
    private static func findEmbeddedUnf(
        in entries: [String: Data],
        diagnostics: DiagnosticSink
    ) -> Data? {
        // Strategy 1: filename ends with `.unf`
        for (name, data) in entries where name.lowercased().hasSuffix(".unf") {
            diagnostics.emit(.info, .other, "Embedded .unf found by extension: '\(name)'")
            return data
        }

        // Strategy 2: entry under `network/` path that looks AES-shaped
        for (name, data) in entries.sorted(by: { $0.key < $1.key }) {
            if name.lowercased().contains("network"),
               data.count >= 16,
               data.count % 16 == 0,
               !isPlainZip(data) {
                diagnostics.emit(.info, .other, "Embedded .unf found by path+shape: '\(name)'")
                return data
            }
        }

        // Strategy 3: any entry that is AES-shaped AND decrypts to a ZIP
        for (name, data) in entries.sorted(by: { $0.value.count > $1.value.count }) {
            if data.count >= 64,
               data.count % 16 == 0,
               !isPlainZip(data) {
                if let decrypted = try? UnfCipher.decrypt(data) {
                    diagnostics.emit(.info, .other, "Embedded .unf found by trial-decrypt: '\(name)'")
                    _ = decrypted
                    return data
                }
            }
        }

        return nil
    }

    // MARK: - .unf (Network-only backup)

    private static func loadUnf(
        sourceURL: URL?,
        ciphertext: Data,
        loadStatistics: Bool,
        isUnifiOSBackup: Bool,
        extraDiagnostics: DiagnosticSink? = nil
    ) throws -> Backup {
        let diagnostics = extraDiagnostics ?? DiagnosticSink()

        // 1. AES-128-CBC NoPadding.
        let plaintext = try UnfCipher.decrypt(ciphertext)

        // 2. Tolerant ZIP read.
        let zip = try TolerantZipReader(plaintext)
        for d in zip.diagnostics { diagnostics.emit(d) }

        var entries: [String: Data] = [:]
        for (name, entry) in zip.entries {
            entries[name] = entry.data
        }

        return try parseDecryptedZip(
            sourceURL: sourceURL,
            entries: entries,
            loadStatistics: loadStatistics,
            isUnifiOSBackup: isUnifiOSBackup,
            diagnostics: diagnostics
        )
    }

    /// Parse the *already-decrypted* flat ZIP contents of a Network backup.
    /// Used by both `.unf` (post-decrypt) and `.unifi` (inline unencrypted).
    private static func parseDecryptedZip(
        sourceURL: URL?,
        entries: [String: Data],
        loadStatistics: Bool,
        isUnifiOSBackup: Bool,
        diagnostics: DiagnosticSink
    ) throws -> Backup {
        var sizes: [String: Int] = [:]
        for (name, data) in entries {
            sizes[name] = data.count
        }

        diagnostics.emit(
            .info, .other,
            "Inner ZIP entries: \(entries.keys.sorted().joined(separator: ", "))"
        )

        // 3. Detect layout and parse.
        let bsonEntryNames = entries.keys.filter { name in
            name.hasSuffix(".bson") && !name.hasPrefix("__MACOSX")
        }.sorted()

        var combinedOutput: CollectionStream.Output
        var warnings: [String] = []
        var statsLoaded = false

        if !bsonEntryNames.isEmpty {
            // Path A: per-collection .bson files (format="bson")
            diagnostics.emit(
                .info, .other,
                "Detected per-collection .bson layout (\(bsonEntryNames.count) files): \(bsonEntryNames.prefix(20).joined(separator: ", "))\(bsonEntryNames.count > 20 ? ", …" : "")"
            )
            combinedOutput = readPerCollectionBSON(
                entries: entries,
                bsonEntryNames: bsonEntryNames,
                loadStatistics: loadStatistics,
                diagnostics: diagnostics
            )
            statsLoaded = loadStatistics
        } else if let dbgz = entries["db.gz"] {
            // Path B: single-stream db.gz (legacy)
            diagnostics.emit(
                .info, .other,
                "Detected single-stream db.gz layout (legacy)."
            )
            let dbBytes: Data
            do {
                dbBytes = try Gunzip.decompress(dbgz)
            } catch {
                throw FatalBackupError.configurationDatabaseMissing(
                    detail: "db.gz could not be gunzipped: \(error)"
                )
            }
            combinedOutput = CollectionStream.readAll(dbBytes, diagnostics: diagnostics)

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
                        .warning, .truncatedStatsStream,
                        "Could not parse db_stat.gz (\(error)); statistics unavailable."
                    )
                    warnings.append("Statistics could not be loaded: \(error)")
                }
            }
        } else {
            throw FatalBackupError.configurationDatabaseMissing(
                detail: "Neither .bson files nor db.gz found in ZIP (entries: \(entries.keys.sorted().joined(separator: ", ")))"
            )
        }

        // 4. Model.
        let mapper = ModelMapper(diagnostics: diagnostics)
        let model = mapper.map(combinedOutput)

        // 5. Identity.
        let identity = Identity.parse(
            entries: entries,
            collectionNames: Set(combinedOutput.orderedCollectionNames),
            diagnostics: diagnostics
        )

        // 6. Tree.
        let tree = TreeBuilder.build(model)

        // 7. Secret inventory.
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
            secretInventory: inventory,
            isUnifiOSBackup: isUnifiOSBackup
        )
    }

    // MARK: - Path A: per-collection .bson files

    private static func readPerCollectionBSON(
        entries: [String: Data],
        bsonEntryNames: [String],
        loadStatistics: Bool,
        diagnostics: DiagnosticSink
    ) -> CollectionStream.Output {
        let statPrefixes = ["stat_", "event_archive", "rogue"]
        var recordsByCollection: [String: [BSONDocument]] = [:]
        var orderedNames: [String] = []

        for entryName in bsonEntryNames {
            let collectionName = Self.collectionName(from: entryName)

            let isStatCollection = statPrefixes.contains { collectionName.hasPrefix($0) }
            if isStatCollection && !loadStatistics {
                continue
            }

            guard let data = entries[entryName] else { continue }

            let bsonData: Data
            if data.count >= 2, data[0] == 0x1f, data[1] == 0x8b {
                do { bsonData = try Gunzip.decompress(data) }
                catch {
                    diagnostics.emit(
                        .warning, .zipEntryUnreadable,
                        "Could not gunzip '\(entryName)': \(error). Skipping.",
                        collection: collectionName
                    )
                    continue
                }
            } else {
                bsonData = data
            }

            var docs: [BSONDocument] = []
            var reader = BSONReader(bsonData)
            while !reader.isAtEnd {
                let offset = reader.cursor
                do {
                    let doc = try reader.readDocument()
                    docs.append(doc)
                } catch {
                    diagnostics.emit(
                        .warning, .bsonMalformedDocument,
                        "BSON parse error in '\(entryName)' at offset \(offset): \(error). Remaining skipped.",
                        offset: offset,
                        collection: collectionName
                    )
                    break
                }
            }

            if !docs.isEmpty {
                recordsByCollection[collectionName] = docs
                orderedNames.append(collectionName)
            }
        }

        return CollectionStream.Output(
            recordsByCollection: recordsByCollection,
            orderedCollectionNames: orderedNames
        )
    }

    static func collectionName(from entryPath: String) -> String {
        let filename = (entryPath as NSString).lastPathComponent
        return (filename as NSString).deletingPathExtension
    }

    // MARK: - Helpers

    /// Checks if data starts with the ZIP local-file-header magic.
    private static func isPlainZip(_ data: Data) -> Bool {
        data.count >= 4
            && data[0] == 0x50 && data[1] == 0x4B
            && data[2] == 0x03 && data[3] == 0x04
    }
}
