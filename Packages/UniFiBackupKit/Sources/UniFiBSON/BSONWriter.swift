import Foundation

/// Minimal BSON writer — used solely by tests to build synthetic fixtures
/// programmatically (see ADR-013). Not used at runtime.
///
/// Supports the subset of types a UniFi backup actually uses; keeps the
/// implementation tiny and transparent.
public struct BSONWriter {
    public init() {}

    public func write(_ doc: BSONDocument) -> Data {
        var body = Data()
        for (key, value) in doc.pairs {
            body.append(typeByte(for: value))
            body.append(cstring(key))
            body.append(valueBytes(value))
        }
        body.append(0x00) // document terminator
        var out = Data()
        var total = Int32(body.count + 4).littleEndian
        withUnsafeBytes(of: &total) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    private func typeByte(for v: BSONValue) -> UInt8 {
        switch v {
        case .double: return 0x01
        case .string: return 0x02
        case .document: return 0x03
        case .array: return 0x04
        case .binary: return 0x05
        case .objectId: return 0x07
        case .bool: return 0x08
        case .datetime: return 0x09
        case .null: return 0x0A
        case .regex: return 0x0B
        case .int32: return 0x10
        case .timestamp: return 0x11
        case .int64: return 0x12
        case .unsupported(let tb): return tb
        }
    }

    private func cstring(_ s: String) -> Data {
        var d = Data(s.utf8)
        d.append(0x00)
        return d
    }

    private func bsonString(_ s: String) -> Data {
        let utf8 = Data(s.utf8)
        var len = Int32(utf8.count + 1).littleEndian
        var out = Data()
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(utf8)
        out.append(0x00)
        return out
    }

    private func valueBytes(_ v: BSONValue) -> Data {
        switch v {
        case .double(let d):
            var bits = d.bitPattern.littleEndian
            return Data(withUnsafeBytes(of: &bits) { Array($0) })
        case .string(let s):
            return bsonString(s)
        case .document(let d):
            return write(d)
        case .array(let values):
            var arrDoc = BSONDocument()
            for (i, v) in values.enumerated() {
                arrDoc[String(i)] = v
            }
            return write(arrDoc)
        case .binary(let data, let subtype):
            var len = Int32(data.count).littleEndian
            var out = Data()
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(subtype)
            out.append(data)
            return out
        case .objectId(let oid):
            return Data(oid.bytes)
        case .bool(let b):
            return Data([b ? 0x01 : 0x00])
        case .datetime(let ms):
            var v = ms.littleEndian
            return Data(withUnsafeBytes(of: &v) { Array($0) })
        case .null:
            return Data()
        case .regex(let p, let o):
            return cstring(p) + cstring(o)
        case .int32(let v):
            var x = v.littleEndian
            return Data(withUnsafeBytes(of: &x) { Array($0) })
        case .timestamp(let inc, let sec):
            var i = inc.littleEndian
            var s = sec.littleEndian
            var out = Data()
            withUnsafeBytes(of: &i) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: &s) { out.append(contentsOf: $0) }
            return out
        case .int64(let v):
            var x = v.littleEndian
            return Data(withUnsafeBytes(of: &x) { Array($0) })
        case .unsupported:
            return Data()
        }
    }
}
