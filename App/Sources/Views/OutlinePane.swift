import SwiftUI
import UniFiBackupKit

/// Middle-pane outline view. Hierarchical, disclosable, with optional
/// selection checkboxes when `controller.selectionMode` is on.
struct OutlinePane: View {
    @Bindable var controller: InspectorController

    var body: some View {
        VStack(spacing: 0) {
            if controller.backup == nil && controller.loadError == nil {
                EmptyState()
            } else if let _ = controller.backup {
                OutlineSearchField(text: $controller.searchText)
                List(selection: $controller.focusedNodeID) {
                    ForEach(topLevelNodes, id: \.id) { node in
                        OutlineRow(
                            controller: controller,
                            node: node,
                            depth: 0,
                            filter: controller.searchText.lowercased()
                        )
                    }
                }
                .listStyle(.sidebar)
            } else if let err = controller.loadError {
                ErrorState(error: err, onRetry: {
                    Task { await controller.openWithPanel() }
                })
            }
        }
    }

    private var topLevelNodes: [TreeNode] {
        guard let tree = controller.backup?.tree else { return [] }
        let selectedCat = controller.selectedCategoryID
        if let selectedCat, let match = tree.first(where: { $0.id == selectedCat }) {
            return TreeBuilder.children(of: match)
        }
        return tree.flatMap { TreeBuilder.children(of: $0) }
    }
}

struct OutlineRow: View {
    @Bindable var controller: InspectorController
    let node: TreeNode
    let depth: Int
    let filter: String

    private var children: [TreeNode] { TreeBuilder.children(of: node) }

    var body: some View {
        Group {
            if children.isEmpty {
                row
            } else {
                DisclosureGroup {
                    ForEach(children, id: \.id) { child in
                        OutlineRow(controller: controller, node: child, depth: depth + 1, filter: filter)
                    }
                } label: {
                    row
                }
            }
        }
        .tag(node.id)
    }

    private var row: some View {
        HStack(spacing: 8) {
            if controller.selectionMode {
                Button {
                    controller.toggle(node)
                } label: {
                    Image(systemName: controller.selectedNodeIDs.contains(node.id) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
            Label(node.title, systemImage: node.symbolName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .opacity(matchesFilter ? 1.0 : 0.35)
        .contentShape(Rectangle())
    }

    private var matchesFilter: Bool {
        guard !filter.isEmpty else { return true }
        if node.title.lowercased().contains(filter) { return true }
        if let raw = node.rawDocument {
            for (k, v) in raw.pairs {
                if k.lowercased().contains(filter) { return true }
                if v.displayString.lowercased().contains(filter) { return true }
            }
        }
        return false
    }
}

struct OutlineSearchField: View {
    @Binding var text: String
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search everything…", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Drop a .unf file here, or press ⌘O to open one.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

struct ErrorState: View {
    let error: FatalBackupError
    var onRetry: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)
            Text("Couldn't open this backup")
                .font(.headline)
            Text(String(describing: error))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            HStack {
                Button("Try another file…") { onRetry() }
                Button("Copy details") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(String(describing: error), forType: .string)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
