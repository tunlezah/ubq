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

    // MARK: - Bug 7: sliced Data (nonzero startIndex)

    func testReadsFromSlicedData() throws {
        let data = TestZip.build(entries: [
            ("a.txt", Data("aaa".utf8)),
            ("b.txt", Data("bbb".utf8)),
        ])
        // Prepend 5 junk bytes, then slice them off so startIndex == 5.
        var withJunk = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00])
        withJunk.append(data)
        let sliced = withJunk[5...].dropFirst(0)
        XCTAssertNotEqual(sliced.startIndex, 0, "precondition: the slice must be non-zero-based")

        let fromSlice = try TolerantZipReader(sliced)
        let fromPlain = try TolerantZipReader(data)
        XCTAssertEqual(fromSlice.entries.count, fromPlain.entries.count)
        XCTAssertEqual(fromSlice.entries["a.txt"]?.data, fromPlain.entries["a.txt"]?.data)
        XCTAssertEqual(fromSlice.entries["b.txt"]?.data, fromPlain.entries["b.txt"]?.data)
        XCTAssertEqual(fromSlice.entries["a.txt"]?.data, Data("aaa".utf8))
    }

    // MARK: - Bug 8: PK\x07\x08 inside deflate payload is not a false boundary

    func testDataDescriptorSignatureInsidePayloadIsNotAFalseBoundary() throws {
        // Content deliberately embeds the data-descriptor signature bytes.
        var content = Data("LEADING_PADDING_BYTES_".utf8)
        content.append(contentsOf: [0x50, 0x4b, 0x07, 0x08])   // PK\x07\x08 embedded
        content.append(Data("_TRAILING_PAYLOAD_DATA".utf8))

        let deflate = storedRawDeflate(content)                // decodes back to content
        let zip = buildDeflateDataDescriptorEntry(name: "blob.bin", deflate: deflate, content: content)

        let reader = try TolerantZipReader(zip)
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(
            reader.entries["blob.bin"]?.data, content,
            "embedded PK\\x07\\x08 must not truncate the payload"
        )
    }

    // MARK: - TarReader

    func testTarReaderReadsUstarFiles() {
        let versionBytes = Data("10.6.101\n".utf8)
        let dbBytes = Data([0x1f, 0x8b, 0x08, 0x00])
        let tar = buildTar(entries: [
            ("backup/network/version", versionBytes),
            ("backup/network/db.gz", dbBytes),
        ])
        let reader = TarReader(tar)
        XCTAssertEqual(reader.entries.count, 2)
        XCTAssertEqual(reader.map["backup/network/version"], versionBytes)
        XCTAssertEqual(reader.map["backup/network/db.gz"], dbBytes)
        XCTAssertTrue(reader.diagnostics.isEmpty)
    }

    func testTarReaderReadsGNULongName() {
        let longName = "backup/network/" + String(repeating: "a", count: 120) + "/system.properties"
        let data = Data("unifi.version=10.6.101\n".utf8)
        let tar = buildGNULongNameTar(longName: longName, stubName: "shortstub", data: data)
        let reader = TarReader(tar)
        XCTAssertEqual(reader.map[longName], data)
        XCTAssertNil(reader.map["shortstub"])
        XCTAssertEqual(reader.entries.first?.name, longName)
    }

    func testTarReaderToleratesOverrunWithoutCrashing() {
        var tar = tarHeader(name: "big", size: 100_000, typeflag: 0x30)
        tar.append(Data(count: 512))   // far short of the declared 100000 bytes
        let reader = TarReader(tar)
        XCTAssertTrue(reader.entries.isEmpty)
        XCTAssertFalse(reader.diagnostics.isEmpty)
    }

    // MARK: - Builders for the above

    /// Raw DEFLATE using stored blocks (BTYPE=00): literal bytes survive
    /// verbatim, so arbitrary sequences (incl. PK\x07\x08) round-trip.
    private func storedRawDeflate(_ data: Data) -> Data {
        var out = Data()
        var remaining = data
        if remaining.isEmpty {
            out.append(contentsOf: [0x01, 0x00, 0x00, 0xff, 0xff])
            return out
        }
        while !remaining.isEmpty {
            let chunk = min(remaining.count, 65_535)
            let isFinal = remaining.count <= 65_535
            out.append(isFinal ? 0x01 : 0x00)
            let len = UInt16(chunk)
            let nlen = ~len
            TestZip.appendU16(&out, len)
            TestZip.appendU16(&out, nlen)
            out.append(remaining.prefix(chunk))
            remaining = remaining.dropFirst(chunk)
        }
        return out
    }

    /// A single deflate entry using a streaming data descriptor (GP flag bit 3,
    /// zero sizes in the local header, real sizes in a trailing PK\x07\x08
    /// descriptor). No central directory — the tolerant reader scans locals.
    private func buildDeflateDataDescriptorEntry(name: String, deflate: Data, content: Data) -> Data {
        var zip = Data()
        let nameBytes = Data(name.utf8)
        zip.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
        TestZip.appendU16(&zip, 20)          // version needed
        TestZip.appendU16(&zip, 0x0808)      // GP flags: data descriptor + UTF-8
        TestZip.appendU16(&zip, 8)           // method: deflate
        TestZip.appendU16(&zip, 0)           // mod time
        TestZip.appendU16(&zip, 0)           // mod date
        TestZip.appendU32(&zip, 0)           // crc (deferred to descriptor)
        TestZip.appendU32(&zip, 0)           // comp size (deferred)
        TestZip.appendU32(&zip, 0)           // uncomp size (deferred)
        TestZip.appendU16(&zip, UInt16(nameBytes.count))
        TestZip.appendU16(&zip, 0)           // extra length
        zip.append(nameBytes)
        zip.append(deflate)
        // Real data descriptor with signature.
        zip.append(contentsOf: [0x50, 0x4b, 0x07, 0x08])
        TestZip.appendU32(&zip, TestZip.crc32(content))
        TestZip.appendU32(&zip, UInt32(deflate.count))
        TestZip.appendU32(&zip, UInt32(content.count))
        return zip
    }

    private func buildTar(entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        for (name, data) in entries {
            out.append(tarHeader(name: name, size: data.count, typeflag: 0x30))
            out.append(padTo512(data))
        }
        out.append(Data(count: 1024))   // two zero blocks end the archive
        return out
    }

    private func buildGNULongNameTar(longName: String, stubName: String, data: Data) -> Data {
        var out = Data()
        let longNameData = Data((longName + "\u{0}").utf8)
        out.append(tarHeader(name: "././@LongLink", size: longNameData.count, typeflag: 0x4C))
        out.append(padTo512(longNameData))
        out.append(tarHeader(name: stubName, size: data.count, typeflag: 0x30))
        out.append(padTo512(data))
        out.append(Data(count: 1024))
        return out
    }

    private func tarHeader(name: String, size: Int, typeflag: UInt8) -> Data {
        var block = Data(count: 512)
        writeString(&block, at: 0, name, maxLen: 100)
        writeString(&block, at: 100, "0000644", maxLen: 8)     // mode
        writeString(&block, at: 108, "0000000", maxLen: 8)     // uid
        writeString(&block, at: 116, "0000000", maxLen: 8)     // gid
        writeString(&block, at: 124, octalString(size, width: 11), maxLen: 12) // size
        writeString(&block, at: 136, "00000000000", maxLen: 12) // mtime
        block[156] = typeflag
        writeString(&block, at: 257, "ustar", maxLen: 6)       // magic "ustar\0"
        block[263] = 0x30; block[264] = 0x30                    // version "00"
        // Checksum: sum the whole block with the chksum field taken as spaces.
        for i in 148..<156 { block[i] = 0x20 }
        var sum = 0
        for b in block { sum += Int(b) }
        writeString(&block, at: 148, octalString(sum, width: 6), maxLen: 6)
        block[154] = 0x00
        block[155] = 0x20
        return block
    }

    private func padTo512(_ data: Data) -> Data {
        var out = data
        let rem = data.count % 512
        if rem != 0 { out.append(Data(count: 512 - rem)) }
        return out
    }

    private func writeString(_ block: inout Data, at offset: Int, _ string: String, maxLen: Int) {
        let bytes = Array(string.utf8).prefix(maxLen)
        for (i, b) in bytes.enumerated() {
            block[offset + i] = b
        }
    }

    private func octalString(_ value: Int, width: Int) -> String {
        let s = String(value, radix: 8)
        if s.count >= width { return s }
        return String(repeating: "0", count: width - s.count) + s
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
