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

    private var focusedNode: TreeNode? {
        guard let id = controller.focusedNodeID,
              let tree = controller.backup?.tree else { return nil }
        return TreeBuilder.flatten(tree).first { $0.id == id }
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

    @ViewBuilder
    private func prettyFields(for raw: UniFiBSON.BSONDocument) -> some View {
        let effective = showRevealedSecrets ? raw : SecretVault.redact(raw)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(effective.pairs.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .firstTextBaseline) {
                    Text(pair.0)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 220, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(pair.1.displayString)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(4)
                    Spacer()
                }
                .padding(.vertical, 3)
                Divider()
            }
        }
        .padding(.vertical, 8)
    }

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

struct SecretsStrip: View {
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
