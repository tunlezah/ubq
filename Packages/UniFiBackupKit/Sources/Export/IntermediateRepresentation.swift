import Foundation
import UniFiBSON
import UniFiModel
import Redaction

/// Language-agnostic, format-neutral representation of a selection.
///
/// Each per-format exporter walks this IR. When a new LLM preset or format
/// shows up we add one renderer; the IR stays stable.
public struct IntermediateRepresentation: Sendable {
    public struct Section: Sendable {
        public let tag: String            // "site", "device", "wlan", ...
        public let title: String
        public let fields: [(String, String)]  // pretty key-value pairs
        public let rawJSON: String?       // pretty-printed JSON of the raw BSON doc
        public let children: [Section]
    }

    public let header: Header
    public let sections: [Section]

    public struct Header: Sendable {
        public let version: String?
        public let format: Int?
        public let timestamp: Date?
        public let origin: Identity.Origin?
        public let kind: Identity.Kind?
        public let redacted: Bool
        public let selectionCount: Int
        public let producedBy: String
    }

    public static func from(
        _ nodes: [TreeNode],
        identity: Identity?,
        redact: Bool
    ) -> IntermediateRepresentation {
        let flattened = TreeBuilder.flatten(nodes)
        let leafNodes = flattened.filter { node in
            // A "leaf" for export = anything that carries a rawDocument, or is
            // a collection / category we want to capture as a heading.
            node.rawDocument != nil
        }
        let sections = leafNodes.map { node -> Section in
            renderSection(node: node, redact: redact)
        }
        let header = Header(
            version: identity?.version,
            format: identity?.format,
            timestamp: identity?.timestamp,
            origin: identity?.origin,
            kind: identity?.kind,
            redacted: redact,
            selectionCount: leafNodes.count,
            producedBy: "UniFi Backup Inspector"
        )
        return IntermediateRepresentation(header: header, sections: sections)
    }

    private static func renderSection(node: TreeNode, redact: Bool) -> Section {
        let raw = node.rawDocument ?? BSONDocument()
        let effective = redact ? SecretVault.redact(raw) : raw
        let tag = tag(for: node)
        let fields = prettyFields(from: effective)
        let rawJSON = jsonString(from: effective)
        return Section(tag: tag, title: node.title, fields: fields, rawJSON: rawJSON, children: [])
    }

    private static func tag(for node: TreeNode) -> String {
        switch node {
        case .site: "site"
        case .device: "device"
        case .wlan: "wlan"
        case .wlanGroup: "wlan_group"
        case .network: "network"
        case .firewallRule: "firewall_rule"
        case .firewallGroup: "firewall_group"
        case .portForward: "port_forward"
        case .portProfile: "port_profile"
        case .routing: "routing"
        case .client: "client"
        case .admin: "admin"
        case .account: "account"
        case .radius: "radius_profile"
        case .hotspotOp: "hotspot_operator"
        case .setting: "setting"
        case .opaqueRecord(let n): n.parentCollection
        default: "record"
        }
    }

    /// Render a BSON document as a list of human-readable "Label: value" pairs.
    /// Arrays and nested documents collapse to summary strings; full detail is
    /// available in the raw JSON.
    private static func prettyFields(from doc: BSONDocument) -> [(String, String)] {
        var out: [(String, String)] = []
        for (key, value) in doc.pairs {
            let rendered = prettyValue(value)
            out.append((key, rendered))
        }
        return out
    }

    private static func prettyValue(_ v: BSONValue) -> String {
        switch v {
        case .document(let d): return "{\(d.keys.joined(separator: ", "))}"
        case .array(let values) where values.count > 8:
            return "[\(values.count) items]"
        case .array(let values):
            let parts = values.map { prettyValue($0) }
            return "[\(parts.joined(separator: ", "))]"
        default: return v.displayString
        }
    }

    /// JSON-render a BSON document for machine consumption. Everything emitted
    /// is valid JSON — BSON types that don't map directly (ObjectId, binary,
    /// datetime) are stringified with a typed prefix, matching MongoDB's
    /// Extended JSON v1 spirit.
    public static func jsonString(from doc: BSONDocument) -> String {
        let any = jsonValue(for: .document(doc))
        let data = try? JSONSerialization.data(
            withJSONObject: any, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let data, let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    static func jsonValue(for v: BSONValue) -> Any {
        switch v {
        case .double(let d): return d.isFinite ? d : NSNull()
        case .string(let s): return s
        case .document(let d):
            var out: [String: Any] = [:]
            for (k, vv) in d.pairs {
                out[k] = jsonValue(for: vv)
            }
            return out
        case .array(let values):
            return values.map { jsonValue(for: $0) }
        case .binary(let data, let sub):
            return ["$binary": data.base64EncodedString(), "$subtype": String(format: "%02x", sub)]
        case .objectId(let oid):
            return ["$oid": oid.hexString]
        case .bool(let b): return b
        case .datetime(let ms):
            let date = Date(timeIntervalSince1970: Double(ms) / 1000)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return ["$date": f.string(from: date)]
        case .null: return NSNull()
        case .regex(let p, let o):
            return ["$regex": p, "$options": o]
        case .int32(let v): return Int(v)
        case .timestamp(let inc, let sec):
            return ["$timestamp": ["t": Int(sec), "i": Int(inc)]]
        case .int64(let v): return v
        case .unsupported(let tb): return ["$unsupported": String(format: "0x%02x", tb)]
        }
    }
}
