import SwiftUI
import UniFiBackupKit

/// Middle-pane outline view. Hierarchical, disclosable, with optional
/// selection checkboxes when `controller.selectionMode` is on.
///
/// Search (ROADMAP Tier-1 #2): rather than dimming non-matching rows, the
/// filter *hides* them. A node stays visible when it matches the query
/// itself, or when any descendant does (so the ancestor chain down to a
/// match is always reachable). The match test is `controller.matches(_:filter:)`,
/// which is backed by `BackupIndex`'s prebuilt per-node search text — O(1) per
/// node — so filtering the whole tree is a single O(n) pass, never a
/// per-keystroke `rawDocument` scan and never a `TreeBuilder.flatten` re-walk.
struct OutlinePane: View {
    @Bindable var controller: InspectorController

    /// The search text, ~150ms after the user stops typing. Filtering reads
    /// this instead of `controller.searchText` directly so keystrokes never
    /// trigger a tree-wide recompute.
    @State private var debounced: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if controller.backup == nil && controller.loadError == nil {
                EmptyState()
            } else if let backup = controller.backup {
                OutlineSearchField(text: $controller.searchText)
                if let kind = controller.entityFilter {
                    EntityFilterChip(kind: kind) { controller.entityFilter = nil }
                }
                if backup.isSupportBundle && backup.tree.isEmpty {
                    SupportBundleNote()
                } else {
                    List(selection: $controller.focusedNodeID) {
                        ForEach(topLevelNodes, id: \.id) { node in
                            OutlineRow(
                                controller: controller,
                                node: node,
                                visibleIDs: visibleIDs
                            )
                        }
                    }
                    .listStyle(.sidebar)
                    .overlay {
                        if isFiltering && topLevelNodes.isEmpty {
                            NoMatchesHint()
                        }
                    }
                }
            } else if let err = controller.loadError {
                ErrorState(error: err, onRetry: {
                    Task { await controller.openWithPanel() }
                })
            }
        }
        .task(id: controller.searchText) {
            // Debounce: wait for a quiet period before adopting the new text.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            debounced = controller.searchText
        }
    }

    private var isFiltering: Bool { !debounced.isEmpty }

    private var topLevelNodes: [TreeNode] {
        guard let tree = controller.backup?.tree else { return [] }
        let base: [TreeNode]
        if controller.entityFilter != nil {
            // Flat, cross-site view of one entity type (from the Overview counts).
            base = controller.entityFilteredNodes
        } else if let selectedCat = controller.selectedCategoryID,
                  let match = tree.first(where: { $0.id == selectedCat }) {
            base = TreeBuilder.children(of: match)
        } else {
            base = tree.flatMap { TreeBuilder.children(of: $0) }
        }
        guard let visibleIDs else { return base }
        return base.filter { visibleIDs.contains($0.id) }
    }

    /// The set of node ids that should be shown for the current filter, or
    /// `nil` when there is no active filter (everything shows). A node is
    /// included when it matches directly, or when it is an ancestor of a
    /// node that does. Computed from `controller.index` — the prebuilt
    /// `orderedIDs` / `descendantIDs` lookups — never by re-walking the tree.
    private var visibleIDs: Set<String>? {
        guard isFiltering else { return nil }
        let filter = debounced.lowercased()
        let index = controller.index

        var direct = Set<String>()
        for id in index.orderedIDs where controller.matches(id, filter: filter) {
            direct.insert(id)
        }
        guard !direct.isEmpty else { return direct }

        var visible = direct
        for id in index.orderedIDs where !visible.contains(id) {
            if !index.descendantIDs(of: id).isDisjoint(with: direct) {
                visible.insert(id)
            }
        }
        return visible
    }
}

private struct OutlineRow: View {
    @Bindable var controller: InspectorController
    let node: TreeNode
    /// `nil` when unfiltered; otherwise the full set of node ids currently
    /// visible in the tree (see `OutlinePane.visibleIDs`).
    let visibleIDs: Set<String>?

    /// Manual expand/collapse state, remembered per row across a live filter
    /// coming and going. While filtering, expansion is forced open instead
    /// (see `isExpandedBinding`) so a match is never hidden behind a
    /// collapsed disclosure the user never touched.
    @State private var expanded: Bool = false

    private var children: [TreeNode] { TreeBuilder.children(of: node) }

    private var visibleChildren: [TreeNode] {
        guard let visibleIDs else { return children }
        return children.filter { visibleIDs.contains($0.id) }
    }

    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: { visibleIDs != nil ? true : expanded },
            set: { expanded = $0 }
        )
    }

    var body: some View {
        Group {
            if visibleChildren.isEmpty {
                row
            } else {
                DisclosureGroup(isExpanded: isExpandedBinding) {
                    ForEach(visibleChildren, id: \.id) { child in
                        OutlineRow(controller: controller, node: child, visibleIDs: visibleIDs)
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
        .contentShape(Rectangle())
    }
}

private struct OutlineSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search everything…", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
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
        // The window's ⌘F command (owned elsewhere) posts this notification;
        // we just need to become first responder when it arrives.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("focusSearch"))) { _ in
            isFocused = true
        }
        // Escape clears the query first, then relinquishes focus on a second press.
        .onExitCommand {
            if !text.isEmpty {
                text = ""
            } else {
                isFocused = false
            }
        }
    }
}

/// Shows the active flat entity filter (e.g. "Devices") with a clear button,
/// so it is obvious the middle pane is scoped and how to get back.
private struct EntityFilterChip: View {
    let kind: EntityFilter
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.symbol)
                .foregroundStyle(.tint)
            Text("All \(kind.title)")
                .font(.caption.weight(.medium))
            Spacer()
            Button(action: onClear) {
                Label("Clear", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear filter")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }
}

private struct NoMatchesHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No matches")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .allowsHitTesting(false)
    }
}

private struct SupportBundleNote: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Support bundle — no configuration to browse; see Files/Diagnostics")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

private struct EmptyState: View {
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

private struct ErrorState: View {
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
