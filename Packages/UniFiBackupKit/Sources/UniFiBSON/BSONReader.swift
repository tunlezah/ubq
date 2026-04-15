import Foundation
import Diagnostics

/// Recoverable BSON parse error. Tracked by the stream walker and surfaced as
/// a `Diagnostic`; never crashes.
public enum BSONParseError: Error, Sendable, Hashable {
    case unexpectedEOF(at: Int)
    case invalidLength(length: Int, at: Int)
    case unterminatedCString(from: Int)
    case invalidUTF8(at: Int)
    case malformed(reason: String, at: Int)
}

/// A cursor-based reader over a `Data` buffer.
///
/// Designed for streaming the concatenated BSON documents inside a gunzipped
/// UniFi `db.gz`: every `readDocument()` parses exactly one top-level BSON
/// document and advances the cursor. No allocation per byte; all slices are
/// views into the backing buffer.
public struct BSONReader {
    public let data: Data
    public private(set) var cursor: Int
    public var isAtEnd: Bool { cursor >= data.count }

    public init(_ data: Data, cursor: Int = 0) {
        self.data = data
        self.cursor = cursor
    }

    // MARK: - Primitives

    @inline(__always)
    mutating func requireBytes(_ n: Int) throws {
        guard cursor + n <= data.count else {
            throw BSONParseError.unexpectedEOF(at: cursor)
        }
    }

    @inline(__always)
    mutating func readUInt8() throws -> UInt8 {
        try requireBytes(1)
        let b = data[data.startIndex + cursor]
        cursor += 1
        return b
    }

    @inline(__always)
    mutating func readInt32() throws -> Int32 {
        try requireBytes(4)
        let v: Int32 = data.withUnsafeBytes { buf in
            let p = buf.baseAddress!.advanced(by: cursor)
            var raw: Int32 = 0
            memcpy(&raw, p, 4)
            return Int32(littleEndian: raw)
        }
        cursor += 4
        return v
    }

    @inline(__always)
    mutating func readInt64() throws -> Int64 {
        try requireBytes(8)
        let v: Int64 = data.withUnsafeBytes { buf in
            let p = buf.baseAddress!.advanced(by: cursor)
            var raw: Int64 = 0
            memcpy(&raw, p, 8)
            return Int64(littleEndian: raw)
        }
        cursor += 8
        return v
    }

    @inline(__always)
    mutating func readUInt32() throws -> UInt32 {
        try requireBytes(4)
        let v: UInt32 = data.withUnsafeBytes { buf in
            let p = buf.baseAddress!.advanced(by: cursor)
            var raw: UInt32 = 0
            memcpy(&raw, p, 4)
            return UInt32(littleEndian: raw)
        }
        cursor += 4
        return v
    }

    @inline(__always)
    mutating func readDouble() throws -> Double {
        try requireBytes(8)
        let v: Double = data.withUnsafeBytes { buf in
            let p = buf.baseAddress!.advanced(by: cursor)
            var raw: UInt64 = 0
            memcpy(&raw, p, 8)
            return Double(bitPattern: UInt64(littleEndian: raw))
        }
        cursor += 8
        return v
    }

    /// A NUL-terminated UTF-8 string ("cstring") used for BSON field names.
    mutating func readCString() throws -> String {
        let start = cursor
        while cursor < data.count {
            if data[data.startIndex + cursor] == 0 {
                let slice = data[(data.startIndex + start)..<(data.startIndex + cursor)]
                cursor += 1 // consume terminator
                if let s = String(data: slice, encoding: .utf8) {
                    return s
                }
                // Fall back to replacing invalid bytes rather than throwing.
                return String(decoding: slice, as: UTF8.self)
            }
            cursor += 1
        }
        throw BSONParseError.unterminatedCString(from: start)
    }

    /// A length-prefixed UTF-8 string (BSON `string` element).
    mutating func readBSONString() throws -> String {
        let len32 = try readInt32()
        guard len32 > 0 else {
            throw BSONParseError.malformed(reason: "non-positive string length \(len32)", at: cursor - 4)
        }
        let len = Int(len32)
        try requireBytes(len)
        // Payload is (len - 1) bytes of UTF-8 followed by a trailing NUL.
        let startAbs = data.startIndex + cursor
        let slice = data[startAbs..<(startAbs + len - 1)]
        cursor += len
        if let s = String(data: slice, encoding: .utf8) {
            return s
        }
        return String(decoding: slice, as: UTF8.self)
    }

    mutating func readBytes(_ n: Int) throws -> Data {
        try requireBytes(n)
        let start = data.startIndex + cursor
        let out = data.subdata(in: start..<(start + n))
        cursor += n
        return out
    }

    // MARK: - Document / value

    /// Reads exactly one top-level BSON document and advances the cursor past it.
    public mutating func readDocument() throws -> BSONDocument {
        let docStart = cursor
        let totalLen32 = try readInt32()
        let totalLen = Int(totalLen32)
        // Sanity bounds: at minimum 4 (length) + 1 (trailing NUL) = 5.
        guard totalLen >= 5 else {
            throw BSONParseError.invalidLength(length: totalLen, at: docStart)
        }
        guard totalLen <= 16 * 1024 * 1024 else {
            throw BSONParseError.invalidLength(length: totalLen, at: docStart)
        }
        let docEnd = docStart + totalLen
        guard docEnd <= data.count else {
            throw BSONParseError.invalidLength(length: totalLen, at: docStart)
        }

        var pairs: [(String, BSONValue)] = []
        while cursor < docEnd - 1 {
            let typeByte = try readUInt8()
            if typeByte == 0x00 {
                // End-of-document terminator — but shouldn't happen before docEnd - 1.
                break
            }
            let key = try readCString()
            let value = try readValue(typeByte: typeByte, boundsEnd: docEnd)
            pairs.append((key, value))
        }

        // Expect trailing NUL at docEnd - 1.
        guard cursor == docEnd - 1 else {
            throw BSONParseError.malformed(
                reason: "document body exceeded declared length",
                at: docStart
            )
        }
        let trailing = try readUInt8()
        guard trailing == 0 else {
            throw BSONParseError.malformed(
                reason: "missing trailing NUL (got 0x\(String(trailing, radix: 16)))",
                at: cursor - 1
            )
        }

        return BSONDocument(pairs: pairs)
    }

    // Reads the value bytes for a given type code, assuming the type byte and
    // the field name have already been consumed.
    mutating func readValue(typeByte: UInt8, boundsEnd: Int) throws -> BSONValue {
        switch typeByte {
        case 0x01: // double
            return .double(try readDouble())

        case 0x02: // UTF-8 string
            return .string(try readBSONString())

        case 0x03: // embedded document
            return .document(try readDocument())

        case 0x04: // array
            let doc = try readDocument()
            // BSON arrays are documents with numeric string keys. We don't verify
            // "0","1",... strictly; just take the values in document order.
            return .array(doc.values)

        case 0x05: // binary
            let len32 = try readInt32()
            let len = Int(len32)
            guard len >= 0 else {
                throw BSONParseError.malformed(reason: "negative binary length", at: cursor - 4)
            }
            let subtype = try readUInt8()
            let bytes = try readBytes(len)
            return .binary(data: bytes, subtype: subtype)

        case 0x07: // ObjectId — 12 raw bytes
            let raw = try readBytes(12)
            return .objectId(ObjectId(bytes: Array(raw)))

        case 0x08: // bool
            let b = try readUInt8()
            return .bool(b != 0)

        case 0x09: // UTC datetime — int64 ms
            return .datetime(try readInt64())

        case 0x0A: // null
            return .null

        case 0x0B: // regex — cstring pattern + cstring options
            let p = try readCString()
            let o = try readCString()
            return .regex(pattern: p, options: o)

        case 0x10: // int32
            return .int32(try readInt32())

        case 0x11: // timestamp — uint32 increment + uint32 seconds
            let inc = try readUInt32()
            let sec = try readUInt32()
            return .timestamp(increment: inc, seconds: sec)

        case 0x12: // int64
            return .int64(try readInt64())

        case 0x06, 0x0C, 0x0D, 0x0E, 0x0F, 0x13, 0xFF, 0x7F:
            // Deprecated / internal / decimal128 / min/max. UniFi doesn't emit
            // these, but if they appear we must still advance past them so we
            // don't desync the stream. Conservatively: for codes we cannot size
            // safely, we bail to a diagnostic.
            throw BSONParseError.malformed(
                reason: "unsupported BSON type 0x\(String(typeByte, radix: 16))",
                at: cursor
            )

        default:
            throw BSONParseError.malformed(
                reason: "unknown BSON type 0x\(String(typeByte, radix: 16))",
                at: cursor
            )
        }
    }

    /// Convenience: parse a standalone single-document `Data` blob.
    public static func parseDocument(_ data: Data) throws -> BSONDocument {
        var r = BSONReader(data)
        return try r.readDocument()
    }
}
