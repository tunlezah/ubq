import Foundation

/// Structured, non-fatal parse feedback surfaced to the UI.
///
/// A `Diagnostic` is how the parser reports a recoverable problem (a malformed
/// BSON document, a truncated statistics stream, an unexpected collection) without
/// throwing all the way out. The caller accumulates these, renders them in a
/// Diagnostics panel, and the user can decide what to do.
///
/// For genuinely fatal problems (file isn't a `.unf`, decryption failed, no ZIP
/// header after decrypt), the loader throws a `FatalBackupError` instead.
public struct Diagnostic: Hashable, Sendable, Codable {
    public enum Severity: String, Hashable, Sendable, Codable {
        case info
        case warning
        case error
    }

    /// Stable machine-readable code. UI can branch on this; strings are for humans.
    public enum Code: String, Hashable, Sendable, Codable {
        // Container
        case zipRecoveryMode
        case zipEntryUnreadable
        case missingOptionalEntry
        case truncatedStatsStream

        // BSON
        case bsonLengthOverrun
        case bsonUnsupportedType
        case bsonMalformedDocument

        // Backup stream
        case unknownCollection
        case orphanedRecord          // record appeared before any collection marker

        // Identity
        case versionUnparseable
        case timestampUnparseable
        case formatUnparseable

        // Kind detection
        case siteExportDetected
        case settingsOnlyDetected

        // Generic
        case other
    }

    public let severity: Severity
    public let code: Code
    public let message: String
    /// Byte offset within the relevant stream, if applicable.
    public let offset: Int?
    /// Collection name, if applicable.
    public let collection: String?

    public init(
        severity: Severity,
        code: Code,
        message: String,
        offset: Int? = nil,
        collection: String? = nil
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.offset = offset
        self.collection = collection
    }
}

/// Thread-safe accumulator for diagnostics produced while parsing.
///
/// The parser runs on a background actor; the UI observes the final array after
/// parsing completes, so we do not need an observable stream here (add one later
/// if progressive rendering is desired).
public final class DiagnosticSink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Diagnostic] = []

    public init() {}

    public func emit(_ diagnostic: Diagnostic) {
        lock.lock()
        defer { lock.unlock() }
        items.append(diagnostic)
    }

    public func emit(
        _ severity: Diagnostic.Severity,
        _ code: Diagnostic.Code,
        _ message: String,
        offset: Int? = nil,
        collection: String? = nil
    ) {
        emit(
            Diagnostic(
                severity: severity,
                code: code,
                message: message,
                offset: offset,
                collection: collection
            )
        )
    }

    public func drain() -> [Diagnostic] {
        lock.lock()
        defer { lock.unlock() }
        let copy = items
        items.removeAll(keepingCapacity: false)
        return copy
    }

    public func snapshot() -> [Diagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Fatal errors — cannot even start to render the backup.
public enum FatalBackupError: Error, CustomStringConvertible, Sendable {
    /// The file is clearly not a UniFi Network `.unf` (wrong magic after decrypt,
    /// wrong file size invariants, or a detected `.unifi` / `.ubv` superset).
    case notAUniFiNetworkBackup(detail: String)

    /// AES decryption returned an OS error code.
    case decryptFailed(status: Int32)

    /// Ciphertext length isn't a multiple of 16 bytes.
    case truncatedAtBlockBoundary(actual: Int)

    /// Decrypted payload did not start with ZIP local-file-header magic.
    case notZip

    /// ZIP couldn't be read even in tolerant mode.
    case zipUnreadable(detail: String)

    /// The primary configuration stream (`db.gz`) is missing or corrupted beyond
    /// recovery. Without it we have nothing to show.
    case configurationDatabaseMissing(detail: String)

    /// Arbitrary I/O error.
    case io(String)

    public var description: String {
        switch self {
        case .notAUniFiNetworkBackup(let d): "Not a UniFi Network backup: \(d)"
        case .decryptFailed(let s): "Decryption failed with OS status \(s)"
        case .truncatedAtBlockBoundary(let n): "Ciphertext length \(n) is not a multiple of 16 bytes"
        case .notZip: "Decrypted payload is not a ZIP archive"
        case .zipUnreadable(let d): "ZIP unreadable: \(d)"
        case .configurationDatabaseMissing(let d): "Configuration database missing: \(d)"
        case .io(let d): "I/O error: \(d)"
        }
    }
}
