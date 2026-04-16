import Foundation
import UniFiBSON
import Diagnostics

/// Walks the concatenated BSON stream emitted by UniFi inside `db.gz` /
/// `db_stat.gz`.
///
/// The stream is a sequence of BSON documents. Every time a document with the
/// single field `collection` is seen, subsequent documents belong to that
/// logical collection. The very first document in `db.gz` is always such a
/// marker.
public struct CollectionStream {
    public struct Record: Sendable {
        public let collection: String
        public let document: BSONDocument
    }

    public struct Output: Sendable {
        public var recordsByCollection: [String: [BSONDocument]]
        public var orderedCollectionNames: [String]
    }

    /// Reads the whole stream into memory, organised by collection.
    ///
    /// For `db_stat.gz` (potentially hundreds of MB) prefer
    /// `forEach(_:diagnostics:)` to stream one record at a time.
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

    /// Streams one record at a time. Errors emitted as diagnostics; the stream
    /// continues after attempting to resync.
    public static func forEach(
        _ data: Data,
        diagnostics: DiagnosticSink,
        handler: (Record) -> Void
    ) {
        var reader = BSONReader(data)
        var currentCollection: String? = nil

        while !reader.isAtEnd {
            let docStart = reader.cursor
            do {
                let doc = try reader.readDocument()
                if isCollectionMarker(doc), let name = doc["collection"]?.stringValue {
                    currentCollection = name
                } else {
                    guard let coll = currentCollection else {
                        diagnostics.emit(
                            .warning,
                            .orphanedRecord,
                            "Record at offset \(docStart) appeared before any collection marker; skipping.",
                            offset: docStart
                        )
                        continue
                    }
                    handler(Record(collection: coll, document: doc))
                }
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

    private static func isCollectionMarker(_ doc: BSONDocument) -> Bool {
        doc.count == 1 && doc.keys.first == "collection"
    }
}
