import Foundation

/// An ordered set of `(fieldName, value)` pairs.
///
/// BSON preserves insertion order, and the UI surfaces fields in their original
/// order, so we back the document with an array of tuples rather than a
/// dictionary. Duplicate keys are technically legal in BSON; UniFi does not
/// produce them, but if they appear, `subscript` returns the last-wins value.
public struct BSONDocument: Hashable, Sendable {
    public private(set) var pairs: [(key: String, value: BSONValue)]

    public init(pairs: [(String, BSONValue)] = []) {
        self.pairs = pairs
    }

    public var keys: [String] { pairs.map(\.key) }
    public var values: [BSONValue] { pairs.map(\.value) }
    public var count: Int { pairs.count }
    public var isEmpty: Bool { pairs.isEmpty }

    public subscript(key: String) -> BSONValue? {
        get { pairs.last { $0.key == key }?.value }
        set {
            if let idx = pairs.lastIndex(where: { $0.key == key }) {
                if let v = newValue { pairs[idx] = (key, v) }
                else { pairs.remove(at: idx) }
            } else if let v = newValue {
                pairs.append((key, v))
            }
        }
    }

    public func contains(_ key: String) -> Bool {
        pairs.contains { $0.key == key }
    }

    public static func == (lhs: BSONDocument, rhs: BSONDocument) -> Bool {
        guard lhs.pairs.count == rhs.pairs.count else { return false }
        for (a, b) in zip(lhs.pairs, rhs.pairs) {
            if a.key != b.key || a.value != b.value { return false }
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        for p in pairs {
            hasher.combine(p.key)
            hasher.combine(p.value)
        }
    }
}
