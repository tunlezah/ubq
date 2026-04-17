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
    public init(id: String, name: String, desc: String?, attrHiddenId: String?, attrNoDelete: Bool?, rawDocument: BSONDocument) {
        self.id = id; self.name = name; self.desc = desc; self.attrHiddenId = attrHiddenId; self.attrNoDelete = attrNoDelete; self.rawDocument = rawDocument
    }
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
    public init(id: String, siteId: String?, mac: String?, name: String?, model: String?, type: String?, version: String?, adopted: Bool?, serial: String?, rawDocument: BSONDocument) {
        self.id = id; self.siteId = siteId; self.mac = mac; self.name = name; self.model = model; self.type = type; self.version = version; self.adopted = adopted; self.serial = serial; self.rawDocument = rawDocument
    }
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
    public init(id: String, siteId: String?, mac: String?, hostname: String?, name: String?, isGuest: Bool?, isWired: Bool?, noted: Bool?, fixedIp: String?, usergroupId: String?, networkId: String?, rawDocument: BSONDocument) {
        self.id = id; self.siteId = siteId; self.mac = mac; self.hostname = hostname; self.name = name; self.isGuest = isGuest; self.isWired = isWired; self.noted = noted; self.fixedIp = fixedIp; self.usergroupId = usergroupId; self.networkId = networkId; self.rawDocument = rawDocument
    }
}

public struct Wlan: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let security: String?
    public let wpaMode: String?
    public let vlan: Int32?
    public let enabled: Bool?
    public let isGuest: Bool?
    public let wlangroupId: String?
    public let usergroupId: String?
    public let passphrase: String?
    public let rawDocument: BSONDocument
    public init(id: String, siteId: String?, name: String?, security: String?, wpaMode: String?, vlan: Int32?, enabled: Bool?, isGuest: Bool?, wlangroupId: String?, usergroupId: String?, passphrase: String?, rawDocument: BSONDocument) {
        self.id = id; self.siteId = siteId; self.name = name; self.security = security; self.wpaMode = wpaMode; self.vlan = vlan; self.enabled = enabled; self.isGuest = isGuest; self.wlangroupId = wlangroupId; self.usergroupId = usergroupId; self.passphrase = passphrase; self.rawDocument = rawDocument
    }
}

public struct WlanGroup: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let rawDocument: BSONDocument
    public init(id: String, siteId: String?, name: String?, rawDocument: BSONDocument) {
        self.id = id; self.siteId = siteId; self.name = name; self.rawDocument = rawDocument
    }
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
    public init(id: String, siteId: String?, name: String?, purpose: String?, vlan: Int32?, ipSubnet: String?, domainName: String?, isNat: Bool?, rawDocument: BSONDocument) {
        self.id = id; self.siteId = siteId; self.name = name; self.purpose = purpose; self.vlan = vlan; self.ipSubnet = ipSubnet; self.domainName = domainName; self.isNat = isNat; self.rawDocument = rawDocument
    }
}

public struct PortProfile: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let nativeNetworkId: String?
    public let forward: String?
    public let poeMode: String?
    public let rawDocument: BSONDocument
    public init(id: String, siteId: String?, name: String?, nativeNetworkId: String?, forward: String?, poeMode: String?, rawDocument: BSONDocument) {
        self.id = id; self.siteId = siteId; self.name = name; self.nativeNetworkId = nativeNetworkId; self.forward = forward; self.poeMode = poeMode; self.rawDocument = rawDocument
    }
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
    public init(id: String, siteId: String?, name: String?, fwd: String?, src: String?, proto: String?, dstPort: String?, fwdPort: String?, enabled: Bool?, rawDocument: BSONDocument) {
        self.id = id; self.siteId = siteId; self.name = name; self.fwd = fwd; self.src = src; self.proto = proto; self.dstPort = dstPort; self.fwdPort = fwdPort; self.enabled = enabled; self.rawDocument = rawDocument
    }
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
    public init(id: String, siteId: String?, name: String?, ruleset: String?, ruleIndex: Int32?, action: String?, proto: String?, enabled: Bool?, rawDocument: BSONDocument) {
        self.id = id; self.siteId = siteId; self.name = name; self.ruleset = ruleset; self.ruleIndex = ruleIndex; self.action = action; self.proto = proto; self.enabled = enabled; self.rawDocument = rawDocument
    }
}

public struct FirewallGroup: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let groupType: String?
    public let groupMembers: [String]
    public let rawDocument: BSONDocument
    public init(id: String, siteId: String?, name: String?, groupType: String?, groupMembers: [String], rawDocument: BSONDocument) {
        self.id = id; self.siteId = siteId; self.name = name; self.groupType = groupType; self.groupMembers = groupMembers; self.rawDocument = rawDocument
    }
}

public struct RoutingEntry: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let enabled: Bool?
    public let rawDocument: BSONDocument
    public init(id: String, siteId: String?, name: String?, enabled: Bool?, rawDocument: BSONDocument) {
        self.id = id; self.siteId = siteId; self.name = name; self.enabled = enabled; self.rawDocument = rawDocument
    }
}

public struct Admin: Sendable, Hashable {
    public let id: String
    public let name: String?
    public let email: String?
    public let lastSiteName: String?
    public let timeCreated: Date?
    public let rawDocument: BSONDocument
    public init(id: String, name: String?, email: String?, lastSiteName: String?, timeCreated: Date?, rawDocument: BSONDocument) {
        self.id = id; self.name = name; self.email = email; self.lastSiteName = lastSiteName; self.timeCreated = timeCreated; self.rawDocument = rawDocument
    }
}

public struct Account: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let vlan: Int32?
    public let tunnelType: String?
    public let rawDocument: BSONDocument
    public init(id: String, siteId: String?, name: String?, vlan: Int32?, tunnelType: String?, rawDocument: BSONDocument) {
        self.id = id; self.siteId = siteId; self.name = name; self.vlan = vlan; self.tunnelType = tunnelType; self.rawDocument = rawDocument
    }
}

public struct RadiusProfile: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let rawDocument: BSONDocument
    public init(id: String, siteId: String?, name: String?, rawDocument: BSONDocument) {
        self.id = id; self.siteId = siteId; self.name = name; self.rawDocument = rawDocument
    }
}

public struct HotspotOperator: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let name: String?
    public let rawDocument: BSONDocument
    public init(id: String, siteId: String?, name: String?, rawDocument: BSONDocument) {
        self.id = id; self.siteId = siteId; self.name = name; self.rawDocument = rawDocument
    }
}

public struct SettingPanel: Sendable, Hashable {
    public let id: String
    public let siteId: String?
    public let key: String?
    public let rawDocument: BSONDocument
    public init(id: String, siteId: String?, key: String?, rawDocument: BSONDocument) {
        self.id = id; self.siteId = siteId; self.key = key; self.rawDocument = rawDocument
    }
}

public struct OpaqueRecord: Sendable, Hashable {
    public let id: String
    public let rawDocument: BSONDocument
    public init(id: String, rawDocument: BSONDocument) {
        self.id = id; self.rawDocument = rawDocument
    }
}

public struct OpaqueCollection: Sendable, Hashable {
    public let name: String
    public let records: [OpaqueRecord]
    public init(name: String, records: [OpaqueRecord]) {
        self.name = name; self.records = records
    }
}

extension BSONDocument {
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
