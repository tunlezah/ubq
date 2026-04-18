import Foundation
import UniFiBSON
import Diagnostics

/// Walks the concatenated BSON stream emitted by UniFi inside `db.gz` /
/// `db_stat.gz`.
///
/// The stream is a sequence of BSON documents. The exact shape of
/// "collection marker" documents varies between controller versions and third-
/// party re-implementations describe it inconsistently. Our strategy:
///
/// * Look for documents whose shape strongly implies they are namespace
///   headers: tiny docs (≤4 fields) carrying fields like `collection`, `ns`,
///   `{db, collection}`, or `{namespace}` — any of which give us a new active
///   collection name.
/// * Anything else we emit under whatever collection is currently active.
/// * Records that appear before any identifiable marker are **not** dropped:
///   they are bucketed into a synthetic collection (`_uncategorized`) so the
///   UI can still show them. Surfacing data beats silently losing it.
/// * On the very first handful of "orphan" documents, we emit a sampling
///   diagnostic that dumps the document's keyset — this tells us (and the
///   user) what the real marker shape in their controller version looks like,
///   so the heuristic can be tightened in a follow-up.
public struct CollectionStream {
    public struct Record: Sendable {
        public let collection: String
        public let document: BSONDocument
        public init(collection: String, document: BSONDocument) {
            self.collection = collection
            self.document = document
        }
    }

    public struct Output: Sendable {
        public var recordsByCollection: [String: [BSONDocument]]
        public var orderedCollectionNames: [String]
        public init(recordsByCollection: [String: [BSONDocument]] = [:], orderedCollectionNames: [String] = []) {
            self.recordsByCollection = recordsByCollection
            self.orderedCollectionNames = orderedCollectionNames
        }
    }

    /// Bucket name used when no collection marker has been identified yet.
    public static let uncategorisedCollection = "_uncategorized"

    public static func readAll(
        _ data: Data,
        diagnostics: DiagnosticSink
    ) -> Output {
        var recordsByCollection: [String: [BSONDocument]] = [:]
        var order: [String] = []

        forEach(data, diagnostics: diagnostics) { record in
            if recordsByCollection[record.collection] == nil {
                recordsByCollection[record.collection] = []
                order.append(record.collection)
            }
            recordsByCollection[record.collection, default: []].append(record.document)
        }

        return Output(recordsByCollection: recordsByCollection, orderedCollectionNames: order)
    }

    public static func forEach(
        _ data: Data,
        diagnostics: DiagnosticSink,
        handler: (Record) -> Void
    ) {
        var reader = BSONReader(data)
        var currentCollection: String? = nil

        // When the marker heuristic fails, sample a couple of orphaned docs'
        // keysets so bug reports can tighten the detector. Suppressed entirely
        // on clean parses.
        var orphanFingerprintsEmitted = 0
        let orphanFingerprintBudget = 2

        while !reader.isAtEnd {
            let docStart = reader.cursor
            do {
                let doc = try reader.readDocument()

                if let name = detectMarker(doc) {
                    currentCollection = name
                    continue
                }

                let coll = currentCollection ?? Self.uncategorisedCollection
                if currentCollection == nil {
                    if orphanFingerprintsEmitted == 0 {
                        diagnostics.emit(
                            .warning,
                            .orphanedRecord,
                            "No collection marker recognised yet; records routed to '\(Self.uncategorisedCollection)'.",
                            offset: docStart
                        )
                    }
                    if orphanFingerprintsEmitted < orphanFingerprintBudget {
                        diagnostics.emit(
                            .info,
                            .other,
                            "Orphan BSON doc @\(docStart): keys=\(doc.keys.prefix(8).joined(separator: ","))\(doc.keys.count > 8 ? ",…" : "")",
                            offset: docStart
                        )
                        orphanFingerprintsEmitted += 1
                    }
                }
                handler(Record(collection: coll, document: doc))
            } catch let err as BSONParseError {
                let message: String
                switch err {
                case .invalidLength(let l, _):
                    message = "BSON length \(l) at offset \(docStart) is implausible; aborting stream."
                case .unexpectedEOF:
                    message = "Unexpected end of stream at offset \(docStart); aborting."
                case .malformed(let reason, _):
                    message = "Malformed BSON at offset \(docStart): \(reason)."
                case .invalidUTF8:
                    message = "Invalid UTF-8 in BSON at offset \(docStart)."
                case .unterminatedCString:
                    message = "Unterminated cstring in BSON at offset \(docStart)."
                }
                diagnostics.emit(
                    .error,
                    .bsonMalformedDocument,
                    message,
                    offset: docStart,
                    collection: currentCollection
                )
                return
            } catch {
                diagnostics.emit(
                    .error,
                    .bsonMalformedDocument,
                    "Unexpected error reading BSON at offset \(docStart): \(error).",
                    offset: docStart,
                    collection: currentCollection
                )
                return
            }
        }
    }

    /// Returns a collection name if the document plausibly identifies one.
    ///
    /// Known marker shapes in the wild:
    ///   * `{ collection: "name" }`                           — most common
    ///   * `{ __cmd: "select", collection: "name" }`          — some older controllers
    ///   * `{ db: "ace", collection: "name" }`                — mongodump metadata
    ///   * `{ ns: "ace.name" }`                               — mongo operation-log
    ///   * `{ namespace: "ace.name" }`                        — alternate form
    ///
    /// Only small header-style documents are considered (≤4 fields) — real
    /// data records are not confused with markers.
    public static func detectMarker(_ doc: BSONDocument) -> String? {
        guard doc.count >= 1 && doc.count <= 4 else { return nil }

        if let name = doc["collection"]?.stringValue, !name.isEmpty {
            return name
        }
        if let ns = doc["ns"]?.stringValue, !ns.isEmpty {
            let afterDot = String(ns.split(separator: ".").dropFirst().joined(separator: "."))
            return afterDot.isEmpty ? ns : afterDot
        }
        if let ns = doc["namespace"]?.stringValue, !ns.isEmpty {
            let afterDot = String(ns.split(separator: ".").dropFirst().joined(separator: "."))
            return afterDot.isEmpty ? ns : afterDot
        }
        return nil
    }
}
