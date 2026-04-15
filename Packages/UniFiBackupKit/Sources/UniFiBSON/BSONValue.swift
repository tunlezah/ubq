import Foundation

/// The value types we decode from BSON.
///
/// Covers the subset used by UniFi configuration data (see `/FORMAT.md` §
/// "BSON type codes you must support"). Decimal128, regex, and deprecated type
/// codes are stored as `.unsupported(typeByte)` — surfaced as a diagnostic but
/// never crash the parser.
public indirect enum BSONValue: Hashable, Sendable {
    case double(Double)
    case string(String)
    case document(BSONDocument)
    case array([BSONValue])
    /// Binary data plus its subtype. Subtype 0x00 is generic; 0x04 is UUID.
    case binary(data: Data, subtype: UInt8)
    case objectId(ObjectId)
    case bool(Bool)
    /// UTC milliseconds since Unix epoch. May be negative.
    case datetime(Int64)
    case null
    case regex(pattern: String, options: String)
    case int32(Int32)
    case timestamp(increment: UInt32, seconds: UInt32)
    case int64(Int64)
    case unsupported(typeByte: UInt8)

    /// Best-effort string coercion for UI display.
    public var displayString: String {
        switch self {
        case .double(let v): return String(v)
        case .string(let s): return s
        case .document(let d): return "{\(d.keys.joined(separator: ", "))}"
        case .array(let a): return "[\(a.count) items]"
        case .binary(let data, let subtype):
            if subtype == 0x04, data.count == 16 {
                return "UUID(\(uuidString(data)))"
            }
            return "Binary(\(data.count) bytes)"
        case .objectId(let oid): return oid.hexString
        case .bool(let b): return b ? "true" : "false"
        case .datetime(let ms):
            let date = Date(timeIntervalSince1970: Double(ms) / 1000)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: date)
        case .null: return "null"
        case .regex(let p, let o): return "/\(p)/\(o)"
        case .int32(let v): return String(v)
        case .timestamp(let inc, let sec): return "Timestamp(\(sec), \(inc))"
        case .int64(let v): return String(v)
        case .unsupported(let tb): return "Unsupported(0x\(String(tb, radix: 16)))"
        }
    }

    // Convenience accessors used heavily by the model mapper.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    public var int32Value: Int32? {
        switch self {
        case .int32(let v): return v
        case .int64(let v): return Int32(clamping: v)
        case .double(let v): return Int32(v)
        default: return nil
        }
    }
    public var int64Value: Int64? {
        switch self {
        case .int64(let v): return v
        case .int32(let v): return Int64(v)
        case .double(let v): return Int64(v)
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int32(let v): return Double(v)
        case .int64(let v): return Double(v)
        default: return nil
        }
    }
    public var documentValue: BSONDocument? {
        if case .document(let d) = self { return d }
        return nil
    }
    public var arrayValue: [BSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    public var objectIdValue: ObjectId? {
        if case .objectId(let o) = self { return o }
        return nil
    }
    public var datetimeValue: Date? {
        switch self {
        case .datetime(let ms): return Date(timeIntervalSince1970: Double(ms) / 1000)
        case .int64(let v) where v > 1_000_000_000_000 && v < 10_000_000_000_000:
            // Epoch-ms stored as plain int64 (older controllers do this)
            return Date(timeIntervalSince1970: Double(v) / 1000)
        default: return nil
        }
    }

    private func uuidString(_ data: Data) -> String {
        let bytes = Array(data)
        let seg: (Int, Int) -> String = { lo, hi in
            bytes[lo..<hi].map { String(format: "%02x", $0) }.joined()
        }
        return "\(seg(0, 4))-\(seg(4, 6))-\(seg(6, 8))-\(seg(8, 10))-\(seg(10, 16))"
    }
}

/// 12-byte MongoDB ObjectId.
public struct ObjectId: Hashable, Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 12)
        self.bytes = bytes
    }

    public var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
