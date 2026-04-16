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
    public let format: Int?
    public let timestamp: Date?
    public let kind: Kind
    public let origin: Origin

    public init(
        version: String?,
        format: Int?,
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

    static func parseFormat(_ data: Data?, diagnostics: DiagnosticSink) -> Int? {
        guard let data else { return nil }
        guard let raw = String(data: data, encoding: .utf8) else {
            diagnostics.emit(.warning, .formatUnparseable, "`format` not valid UTF-8.")
            return nil
        }
        let cleaned = sanitise(raw)
        guard let value = Int(cleaned) else {
            diagnostics.emit(.warning, .formatUnparseable, "`format` not an integer: '\(cleaned)'.")
            return nil
        }
        return value
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
        let hasStats = entries.keys.contains { $0.hasSuffix("db_stat.gz") || $0 == "db_stat.gz" }
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
                "This is a settings-only export (no db_stat.gz present)."
            )
            return .settingsOnly
        }

        if hasSite { return .full }
        return .unknown
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
