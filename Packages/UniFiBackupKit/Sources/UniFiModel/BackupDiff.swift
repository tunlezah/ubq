import Foundation
import UniFiBSON

/// Compares two mapped backups field-by-field and produces a structured,
/// renderable delta. Pure value logic: no I/O, no global state.
///
/// The engine works over `ModelMapper.MappedModel` (the strongly-typed view
/// plus opaque collections) rather than the umbrella `Backup` type, and keys
/// records by their stable id so it is robust to reordering between backups.
///
/// Secrets never leak: field changes whose leaf name matches the injected
/// `isSecretField` predicate still record *that* the field changed, but emit
/// `"<redacted>"` in place of the before/after values.
public struct BackupDiff: Sendable {

    public enum ChangeKind: String, Sendable, Hashable {
        case added
        case removed
        case modified
    }

    /// A single scalar field difference within a modified record.
    /// `before`/`after` are already display-formatted (and masked when secret).
    public struct FieldChange: Sendable, Hashable {
        public let path: String
        public let before: String?
        public let after: String?
        public init(path: String, before: String?, after: String?) {
            self.path = path
            self.before = before
            self.after = after
        }
    }

    /// One record's fate between the two backups.
    public struct RecordDelta: Sendable, Hashable, Identifiable {
        public let id: String            // "<collection>:<recordId>"
        public let collection: String
        public let recordId: String
        public let kind: ChangeKind
        public let title: String
        public let fieldChanges: [FieldChange]   // populated for .modified
        public init(
            id: String,
            collection: String,
            recordId: String,
            kind: ChangeKind,
            title: String,
            fieldChanges: [FieldChange]
        ) {
            self.id = id
            self.collection = collection
            self.recordId = recordId
            self.kind = kind
            self.title = title
            self.fieldChanges = fieldChanges
        }
    }

    /// All deltas for one collection, plus roll-up counts.
    public struct CollectionDelta: Sendable, Hashable, Identifiable {
        public var id: String { collection }
        public let collection: String
        public let added: Int
        public let removed: Int
        public let modified: Int
        public let deltas: [RecordDelta]
        public init(
            collection: String,
            added: Int,
            removed: Int,
            modified: Int,
            deltas: [RecordDelta]
        ) {
            self.collection = collection
            self.added = added
            self.removed = removed
            self.modified = modified
            self.deltas = deltas
        }
    }

    public let leftIdentity: Identity
    public let rightIdentity: Identity
    /// Sorted by collection name; only collections with at least one change.
    public let collectionDeltas: [CollectionDelta]

    public init(
        leftIdentity: Identity,
        rightIdentity: Identity,
        collectionDeltas: [CollectionDelta]
    ) {
        self.leftIdentity = leftIdentity
        self.rightIdentity = rightIdentity
        self.collectionDeltas = collectionDeltas
    }

    public var totalChanges: Int {
        collectionDeltas.reduce(0) { $0 + $1.deltas.count }
    }

    public var isEmpty: Bool { collectionDeltas.isEmpty }

    // MARK: - Compute

    public static func compute(
        left: ModelMapper.MappedModel, leftIdentity: Identity,
        right: ModelMapper.MappedModel, rightIdentity: Identity,
        isSecretField: @Sendable (String) -> Bool = { _ in false }
    ) -> BackupDiff {
        let leftMap = collectionMap(left)
        let rightMap = collectionMap(right)
        let names = Set(leftMap.keys).union(rightMap.keys).sorted()

        var collectionDeltas: [CollectionDelta] = []
        for name in names {
            let deltas = diffCollection(
                name: name,
                left: leftMap[name] ?? [],
                right: rightMap[name] ?? [],
                isSecretField: isSecretField
            )
            guard !deltas.isEmpty else { continue }
            let added = deltas.lazy.filter { $0.kind == .added }.count
            let removed = deltas.lazy.filter { $0.kind == .removed }.count
            let modified = deltas.lazy.filter { $0.kind == .modified }.count
            collectionDeltas.append(
                CollectionDelta(
                    collection: name,
                    added: added,
                    removed: removed,
                    modified: modified,
                    deltas: deltas
                )
            )
        }

        return BackupDiff(
            leftIdentity: leftIdentity,
            rightIdentity: rightIdentity,
            collectionDeltas: collectionDeltas
        )
    }

    // MARK: - Record extraction

    /// A record ready for diffing: raw document plus its stable id.
    private struct Record {
        let id: String
        let doc: BSONDocument
    }

    /// A record with a within-collection match key that is guaranteed unique
    /// (empty / duplicate ids are disambiguated so nothing silently collapses).
    private struct KeyedRecord {
        let key: String
        let id: String
        let doc: BSONDocument
    }

    /// Flatten a mapped model into `collectionName -> [Record]`, using the raw
    /// UniFi collection names throughout (typed and opaque share one namespace,
    /// and cannot collide because opaque names are exactly those the mapper did
    /// not strongly type).
    private static func collectionMap(_ m: ModelMapper.MappedModel) -> [String: [Record]] {
        var out: [String: [Record]] = [:]
        func put(_ name: String, _ records: [Record]) {
            guard !records.isEmpty else { return }
            out[name, default: []].append(contentsOf: records)
        }
        put("site", m.sites.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("device", m.devices.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("user", m.clients.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("wlanconf", m.wlans.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("wlangroup", m.wlanGroups.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("networkconf", m.networks.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("portconf", m.portProfiles.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("portforward", m.portForwards.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("firewallrule", m.firewallRules.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("firewallgroup", m.firewallGroups.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("routing", m.routing.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("admin", m.admins.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("account", m.accounts.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("radiusprofile", m.radiusProfiles.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("hotspotop", m.hotspotOperators.map { Record(id: $0.id, doc: $0.rawDocument) })
        put("setting", m.settings.map { Record(id: $0.id, doc: $0.rawDocument) })
        for oc in m.opaqueCollections {
            put(oc.name, oc.records.map { Record(id: $0.id, doc: $0.rawDocument) })
        }
        return out
    }

    private static func keyed(_ records: [Record]) -> [KeyedRecord] {
        var seen: [String: Int] = [:]
        var out: [KeyedRecord] = []
        out.reserveCapacity(records.count)
        for r in records {
            // Non-empty ids key directly; anonymous records fall back to a
            // content hash (stable within this process, which is all a single
            // diff call needs) so distinct records never collapse together.
            let base = r.id.isEmpty ? "#anon-\(r.doc.hashValue)" : r.id
            let n = seen[base, default: 0]
            seen[base] = n + 1
            let key = n == 0 ? base : "\(base)~dup\(n)"
            out.append(KeyedRecord(key: key, id: r.id, doc: r.doc))
        }
        return out
    }

    // MARK: - Per-collection diff

    private static func diffCollection(
        name: String,
        left: [Record],
        right: [Record],
        isSecretField: @Sendable (String) -> Bool
    ) -> [RecordDelta] {
        let leftByKey = Dictionary(uniqueKeysWithValues: keyed(left).map { ($0.key, $0) })
        let rightByKey = Dictionary(uniqueKeysWithValues: keyed(right).map { ($0.key, $0) })
        let allKeys = Set(leftByKey.keys).union(rightByKey.keys)

        var removed: [RecordDelta] = []
        var added: [RecordDelta] = []
        var modified: [RecordDelta] = []

        for key in allKeys {
            switch (leftByKey[key], rightByKey[key]) {
            case let (.some(l), .none):
                removed.append(
                    RecordDelta(
                        id: "\(name):\(key)",
                        collection: name,
                        recordId: l.id,
                        kind: .removed,
                        title: title(l.doc, fallback: l.id),
                        fieldChanges: []
                    )
                )
            case let (.none, .some(r)):
                added.append(
                    RecordDelta(
                        id: "\(name):\(key)",
                        collection: name,
                        recordId: r.id,
                        kind: .added,
                        title: title(r.doc, fallback: r.id),
                        fieldChanges: []
                    )
                )
            case let (.some(l), .some(r)):
                var changes: [FieldChange] = []
                diffDocuments(path: "", left: l.doc, right: r.doc, into: &changes, isSecretField: isSecretField)
                guard !changes.isEmpty else { continue }
                modified.append(
                    RecordDelta(
                        id: "\(name):\(key)",
                        collection: name,
                        recordId: r.id,
                        kind: .modified,
                        title: title(r.doc, fallback: r.id),
                        fieldChanges: changes
                    )
                )
            case (.none, .none):
                break
            }
        }

        let byTitle: (RecordDelta, RecordDelta) -> Bool = { a, b in
            if a.title != b.title { return a.title < b.title }
            return a.recordId < b.recordId
        }
        // Order: removed, then added, then modified (stable within each group).
        return removed.sorted(by: byTitle) + added.sorted(by: byTitle) + modified.sorted(by: byTitle)
    }

    // MARK: - Field-level diff

    private static func diffDocuments(
        path: String,
        left: BSONDocument,
        right: BSONDocument,
        into changes: inout [FieldChange],
        isSecretField: @Sendable (String) -> Bool
    ) {
        // Union of keys, left order first then right-only keys.
        var order: [String] = []
        var seen = Set<String>()
        for k in left.keys where seen.insert(k).inserted { order.append(k) }
        for k in right.keys where seen.insert(k).inserted { order.append(k) }

        for k in order {
            let childPath = path.isEmpty ? k : "\(path).\(k)"
            diffValue(
                path: childPath,
                left: left[k],
                right: right[k],
                into: &changes,
                isSecretField: isSecretField
            )
        }
    }

    private static func diffValue(
        path: String,
        left: BSONValue?,
        right: BSONValue?,
        into changes: inout [FieldChange],
        isSecretField: @Sendable (String) -> Bool
    ) {
        if left == right { return }   // includes both-nil and deep-equal containers

        switch (left, right) {
        case let (.some(.document(ld)), .some(.document(rd))):
            diffDocuments(path: path, left: ld, right: rd, into: &changes, isSecretField: isSecretField)
        case let (.some(.array(la)), .some(.array(ra))):
            let count = max(la.count, ra.count)
            for i in 0..<count {
                diffValue(
                    path: "\(path)[\(i)]",
                    left: i < la.count ? la[i] : nil,
                    right: i < ra.count ? ra[i] : nil,
                    into: &changes,
                    isSecretField: isSecretField
                )
            }
        default:
            let name = lastComponentName(path)
            changes.append(
                FieldChange(
                    path: path,
                    before: formatValue(left, name: name, isSecretField: isSecretField),
                    after: formatValue(right, name: name, isSecretField: isSecretField)
                )
            )
        }
    }

    private static func formatValue(
        _ value: BSONValue?,
        name: String,
        isSecretField: @Sendable (String) -> Bool
    ) -> String? {
        guard let value else { return nil }
        if isSecretField(name) { return "<redacted>" }
        return value.displayString
    }

    /// The bare field name at the tail of a dotted path, with any trailing
    /// `[index]` stripped — this is what the secret predicate is tested against.
    private static func lastComponentName(_ path: String) -> String {
        let last = path.split(separator: ".").last.map { String($0) } ?? path
        if let bracket = last.firstIndex(of: "[") {
            return String(last[..<bracket])
        }
        return last
    }

    /// Human title for a record: name / hostname / mac / key, else the id.
    private static func title(_ doc: BSONDocument, fallback id: String) -> String {
        for key in ["name", "hostname", "mac", "key"] {
            if let s = doc[key]?.stringValue, !s.isEmpty { return s }
        }
        return id.isEmpty ? "(no id)" : id
    }

    // MARK: - Markdown rendering

    /// A grouped Markdown report suitable for the existing export pipeline.
    public func markdownReport() -> String {
        var out = "# Backup Diff\n\n"
        out += "| | Left | Right |\n|---|---|---|\n"
        out += "| Version | \(cell(leftIdentity.version ?? "?")) | \(cell(rightIdentity.version ?? "?")) |\n"
        out += "| Timestamp | \(cell(Self.isoDate(leftIdentity.timestamp))) | \(cell(Self.isoDate(rightIdentity.timestamp))) |\n"
        out += "| Kind | \(leftIdentity.kind.rawValue) | \(rightIdentity.kind.rawValue) |\n\n"

        if isEmpty {
            out += "_No configuration differences._\n"
            return out
        }

        out += "**\(totalChanges) change(s)** across \(collectionDeltas.count) collection(s).\n\n"

        for cd in collectionDeltas {
            out += "## \(cd.collection)  (+\(cd.added) -\(cd.removed) ~\(cd.modified))\n\n"
            for d in cd.deltas {
                switch d.kind {
                case .added:
                    out += "- **+ \(inline(d.title))** `\(d.recordId)`\n"
                case .removed:
                    out += "- **- \(inline(d.title))** `\(d.recordId)`\n"
                case .modified:
                    out += "- **~ \(inline(d.title))** `\(d.recordId)`\n\n"
                    out += "  | Field | Before | After |\n  |---|---|---|\n"
                    for fc in d.fieldChanges {
                        out += "  | \(cell(fc.path)) | \(cell(fc.before ?? "—")) | \(cell(fc.after ?? "—")) |\n"
                    }
                    out += "\n"
                }
            }
            out += "\n"
        }
        return out
    }

    private static func isoDate(_ date: Date?) -> String {
        guard let date else { return "?" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private func cell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
         .replacingOccurrences(of: "\n", with: " ")
    }

    private func inline(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
    }
}
