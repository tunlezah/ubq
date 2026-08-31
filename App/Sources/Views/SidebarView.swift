import SwiftUI
import UniFiBackupKit

struct SidebarView: View {
    @Bindable var controller: InspectorController

    var body: some View {
        List(selection: $controller.selectedCategoryID) {
            if let tree = controller.backup?.tree {
                Section("Categories") {
                    ForEach(tree, id: \.id) { node in
                        if case .category(let cat) = node {
                            Label {
                                HStack {
                                    Text(cat.title)
                                    if let badge = cat.badge {
                                        Spacer()
                                        Text("\(badge)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: cat.symbolName)
                            }
                            .tag(cat.id)
                        }
                    }
                }
            }

            if let b = controller.backup {
                Section("Overview") {
                    LabelledRow(title: "Sites", value: "\(b.model.sites.count)", symbol: "house")
                    LabelledRow(title: "Devices", value: "\(b.model.devices.count)", symbol: "antenna.radiowaves.left.and.right")
                    LabelledRow(title: "WLANs", value: "\(b.model.wlans.count)", symbol: "wifi")
                    LabelledRow(title: "Networks", value: "\(b.model.networks.count)", symbol: "network")
                    LabelledRow(title: "Firewall rules", value: "\(b.model.firewallRules.count)", symbol: "shield")
                    LabelledRow(title: "Admins", value: "\(b.model.admins.count)", symbol: "person.badge.key")
                    Button {
                        controller.showSecretInventory = true
                    } label: {
                        LabelledRow(
                            title: "Secrets",
                            value: "\(b.secretInventory.values.reduce(0, +))",
                            symbol: "key.viewfinder"
                        )
                    }
                    .buttonStyle(.plain)
                }

                if let note = b.containerNote {
                    Section {
                        Label {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Statistics") {
                    Button {
                        controller.showStatistics = true
                    } label: {
                        Label(
                            b.statsLoaded ? "View statistics…" : "Load statistics…",
                            systemImage: "chart.line.uptrend.xyaxis"
                        )
                    }
                    .buttonStyle(.link)
                }

                if !b.isSupportBundle {
                    Section("Analysis") {
                        Button {
                            controller.showAudit = true
                        } label: {
                            HStack {
                                Label("Config Audit…", systemImage: "checkmark.shield")
                                if auditBadgeCount > 0 {
                                    Spacer()
                                    Text("\(auditBadgeCount)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(auditBadgeColor))
                                }
                            }
                        }
                        .buttonStyle(.link)

                        Button {
                            controller.showDiff = true
                        } label: {
                            Label("Compare backups…", systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(.link)

                        Button {
                            controller.showRestoreAdvisor = true
                        } label: {
                            Label("Restore Advisor…", systemImage: "wrench.and.screwdriver")
                        }
                        .buttonStyle(.link)
                    }
                }

                Section("Files") {
                    Button {
                        controller.showFiles = true
                    } label: {
                        Label("Archive files…", systemImage: "doc.zipper")
                    }
                    .buttonStyle(.link)
                }
            }

            if controller.backup == nil && !controller.recentFiles.isEmpty {
                Section("Recent") {
                    ForEach(controller.recentFiles, id: \.self) { url in
                        Button {
                            Task { await controller.open(url: url) }
                        } label: {
                            Label(url.lastPathComponent, systemImage: "clock")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// High + critical finding count from the last audit run, for the small
    /// badge next to "Config Audit…".
    private var auditBadgeCount: Int {
        guard let summary = controller.audit?.summaryBySeverity else { return 0 }
        return (summary[.high] ?? 0) + (summary[.critical] ?? 0)
    }

    private var auditBadgeColor: Color {
        guard let summary = controller.audit?.summaryBySeverity else { return .secondary }
        if (summary[.critical] ?? 0) > 0 { return .red }
        return .orange
    }
}

private struct LabelledRow: View {
    let title: String
    let value: String
    let symbol: String
    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
