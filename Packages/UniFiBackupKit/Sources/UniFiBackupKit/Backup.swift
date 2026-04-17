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

        var entries: [String: Data] = [:]
        var sizes: [String: Int] = [:]
        for (name, entry) in zip.entries {
            entries[name] = entry.data
            sizes[name] = entry.data.count
        }

        diagnostics.emit(
            .info,
            .other,
            "ZIP entries: \(entries.keys.sorted().joined(separator: ", "))"
        )

        // 3. Detect backup layout and parse accordingly.
        //
        // Two known layouts:
        //
        // A) "bson" format (modern controllers, ~2024+):
        //    ZIP contains individual `.bson` files, one per collection.
        //    The filename (without extension, without directory prefix) IS
        //    the collection name. May also contain `.bson` files under
        //    subdirectories like `db/` or `ace/`.
        //
        // B) Legacy "db.gz" format (older controllers):
        //    ZIP contains `db.gz` — a single gzipped concatenated BSON
        //    stream with collection-marker documents separating logical
        //    collections. Also `db_stat.gz` for statistics.
        //
        // We detect by: presence of *.bson entries → path A; else → path B.

        let bsonEntryNames = entries.keys.filter { name in
            name.hasSuffix(".bson") && !name.hasPrefix("__MACOSX")
        }.sorted()

        var combinedOutput: CollectionStream.Output
        var warnings: [String] = []
        var statsLoaded = false

        if !bsonEntryNames.isEmpty {
            // ── Path A: per-collection .bson files ──
            diagnostics.emit(
                .info,
                .other,
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
            // ── Path B: single-stream db.gz ──
            diagnostics.emit(
                .info,
                .other,
                "Detected single-stream db.gz layout (legacy). Attempting marker-based collection splitting."
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
                        .warning,
                        .truncatedStatsStream,
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

        // 4. Map to strongly-typed model + opaque fallback.
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
            secretInventory: inventory
        )
    }

    // MARK: - Path A: per-collection .bson files

    /// Newer backups (format="bson") store each MongoDB collection as a
    /// separate `.bson` file. The filename (minus extension, minus any
    /// directory prefix) is the collection name. Each file is a
    /// concatenation of BSON documents for that collection.
    ///
    /// Some known subdirectory patterns:
    ///   `device.bson`              → collection "device"
    ///   `db/device.bson`           → collection "device"
    ///   `ace/device.bson`          → collection "device"
    ///   `db/ace/device.bson`       → collection "device"
    ///   `db_stat/stat_hourly.bson` → collection "stat_hourly" (stats)
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
                diagnostics.emit(
                    .info,
                    .other,
                    "Skipping statistics collection '\(collectionName)' (opt-in).",
                    collection: collectionName
                )
                continue
            }

            guard let data = entries[entryName] else { continue }

            // Each .bson file may be gzipped or raw.
            let bsonData: Data
            if data.count >= 2, data[0] == 0x1f, data[1] == 0x8b {
                do {
                    bsonData = try Gunzip.decompress(data)
                } catch {
                    diagnostics.emit(
                        .warning,
                        .zipEntryUnreadable,
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
                        .warning,
                        .bsonMalformedDocument,
                        "BSON parse error in '\(entryName)' at offset \(offset): \(error). Remaining documents skipped.",
                        offset: offset,
                        collection: collectionName
                    )
                    break
                }
            }

            if !docs.isEmpty {
                recordsByCollection[collectionName] = docs
                orderedNames.append(collectionName)
                diagnostics.emit(
                    .info,
                    .other,
                    "Collection '\(collectionName)': \(docs.count) records from '\(entryName)'.",
                    collection: collectionName
                )
            }
        }

        return CollectionStream.Output(
            recordsByCollection: recordsByCollection,
            orderedCollectionNames: orderedNames
        )
    }

    /// Derive a MongoDB collection name from a ZIP entry path.
    ///
    ///   `device.bson`             → `device`
    ///   `db/device.bson`          → `device`
    ///   `ace/device.bson`         → `device`
    ///   `db/ace/device.bson`      → `device`
    ///   `db_stat/stat_hourly.bson` → `stat_hourly`
    static func collectionName(from entryPath: String) -> String {
        let filename = (entryPath as NSString).lastPathComponent
        let name = (filename as NSString).deletingPathExtension
        return name
    }

    /// Returns a copy of this backup with statistics now loaded.
    public func loadingStatistics() throws -> Backup {
        guard let ciphertext = sourceURL.flatMap({ try? Data(contentsOf: $0) }) else {
            return self
        }
        return try Backup.load(sourceURL: sourceURL, ciphertext: ciphertext, loadStatistics: true)
    }
}
