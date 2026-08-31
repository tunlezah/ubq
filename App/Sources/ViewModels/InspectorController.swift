import SwiftUI
import AppKit
import UniFiBackupKit

/// A flat, cross-site view of one entity type, reachable from the sidebar
/// Overview counts. These entities are otherwise nested under each site in the
/// tree, so this gives the "show me all devices / WLANs / …" view users expect.
enum EntityFilter: String, CaseIterable, Hashable {
    case devices, wlans, networks, firewall, clients

    var title: String {
        switch self {
        case .devices: "Devices"
        case .wlans: "WLANs"
        case .networks: "Networks"
        case .firewall: "Firewall"
        case .clients: "Clients"
        }
    }

    var symbol: String {
        switch self {
        case .devices: "antenna.radiowaves.left.and.right"
        case .wlans: "wifi"
        case .networks: "network"
        case .firewall: "shield"
        case .clients: "person.2"
        }
    }
}

/// Top-level UI controller. Owns the loaded `Backup`, an optional second
/// backup for diffing, selection/search state, and the async loading
/// pipeline. Heavy tree walks are precomputed once per load into
/// `BackupIndex` so per-keystroke / per-render work stays O(1).
@MainActor
@Observable
final class InspectorController {
    // MARK: Loaded backup + lifecycle
    var backup: Backup? { didSet { rebuildIndexAndDerived() } }
    var loadError: FatalBackupError?
    var statsError: FatalBackupError?
    var isLoading: Bool = false
    var sourceURL: URL?
    var recentFiles: [URL] = RecentFilesStore.urls()

    /// Optional second backup, used only for the Diff feature.
    var secondaryBackup: Backup? { didSet { recomputeDiff() } }
    var secondaryURL: URL?
    var secondaryError: FatalBackupError?

    /// URLs discovered by "Open autobackup folder…", newest first.
    var folderBackups: [URL] = []

    // MARK: Selection
    var selectionMode: Bool = false
    var selectedNodeIDs: Set<String> = []
    var selectedCategoryID: String? {
        // Choosing a structural category and applying a flat entity filter are
        // mutually exclusive: selecting a category clears any active filter.
        didSet { if selectedCategoryID != nil { entityFilter = nil } }
    }
    var focusedNodeID: String?

    /// Flat, cross-site "quick filter" by entity type (Devices, WLANs, …),
    /// driven by the sidebar Overview rows. `nil` = show the selected category.
    var entityFilter: EntityFilter?

    // MARK: Search
    var searchText: String = ""

    // MARK: Sheets
    var showExportSheet: Bool = false
    var showDiagnostics: Bool = false
    var showDiff: Bool = false
    var showAudit: Bool = false
    var showRestoreAdvisor: Bool = false
    var showSecretInventory: Bool = false
    var showFiles: Bool = false
    var showStatistics: Bool = false

    // MARK: Export options
    var exportFormat: ExportFormat = .markdown
    var exportPreset: LLMPreset = .claude
    var includeSecrets: Bool = false
    var exportError: String?

    // MARK: Derived (precomputed per load)
    private(set) var index = BackupIndex.empty
    private(set) var crossRef: CrossReference?
    private(set) var audit: ConfigAudit?
    private(set) var diff: BackupDiff?

    // MARK: - File loading

    func openWithPanel() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a .unf, .unifi, or .supp backup file"
        if panel.runModal() == .OK, let url = panel.url {
            await open(url: url)
        }
    }

    func open(url: URL) async {
        let resolved = RecentFilesStore.resolveForOpening(url)
        defer { if resolved.needsScopeRelease { resolved.url.stopAccessingSecurityScopedResource() } }
        let target = resolved.url

        sourceURL = target
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let result = await Self.loadDetached(url: target, loadStatistics: false)
        switch result {
        case .success(let b):
            backup = b
            selectedNodeIDs.removeAll()
            selectedCategoryID = b.tree.first?.id
            focusedNodeID = nil
            RecentFilesStore.add(url)
            recentFiles = RecentFilesStore.urls()
        case .failure(let err):
            backup = nil
            loadError = err
        }
    }

    /// Loads a second backup for diffing without disturbing the primary.
    func openSecondary(url: URL) async {
        let resolved = RecentFilesStore.resolveForOpening(url)
        defer { if resolved.needsScopeRelease { resolved.url.stopAccessingSecurityScopedResource() } }
        secondaryError = nil
        isLoading = true
        defer { isLoading = false }
        let result = await Self.loadDetached(url: resolved.url, loadStatistics: false)
        switch result {
        case .success(let b):
            secondaryBackup = b
            secondaryURL = url
        case .failure(let err):
            secondaryError = err
        }
    }

    func openSecondaryWithPanel() async {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Compare"
        panel.message = "Choose a second backup to compare against"
        if panel.runModal() == .OK, let url = panel.url {
            await openSecondary(url: url)
        }
    }

    func clearSecondary() {
        secondaryBackup = nil
        secondaryURL = nil
        secondaryError = nil
    }

    /// Scans a folder for `.unf` autobackups, newest first (filenames embed a
    /// trailing epoch-ms, so a reverse lexical sort is chronological).
    func openFolderWithPanel() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose a folder of .unf autobackups"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let began = dir.startAccessingSecurityScopedResource()
        defer { if began { dir.stopAccessingSecurityScopedResource() } }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        folderBackups = contents
            .filter { $0.pathExtension.lowercased() == "unf" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func loadStatistics() async {
        guard let current = backup else { return }
        isLoading = true
        statsError = nil
        defer { isLoading = false }
        let result: Result<Backup, FatalBackupError> = await Task.detached(priority: .userInitiated) {
            do { return .success(try current.loadingStatistics()) }
            catch let err as FatalBackupError { return .failure(err) }
            catch { return .failure(.io(String(describing: error))) }
        }.value
        switch result {
        case .success(let updated): backup = updated
        case .failure(let err): statsError = err
        }
    }

    private static func loadDetached(url: URL, loadStatistics: Bool) async -> Result<Backup, FatalBackupError> {
        await Task.detached(priority: .userInitiated) {
            do { return .success(try Backup.open(url: url, loadStatistics: loadStatistics)) }
            catch let err as FatalBackupError { return .failure(err) }
            catch { return .failure(.io(String(describing: error))) }
        }.value
    }

    // MARK: - Derived rebuild

    private func rebuildIndexAndDerived() {
        guard let b = backup else {
            index = .empty; crossRef = nil; audit = nil; recomputeDiff(); return
        }
        index = BackupIndex(tree: b.tree)
        crossRef = CrossReference(model: b.model)
        audit = ConfigAudit.run(
            model: b.model,
            identity: b.identity,
            isSecretField: { SecretVault.isSecret(fieldName: $0) }
        )
        recomputeDiff()
    }

    private func recomputeDiff() {
        guard let a = backup, let b = secondaryBackup else { diff = nil; return }
        diff = BackupDiff.compute(
            left: a.model, leftIdentity: a.identity,
            right: b.model, rightIdentity: b.identity,
            isSecretField: { SecretVault.isSecret(fieldName: $0) }
        )
    }

    var restoreAdvice: RestoreAdvisor.Advice? {
        guard let b = backup else { return nil }
        return RestoreAdvisor.advise(identity: b.identity, siteCount: b.model.sites.count)
    }

    // MARK: - Selection (O(1) via index)

    var selectedNodes: [TreeNode] {
        index.orderedIDs
            .filter { selectedNodeIDs.contains($0) }
            .compactMap { index.node(for: $0) }
            .filter { $0.rawDocument != nil }
    }

    func node(for id: String) -> TreeNode? { index.node(for: id) }

    // MARK: - Entity quick-filter (flat, cross-site)

    /// All nodes of a given entity kind across every site, in tree order.
    var entityFilteredNodes: [TreeNode] {
        guard let kind = entityFilter else { return [] }
        return index.orderedIDs.compactMap { index.node(for: $0) }
            .filter { Self.entityKind(of: $0) == kind }
    }

    /// Maps a tree node to the flat entity bucket it belongs to, if any.
    static func entityKind(of node: TreeNode) -> EntityFilter? {
        switch node {
        case .device: .devices
        case .wlan: .wlans
        case .network: .networks
        case .firewallRule, .firewallGroup, .portForward, .routing: .firewall
        case .client: .clients
        default: nil
        }
    }

    func toggle(_ node: TreeNode) {
        let willSelect = !selectedNodeIDs.contains(node.id)
        var affected = index.descendantIDs(of: node.id)
        affected.insert(node.id)
        if willSelect { selectedNodeIDs.formUnion(affected) }
        else { selectedNodeIDs.subtract(affected) }
    }

    func selectAllVisible() {
        selectedNodeIDs = Set(index.orderedIDs)
    }

    func clearSelection() { selectedNodeIDs.removeAll() }

    // MARK: - Search (backed by a prebuilt per-node text index)

    func matches(_ id: String, filter: String) -> Bool {
        guard !filter.isEmpty else { return true }
        return index.searchText(for: id)?.contains(filter) ?? false
    }

    // MARK: - Cross-reference navigation

    /// Reveals and focuses a record. Accepts either a `TreeNode.id` or a raw
    /// UniFi record `_id` (cross-reference links and diff/audit "Reveal" pass the
    /// raw id). Puts the target on screen: for a flat-filterable kind it switches
    /// to that entity view (where the row is top-level and visible); otherwise it
    /// selects the owning top-level category.
    func navigate(toId id: String) {
        let nodeID: String
        if index.node(for: id) != nil {
            nodeID = id
        } else if let mapped = index.nodeID(forRecordID: id) {
            nodeID = mapped
        } else {
            return
        }
        if let node = index.node(for: nodeID), let kind = Self.entityKind(of: node) {
            entityFilter = kind
            selectedCategoryID = nil
        } else if let cat = index.topCategoryID(for: nodeID) {
            selectedCategoryID = cat   // didSet clears entityFilter
        }
        focusedNodeID = nodeID
    }

    // MARK: - Export

    func budgetOverride(for preset: LLMPreset) -> Int? {
        let v = UserDefaults.standard.integer(forKey: Self.budgetKey(preset))
        return v > 0 ? v : nil
    }

    func setBudgetOverride(_ value: Int?, for preset: LLMPreset) {
        let key = Self.budgetKey(preset)
        if let value, value > 0 { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private static func budgetKey(_ p: LLMPreset) -> String { "budgetOverride.\(p.rawValue)" }

    func currentExportRequest() -> ExportRequest {
        ExportRequest(
            nodes: selectedNodes,
            format: exportFormat,
            preset: exportPreset,
            includeSecrets: includeSecrets,
            identity: backup?.identity,
            budgetOverride: budgetOverride(for: exportPreset)
        )
    }

    func exportToPasteboard() {
        let output = Exporter.export(currentExportRequest())
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(output, forType: .string)
    }

    /// Saves the export, surfacing any write failure instead of swallowing it.
    func exportToFile() {
        let request = currentExportRequest()
        let suggested = Exporter.suggestedFilename(for: request)
        let output = Exporter.export(request)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        panel.showsTagField = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = "Could not save export to \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Writes an arbitrary report string (diff / audit markdown) to a
    /// user-chosen file, surfacing errors.
    func saveReport(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.showsTagField = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { exportError = "Could not save \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - App version

    var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}

// MARK: - BackupIndex

/// Precomputed, immutable lookups over a loaded tree so the UI never walks the
/// whole tree per keystroke or per render.
struct BackupIndex {
    private let nodesByID: [String: TreeNode]
    private let descendants: [String: Set<String>]
    private let topCategory: [String: String]
    private let searchIndex: [String: String]
    /// Maps a raw UniFi record `_id` to the owning `TreeNode.id`, so navigation
    /// from a cross-reference / diff / audit (which speak raw record ids) can
    /// resolve to the tree node.
    private let recordToNode: [String: String]
    let orderedIDs: [String]

    static let empty = BackupIndex()

    private init() {
        nodesByID = [:]; descendants = [:]; topCategory = [:]
        searchIndex = [:]; recordToNode = [:]; orderedIDs = []
    }

    init(tree: [TreeNode]) {
        var nodesByID: [String: TreeNode] = [:]
        var descendants: [String: Set<String>] = [:]
        var topCategory: [String: String] = [:]
        var searchIndex: [String: String] = [:]
        var recordToNode: [String: String] = [:]
        var ordered: [String] = []

        // Recursive walk that records nodes, ordering, per-node search text, the
        // owning top-level category, and each node's descendant id set.
        @discardableResult
        func walk(_ node: TreeNode, currentTop: String?) -> Set<String> {
            nodesByID[node.id] = node
            ordered.append(node.id)

            let top: String
            if case .category = node { top = node.id } else { top = currentTop ?? node.id }
            topCategory[node.id] = top

            var text = node.title.lowercased()
            if let raw = node.rawDocument {
                for (k, v) in raw.pairs {
                    text += " " + k.lowercased() + " " + v.displayString.lowercased()
                }
                let rid = raw.idString
                if !rid.isEmpty, recordToNode[rid] == nil {
                    recordToNode[rid] = node.id
                }
            }
            searchIndex[node.id] = text

            var kids = Set<String>()
            for child in TreeBuilder.children(of: node) {
                kids.insert(child.id)
                kids.formUnion(walk(child, currentTop: top))
            }
            descendants[node.id] = kids
            return kids
        }

        for root in tree { walk(root, currentTop: nil) }

        self.nodesByID = nodesByID
        self.descendants = descendants
        self.topCategory = topCategory
        self.searchIndex = searchIndex
        self.recordToNode = recordToNode
        self.orderedIDs = ordered
    }

    func node(for id: String) -> TreeNode? { nodesByID[id] }
    func descendantIDs(of id: String) -> Set<String> { descendants[id] ?? [] }
    func topCategoryID(for id: String) -> String? { topCategory[id] }
    func searchText(for id: String) -> String? { searchIndex[id] }
    func nodeID(forRecordID id: String) -> String? { recordToNode[id] }
}
