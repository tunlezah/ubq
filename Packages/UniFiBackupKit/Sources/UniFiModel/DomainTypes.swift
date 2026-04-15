import Foundation
import UniFiBSON

/// Lightweight strongly-typed view over the most commonly-inspected UniFi
/// collections. We keep the original `BSONDocument` around so the UI and
/// export layer can drill down beyond what we've mapped.
///
/// Unknown fields and unknown collections are never lost: they end up in
/// `rawDocument` (individual records) or `OpaqueCollection` (whole collections).

public struct Site: Sendable, Hashable {
    public let id: String
    public let name: String
    public let desc: String?
    public let attrHiddenId: String?
    public let attrNoDelete: Bool?
    public let rawDocument: BSONDocument
}

public struct Device: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let mac: String?
    public let name: String?
    public let model: String?
    public let type: String?
    public let version: String?
    public let adopted: Bool?
    public let serial: String?
    public let rawDocument: BSONDocument
}

public struct Client: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let mac: String?
    public let hostname: String?
    public let name: String?
    public let isGuest: Bool?
    public let isWired: Bool?
    public let noted: Bool?
    public let fixedIp: String?
    public let usergroupId: String?
    public let networkId: String?
    public let rawDocument: BSONDocument
}

public struct Wlan: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?       // SSID
    public let security: String?
    public let wpaMode: String?
    public let vlan: Int32?
    public let enabled: Bool?
    public let isGuest: Bool?
    public let wlangroupId: String?
    public let usergroupId: String?
    public let passphrase: String? // x_passphrase — secret
    public let rawDocument: BSONDocument
}

public struct WlanGroup: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let rawDocument: BSONDocument
}

public struct Network: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let purpose: String?
    public let vlan: Int32?
    public let ipSubnet: String?
    public let domainName: String?
    public let isNat: Bool?
    public let rawDocument: BSONDocument
}

public struct PortProfile: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let nativeNetworkId: String?
    public let forward: String?
    public let poeMode: String?
    public let rawDocument: BSONDocument
}

public struct PortForward: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let fwd: String?
    public let src: String?
    public let proto: String?
    public let dstPort: String?
    public let fwdPort: String?
    public let enabled: Bool?
    public let rawDocument: BSONDocument
}

public struct FirewallRule: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let ruleset: String?
    public let ruleIndex: Int32?
    public let action: String?
    public let proto: String?
    public let enabled: Bool?
    public let rawDocument: BSONDocument
}

public struct FirewallGroup: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let groupType: String?
    public let groupMembers: [String]
    public let rawDocument: BSONDocument
}

public struct RoutingEntry: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let enabled: Bool?
    public let rawDocument: BSONDocument
}

public struct Admin: Sendable, Hashable {
    public let id: String
    public let name: String?
    public let email: String?
    public let lastSiteName: String?
    public let timeCreated: Date?
    public let rawDocument: BSONDocument       // contains x_shadow — secret
}

public struct Account: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let vlan: Int32?
    public let tunnelType: String?
    public let rawDocument: BSONDocument       // contains x_password — secret
}

public struct RadiusProfile: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let rawDocument: BSONDocument       // auth_servers contain shared secrets
}

public struct HotspotOperator: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let rawDocument: BSONDocument       // x_password — secret
}

public struct SettingPanel: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let key: String?
    public let rawDocument: BSONDocument
}

/// Fallback record for every collection we haven't strongly-typed. Preserves
/// everything verbatim.
public struct OpaqueRecord: Sendable, Hashable {
    public let id: String
    public let rawDocument: BSONDocument
}

/// Fallback for whole collections we don't recognise.
public struct OpaqueCollection: Sendable, Hashable {
    public let name: String
    public let records: [OpaqueRecord]
}

// Helpers to extract common fields.
extension BSONDocument {
    /// `_id` as a hex string, or empty if missing / unexpected type.
    public var idString: String {
        switch self["_id"] {
        case .some(.objectId(let oid)): return oid.hexString
        case .some(.string(let s)): return s
        case .some(.int32(let v)): return String(v)
        case .some(.int64(let v)): return String(v)
        default: return ""
        }
    }
    public var siteIdString: String? {
        switch self["site_id"] {
        case .some(.objectId(let oid)): return oid.hexString
        case .some(.string(let s)): return s
        default: return nil
        }
    }
}
