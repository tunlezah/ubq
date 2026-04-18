import Foundation
import UniFiBSON
import BackupStream
import Diagnostics

/// Maps the raw `[collection -> [BSONDocument]]` output of `CollectionStream`
/// into strongly-typed arrays where we know the schema, and opaque collections
/// where we don't. Defensive throughout: a missing field doesn't fail a record;
/// a totally unexpected shape gets logged as a diagnostic.
public struct ModelMapper {
    public let diagnostics: DiagnosticSink
    public init(diagnostics: DiagnosticSink) { self.diagnostics = diagnostics }

    public struct MappedModel: Sendable {
        public var sites: [Site] = []
        public var devices: [Device] = []
        public var clients: [Client] = []
        public var wlans: [Wlan] = []
        public var wlanGroups: [WlanGroup] = []
        public var networks: [Network] = []
        public var portProfiles: [PortProfile] = []
        public var portForwards: [PortForward] = []
        public var firewallRules: [FirewallRule] = []
        public var firewallGroups: [FirewallGroup] = []
        public var routing: [RoutingEntry] = []
        public var admins: [Admin] = []
        public var accounts: [Account] = []
        public var radiusProfiles: [RadiusProfile] = []
        public var hotspotOperators: [HotspotOperator] = []
        public var settings: [SettingPanel] = []
        public var opaqueCollections: [OpaqueCollection] = []
        public init() {}
    }

    public func map(_ output: CollectionStream.Output) -> MappedModel {
        var model = MappedModel()
        for name in output.orderedCollectionNames {
            let docs = output.recordsByCollection[name] ?? []
            switch name {
            case "site":
                model.sites = docs.map(mapSite)
            case "device":
                model.devices = docs.map(mapDevice)
            case "user":
                model.clients = docs.map(mapClient)
            case "wlanconf":
                model.wlans = docs.map(mapWlan)
            case "wlangroup":
                model.wlanGroups = docs.map(mapWlanGroup)
            case "networkconf":
                model.networks = docs.map(mapNetwork)
            case "portconf":
                model.portProfiles = docs.map(mapPortProfile)
            case "portforward":
                model.portForwards = docs.map(mapPortForward)
            case "firewallrule":
                model.firewallRules = docs.map(mapFirewallRule)
            case "firewallgroup":
                model.firewallGroups = docs.map(mapFirewallGroup)
            case "routing":
                model.routing = docs.map(mapRouting)
            case "admin":
                model.admins = docs.map(mapAdmin)
            case "account":
                model.accounts = docs.map(mapAccount)
            case "radiusprofile":
                model.radiusProfiles = docs.map(mapRadius)
            case "hotspotop":
                model.hotspotOperators = docs.map(mapHotspotOp)
            case "setting":
                model.settings = docs.map(mapSetting)
            default:
                diagnostics.emit(
                    .info,
                    .unknownCollection,
                    "Collection '\(name)' (\(docs.count) records) is not strongly-typed; surfacing as opaque.",
                    collection: name
                )
                model.opaqueCollections.append(
                    OpaqueCollection(
                        name: name,
                        records: docs.map { OpaqueRecord(id: $0.idString, rawDocument: $0) }
                    )
                )
            }
        }
        return model
    }

    // MARK: - Per-collection mappers

    func mapSite(_ d: BSONDocument) -> Site {
        Site(
            id: d.idString,
            name: d["name"]?.stringValue ?? "",
            desc: d["desc"]?.stringValue,
            attrHiddenId: d["attr_hidden_id"]?.stringValue,
            attrNoDelete: d["attr_no_delete"]?.boolValue,
            rawDocument: d
        )
    }

    func mapDevice(_ d: BSONDocument) -> Device {
        Device(
            id: d.idString,
            siteId: d.siteIdString,
            mac: d["mac"]?.stringValue,
            name: d["name"]?.stringValue,
            model: d["model"]?.stringValue,
            type: d["type"]?.stringValue,
            version: d["version"]?.stringValue,
            adopted: d["adopted"]?.boolValue,
            serial: d["serial"]?.stringValue,
            rawDocument: d
        )
    }

    func mapClient(_ d: BSONDocument) -> Client {
        Client(
            id: d.idString,
            siteId: d.siteIdString,
            mac: d["mac"]?.stringValue,
            hostname: d["hostname"]?.stringValue,
            name: d["name"]?.stringValue,
            isGuest: d["is_guest"]?.boolValue,
            isWired: d["is_wired"]?.boolValue,
            noted: d["noted"]?.boolValue,
            fixedIp: d["fixed_ip"]?.stringValue,
            usergroupId: d["usergroup_id"]?.objectIdValue?.hexString ?? d["usergroup_id"]?.stringValue,
            networkId: d["network_id"]?.objectIdValue?.hexString ?? d["network_id"]?.stringValue,
            rawDocument: d
        )
    }

    func mapWlan(_ d: BSONDocument) -> Wlan {
        Wlan(
            id: d.idString,
            siteId: d.siteIdString,
            name: d["name"]?.stringValue,
            security: d["security"]?.stringValue,
            wpaMode: d["wpa_mode"]?.stringValue,
            vlan: d["vlan"]?.int32Value,
            enabled: d["enabled"]?.boolValue,
            isGuest: d["is_guest"]?.boolValue,
            wlangroupId: d["wlangroup_id"]?.objectIdValue?.hexString ?? d["wlangroup_id"]?.stringValue,
            usergroupId: d["usergroup_id"]?.objectIdValue?.hexString ?? d["usergroup_id"]?.stringValue,
            passphrase: d["x_passphrase"]?.stringValue,
            rawDocument: d
        )
    }

    func mapWlanGroup(_ d: BSONDocument) -> WlanGroup {
        WlanGroup(
            id: d.idString,
            siteId: d.siteIdString,
            name: d["name"]?.stringValue,
            rawDocument: d
        )
    }

    func mapNetwork(_ d: BSONDocument) -> Network {
        Network(
            id: d.idString,
            siteId: d.siteIdString,
            name: d["name"]?.stringValue,
            purpose: d["purpose"]?.stringValue,
            vlan: d["vlan"]?.int32Value,
            ipSubnet: d["ip_subnet"]?.stringValue,
            domainName: d["domain_name"]?.stringValue,
            isNat: d["is_nat"]?.boolValue,
            rawDocument: d
        )
    }

    func mapPortProfile(_ d: BSONDocument) -> PortProfile {
        PortProfile(
            id: d.idString,
            siteId: d.siteIdString,
            name: d["name"]?.stringValue,
            nativeNetworkId: d["native_networkconf_id"]?.objectIdValue?.hexString ?? d["native_networkconf_id"]?.stringValue,
            forward: d["forward"]?.stringValue,
            poeMode: d["poe_mode"]?.stringValue,
            rawDocument: d
        )
    }

    func mapPortForward(_ d: BSONDocument) -> PortForward {
        PortForward(
            id: d.idString,
            siteId: d.siteIdString,
            name: d["name"]?.stringValue,
            fwd: d["fwd"]?.stringValue,
            src: d["src"]?.stringValue,
            proto: d["proto"]?.stringValue,
            dstPort: d["dst_port"]?.stringValue,
            fwdPort: d["fwd_port"]?.stringValue,
            enabled: d["enabled"]?.boolValue,
            rawDocument: d
        )
    }

    func mapFirewallRule(_ d: BSONDocument) -> FirewallRule {
        FirewallRule(
            id: d.idString,
            siteId: d.siteIdString,
            name: d["name"]?.stringValue,
            ruleset: d["ruleset"]?.stringValue,
            ruleIndex: d["rule_index"]?.int32Value,
            action: d["action"]?.stringValue,
            proto: d["protocol"]?.stringValue,
            enabled: d["enabled"]?.boolValue,
            rawDocument: d
        )
    }

    func mapFirewallGroup(_ d: BSONDocument) -> FirewallGroup {
        let members: [String] = (d["group_members"]?.arrayValue ?? []).compactMap {
            $0.stringValue
        }
        return FirewallGroup(
            id: d.idString,
            siteId: d.siteIdString,
            name: d["name"]?.stringValue,
            groupType: d["group_type"]?.stringValue,
            groupMembers: members,
            rawDocument: d
        )
    }

    func mapRouting(_ d: BSONDocument) -> RoutingEntry {
        RoutingEntry(
            id: d.idString,
            siteId: d.siteIdString,
            name: d["name"]?.stringValue,
            enabled: d["enabled"]?.boolValue,
            rawDocument: d
        )
    }

    func mapAdmin(_ d: BSONDocument) -> Admin {
        Admin(
            id: d.idString,
            name: d["name"]?.stringValue,
            email: d["email"]?.stringValue,
            lastSiteName: d["last_site_name"]?.stringValue,
            timeCreated: d["time_created"]?.datetimeValue,
            rawDocument: d
        )
    }

    func mapAccount(_ d: BSONDocument) -> Account {
        Account(
            id: d.idString,
            siteId: d.siteIdString,
            name: d["name"]?.stringValue,
            vlan: d["vlan"]?.int32Value,
            tunnelType: d["tunnel_type"]?.stringValue,
            rawDocument: d
        )
    }

    func mapRadius(_ d: BSONDocument) -> RadiusProfile {
        RadiusProfile(
            id: d.idString,
            siteId: d.siteIdString,
            name: d["name"]?.stringValue,
            rawDocument: d
        )
    }

    func mapHotspotOp(_ d: BSONDocument) -> HotspotOperator {
        HotspotOperator(
            id: d.idString,
            siteId: d.siteIdString,
            name: d["name"]?.stringValue,
            rawDocument: d
        )
    }

    func mapSetting(_ d: BSONDocument) -> SettingPanel {
        SettingPanel(
            id: d.idString,
            siteId: d.siteIdString,
            key: d["key"]?.stringValue,
            rawDocument: d
        )
    }
}
