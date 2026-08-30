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
        public let tag: String
        public let title: String
        public let fields: [(String, String)]
        public let rawJSON: String?
        public let children: [Section]
        public init(tag: String, title: String, fields: [(String, String)], rawJSON: String?, children: [Section]) {
            self.tag = tag; self.title = title; self.fields = fields; self.rawJSON = rawJSON; self.children = children
        }
    }

    public let header: Header
    public let sections: [Section]

    public init(header: Header, sections: [Section]) {
        self.header = header; self.sections = sections
    }

    public struct Header: Sendable {
        public let version: String?
        public let format: String?
        public let timestamp: Date?
        public let origin: Identity.Origin?
        public let kind: Identity.Kind?
        public let redacted: Bool
        public let selectionCount: Int
        public let producedBy: String
        /// Set by `Exporter.exportSlices` when a selection was split across
        /// more than one standalone document (e.g. "part 2 of 5"); `nil` for
        /// a single-document export.
        public let partNote: String?
        public init(
            version: String?,
            format: String?,
            timestamp: Date?,
            origin: Identity.Origin?,
            kind: Identity.Kind?,
            redacted: Bool,
            selectionCount: Int,
            producedBy: String,
            partNote: String? = nil
        ) {
            self.version = version; self.format = format; self.timestamp = timestamp; self.origin = origin; self.kind = kind; self.redacted = redacted; self.selectionCount = selectionCount; self.producedBy = producedBy; self.partNote = partNote
        }
    }

    /// Builds the IR from a user selection, preserving hierarchy: when the
    /// selection includes a container node (`.site`, `.siteChildCategory`,
    /// `.wlanGroup`, `.category`, `.opaqueCollection`), its descendants — the
    /// full subtree, per `TreeBuilder.children(of:)` — are nested under that
    /// container's `Section.children` rather than flattened alongside it.
    /// A record selected without its container ancestor present stays a
    /// top-level `Section`, matching the flat behaviour of a single-node
    /// selection.
    public static func from(
        _ nodes: [TreeNode],
        identity: Identity?,
        redact: Bool
    ) -> IntermediateRepresentation {
        var visited = Set<String>()
        var sections: [Section] = []
        for node in nodes {
            if visited.contains(node.id) { continue }
            if let section = buildSection(node: node, redact: redact, visited: &visited) {
                sections.append(section)
            }
        }

        // Selection count mirrors the flat "how many exportable records did
        // this pull in" metric regardless of how they end up nested.
        let recordCount = TreeBuilder.flatten(nodes).filter { $0.rawDocument != nil }.count

        let header = Header(
            version: identity?.version,
            format: identity?.format,
            timestamp: identity?.timestamp,
            origin: identity?.origin,
            kind: identity?.kind,
            redacted: redact,
            selectionCount: recordCount,
            producedBy: "UniFi Backup Inspector"
        )
        return IntermediateRepresentation(header: header, sections: sections)
    }

    /// Container node kinds whose descendants (per `TreeBuilder.children(of:)`)
    /// get nested under them rather than flattened.
    private static func isContainer(_ node: TreeNode) -> Bool {
        switch node {
        case .category, .site, .siteChildCategory, .wlanGroup, .opaqueCollection:
            return true
        default:
            return false
        }
    }

    /// Recursively builds a `Section` for `node`. Containers walk their model
    /// children (skipping any already `visited` — e.g. because they were
    /// already emitted top-level earlier in the selection) and nest the
    /// results; leaves render flat as before. Returns `nil` when there's
    /// nothing to show (a container with no own document and no non-empty
    /// descendants, or a leaf with no backing document).
    private static func buildSection(
        node: TreeNode,
        redact: Bool,
        visited: inout Set<String>
    ) -> Section? {
        visited.insert(node.id)

        var childSections: [Section] = []
        if isContainer(node) {
            for child in TreeBuilder.children(of: node) {
                if visited.contains(child.id) { continue }
                if let s = buildSection(node: child, redact: redact, visited: &visited) {
                    childSections.append(s)
                }
            }
        }

        guard let raw = node.rawDocument else {
            guard isContainer(node), !childSections.isEmpty else { return nil }
            return Section(tag: tag(for: node), title: node.title, fields: [], rawJSON: nil, children: childSections)
        }

        let effective = redact ? SecretVault.redact(raw) : raw
        let fields = prettyFields(from: effective)
        let rawJSON = jsonString(from: effective)
        return Section(tag: tag(for: node), title: node.title, fields: fields, rawJSON: rawJSON, children: childSections)
    }

    private static func tag(for node: TreeNode) -> String {
        switch node {
        case .category(let n): n.id
        case .site: "site"
        case .siteChildCategory(let n): n.kind.rawValue
        case .device: "device"
        case .wlanGroup: "wlan_group"
        case .wlan: "wlan"
        case .network: "network"
        case .firewallGroup: "firewall_group"
        case .firewallRule: "firewall_rule"
        case .portForward: "port_forward"
        case .portProfile: "port_profile"
        case .routing: "routing"
        case .client: "client"
        case .admin: "admin"
        case .account: "account"
        case .radius: "radius_profile"
        case .hotspotOp: "hotspot_operator"
        case .setting: "setting"
        case .opaqueCollection(let n): n.name
        case .opaqueRecord(let n): n.parentCollection
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
