import XCTest
@testable import BackupStream
import UniFiBSON
import Diagnostics

final class CollectionStreamTests: XCTestCase {

    func testHappyPathWithMarkers() {
        var stream = Data()
        let w = BSONWriter()

        stream.append(w.write(doc([("collection", .string("site"))])))
        stream.append(w.write(doc([("_id", .string("s1")), ("name", .string("default"))])))
        stream.append(w.write(doc([("_id", .string("s2")), ("name", .string("branch"))])))
        stream.append(w.write(doc([("collection", .string("device"))])))
        stream.append(w.write(doc([("_id", .string("d1")), ("mac", .string("aa:bb"))])))

        let sink = DiagnosticSink()
        let out = CollectionStream.readAll(stream, diagnostics: sink)

        XCTAssertEqual(out.orderedCollectionNames, ["site", "device"])
        XCTAssertEqual(out.recordsByCollection["site"]?.count, 2)
        XCTAssertEqual(out.recordsByCollection["device"]?.count, 1)
        XCTAssertTrue(sink.snapshot().isEmpty, "happy path should emit no diagnostics")
    }

    func testOrphanedRecordEmitsDiagnostic() {
        var stream = Data()
        let w = BSONWriter()
        // Record without any preceding collection marker.
        stream.append(w.write(doc([("_id", .string("orphan"))])))
        stream.append(w.write(doc([("collection", .string("site"))])))
        stream.append(w.write(doc([("_id", .string("s1"))])))

        let sink = DiagnosticSink()
        let out = CollectionStream.readAll(stream, diagnostics: sink)

        XCTAssertEqual(out.orderedCollectionNames, ["site"])
        XCTAssertEqual(out.recordsByCollection["site"]?.count, 1)
        let diags = sink.snapshot()
        XCTAssertEqual(diags.count, 1)
        XCTAssertEqual(diags.first?.code, .orphanedRecord)
    }

    func testMalformedDocumentStopsStreamWithDiagnostic() {
        var stream = Data()
        let w = BSONWriter()
        stream.append(w.write(doc([("collection", .string("site"))])))
        stream.append(w.write(doc([("_id", .string("s1"))])))
        // Inject a plainly-bogus "length" header.
        stream.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0x00])

        let sink = DiagnosticSink()
        let out = CollectionStream.readAll(stream, diagnostics: sink)

        XCTAssertEqual(out.recordsByCollection["site"]?.count, 1)
        let diags = sink.snapshot()
        XCTAssertTrue(diags.contains { $0.code == .bsonMalformedDocument })
    }

    private func doc(_ pairs: [(String, BSONValue)]) -> BSONDocument {
        var d = BSONDocument()
        for (k, v) in pairs { d[k] = v }
        return d
    }
}
