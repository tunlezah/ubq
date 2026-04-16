import Foundation
import UniFiBSON

/// Uniform navigable tree consumed by the UI. Categories are the top-level
/// source-list entries; nested nodes are the middle-pane outline rows.
public enum TreeNode: Identifiable, Hashable, Sendable {
    case category(CategoryNode)
    case site(SiteNode)
    case siteChildCategory(SiteChildCategory)
    case device(DeviceNode)
    case wlanGroup(WlanGroupNode)
    case wlan(WlanNode)
    case network(NetworkNode)
    case firewallGroup(FirewallGroupNode)
    case firewallRule(FirewallRuleNode)
    case portForward(PortForwardNode)
    case portProfile(PortProfileNode)
    case routing(RoutingNode)
    case client(ClientNode)
    case admin(AdminNode)
    case account(AccountNode)
    case radius(RadiusNode)
    case hotspotOp(HotspotOpNode)
    case setting(SettingNode)
    case opaqueCollection(OpaqueCollectionNode)
    case opaqueRecord(OpaqueRecordNode)

    public var id: String {
        switch self {
        case .category(let n): "cat:\(n.id)"
        case .site(let n): "site:\(n.id)"
        case .siteChildCategory(let n): "sitechild:\(n.siteId):\(n.kind.rawValue)"
        case .device(let n): "device:\(n.id)"
        case .wlanGroup(let n): "wlangroup:\(n.id)"
        case .wlan(let n): "wlan:\(n.id)"
        case .network(let n): "network:\(n.id)"
        case .firewallGroup(let n): "fwgroup:\(n.id)"
        case .firewallRule(let n): "fwrule:\(n.id)"
        case .portForward(let n): "pf:\(n.id)"
        case .portProfile(let n): "pp:\(n.id)"
        case .routing(let n): "rt:\(n.id)"
        case .client(let n): "client:\(n.id)"
        case .admin(let n): "admin:\(n.id)"
        case .account(let n): "acct:\(n.id)"
        case .radius(let n): "radius:\(n.id)"
        case .hotspotOp(let n): "hsop:\(n.id)"
        case .setting(let n): "set:\(n.id)"
        case .opaqueCollection(let n): "opcoll:\(n.name)"
        case .opaqueRecord(let n): "oprec:\(n.parentCollection):\(n.id)"
        }
    }

    public var title: String {
        switch self {
        case .category(let n): n.title
        case .site(let n): n.title
        case .siteChildCategory(let n): n.kind.title
        case .device(let n): n.title
        case .wlanGroup(let n): n.title
        case .wlan(let n): n.title
        case .network(let n): n.title
        case .firewallGroup(let n): n.title
        case .firewallRule(let n): n.title
        case .portForward(let n): n.title
        case .portProfile(let n): n.title
        case .routing(let n): n.title
        case .client(let n): n.title
        case .admin(let n): n.title
        case .account(let n): n.title
        case .radius(let n): n.title
        case .hotspotOp(let n): n.title
        case .setting(let n): n.title
        case .opaqueCollection(let n): n.name
        case .opaqueRecord(let n): n.title
        }
    }

    public var symbolName: String {
        switch self {
        case .category(let n): n.symbolName
        case .site: "house"
        case .siteChildCategory(let n): n.kind.symbolName
        case .device: "antenna.radiowaves.left.and.right"
        case .wlanGroup: "wifi.square"
        case .wlan: "wifi"
        case .network: "network"
        case .firewallGroup: "shield.lefthalf.filled"
        case .firewallRule: "shield"
        case .portForward: "arrow.forward.to.line"
        case .portProfile: "rectangle.stack"
        case .routing: "arrow.triangle.branch"
        case .client: "person"
        case .admin: "person.badge.key"
        case .account: "person.crop.circle.badge.questionmark"
        case .radius: "key"
        case .hotspotOp: "ticket"
        case .setting: "slider.horizontal.3"
        case .opaqueCollection: "tray.full"
        case .opaqueRecord: "doc.text"
        }
    }

    /// BSON raw backing document, when the node maps to a single record.
    public var rawDocument: BSONDocument? {
        switch self {
        case .site(let n): n.raw
        case .device(let n): n.raw
        case .wlan(let n): n.raw
        case .network(let n): n.raw
        case .firewallGroup(let n): n.raw
        case .firewallRule(let n): n.raw
        case .portForward(let n): n.raw
        case .portProfile(let n): n.raw
        case .routing(let n): n.raw
        case .client(let n): n.raw
        case .admin(let n): n.raw
        case .account(let n): n.raw
        case .radius(let n): n.raw
        case .hotspotOp(let n): n.raw
        case .setting(let n): n.raw
        case .opaqueRecord(let n): n.raw
        default: nil
        }
    }
}

public struct CategoryNode: Hashable, Sendable {
    public let id: String
    public let title: String
    public let symbolName: String
    public let badge: Int?
    public var children: [TreeNode]

    public init(id: String, title: String, symbolName: String, badge: Int?, children: [TreeNode]) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.badge = badge
        self.children = children
    }
}

public struct SiteNode: Hashable, Sendable {
    public let id: String
    public let title: String
    public let raw: BSONDocument?
    public var children: [TreeNode]

    public init(id: String, title: String, raw: BSONDocument?, children: [TreeNode]) {
        self.id = id
        self.title = title
        self.raw = raw
        self.children = children
    }
}

public struct SiteChildCategory: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case devices, wlans, networks, firewall, portProfiles, clients, settings
        public var title: String {
            switch self {
            case .devices: "Devices"
            case .wlans: "WLANs"
            case .networks: "Networks"
            case .firewall: "Firewall"
            case .portProfiles: "Port Profiles"
            case .clients: "Clients"
            case .settings: "Settings"
            }
        }
        public var symbolName: String {
            switch self {
            case .devices: "antenna.radiowaves.left.and.right"
            case .wlans: "wifi"
            case .networks: "network"
            case .firewall: "shield"
            case .portProfiles: "rectangle.stack"
            case .clients: "person.2"
            case .settings: "slider.horizontal.3"
            }
        }
    }
    public let siteId: String
    public let kind: Kind
    public var children: [TreeNode]

    public init(siteId: String, kind: Kind, children: [TreeNode]) {
        self.siteId = siteId
        self.kind = kind
        self.children = children
    }
}

/// Simple leaf node for a record that has a raw backing document.
public struct RecordNode: Hashable, Sendable {
    public let id: String
    public let title: String
    public let raw: BSONDocument?
    public init(id: String, title: String, raw: BSONDocument?) {
        self.id = id
        self.title = title
        self.raw = raw
    }
}

public typealias DeviceNode = RecordNode
public typealias WlanNode = RecordNode
public typealias NetworkNode = RecordNode
public typealias FirewallGroupNode = RecordNode
public typealias FirewallRuleNode = RecordNode
public typealias PortForwardNode = RecordNode
public typealias PortProfileNode = RecordNode
public typealias RoutingNode = RecordNode
public typealias ClientNode = RecordNode
public typealias AdminNode = RecordNode
public typealias AccountNode = RecordNode
public typealias RadiusNode = RecordNode
public typealias HotspotOpNode = RecordNode
public typealias SettingNode = RecordNode

public struct WlanGroupNode: Hashable, Sendable {
    public let id: String
    public let title: String
    public var children: [TreeNode]
    public init(id: String, title: String, children: [TreeNode]) {
        self.id = id
        self.title = title
        self.children = children
    }
}

public struct OpaqueCollectionNode: Hashable, Sendable {
    public let name: String
    public var children: [TreeNode]
    public init(name: String, children: [TreeNode]) {
        self.name = name
        self.children = children
    }
}

public struct OpaqueRecordNode: Hashable, Sendable {
    public let id: String
    public let title: String
    public let parentCollection: String
    public let raw: BSONDocument
    public init(id: String, title: String, parentCollection: String, raw: BSONDocument) {
        self.id = id
        self.title = title
        self.parentCollection = parentCollection
        self.raw = raw
    }
}

/// Builds the top-level tree from a `MappedModel`.
public enum TreeBuilder {
    public static func build(_ m: ModelMapper.MappedModel) -> [TreeNode] {
        var cats: [TreeNode] = []

        // Sites category — each site drills into its children (devices, wlans, …)
        let siteNodes = m.sites.map { site -> TreeNode in
            let siteId = site.id
            let siteDevices = m.devices.filter { $0.siteId == siteId }
            let siteWlans = m.wlans.filter { $0.siteId == siteId }
            let siteWlanGroups = m.wlanGroups.filter { $0.siteId == siteId }
            let siteNetworks = m.networks.filter { $0.siteId == siteId }
            let siteFwRules = m.firewallRules.filter { $0.siteId == siteId }
            let siteFwGroups = m.firewallGroups.filter { $0.siteId == siteId }
            let sitePortForwards = m.portForwards.filter { $0.siteId == siteId }
            let sitePortProfiles = m.portProfiles.filter { $0.siteId == siteId }
            let siteClients = m.clients.filter { $0.siteId == siteId }
            let siteSettings = m.settings.filter { $0.siteId == siteId }
            let siteRouting = m.routing.filter { $0.siteId == siteId }

            var kids: [TreeNode] = []

            if !siteDevices.isEmpty {
                kids.append(.siteChildCategory(SiteChildCategory(
                    siteId: siteId, kind: .devices,
                    children: siteDevices.map { d in
                        .device(DeviceNode(
                            id: d.id,
                            title: [d.name, d.mac, d.model].compactMap { $0 }.joined(separator: " · "),
                            raw: d.rawDocument
                        ))
                    }
                )))
            }

            if !siteWlans.isEmpty || !siteWlanGroups.isEmpty {
                // WLANs grouped by wlangroup where the group is known; stragglers flat.
                var wlanChildren: [TreeNode] = []
                for group in siteWlanGroups {
                    let kids = siteWlans
                        .filter { $0.wlangroupId == group.id }
                        .map { w in TreeNode.wlan(WlanNode(id: w.id, title: w.name ?? "(unnamed)", raw: w.rawDocument)) }
                    wlanChildren.append(.wlanGroup(WlanGroupNode(
                        id: group.id,
                        title: group.name ?? "Group",
                        children: kids
                    )))
                }
                let ungrouped = siteWlans.filter { w in
                    w.wlangroupId == nil || !siteWlanGroups.contains(where: { $0.id == w.wlangroupId })
                }
                for w in ungrouped {
                    wlanChildren.append(.wlan(WlanNode(id: w.id, title: w.name ?? "(unnamed)", raw: w.rawDocument)))
                }
                kids.append(.siteChildCategory(SiteChildCategory(
                    siteId: siteId, kind: .wlans, children: wlanChildren
                )))
            }

            if !siteNetworks.isEmpty {
                kids.append(.siteChildCategory(SiteChildCategory(
                    siteId: siteId, kind: .networks,
                    children: siteNetworks.map { n in
                        .network(NetworkNode(id: n.id, title: [n.name, n.ipSubnet].compactMap { $0 }.joined(separator: " · "), raw: n.rawDocument))
                    }
                )))
            }

            if !siteFwRules.isEmpty || !siteFwGroups.isEmpty || !sitePortForwards.isEmpty {
                var fwKids: [TreeNode] = []
                fwKids.append(contentsOf: siteFwRules.map { r in
                    TreeNode.firewallRule(FirewallRuleNode(
                        id: r.id,
                        title: [r.ruleset, r.name].compactMap { $0 }.joined(separator: " · "),
                        raw: r.rawDocument
                    ))
                })
                fwKids.append(contentsOf: siteFwGroups.map { g in
                    TreeNode.firewallGroup(FirewallGroupNode(
                        id: g.id,
                        title: [g.groupType, g.name].compactMap { $0 }.joined(separator: " · "),
                        raw: g.rawDocument
                    ))
                })
                fwKids.append(contentsOf: sitePortForwards.map { p in
                    TreeNode.portForward(PortForwardNode(
                        id: p.id,
                        title: p.name ?? "(unnamed)",
                        raw: p.rawDocument
                    ))
                })
                fwKids.append(contentsOf: siteRouting.map { r in
                    TreeNode.routing(RoutingNode(
                        id: r.id,
                        title: r.name ?? "(unnamed route)",
                        raw: r.rawDocument
                    ))
                })
                kids.append(.siteChildCategory(SiteChildCategory(
                    siteId: siteId, kind: .firewall, children: fwKids
                )))
            }

            if !sitePortProfiles.isEmpty {
                kids.append(.siteChildCategory(SiteChildCategory(
                    siteId: siteId, kind: .portProfiles,
                    children: sitePortProfiles.map { p in
                        .portProfile(PortProfileNode(id: p.id, title: p.name ?? "(unnamed)", raw: p.rawDocument))
                    }
                )))
            }

            if !siteClients.isEmpty {
                kids.append(.siteChildCategory(SiteChildCategory(
                    siteId: siteId, kind: .clients,
                    children: siteClients.map { c in
                        .client(ClientNode(
                            id: c.id,
                            title: [c.name, c.hostname, c.mac].compactMap { $0 }.joined(separator: " · "),
                            raw: c.rawDocument
                        ))
                    }
                )))
            }

            if !siteSettings.isEmpty {
                kids.append(.siteChildCategory(SiteChildCategory(
                    siteId: siteId, kind: .settings,
                    children: siteSettings.map { s in
                        .setting(SettingNode(id: s.id, title: s.key ?? "(setting)", raw: s.rawDocument))
                    }
                )))
            }

            return .site(SiteNode(
                id: site.id,
                title: [site.desc, site.name].compactMap { $0 }.first ?? site.id,
                raw: site.rawDocument,
                children: kids
            ))
        }

        if !siteNodes.isEmpty {
            cats.append(.category(CategoryNode(
                id: "sites", title: "Sites", symbolName: "house",
                badge: siteNodes.count, children: siteNodes
            )))
        }

        // Admins (controller-wide).
        if !m.admins.isEmpty {
            let children = m.admins.map { a in
                TreeNode.admin(AdminNode(id: a.id, title: [a.name, a.email].compactMap { $0 }.joined(separator: " · "), raw: a.rawDocument))
            }
            cats.append(.category(CategoryNode(
                id: "admins", title: "Admins", symbolName: "person.badge.key",
                badge: m.admins.count, children: children
            )))
        }

        // RADIUS (controller-wide aggregate).
        if !m.radiusProfiles.isEmpty {
            let children = m.radiusProfiles.map { r in
                TreeNode.radius(RadiusNode(id: r.id, title: r.name ?? "(profile)", raw: r.rawDocument))
            }
            cats.append(.category(CategoryNode(
                id: "radius", title: "RADIUS Profiles", symbolName: "key",
                badge: m.radiusProfiles.count, children: children
            )))
        }

        if !m.hotspotOperators.isEmpty {
            let children = m.hotspotOperators.map { h in
                TreeNode.hotspotOp(HotspotOpNode(id: h.id, title: h.name ?? "(op)", raw: h.rawDocument))
            }
            cats.append(.category(CategoryNode(
                id: "hotspot", title: "Hotspot Operators", symbolName: "ticket",
                badge: m.hotspotOperators.count, children: children
            )))
        }

        if !m.accounts.isEmpty {
            let children = m.accounts.map { a in
                TreeNode.account(AccountNode(id: a.id, title: a.name ?? "(account)", raw: a.rawDocument))
            }
            cats.append(.category(CategoryNode(
                id: "accounts", title: "Accounts", symbolName: "person.crop.circle.badge.questionmark",
                badge: m.accounts.count, children: children
            )))
        }

        // Opaque / unknown collections.
        if !m.opaqueCollections.isEmpty {
            let opaqueChildren = m.opaqueCollections.map { c -> TreeNode in
                let kids = c.records.map { r in
                    TreeNode.opaqueRecord(OpaqueRecordNode(
                        id: r.id,
                        title: r.id.isEmpty ? "(no id)" : r.id,
                        parentCollection: c.name,
                        raw: r.rawDocument
                    ))
                }
                return .opaqueCollection(OpaqueCollectionNode(name: c.name, children: kids))
            }
            cats.append(.category(CategoryNode(
                id: "opaque", title: "Other Collections", symbolName: "tray.full",
                badge: m.opaqueCollections.count, children: opaqueChildren
            )))
        }

        return cats
    }

    /// Walks a tree to produce a flat list of all nodes — used by the outline
    /// view for filtering / selection state.
    public static func flatten(_ nodes: [TreeNode]) -> [TreeNode] {
        var out: [TreeNode] = []
        for n in nodes {
            out.append(n)
            out.append(contentsOf: flatten(children(of: n)))
        }
        return out
    }

    public static func children(of node: TreeNode) -> [TreeNode] {
        switch node {
        case .category(let n): n.children
        case .site(let n): n.children
        case .siteChildCategory(let n): n.children
        case .wlanGroup(let n): n.children
        case .opaqueCollection(let n): n.children
        default: []
        }
    }
}
