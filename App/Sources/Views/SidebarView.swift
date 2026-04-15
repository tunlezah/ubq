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
                    LabelledRow(
                        title: "Secrets",
                        value: "\(b.secretInventory.values.reduce(0, +))",
                        symbol: "key.viewfinder"
                    )
                }

                if !b.statsLoaded {
                    Section("Statistics") {
                        Button {
                            Task { await controller.loadStatistics() }
                        } label: {
                            Label("Load statistics…", systemImage: "chart.line.uptrend.xyaxis")
                        }
                        .buttonStyle(.link)
                    }
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
}

struct LabelledRow: View {
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
