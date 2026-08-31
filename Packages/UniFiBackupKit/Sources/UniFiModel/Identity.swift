import Foundation
import Diagnostics

/// Controller / backup identity, derived from the `version`, `format`,
/// `timestamp`, and `system.properties` entries of the decrypted ZIP plus the
/// presence or absence of certain collections.
public struct Identity: Hashable, Sendable, Codable {
    /// What kind of backup this file represents.
    public enum Kind: String, Hashable, Sendable, Codable {
        case full
        case settingsOnly
        case siteExport
        case unknown
    }

    /// Origin hint inferred from `system.properties` paths.
    public enum Origin: String, Hashable, Sendable, Codable {
        case selfHostedLinux
        case selfHostedMac
        case selfHostedWindows
        case cloudKey
        case unifiOS
        case unknown
    }

    public let version: String?
    /// Raw contents of the `format` entry in the ZIP. Often an integer string
    /// (e.g. `"7"`, `"8"`) on older controllers; some versions use a label
    /// like `"bson"`. Stored as-is so the UI can display whatever's there.
    public let format: String?
    public let timestamp: Date?
    public let kind: Kind
    public let origin: Origin

    public init(
        version: String?,
        format: String?,
        timestamp: Date?,
        kind: Kind,
        origin: Origin
    ) {
        self.version = version
        self.format = format
        self.timestamp = timestamp
        self.kind = kind
        self.origin = origin
    }

    /// Parse identity from decrypted-zip entries. Populates diagnostics for
    /// any unparseable fields without throwing.
    public static func parse(
        entries: [String: Data],
        collectionNames: Set<String>,
        diagnostics: DiagnosticSink
    ) -> Identity {
        let version = parseVersion(entries["version"], diagnostics: diagnostics)
        let format = parseFormat(entries["format"], diagnostics: diagnostics)
        let timestamp = parseTimestamp(entries["timestamp"], diagnostics: diagnostics)
        let origin = parseOrigin(entries["system.properties"])
        let kind = detectKind(
            entries: entries,
            collectionNames: collectionNames,
            diagnostics: diagnostics
        )
        return Identity(
            version: version,
            format: format,
            timestamp: timestamp,
            kind: kind,
            origin: origin
        )
    }

    // MARK: - Field parsers

    static func parseVersion(_ data: Data?, diagnostics: DiagnosticSink) -> String? {
        guard let data else { return nil }
        guard let raw = String(data: data, encoding: .utf8) else {
            diagnostics.emit(.warning, .versionUnparseable, "`version` not valid UTF-8.")
            return nil
        }
        let cleaned = sanitise(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func parseFormat(_ data: Data?, diagnostics: DiagnosticSink) -> String? {
        guard let data else { return nil }
        guard let raw = String(data: data, encoding: .utf8) else {
            diagnostics.emit(.warning, .formatUnparseable, "`format` not valid UTF-8.")
            return nil
        }
        let cleaned = sanitise(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func parseTimestamp(_ data: Data?, diagnostics: DiagnosticSink) -> Date? {
        guard let data else { return nil }
        guard let raw = String(data: data, encoding: .utf8) else {
            diagnostics.emit(.warning, .timestampUnparseable, "`timestamp` not valid UTF-8.")
            return nil
        }
        let cleaned = sanitise(raw)
        if let ms = Int64(cleaned) {
            return Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: cleaned) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: cleaned) { return d }
        diagnostics.emit(.warning, .timestampUnparseable, "`timestamp` not epoch-ms or ISO-8601: '\(cleaned)'.")
        return nil
    }

    static func parseOrigin(_ data: Data?) -> Origin {
        guard let data, let text = String(data: data, encoding: .utf8) else {
            return .unknown
        }
        let lower = text.lowercased()
        if lower.contains("/data/unifi") { return .cloudKey }
        if lower.contains("/usr/lib/unifi") || lower.contains("/var/lib/unifi") { return .selfHostedLinux }
        if lower.contains("c:\\") || lower.contains("c:/") || lower.contains("ubiquiti unifi") { return .selfHostedWindows }
        if lower.contains("applications/unifi.app") || lower.contains("/library/application support/unifi") { return .selfHostedMac }
        if lower.contains("unifi.os") || lower.contains("ucore") { return .unifiOS }
        return .unknown
    }

    static func detectKind(
        entries: [String: Data],
        collectionNames: Set<String>,
        diagnostics: DiagnosticSink
    ) -> Kind {
        let hasStats = statsPresent(entries: entries, collectionNames: collectionNames)
        let hasAdmin = collectionNames.contains("admin")
        let hasAccount = collectionNames.contains("account")
        let hasSite = collectionNames.contains("site")

        if hasSite && !hasAdmin && !hasAccount {
            diagnostics.emit(
                .info,
                .siteExportDetected,
                "This looks like a site export (single site, no controller-level collections)."
            )
            return .siteExport
        }

        if !hasStats && hasSite {
            diagnostics.emit(
                .info,
                .settingsOnlyDetected,
                "This is a settings-only export (no statistics collections or files present)."
            )
            return .settingsOnly
        }

        if hasSite { return .full }
        return .unknown
    }

    /// Whether the backup carries any statistics, keyed off ZIP *entry names*
    /// (which are present even when the stats streams are never decompressed) as
    /// well as any loaded stat collections.
    ///
    /// Per-collection `.bson` full backups contain no `db_stat.gz`, so relying on
    /// that single file misclassified them as settings-only. Treat any of the
    /// following as a statistics-presence signal:
    ///   * an entry whose basename is `db_stat.gz`,
    ///   * an entry whose basename starts with `stat_` and ends `.bson`,
    ///   * an entry whose basename starts with `event_archive` and ends `.bson`,
    ///   * any loaded collection name starting with `stat_`.
    static func statsPresent(
        entries: [String: Data],
        collectionNames: Set<String>
    ) -> Bool {
        let entrySignal = entries.keys.contains { key in
            let base = basename(key)
            if base == "db_stat.gz" { return true }
            if base.hasPrefix("stat_") && base.hasSuffix(".bson") { return true }
            if base.hasPrefix("event_archive") && base.hasSuffix(".bson") { return true }
            return false
        }
        if entrySignal { return true }
        return collectionNames.contains { $0.hasPrefix("stat_") }
    }

    /// Last path component of a (possibly `/`-separated) ZIP entry name.
    static func basename(_ path: String) -> String {
        if let slash = path.lastIndex(of: "/") {
            return String(path[path.index(after: slash)...])
        }
        return path
    }

    // Strip BOM, CRLF, surrounding whitespace.
    static func sanitise(_ raw: String) -> String {
        var s = raw
        if s.first == "\u{FEFF}" { s.removeFirst() }
        return s.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.controlCharacters)
        )
    }
}
