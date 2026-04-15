import SwiftUI
import AppKit
import UniFiBackupKit

/// Top-level UI controller. Owns the loaded `Backup`, selection state,
/// search text, and the async loading pipeline.
@MainActor
@Observable
final class InspectorController {
    // Loaded backup + lifecycle
    var backup: Backup?
    var loadError: FatalBackupError?
    var isLoading: Bool = false
    var sourceURL: URL?
    var recentFiles: [URL] = []

    // Selection
    var selectionMode: Bool = false
    var selectedNodeIDs: Set<String> = []
    var selectedCategoryID: String?
    var focusedNodeID: String?

    // Search
    var searchText: String = ""

    // Export sheet
    var showExportSheet: Bool = false
    var exportFormat: ExportFormat = .markdown
    var exportPreset: LLMPreset = .claude
    var includeSecrets: Bool = false

    // Diagnostics panel
    var showDiagnostics: Bool = false

    // MARK: - File loading

    func openWithPanel() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a .unf backup file"
        if panel.runModal() == .OK, let url = panel.url {
            await open(url: url)
        }
    }

    func open(url: URL) async {
        sourceURL = url
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let result = await Task.detached(priority: .userInitiated) {
            do {
                let b = try Backup.open(url: url, loadStatistics: false)
                return Result<Backup, FatalBackupError>.success(b)
            } catch let err as FatalBackupError {
                return .failure(err)
            } catch {
                return .failure(.io(String(describing: error)))
            }
        }.value

        switch result {
        case .success(let b):
            backup = b
            selectedNodeIDs.removeAll()
            selectedCategoryID = b.tree.first?.id
            addRecent(url)
        case .failure(let err):
            backup = nil
            loadError = err
        }
    }

    func loadStatistics() async {
        guard let current = backup, let url = current.sourceURL ?? sourceURL else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await Task.detached(priority: .userInitiated) {
            try? Backup.open(url: url, loadStatistics: true)
        }.value
        if let updated = result { backup = updated }
    }

    private func addRecent(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 8 { recentFiles.removeLast() }
    }

    // MARK: - Selection

    var selectedNodes: [TreeNode] {
        guard let b = backup else { return [] }
        let flat = TreeBuilder.flatten(b.tree)
        return flat.filter { selectedNodeIDs.contains($0.id) && $0.rawDocument != nil }
    }

    func toggle(_ node: TreeNode) {
        if selectedNodeIDs.contains(node.id) {
            selectedNodeIDs.remove(node.id)
        } else {
            selectedNodeIDs.insert(node.id)
        }
        // Also toggle descendants.
        for desc in TreeBuilder.flatten(TreeBuilder.children(of: node)) {
            if selectedNodeIDs.contains(node.id) {
                selectedNodeIDs.insert(desc.id)
            } else {
                selectedNodeIDs.remove(desc.id)
            }
        }
    }

    // MARK: - Export

    func currentExportRequest() -> ExportRequest {
        ExportRequest(
            nodes: selectedNodes,
            format: exportFormat,
            preset: exportPreset,
            includeSecrets: includeSecrets,
            identity: backup?.identity
        )
    }

    func exportToPasteboard() {
        let output = Exporter.export(currentExportRequest())
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(output, forType: .string)
    }

    func exportToFile() {
        let request = currentExportRequest()
        let suggested = Exporter.suggestedFilename(for: request)
        let output = Exporter.export(request)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        panel.showsTagField = false
        if panel.runModal() == .OK, let url = panel.url {
            try? output.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - App version

    var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}
