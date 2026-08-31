import SwiftUI
import UniFiBackupKit

/// Shows *which* fields carry secrets and how many — never the values
/// themselves (ROADMAP Tier-1 #6). `controller.backup!.secretInventory` maps
/// a dotted `collection.field` name (e.g. `wlanconf.x_passphrase`) to how
/// many records in this backup carry a non-empty value for it.
struct SecretInventoryView: View {
    @Bindable var controller: InspectorController
    @Environment(\.dismiss) private var dismiss

    private var inventory: [String: Int] {
        controller.backup?.secretInventory ?? [:]
    }

    private var totalCount: Int {
        inventory.values.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Secret Inventory")
                        .font(.title2.weight(.semibold))
                    Text(
                        "\(totalCount) secret value\(totalCount == 1 ? "" : "s") across \(inventory.count) field\(inventory.count == 1 ? "" : "s")"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyInventory()
                } label: {
                    Label("Copy inventory (names only)", systemImage: "doc.on.clipboard")
                }
                .disabled(inventory.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            NoticeBanner()

            if groups.isEmpty {
                ContentUnavailableView(
                    "No secrets found",
                    systemImage: "checkmark.shield",
                    description: Text("This backup carries no known secret fields.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                HStack {
                                    Text(entry.field)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Text("\(entry.count)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } header: {
                            HStack {
                                Text(group.name)
                                Spacer()
                                Text("\(group.total)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
    }

    // MARK: - Grouping

    private struct SecretEntry: Identifiable {
        let id = UUID()
        let field: String
        let count: Int
    }

    private struct SecretGroup: Identifiable {
        let name: String
        var entries: [SecretEntry]
        var id: String { name }
        var total: Int { entries.reduce(0) { $0 + $1.count } }
    }

    /// Groups by the part of the key before the first `.` (typically the
    /// collection name, e.g. "wlanconf"), sorted by total descending.
    private var groups: [SecretGroup] {
        var byGroup: [String: [SecretEntry]] = [:]
        for (key, count) in inventory {
            let parts = key.split(separator: ".", maxSplits: 1)
            let groupName = parts.count > 1 ? String(parts[0]) : "other"
            let field = parts.count > 1 ? String(parts[1]) : key
            byGroup[groupName, default: []].append(SecretEntry(field: field, count: count))
        }
        return byGroup.map { name, entries in
            SecretGroup(
                name: name,
                entries: entries.sorted { $0.count != $1.count ? $0.count > $1.count : $0.field < $1.field }
            )
        }.sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
    }

    private func copyInventory() {
        var out = "# Secret inventory (names only — values are never shown)\n\n"
        out += "Total: \(totalCount) secret value\(totalCount == 1 ? "" : "s") across \(inventory.count) field\(inventory.count == 1 ? "" : "s")\n\n"
        for group in groups {
            out += "## \(group.name)\n"
            for entry in group.entries {
                out += "- `\(entry.field)`: \(entry.count)\n"
            }
            out += "\n"
        }
        controller.copyToPasteboard(out)
    }
}

private struct NoticeBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Names only — no values shown")
                    .font(.callout.weight(.semibold))
                Text("This inventory lists which fields carry secrets (WPA passphrases, admin password hashes, RADIUS shared secrets, TOTP seeds) and how many records have them — never the secret values themselves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This inventory lists secret field names and counts only; values are never shown.")
    }
}
