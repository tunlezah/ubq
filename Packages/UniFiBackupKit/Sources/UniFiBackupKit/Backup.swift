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
    /// True when this backup was extracted from a `.unifi` superset container
    /// (either the plain-ZIP shapes or the AES-256 console shape).
    public let isUnifiOSBackup: Bool
    /// True when the file is a `.supp` support bundle: it decrypted to a ZIP
    /// with no Network configuration database, so `model`/`tree` are empty and
    /// only the raw archive entries are exposed for browsing.
    public let isSupportBundle: Bool
    /// True for the AES-256 `gzip → tar` UniFi OS **console** backup shape
    /// (distinct from the plain-ZIP `.unifi` shapes, which also set
    /// `isUnifiOSBackup`).
    public let isUnifiOSConsoleBackup: Bool
    /// Human-readable summary of container-level handling, when notable — e.g.
    /// "UniFi OS console backup — Network payload extracted; UCore Postgres
    /// dump present but not parsed".
    public let containerNote: String?

    // MARK: - Public API

    /// Load a `.unf` or `.unifi` file into a fully-parsed `Backup`.
    public static func open(
        url: URL,
        loadStatistics: Bool = false
    ) throws -> Backup {
        let raw = try Data(contentsOf: url)
        return try load(sourceURL: url, rawFileData: raw, loadStatistics: loadStatistics)
    }

    /// Load from in-memory bytes. Handles every documented container shape.
    ///
    /// Detection ordering (see `/ROADMAP.md` §3.3):
    ///   1. `PK\x03\x04` at byte 0 → plain-ZIP `.unifi` (embedded `.unf` or
    ///      inline Network payload).
    ///   2. Trial **AES-128** decrypt → ZIP → `.unf` path (also `.supp`
    ///      support bundles, which share the AES-128 key/IV).
    ///   3. Trial **AES-256** decrypt (IV = first 16 bytes) → `gzip → tar` →
    ///      UniFi OS console `.unifi`.
    public static func load(
        sourceURL: URL? = nil,
        rawFileData: Data,
        loadStatistics: Bool = false
    ) throws -> Backup {
        // Step 1: plain-ZIP `.unifi`.
        if isPlainZip(rawFileData) {
            return try loadUnifiOS(
                sourceURL: sourceURL,
                outerZipData: rawFileData,
                loadStatistics: loadStatistics
            )
        }

        // Step 2: AES-128 `.unf` / `.supp`.
        if let plaintext = try? UnfCipher.decrypt(rawFileData) {
            return try parsePlaintextZip(
                sourceURL: sourceURL,
                plaintext: plaintext,
                loadStatistics: loadStatistics,
                isUnifiOSBackup: false,
                diagnostics: DiagnosticSink()
            )
        }

        // Step 3: AES-256 UniFi OS console container. Only attempted for
        // `.unifi` (or when the extension is absent — e.g. raw bytes with no
        // URL); a `.unf` that failed step 2 should surface its own decrypt
        // error instead of being mislabelled a console backup.
        let ext = sourceURL?.pathExtension.lowercased()
        if ext == "unifi" || ext == nil || ext == "" {
            return try loadUnifiOSConsole(
                sourceURL: sourceURL,
                rawFileData: rawFileData,
                loadStatistics: loadStatistics
            )
        }

        // Otherwise reproduce the specific AES-128 failure (meaningful for
        // a genuinely corrupt `.unf`).
        return try loadUnf(
            sourceURL: sourceURL,
            ciphertext: rawFileData,
            loadStatistics: loadStatistics,
            isUnifiOSBackup: false
        )
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
    ///
    /// Reuses the already-decrypted ZIP entries cached on `self` (`rawEntries`)
    /// so it does **not** re-read the file from disk or re-run AES — it simply
    /// re-parses the cached plaintext with statistics enabled.
    public func loadingStatistics() throws -> Backup {
        if statsLoaded { return self }

        if !rawEntries.isEmpty {
            let diagnostics = DiagnosticSink()
            return try Backup.parseDecryptedZip(
                sourceURL: sourceURL,
                entries: rawEntries,
                loadStatistics: true,
                isUnifiOSBackup: isUnifiOSBackup,
                diagnostics: diagnostics,
                isUnifiOSConsoleBackup: isUnifiOSConsoleBackup,
                containerNote: containerNote
            )
        }

        // Fallback for Backups constructed without cached entries.
        guard let url = sourceURL, let raw = try? Data(contentsOf: url) else { return self }
        return try Backup.load(sourceURL: url, rawFileData: raw, loadStatistics: true)
    }

    // MARK: - .unifi (UniFi OS System Config Backup — plain ZIP shapes)

    /// `.unifi` files are **plain (unencrypted) ZIPs** in the two shapes handled
    /// here. Two shapes exist in the wild:
    ///
    ///   1. Older UniFi OS builds wrap a nested AES-encrypted `.unf` plus
    ///      UCore Postgres + per-app configs.
    ///   2. Newer UniFi OS builds (2025+) inline the Network payload directly:
    ///      the outer ZIP contains `db.gz`, `version`, `format`, `timestamp`,
    ///      `system.properties`, and optionally `backup.json` — the same
    ///      entries that would appear *inside* a decrypted `.unf`. No
    ///      encryption layer at all.
    ///
    /// (The AES-256 `gzip → tar` console shape is handled separately by
    /// `loadUnifiOSConsole`.)
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

    // MARK: - .unifi (UniFi OS console — AES-256 → gzip → tar)

    /// Console-generated `.unifi` files are **AES-256-CBC, NoPadding, with the
    /// IV prepended** as the first 16 bytes; the plaintext is `gzip → tar`
    /// (ustar / GNU long name). The tar carries `backup/metadata.json`,
    /// `backup/network/` (an inline Network payload: `version`, `timestamp`,
    /// `system.properties`, `db.gz`) and `backup/ucore/database/` (a PostgreSQL
    /// `pg_dump` directory-format dump we keep raw but do not parse).
    ///
    /// The 32-byte AES-256 key is a placeholder pending verification
    /// (`UnfCipher.unifiOSKey256Verified`); while unverified this method
    /// *detects the shape* and reports a clear, actionable error rather than
    /// decrypting with bogus bytes or failing generically.
    private static func loadUnifiOSConsole(
        sourceURL: URL?,
        rawFileData: Data,
        loadStatistics: Bool
    ) throws -> Backup {
        // Shape precondition: IV(16) + ciphertext(multiple of 16) ⇒ total ≥ 32
        // and a multiple of 16.
        guard rawFileData.count >= 32, rawFileData.count % 16 == 0 else {
            throw FatalBackupError.notAUniFiNetworkBackup(
                detail: "Not a plain `.unifi` ZIP, an AES-128 `.unf`, nor an AES-256 console backup (unexpected length \(rawFileData.count))."
            )
        }

        guard UnfCipher.unifiOSKey256Verified else {
            throw FatalBackupError.notAUniFiNetworkBackup(
                detail: "UniFi OS console backup detected (AES-256 tar); decryption key pending verification. The 32-byte AES-256 key (EvilBit-Labs/unifi_extract DECRYPTION.md; see ROADMAP §3.3 and UnfCipher.unifiOSKey256) must be verified against a real console file before this shape can be opened."
            )
        }

        let diagnostics = DiagnosticSink()
        diagnostics.emit(
            .info, .other,
            "Detected UniFi OS console backup (.unifi AES-256 tar container)."
        )

        // 1. AES-256-CBC, IV = first 16 bytes.
        let plaintext: Data
        do {
            plaintext = try UnfCipher.decryptAES256CBC(
                rawFileData,
                key: UnfCipher.unifiOSKey256,
                ivPrepended: true
            )
        } catch {
            throw FatalBackupError.notAUniFiNetworkBackup(
                detail: "UniFi OS console AES-256 decrypt failed: \(error)"
            )
        }

        // 2. Expect a gzip stream.
        guard plaintext.count >= 2, plaintext[plaintext.startIndex] == 0x1f,
              plaintext[plaintext.startIndex + 1] == 0x8b else {
            throw FatalBackupError.notAUniFiNetworkBackup(
                detail: "UniFi OS console AES-256 decrypt did not yield a gzip stream (expected 1f 8b)."
            )
        }
        let tarBytes: Data
        do {
            tarBytes = try Gunzip.decompress(plaintext)
        } catch {
            throw FatalBackupError.notAUniFiNetworkBackup(
                detail: "UniFi OS console gzip payload could not be inflated: \(error)"
            )
        }

        // 3. Tar walk.
        let tar = TarReader(tarBytes)
        for d in tar.diagnostics { diagnostics.emit(d) }
        guard !tar.entries.isEmpty else {
            throw FatalBackupError.notAUniFiNetworkBackup(
                detail: "UniFi OS console tar contained no readable entries."
            )
        }

        // 4. Split backup/network/* (the inline Network payload) from the rest
        //    (metadata.json, ucore/…), which we keep raw for browsing.
        var networkEntries: [String: Data] = [:]
        var extraRaw: [String: Data] = [:]
        var hasUCore = false
        var hasMetadata = false
        let networkPrefix = "backup/network/"
        for entry in tar.entries {
            if entry.name.hasPrefix(networkPrefix) {
                let leaf = String(entry.name.dropFirst(networkPrefix.count))
                if !leaf.isEmpty, !leaf.hasSuffix("/"), !leaf.contains("/") {
                    networkEntries[leaf] = entry.data
                } else if !leaf.isEmpty, !leaf.hasSuffix("/") {
                    // Nested network asset (e.g. sites/…): keep raw under full path.
                    extraRaw[entry.name] = entry.data
                }
            } else {
                if entry.name.hasPrefix("backup/ucore/") { hasUCore = true }
                if entry.name == "backup/metadata.json" { hasMetadata = true }
                extraRaw[entry.name] = entry.data
            }
        }

        let allNames = tar.entries.map { $0.name }.sorted()
        diagnostics.emit(
            .info, .other,
            "Console tar entries: \(allNames.prefix(30).joined(separator: ", "))\(allNames.count > 30 ? ", …" : "")"
        )
        if hasMetadata {
            diagnostics.emit(.info, .other, "Console container carries backup/metadata.json (kept raw for browsing).")
        }
        if hasUCore {
            diagnostics.emit(.info, .other, "Console container carries a UCore PostgreSQL pg_dump under backup/ucore/ — kept raw (not parsed).")
        }

        guard !networkEntries.isEmpty else {
            throw FatalBackupError.notAUniFiNetworkBackup(
                detail: "UniFi OS console tar had no backup/network/ payload. Entries: \(allNames.joined(separator: ", "))"
            )
        }

        var note = "UniFi OS console backup — Network payload extracted"
        if hasUCore { note += "; UCore Postgres dump present but not parsed" }

        return try parseDecryptedZip(
            sourceURL: sourceURL,
            entries: networkEntries,
            loadStatistics: loadStatistics,
            isUnifiOSBackup: true,
            diagnostics: diagnostics,
            isUnifiOSConsoleBackup: true,
            containerNote: note,
            extraRawEntries: extraRaw
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

    /// True if a decrypted ZIP looks like a `.supp` support bundle: no Network
    /// configuration database (`db.gz` / `.bson`), but `support_info.json`
    /// and/or `system.properties` beside a `devices/` tree.
    private static func isSupportBundleLayout(_ entries: [String: Data]) -> Bool {
        if entries["support_info.json"] != nil { return true }
        if entries["system.properties"] != nil,
           entries.keys.contains(where: { $0.hasPrefix("devices/") }) {
            return true
        }
        return false
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

        return try parsePlaintextZip(
            sourceURL: sourceURL,
            plaintext: plaintext,
            loadStatistics: loadStatistics,
            isUnifiOSBackup: isUnifiOSBackup,
            diagnostics: diagnostics
        )
    }

    /// Reads the tolerant ZIP out of already-decrypted plaintext and hands the
    /// flat entries to `parseDecryptedZip`.
    private static func parsePlaintextZip(
        sourceURL: URL?,
        plaintext: Data,
        loadStatistics: Bool,
        isUnifiOSBackup: Bool,
        diagnostics: DiagnosticSink
    ) throws -> Backup {
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
    /// Used by both `.unf` (post-decrypt) and `.unifi` (inline / console).
    ///
    /// - Parameters:
    ///   - entries: The entries to *parse* (the Network payload).
    ///   - extraRawEntries: Sibling container files (e.g. `backup/metadata.json`,
    ///     `backup/ucore/…`) that are exposed in `rawEntries` for browsing but
    ///     not parsed. Merged into the exposed entries; parsing runs over
    ///     `entries` only.
    private static func parseDecryptedZip(
        sourceURL: URL?,
        entries: [String: Data],
        loadStatistics: Bool,
        isUnifiOSBackup: Bool,
        diagnostics: DiagnosticSink,
        isUnifiOSConsoleBackup: Bool = false,
        containerNote: String? = nil,
        extraRawEntries: [String: Data] = [:]
    ) throws -> Backup {
        // Everything we expose for browsing: the parsed Network entries plus any
        // sibling container files kept raw.
        var browseEntries = entries
        for (name, data) in extraRawEntries where browseEntries[name] == nil {
            browseEntries[name] = data
        }

        var sizes: [String: Int] = [:]
        for (name, data) in browseEntries {
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
        var isSupportBundle = false

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
        } else if isSupportBundleLayout(entries) {
            // Path C: `.supp` support bundle — no Network configuration DB.
            diagnostics.emit(
                .info, .other,
                "UniFi support bundle (.supp) detected — no configuration database; showing archive contents."
            )
            isSupportBundle = true
            combinedOutput = CollectionStream.Output()
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
            entryNames: browseEntries.keys.sorted(),
            rawEntries: browseEntries,
            statsLoaded: statsLoaded,
            entrySizes: sizes,
            secretInventory: inventory,
            isUnifiOSBackup: isUnifiOSBackup,
            isSupportBundle: isSupportBundle,
            isUnifiOSConsoleBackup: isUnifiOSConsoleBackup,
            containerNote: containerNote
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
            if data.count >= 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b {
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
        guard data.count >= 4 else { return false }
        let s = data.startIndex
        return data[s] == 0x50 && data[s + 1] == 0x4B
            && data[s + 2] == 0x03 && data[s + 3] == 0x04
    }
}
