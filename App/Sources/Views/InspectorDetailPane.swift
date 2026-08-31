import SwiftUI
import UniFiBackupKit

struct InspectorDetailPane: View {
    @Bindable var controller: InspectorController
    @State private var showRevealedSecrets: Bool = false

    var body: some View {
        if let node = focusedNode, let raw = node.rawDocument {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(node: node)
                    prettyFields(for: raw)
                    backlinksSection(for: raw)
                    rawJSONBlock(for: raw)
                }
                .padding(20)
            }
            .background(.regularMaterial)
        } else if controller.backup != nil {
            ContentUnavailableView {
                Label("Select an item", systemImage: "sidebar.squares.right")
            } description: {
                Text("Choose a node on the left to inspect its details.")
            }
        } else {
            Color.clear
        }
    }

    /// O(1) via `BackupIndex` — never walks the tree per render.
    private var focusedNode: TreeNode? {
        controller.node(for: controller.focusedNodeID ?? "")
    }

    private func header(node: TreeNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: node.symbolName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(node.title)
                    .font(.title3.weight(.semibold))
            }
            if let raw = node.rawDocument {
                let secretPaths = SecretVault.findSecrets(in: raw)
                if !secretPaths.isEmpty {
                    SecretsStrip(paths: secretPaths, revealed: $showRevealedSecrets)
                }
            }
        }
    }

    // MARK: - Fields (with cross-reference links)

    @ViewBuilder
    private func prettyFields(for raw: UniFiBSON.BSONDocument) -> some View {
        let effective = showRevealedSecrets ? raw : SecretVault.redact(raw)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(effective.pairs.enumerated()), id: \.offset) { _, pair in
                fieldRow(key: pair.0, value: pair.1)
                Divider()
            }
        }
        .padding(.vertical, 8)
    }

    private func fieldRow(key: String, value: BSONValue) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.system(.body, design: .monospaced))
                .frame(width: 220, alignment: .leading)
                .foregroundStyle(.secondary)
            fieldValue(key: key, value: value)
            Spacer()
        }
        .padding(.vertical, 3)
    }

    /// Renders a field's value, resolving it through `CrossReference` first:
    /// a scalar id becomes a clickable link, an array of ids becomes a
    /// wrapped row of link chips, and anything that doesn't resolve falls
    /// back to the plain display string exactly as before.
    @ViewBuilder
    private func fieldValue(key: String, value: BSONValue) -> some View {
        if case .array(let items) = value, !items.isEmpty,
           let crossRef = controller.crossRef,
           items.contains(where: { crossRef.resolve(fieldName: key, value: $0) != nil }) {
            FlowLayout(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    if let resolved = crossRef.resolve(fieldName: key, value: item) {
                        CrossRefChip(title: resolved.displayName ?? resolved.targetId) {
                            controller.navigate(toId: resolved.targetId)
                        }
                    } else {
                        Text(item.displayString)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if let resolved = controller.crossRef?.resolve(fieldName: key, value: value) {
            Button {
                controller.navigate(toId: resolved.targetId)
            } label: {
                Text(resolved.displayName ?? resolved.targetId)
                    .font(.system(.body, design: .monospaced))
            }
            .buttonStyle(.link)
        } else {
            Text(value.displayString)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
        }
    }

    // MARK: - Back-links ("Referenced by")

    @ViewBuilder
    private func backlinksSection(for raw: UniFiBSON.BSONDocument) -> some View {
        let recordId = raw.idString
        let usages = recordId.isEmpty ? [] : (controller.crossRef?.usages(ofId: recordId) ?? [])
        if !usages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Referenced by")
                    .font(.headline)
                ForEach(Array(usages.enumerated()), id: \.offset) { _, usage in
                    Button {
                        controller.navigate(toId: usage.byId)
                    } label: {
                        HStack(spacing: 6) {
                            Text(usage.byTitle)
                            Text("via \(usage.viaField)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: - Raw JSON

    @ViewBuilder
    private func rawJSONBlock(for raw: UniFiBSON.BSONDocument) -> some View {
        let effective = showRevealedSecrets ? raw : SecretVault.redact(raw)
        let json = IntermediateRepresentation.jsonString(from: effective)
        DisclosureGroup("Raw JSON") {
            ScrollView(.horizontal) {
                Text(json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.06))
            }
            .frame(maxHeight: 280)
        }
    }
}

private struct SecretsStrip: View {
    let paths: [String]
    @Binding var revealed: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.viewfinder")
                .foregroundStyle(.orange)
            Text("\(paths.count) secret\(paths.count == 1 ? "" : "s"): \(paths.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Toggle(isOn: $revealed) {
                Text(revealed ? "Hide" : "Reveal")
                    .font(.caption)
            }
            .toggleStyle(.button)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A single cross-reference link rendered as a small pill, used for array
/// reference fields (`group_members`, `*_firewallgroup_ids`, …) where several
/// links need to sit together and wrap.
private struct CrossRefChip: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
        }
        .buttonStyle(.link)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

/// Minimal left-to-right, top-to-bottom wrapping layout for the chip rows.
/// Standard `Layout`-protocol flow layout: lays subviews out at their own
/// ideal size, wrapping to a new line whenever the next one would overflow
/// the proposed width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > maxWidth {
                width = max(width, origin.x - spacing)
                origin.x = 0
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        width = max(width, origin.x - spacing)
        let height = origin.y + rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : max(width, 0), height: max(height, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX, origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
