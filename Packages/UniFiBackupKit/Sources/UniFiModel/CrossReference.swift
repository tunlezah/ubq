import Foundation
import UniFiBSON

/// Resolves UniFi id references to human-readable names and computes reverse
/// usage ("used by 3 WLANs"). Built once from a `MappedModel` and then queried
/// by the detail pane to render bare ObjectIds as named, clickable links and to
/// show back-links on the referenced record.
///
/// The joins mirror `FORMAT.md`'s "Cross-collection Relationships":
///
/// ```
/// user.network_id / portconf.native_networkconf_id /
///     portconf.voice_networkconf_id       → networkconf._id
/// wlanconf.wlangroup_id / device.wlangroup_id  → wlangroup._id
/// <anything>.site_id                      → site._id
/// device.port_overrides[].portconf_id     → portconf._id
/// firewallrule.{src,dst}_firewallgroup_ids[] / firewallgroup.group_members[]
///                                         → firewallgroup._id
/// ```
///
/// Pure and `Sendable`: it copies the small id→name maps and the records it
/// needs at init time and never mutates afterwards.
public struct CrossReference: Sendable {

    // MARK: - Public value types

    /// The forward resolution of a single reference field to its target.
    public struct Resolved: Sendable, Hashable {
        /// A stable kind token for the referenced collection, e.g. `"network"`,
        /// `"wlanGroup"`, `"site"`, `"portProfile"`, `"firewallGroup"`.
        public let targetKind: String
        /// The referenced record's id (ObjectId hex or raw string).
        public let targetId: String
        /// The referenced record's human name, when one is known.
        public let displayName: String?

        public init(targetKind: String, targetId: String, displayName: String?) {
            self.targetKind = targetKind
            self.targetId = targetId
            self.displayName = displayName
        }
    }

    /// One place a given id is referenced from (a reverse / back-link).
    public struct Usage: Sendable, Hashable {
        /// Kind token of the referencing record, e.g. `"wlan"`, `"device"`.
        public let byKind: String
        /// Id of the referencing record.
        public let byId: String
        /// Human title of the referencing record.
        public let byTitle: String
        /// The field name the reference travelled through, e.g. `"network_id"`.
        public let viaField: String

        public init(byKind: String, byId: String, byTitle: String, viaField: String) {
            self.byKind = byKind
            self.byId = byId
            self.byTitle = byTitle
            self.viaField = viaField
        }
    }

    // MARK: - Reference-field vocabulary

    /// Scalar reference fields: the field's value *is* a target id.
    static let scalarReferenceFields: Set<String> = [
        "site_id",
        "network_id",
        "native_networkconf_id",
        "voice_networkconf_id",
        "wlangroup_id",
        "usergroup_id",
        "portconf_id",
        "admin_id",
    ]

    /// Array reference fields: the field's value is an array of target ids.
    /// `*_firewallgroup_ids` (e.g. `src_firewallgroup_ids`) is matched by suffix.
    static let arrayReferenceFields: Set<String> = [
        "group_members",
    ]

    static func isReferenceField(_ name: String) -> Bool {
        scalarReferenceFields.contains(name)
            || arrayReferenceFields.contains(name)
            || name.hasSuffix("_firewallgroup_ids")
    }

    // MARK: - Stored maps and record index

    private let networkNames: [String: String]
    private let wlanGroupNames: [String: String]
    private let siteNames: [String: String]
    private let portProfileNames: [String: String]
    private let firewallGroupNames: [String: String]

    private struct RecordRef: Sendable {
        let kind: String
        let id: String
        let title: String
        let raw: BSONDocument
    }

    private let records: [RecordRef]

    // MARK: - Init

    public init(model: ModelMapper.MappedModel) {
        var networks: [String: String] = [:]
        for n in model.networks {
            if let name = n.name, !name.isEmpty { networks[n.id] = name }
        }
        self.networkNames = networks

        var wlanGroups: [String: String] = [:]
        for g in model.wlanGroups {
            if let name = g.name, !name.isEmpty { wlanGroups[g.id] = name }
        }
        self.wlanGroupNames = wlanGroups

        var sites: [String: String] = [:]
        for s in model.sites {
            let name = [s.desc, s.name].compactMap { $0 }.first { !$0.isEmpty }
            if let name { sites[s.id] = name }
        }
        self.siteNames = sites

        var portProfiles: [String: String] = [:]
        for p in model.portProfiles {
            if let name = p.name, !name.isEmpty { portProfiles[p.id] = name }
        }
        self.portProfileNames = portProfiles

        var firewallGroups: [String: String] = [:]
        for g in model.firewallGroups {
            if let name = g.name, !name.isEmpty { firewallGroups[g.id] = name }
        }
        self.firewallGroupNames = firewallGroups

        // Index every typed record so `usages(ofId:)` can scan raw documents.
        var refs: [RecordRef] = []
        func add<T>(_ items: [T], kind: String, id: (T) -> String, title: (T) -> String, raw: (T) -> BSONDocument) {
            for item in items {
                refs.append(RecordRef(kind: kind, id: id(item), title: title(item), raw: raw(item)))
            }
        }
        add(model.sites, kind: "site", id: { $0.id },
            title: { site in [site.desc, site.name].compactMap { $0 }.first { !$0.isEmpty } ?? site.id },
            raw: { $0.rawDocument })
        add(model.devices, kind: "device", id: { $0.id },
            title: { $0.name ?? $0.mac ?? $0.id }, raw: { $0.rawDocument })
        add(model.clients, kind: "client", id: { $0.id },
            title: { $0.name ?? $0.hostname ?? $0.mac ?? $0.id }, raw: { $0.rawDocument })
        add(model.wlans, kind: "wlan", id: { $0.id },
            title: { $0.name ?? $0.id }, raw: { $0.rawDocument })
        add(model.wlanGroups, kind: "wlanGroup", id: { $0.id },
            title: { $0.name ?? $0.id }, raw: { $0.rawDocument })
        add(model.networks, kind: "network", id: { $0.id },
            title: { $0.name ?? $0.id }, raw: { $0.rawDocument })
        add(model.portProfiles, kind: "portProfile", id: { $0.id },
            title: { $0.name ?? $0.id }, raw: { $0.rawDocument })
        add(model.portForwards, kind: "portForward", id: { $0.id },
            title: { $0.name ?? $0.id }, raw: { $0.rawDocument })
        add(model.firewallRules, kind: "firewallRule", id: { $0.id },
            title: { $0.name ?? $0.id }, raw: { $0.rawDocument })
        add(model.firewallGroups, kind: "firewallGroup", id: { $0.id },
            title: { $0.name ?? $0.id }, raw: { $0.rawDocument })
        add(model.routing, kind: "routing", id: { $0.id },
            title: { $0.name ?? $0.id }, raw: { $0.rawDocument })
        add(model.admins, kind: "admin", id: { $0.id },
            title: { $0.name ?? $0.email ?? $0.id }, raw: { $0.rawDocument })
        add(model.accounts, kind: "account", id: { $0.id },
            title: { $0.name ?? $0.id }, raw: { $0.rawDocument })
        add(model.radiusProfiles, kind: "radius", id: { $0.id },
            title: { $0.name ?? $0.id }, raw: { $0.rawDocument })
        add(model.hotspotOperators, kind: "hotspotOp", id: { $0.id },
            title: { $0.name ?? $0.id }, raw: { $0.rawDocument })
        add(model.settings, kind: "setting", id: { $0.id },
            title: { $0.key ?? $0.id }, raw: { $0.rawDocument })
        self.records = refs
    }

    // MARK: - Forward resolution

    /// The human name for an id, searching every id→name map. Nil when the id is
    /// unknown or its record has no name.
    public func displayName(forId id: String) -> String? {
        networkNames[id]
            ?? wlanGroupNames[id]
            ?? siteNames[id]
            ?? portProfileNames[id]
            ?? firewallGroupNames[id]
    }

    /// Resolves a single reference field/value to its target. Returns nil when
    /// the field name isn't a recognised reference or the value carries no id.
    ///
    /// For array reference fields (`*_firewallgroup_ids`, `group_members`) the
    /// caller iterates the array and calls this once per element value; a whole
    /// array passed as `value` yields nil since one call resolves one target.
    public func resolve(fieldName: String, value: BSONValue) -> Resolved? {
        let kind: String
        switch fieldName {
        case "network_id", "native_networkconf_id", "voice_networkconf_id":
            kind = "network"
        case "wlangroup_id":
            kind = "wlanGroup"
        case "site_id":
            kind = "site"
        case "portconf_id":
            kind = "portProfile"
        case "group_members":
            kind = "firewallGroup"
        default:
            guard fieldName.hasSuffix("_firewallgroup_ids") else { return nil }
            kind = "firewallGroup"
        }
        guard let id = Self.scalarId(from: value) else { return nil }
        return Resolved(targetKind: kind, targetId: id, displayName: name(forId: id, kind: kind))
    }

    // MARK: - Reverse usage

    /// Every place `id` is referenced from a known reference field, across all
    /// typed records (including nested documents and arrays of documents, so
    /// e.g. `device.port_overrides[].portconf_id` is found). Deduplicated.
    public func usages(ofId id: String) -> [Usage] {
        guard !id.isEmpty else { return [] }
        var out: [Usage] = []
        var seen: Set<Usage> = []
        for record in records {
            scan(record.raw, targetId: id, record: record, out: &out, seen: &seen)
        }
        return out
    }

    private func scan(
        _ doc: BSONDocument,
        targetId: String,
        record: RecordRef,
        out: inout [Usage],
        seen: inout Set<Usage>
    ) {
        for (key, value) in doc.pairs {
            if Self.isReferenceField(key), Self.valueMatches(value, targetId: targetId) {
                let usage = Usage(
                    byKind: record.kind,
                    byId: record.id,
                    byTitle: record.title,
                    viaField: key
                )
                if seen.insert(usage).inserted { out.append(usage) }
            }
            switch value {
            case .document(let nested):
                scan(nested, targetId: targetId, record: record, out: &out, seen: &seen)
            case .array(let values):
                for v in values {
                    if case .document(let nested) = v {
                        scan(nested, targetId: targetId, record: record, out: &out, seen: &seen)
                    }
                }
            default:
                continue
            }
        }
    }

    // MARK: - Helpers

    private func name(forId id: String, kind: String) -> String? {
        switch kind {
        case "network": return networkNames[id]
        case "wlanGroup": return wlanGroupNames[id]
        case "site": return siteNames[id]
        case "portProfile": return portProfileNames[id]
        case "firewallGroup": return firewallGroupNames[id]
        default: return nil
        }
    }

    /// A single id from a scalar value (ObjectId hex or non-empty string).
    static func scalarId(from value: BSONValue) -> String? {
        switch value {
        case .objectId(let oid): return oid.hexString
        case .string(let s): return s.isEmpty ? nil : s
        default: return nil
        }
    }

    /// Whether a field's value carries `targetId` — either directly (scalar) or
    /// as any element (array).
    static func valueMatches(_ value: BSONValue, targetId: String) -> Bool {
        if case .array(let values) = value {
            return values.contains { scalarId(from: $0) == targetId }
        }
        return scalarId(from: value) == targetId
    }
}
