import Foundation

/// Small, constantly-needed guidance derived purely from a backup's `Identity`
/// and its site count. Encodes the ROADMAP §3.2 restore rules:
///
/// * A backup restores only into a UniFi Network version **equal to or newer**
///   than the one that produced it — forward-only schema migration, no
///   downgrade path.
/// * Importing a full-controller backup into a UniFi OS console silently
///   restores only the Default site.
///
/// Pure value logic; no I/O. Handles missing / odd version strings gracefully.
public struct RestoreAdvisor: Sendable {

    public struct Advice: Sendable, Hashable {
        public let backupVersion: String?
        /// Equal to `backupVersion` — restores are forward-only.
        public let minimumRestoreVersion: String?
        public let messages: [String]
        public let warnings: [String]
        public init(
            backupVersion: String?,
            minimumRestoreVersion: String?,
            messages: [String],
            warnings: [String]
        ) {
            self.backupVersion = backupVersion
            self.minimumRestoreVersion = minimumRestoreVersion
            self.messages = messages
            self.warnings = warnings
        }
    }

    public static func advise(identity: Identity, siteCount: Int) -> Advice {
        let version = identity.version.flatMap { v -> String? in
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        var messages: [String] = []
        var warnings: [String] = []

        if let v = version {
            messages.append("Restores into UniFi Network \u{2265} \(v).")
            messages.append("Will NOT restore into versions older than \(v) — upgrade the target controller first (migration is forward-only; there is no downgrade path).")
        } else {
            messages.append("Backup version is unknown, so the exact minimum restore version can't be determined.")
            messages.append("Restore only into a controller running the same or a newer UniFi Network version than the one that produced this backup — migration is forward-only.")
        }

        switch identity.kind {
        case .full:
            messages.append("This is a full controller backup.")
        case .settingsOnly:
            messages.append("This is a settings-only backup (no statistics database).")
        case .siteExport:
            messages.append("This is a single-site export; it imports one site into an existing controller.")
        case .unknown:
            break
        }

        if siteCount > 1 {
            warnings.append("Importing into a UniFi OS console restores only the Default site (\(siteCount) sites in this backup); the others will not be imported.")
        }

        return Advice(
            backupVersion: version,
            minimumRestoreVersion: version,
            messages: messages,
            warnings: warnings
        )
    }
}
