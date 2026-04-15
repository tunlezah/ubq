import XCTest
@testable import TolerantZip

final class TolerantZipTests: XCTestCase {

    func testReadsStoredZipFromFixture() throws {
        // Build a tiny stored-method ZIP inline.
        let data = TestZip.build(entries: [
            ("hello.txt", Data("hello world".utf8)),
            ("num.txt", Data("42".utf8)),
        ])
        let reader = try TolerantZipReader(data)
        XCTAssertEqual(reader.entries["hello.txt"]?.data, Data("hello world".utf8))
        XCTAssertEqual(reader.entries["num.txt"]?.data, Data("42".utf8))
    }

    func testTruncatedEOCDStillRecoversEntries() throws {
        var data = TestZip.build(entries: [
            ("ok.txt", Data("ok".utf8)),
            ("also.txt", Data("also".utf8)),
        ])
        // Nuke the central directory + EOCD entirely by truncating to just
        // past the last local file entry.
        if let idx = findLastLocalHeaderEnd(in: data) {
            data = data.prefix(idx)
        }
        let reader = try TolerantZipReader(data)
        XCTAssertEqual(reader.entries["ok.txt"]?.data, Data("ok".utf8))
        XCTAssertEqual(reader.entries["also.txt"]?.data, Data("also".utf8))
    }

    // Find the end of the last local-header payload by scanning for the CD sig.
    private func findLastLocalHeaderEnd(in data: Data) -> Int? {
        var i = 0
        while i + 4 <= data.count {
            if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 0x01, data[i + 3] == 0x02 {
                return i
            }
            i += 1
        }
        return nil
    }
}

// Minimal stored-method ZIP builder for TolerantZip unit tests.
// Mirrors the builder in SyntheticFixture (in IntegrationTests target) but is
// self-contained so this target doesn't depend on the integration one.
enum TestZip {
    static func build(entries: [(String, Data)]) -> Data {
        var out = Data()
        struct Record { let name: String; let crc: UInt32; let size: Int; let offset: Int }
        var records: [Record] = []

        for (name, data) in entries {
            let offset = out.count
            let crc = crc32(data)
            let nameBytes = Data(name.utf8)
            out.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
            appendU16(&out, 20)
            appendU16(&out, 0x0800)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU32(&out, crc)
            appendU32(&out, UInt32(data.count))
            appendU32(&out, UInt32(data.count))
            appendU16(&out, UInt16(nameBytes.count))
            appendU16(&out, 0)
            out.append(nameBytes)
            out.append(data)
            records.append(Record(name: name, crc: crc, size: data.count, offset: offset))
        }

        let cdOff = out.count
        for r in records {
            let nameBytes = Data(r.name.utf8)
            out.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
            appendU16(&out, 20)
            appendU16(&out, 20)
            appendU16(&out, 0x0800)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU32(&out, r.crc)
            appendU32(&out, UInt32(r.size))
            appendU32(&out, UInt32(r.size))
            appendU16(&out, UInt16(nameBytes.count))
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU32(&out, 0)
            appendU32(&out, UInt32(r.offset))
            out.append(nameBytes)
        }
        let cdSize = out.count - cdOff

        out.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        appendU16(&out, 0)
        appendU16(&out, 0)
        appendU16(&out, UInt16(records.count))
        appendU16(&out, UInt16(records.count))
        appendU32(&out, UInt32(cdSize))
        appendU32(&out, UInt32(cdOff))
        appendU16(&out, 0)
        return out
    }

    static func appendU16(_ d: inout Data, _ v: UInt16) {
        var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
    }
    static func appendU32(_ d: inout Data, _ v: UInt32) {
        var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
    }
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(b)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
