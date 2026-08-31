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
                    // Sites / Admins jump to their structural category; the rest
                    // apply a flat, cross-site entity filter to the middle pane.
                    OverviewButton(
                        title: "Sites", count: b.model.sites.count, symbol: "house",
                        isActive: controller.selectedCategoryID == "sites" && controller.entityFilter == nil
                    ) { controller.selectedCategoryID = "sites" }

                    OverviewButton(
                        title: "Devices", count: b.model.devices.count,
                        symbol: EntityFilter.devices.symbol,
                        isActive: controller.entityFilter == .devices
                    ) { controller.entityFilter = .devices; controller.selectedCategoryID = nil }

                    OverviewButton(
                        title: "WLANs", count: b.model.wlans.count,
                        symbol: EntityFilter.wlans.symbol,
                        isActive: controller.entityFilter == .wlans
                    ) { controller.entityFilter = .wlans; controller.selectedCategoryID = nil }

                    OverviewButton(
                        title: "Networks", count: b.model.networks.count,
                        symbol: EntityFilter.networks.symbol,
                        isActive: controller.entityFilter == .networks
                    ) { controller.entityFilter = .networks; controller.selectedCategoryID = nil }

                    OverviewButton(
                        title: "Firewall", count: b.model.firewallRules.count,
                        symbol: EntityFilter.firewall.symbol,
                        isActive: controller.entityFilter == .firewall
                    ) { controller.entityFilter = .firewall; controller.selectedCategoryID = nil }

                    OverviewButton(
                        title: "Clients", count: b.model.clients.count,
                        symbol: EntityFilter.clients.symbol,
                        isActive: controller.entityFilter == .clients
                    ) { controller.entityFilter = .clients; controller.selectedCategoryID = nil }

                    OverviewButton(
                        title: "Admins", count: b.model.admins.count, symbol: "person.badge.key",
                        isActive: controller.selectedCategoryID == "admins" && controller.entityFilter == nil
                    ) { controller.selectedCategoryID = "admins" }

                    OverviewButton(
                        title: "Secrets", count: b.secretInventory.values.reduce(0, +),
                        symbol: "key.viewfinder", isActive: false
                    ) { controller.showSecretInventory = true }
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

/// A tappable Overview row: an SF-Symbol label, a trailing count, and an action.
/// Disabled when the count is zero. Highlights when its destination is active.
private struct OverviewButton: View {
    let title: String
    let count: Int
    let symbol: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .fontWeight(isActive ? .semibold : .regular)
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
    }
}
