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

        // Happy path: no warnings, no errors. Info-level fingerprint
        // diagnostics for the first few docs are OK and expected.
        let diags = sink.snapshot()
        let warningsOrErrors = diags.filter { $0.severity != .info }
        XCTAssertTrue(warningsOrErrors.isEmpty,
                      "happy path should emit no warnings/errors, got: \(warningsOrErrors)")
    }

    func testOrphanedRecordsRouteToUncategorised() {
        var stream = Data()
        let w = BSONWriter()
        // Record without any preceding collection marker.
        stream.append(w.write(doc([("_id", .string("orphan"))])))
        stream.append(w.write(doc([("collection", .string("site"))])))
        stream.append(w.write(doc([("_id", .string("s1"))])))

        let sink = DiagnosticSink()
        let out = CollectionStream.readAll(stream, diagnostics: sink)

        // Orphan records are routed to the synthetic `_uncategorized`
        // collection rather than silently dropped. The subsequent marker
        // switches to "site" as normal.
        XCTAssertEqual(
            Set(out.orderedCollectionNames),
            Set([CollectionStream.uncategorisedCollection, "site"])
        )
        XCTAssertEqual(
            out.recordsByCollection[CollectionStream.uncategorisedCollection]?.count,
            1
        )
        XCTAssertEqual(out.recordsByCollection["site"]?.count, 1)

        // At least one orphanedRecord warning must be emitted alongside the
        // info-level fingerprint diagnostics.
        let diags = sink.snapshot()
        XCTAssertTrue(
            diags.contains { $0.code == .orphanedRecord },
            "expected at least one orphanedRecord diagnostic; got: \(diags.map(\.code))"
        )
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

    func testDetectMarkerLegacyShapes() {
        XCTAssertEqual(
            CollectionStream.detectMarker(doc([("collection", .string("site"))])),
            "site"
        )
        XCTAssertEqual(
            CollectionStream.detectMarker(doc([("db", .string("ace")), ("collection", .string("device"))])),
            "device"
        )
        XCTAssertEqual(
            CollectionStream.detectMarker(doc([("ns", .string("ace.wlanconf"))])),
            "wlanconf"
        )
        // A big data-shaped doc is not a marker.
        XCTAssertNil(
            CollectionStream.detectMarker(doc((0..<10).map { i in ("k\(i)", .int32(Int32(i))) }))
        )
    }

    private func doc(_ pairs: [(String, BSONValue)]) -> BSONDocument {
        var d = BSONDocument()
        for (k, v) in pairs { d[k] = v }
        return d
    }
}
