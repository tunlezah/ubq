import XCTest
@testable import UniFiBSON

final class UniFiBSONTests: XCTestCase {

    func testRoundTripSimpleDocument() throws {
        var doc = BSONDocument()
        doc["hello"] = .string("world")
        doc["n"] = .int32(42)
        doc["flag"] = .bool(true)
        doc["nothing"] = .null
        doc["pi"] = .double(3.14159)

        let bytes = BSONWriter().write(doc)
        let parsed = try BSONReader.parseDocument(bytes)

        XCTAssertEqual(parsed["hello"], .string("world"))
        XCTAssertEqual(parsed["n"], .int32(42))
        XCTAssertEqual(parsed["flag"], .bool(true))
        XCTAssertEqual(parsed["nothing"], .null)
        XCTAssertEqual(parsed["pi"]?.doubleValue, 3.14159)
    }

    func testNestedDocumentAndArray() throws {
        var inner = BSONDocument()
        inner["a"] = .int32(1)
        inner["b"] = .string("two")
        var doc = BSONDocument()
        doc["obj"] = .document(inner)
        doc["list"] = .array([.int32(10), .int32(20), .string("thirty")])

        let bytes = BSONWriter().write(doc)
        let parsed = try BSONReader.parseDocument(bytes)

        XCTAssertEqual(parsed["obj"]?.documentValue?["a"], .int32(1))
        XCTAssertEqual(parsed["obj"]?.documentValue?["b"], .string("two"))
        XCTAssertEqual(parsed["list"]?.arrayValue?.count, 3)
        XCTAssertEqual(parsed["list"]?.arrayValue?[0], .int32(10))
        XCTAssertEqual(parsed["list"]?.arrayValue?[2], .string("thirty"))
    }

    func testObjectIdAndDatetime() throws {
        let oid = ObjectId(bytes: Array("abcdefghijkl".utf8))
        var doc = BSONDocument()
        doc["_id"] = .objectId(oid)
        doc["when"] = .datetime(1_700_000_000_000)

        let bytes = BSONWriter().write(doc)
        let parsed = try BSONReader.parseDocument(bytes)

        XCTAssertEqual(parsed["_id"]?.objectIdValue, oid)
        XCTAssertEqual(parsed["when"], .datetime(1_700_000_000_000))
    }

    func testInt64AndBinary() throws {
        let bin = Data([0x01, 0x02, 0x03, 0x04])
        var doc = BSONDocument()
        doc["big"] = .int64(1 << 40)
        doc["blob"] = .binary(data: bin, subtype: 0x00)

        let bytes = BSONWriter().write(doc)
        let parsed = try BSONReader.parseDocument(bytes)

        XCTAssertEqual(parsed["big"]?.int64Value, 1 << 40)
        guard case .binary(let data, let sub) = parsed["blob"] else {
            return XCTFail("missing binary")
        }
        XCTAssertEqual(data, bin)
        XCTAssertEqual(sub, 0x00)
    }

    func testMalformedLengthRejected() {
        // Craft a "document" with length 0xFFFFFFFF.
        var data = Data([0xFF, 0xFF, 0xFF, 0xFF])
        data.append(contentsOf: [0x00])
        XCTAssertThrowsError(try BSONReader.parseDocument(data))
    }

    func testFieldOrderPreserved() throws {
        var doc = BSONDocument()
        doc["zzz"] = .int32(1)
        doc["aaa"] = .int32(2)
        doc["mmm"] = .int32(3)

        let bytes = BSONWriter().write(doc)
        let parsed = try BSONReader.parseDocument(bytes)
        XCTAssertEqual(parsed.keys, ["zzz", "aaa", "mmm"])
    }
}
