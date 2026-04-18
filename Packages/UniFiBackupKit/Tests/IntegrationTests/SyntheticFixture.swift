import Foundation
import UniFiBSON
import UnfCrypto

/// Builds a valid `.unf` in memory, end-to-end, without any real UniFi
/// controller. Used by integration and round-trip tests.
///
/// Layout produced:
///   AES-128-CBC(key, iv) of
///     ZIP {
///       "version"          : "9.5.21\n"
///       "format"            : "8"
///       "timestamp"         : "1713600000000"
///       "system.properties" : "unifi.version=9.5.21\nunifi.db.uri=mongodb://localhost:27117/ace\n"
///       "db.gz"             : gzip(BSON stream described below)
///     }
///
/// BSON stream:
///     {collection: "site"}, {_id: ObjectId, name:"default", desc:"Default"}, ...
///     {collection: "device"}, ...
///     {collection: "wlanconf"}, ...
///     (etc.)
enum SyntheticFixture {
    static func makeMinimalBackup(
        siteName: String = "default",
        siteDesc: String = "Default",
        wlanSSID: String = "FixtureNet",
        wlanPSK: String = "supersecret123",
        includeStatsDB: Bool = false
    ) throws -> Data {
        let w = BSONWriter()

        // Build the BSON stream for db.gz.
        var bsonStream = Data()

        // Collection: site
        bsonStream.append(w.write(document(with: [("collection", .string("site"))])))
        let siteId = makeObjectId(seed: 1)
        bsonStream.append(w.write(document(with: [
            ("_id", .objectId(siteId)),
            ("name", .string(siteName)),
            ("desc", .string(siteDesc)),
            ("attr_hidden_id", .string(siteName)),
        ])))

        // Collection: device
        bsonStream.append(w.write(document(with: [("collection", .string("device"))])))
        let deviceId = makeObjectId(seed: 2)
        bsonStream.append(w.write(document(with: [
            ("_id", .objectId(deviceId)),
            ("site_id", .objectId(siteId)),
            ("mac", .string("aa:bb:cc:dd:ee:01")),
            ("model", .string("U6ENT")),
            ("type", .string("uap")),
            ("version", .string("6.6.74")),
            ("adopted", .bool(true)),
            ("name", .string("TestAP")),
        ])))

        // Collection: wlanconf
        bsonStream.append(w.write(document(with: [("collection", .string("wlanconf"))])))
        let wlanId = makeObjectId(seed: 3)
        let wlanGroupId = makeObjectId(seed: 4)
        bsonStream.append(w.write(document(with: [
            ("_id", .objectId(wlanId)),
            ("site_id", .objectId(siteId)),
            ("name", .string(wlanSSID)),
            ("x_passphrase", .string(wlanPSK)),
            ("security", .string("wpapsk")),
            ("wpa_mode", .string("wpa2")),
            ("vlan", .int32(10)),
            ("enabled", .bool(true)),
            ("is_guest", .bool(false)),
            ("wlangroup_id", .objectId(wlanGroupId)),
        ])))

        // Collection: wlangroup
        bsonStream.append(w.write(document(with: [("collection", .string("wlangroup"))])))
        bsonStream.append(w.write(document(with: [
            ("_id", .objectId(wlanGroupId)),
            ("site_id", .objectId(siteId)),
            ("name", .string("Default")),
        ])))

        // Collection: admin (controller-wide)
        bsonStream.append(w.write(document(with: [("collection", .string("admin"))])))
        bsonStream.append(w.write(document(with: [
            ("_id", .objectId(makeObjectId(seed: 5))),
            ("name", .string("superadmin")),
            ("email", .string("admin@example.com")),
            ("x_shadow", .string("$6$rounds=5000$examplesaltoz$Fak3Sha512$.")),
            ("time_created", .datetime(Int64(1_704_067_200_000))),
        ])))

        // Collection: account (RADIUS / per-site)
        bsonStream.append(w.write(document(with: [("collection", .string("account"))])))
        bsonStream.append(w.write(document(with: [
            ("_id", .objectId(makeObjectId(seed: 6))),
            ("site_id", .objectId(siteId)),
            ("name", .string("alice")),
            ("x_password", .string("radius-secret-alice")),
            ("vlan", .int32(100)),
        ])))

        // Collection: unknown_future (opaque fallback coverage)
        bsonStream.append(w.write(document(with: [("collection", .string("unknown_future"))])))
        bsonStream.append(w.write(document(with: [
            ("_id", .objectId(makeObjectId(seed: 7))),
            ("mystery_field", .string("fine")),
        ])))

        let gz = try gzipCompress(bsonStream)

        // Build zip entries.
        var zipEntries: [(name: String, data: Data)] = [
            ("version", Data("9.5.21\n".utf8)),
            ("format", Data("8".utf8)),
            ("timestamp", Data("1713600000000".utf8)),
            (
                "system.properties",
                Data(
                    """
                    unifi.version=9.5.21
                    db.mongo.uri=mongodb://localhost:27117/ace
                    unifi.https.port=8443
                    """.utf8
                )
            ),
            ("db.gz", gz),
        ]

        if includeStatsDB {
            // A trivial stats stream with a single collection.
            var statsStream = Data()
            statsStream.append(w.write(document(with: [("collection", .string("stat_life"))])))
            statsStream.append(w.write(document(with: [
                ("_id", .objectId(makeObjectId(seed: 99))),
                ("site_id", .objectId(siteId)),
                ("o", .string("ap")),
                ("bytes", .int64(12345)),
            ])))
            zipEntries.append(("db_stat.gz", try gzipCompress(statsStream)))
        }

        let zipped = buildZip(entries: zipEntries)
        // Pad to 16-byte boundary (zero pad — the inner ZIP reader is
        // tolerant of trailing bytes).
        var padded = zipped
        let padLen = (16 - (padded.count % 16)) % 16
        if padLen > 0 {
            padded.append(Data(repeating: 0x00, count: padLen))
        }
        let encrypted = try UnfCipher.encrypt(padded)
        return encrypted
    }

    /// Produces a "format: bson" backup with per-collection .bson files.
    static func makePerCollectionBackup(
        siteName: String = "default",
        siteDesc: String = "Default",
        wlanSSID: String = "FixtureNet",
        wlanPSK: String = "supersecret123"
    ) throws -> Data {
        let w = BSONWriter()
        let siteId = makeObjectId(seed: 1)

        func bsonFile(_ docs: [BSONDocument]) -> Data {
            var stream = Data()
            for d in docs { stream.append(w.write(d)) }
            return stream
        }

        let siteDoc = document(with: [
            ("_id", .objectId(siteId)),
            ("name", .string(siteName)),
            ("desc", .string(siteDesc)),
        ])

        let deviceDoc = document(with: [
            ("_id", .objectId(makeObjectId(seed: 2))),
            ("site_id", .objectId(siteId)),
            ("mac", .string("aa:bb:cc:dd:ee:01")),
            ("model", .string("U6ENT")),
            ("type", .string("uap")),
            ("adopted", .bool(true)),
            ("name", .string("TestAP")),
        ])

        let wlanDoc = document(with: [
            ("_id", .objectId(makeObjectId(seed: 3))),
            ("site_id", .objectId(siteId)),
            ("name", .string(wlanSSID)),
            ("x_passphrase", .string(wlanPSK)),
            ("security", .string("wpapsk")),
            ("enabled", .bool(true)),
        ])

        let adminDoc = document(with: [
            ("_id", .objectId(makeObjectId(seed: 5))),
            ("name", .string("superadmin")),
            ("email", .string("admin@example.com")),
            ("x_shadow", .string("$6$rounds=5000$salt$fakeHash")),
        ])

        let accountDoc = document(with: [
            ("_id", .objectId(makeObjectId(seed: 6))),
            ("site_id", .objectId(siteId)),
            ("name", .string("alice")),
            ("x_password", .string("radius-secret")),
        ])

        let zipEntries: [(name: String, data: Data)] = [
            ("version", Data("9.5.21\n".utf8)),
            ("format", Data("bson".utf8)),
            ("timestamp", Data("1713600000000".utf8)),
            ("site.bson", bsonFile([siteDoc])),
            ("device.bson", bsonFile([deviceDoc])),
            ("wlanconf.bson", bsonFile([wlanDoc])),
            ("admin.bson", bsonFile([adminDoc])),
            ("account.bson", bsonFile([accountDoc])),
        ]

        let zipped = buildZip(entries: zipEntries)
        var padded = zipped
        let padLen = (16 - (padded.count % 16)) % 16
        if padLen > 0 {
            padded.append(Data(repeating: 0x00, count: padLen))
        }
        return try UnfCipher.encrypt(padded)
    }

    private static func document(with pairs: [(String, BSONValue)]) -> BSONDocument {
        var d = BSONDocument()
        for (k, v) in pairs { d[k] = v }
        return d
    }

    private static func makeObjectId(seed: UInt8) -> ObjectId {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 { bytes[i] = seed &+ UInt8(i) }
        return ObjectId(bytes: bytes)
    }

    // Minimal gzip: header (10 bytes) + raw DEFLATE + trailer (CRC32 + ISIZE).
    private static func gzipCompress(_ data: Data) throws -> Data {
        let deflated = try rawDeflate(data)
        var out = Data()
        out.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(deflated)
        var crc = UInt32(crc32(data)).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var isize = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
        return out
    }

    private static func rawDeflate(_ data: Data) throws -> Data {
        // Stored block (BFINAL=1, BTYPE=00): 1 byte header + 4 bytes LEN/NLEN +
        // raw data. Works for any size <= 65535; we chunk for larger inputs.
        var out = Data()
        var remaining = data
        while !remaining.isEmpty {
            let chunkLen = min(remaining.count, 65_535)
            let isFinal = remaining.count <= 65_535
            let headerByte: UInt8 = isFinal ? 0x01 : 0x00
            out.append(headerByte)
            let len = UInt16(chunkLen)
            let nlen = ~len
            withUnsafeBytes(of: len.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: nlen.littleEndian) { out.append(contentsOf: $0) }
            out.append(remaining.prefix(chunkLen))
            remaining = remaining.dropFirst(chunkLen)
        }
        return out
    }

    // Simple CRC32 implementation (reflected, poly 0xEDB88320).
    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            let idx = Int((crc ^ UInt32(b)) & 0xFF)
            crc = (crc >> 8) ^ table[idx]
        }
        return crc ^ 0xFFFF_FFFF
    }

    // Build a minimal ZIP with STORED entries (no compression) and a valid
    // central directory. Tolerant reader must handle this shape regardless.
    private static func buildZip(entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        struct RecordedEntry {
            let name: String
            let crc: UInt32
            let size: Int
            let localHeaderOffset: Int
        }
        var records: [RecordedEntry] = []

        for (name, data) in entries {
            let offset = out.count
            let crc = crc32(data)
            let nameBytes = Data(name.utf8)

            // Local file header
            out.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])         // signature
            appendUInt16(&out, 20)                                   // version needed
            appendUInt16(&out, 0x0800)                               // GP flag: UTF-8
            appendUInt16(&out, 0)                                    // method: stored
            appendUInt16(&out, 0)                                    // mod time
            appendUInt16(&out, 0)                                    // mod date
            appendUInt32(&out, crc)
            appendUInt32(&out, UInt32(data.count))
            appendUInt32(&out, UInt32(data.count))
            appendUInt16(&out, UInt16(nameBytes.count))
            appendUInt16(&out, 0)                                    // extra field length
            out.append(nameBytes)
            out.append(data)

            records.append(RecordedEntry(name: name, crc: crc, size: data.count, localHeaderOffset: offset))
        }

        let cdOffset = out.count
        for rec in records {
            let nameBytes = Data(rec.name.utf8)
            out.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])          // signature
            appendUInt16(&out, 20)                                    // version made by
            appendUInt16(&out, 20)                                    // version needed
            appendUInt16(&out, 0x0800)                                // GP flag
            appendUInt16(&out, 0)                                     // method
            appendUInt16(&out, 0)                                     // mod time
            appendUInt16(&out, 0)                                     // mod date
            appendUInt32(&out, rec.crc)
            appendUInt32(&out, UInt32(rec.size))
            appendUInt32(&out, UInt32(rec.size))
            appendUInt16(&out, UInt16(nameBytes.count))
            appendUInt16(&out, 0)                                     // extra field length
            appendUInt16(&out, 0)                                     // comment length
            appendUInt16(&out, 0)                                     // disk number start
            appendUInt16(&out, 0)                                     // internal attrs
            appendUInt32(&out, 0)                                     // external attrs
            appendUInt32(&out, UInt32(rec.localHeaderOffset))
            out.append(nameBytes)
        }
        let cdSize = out.count - cdOffset

        // EOCD
        out.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        appendUInt16(&out, 0)                                         // disk number
        appendUInt16(&out, 0)                                         // disk w/ CD
        appendUInt16(&out, UInt16(records.count))
        appendUInt16(&out, UInt16(records.count))
        appendUInt32(&out, UInt32(cdSize))
        appendUInt32(&out, UInt32(cdOffset))
        appendUInt16(&out, 0)                                         // comment length

        return out
    }

    private static func appendUInt16(_ d: inout Data, _ v: UInt16) {
        var x = v.littleEndian
        withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ d: inout Data, _ v: UInt32) {
        var x = v.littleEndian
        withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
    }
}
