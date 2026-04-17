import SwiftUI
import UniformTypeIdentifiers
import UniFiBackupKit

/// The three-pane inspector window.
struct InspectorWindow: View {
    @Bindable var controller: InspectorController
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(controller: controller)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
        } content: {
            OutlinePane(controller: controller)
                .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 540)
        } detail: {
            InspectorDetailPane(controller: controller)
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .overlay { dropOverlay }
        .sheet(isPresented: $controller.showExportSheet) {
            ExportSheet(controller: controller)
                .frame(minWidth: 560, minHeight: 560)
        }
        .sheet(isPresented: $controller.showDiagnostics) {
            DiagnosticsView(controller: controller)
                .frame(minWidth: 560, minHeight: 420)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsurl = item as? URL {
                    url = nsurl
                } else {
                    url = nil
                }
                if let url {
                    Task { @MainActor in await controller.open(url: url) }
                }
            }
            return true
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await controller.openWithPanel() }
            } label: {
                Label("Open", systemImage: "doc.badge.plus")
            }
            .help("Open a .unf backup file (⌘O)")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $controller.selectionMode) {
                Label("Select", systemImage: "checkmark.circle")
            }
            .toggleStyle(.button)
            .disabled(controller.backup == nil)
            .help("Toggle selection mode (⌘⌥S)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                controller.showExportSheet = true
            } label: {
                Label(
                    controller.selectedNodes.isEmpty ? "Export" : "Export (\(controller.selectedNodes.count))",
                    systemImage: "square.and.arrow.up"
                )
            }
            .disabled(controller.selectedNodes.isEmpty)
            .help("Export selection (⌘⇧E)")
        }
        ToolbarItem(placement: .automatic) {
            Text("v\(controller.appVersion)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let b = controller.backup {
            IdentityBar(identity: b.identity, warnings: b.warnings, diagnosticCount: b.diagnostics.count, isUnifiOS: b.isUnifiOSBackup) {
                controller.showDiagnostics = true
            }
        } else if let err = controller.loadError {
            ErrorBar(error: err)
        }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if controller.isLoading {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                ProgressView("Parsing backup…")
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Identity bar

struct IdentityBar: View {
    let identity: Identity
    let warnings: [String]
    let diagnosticCount: Int
    let isUnifiOS: Bool
    var onShowDiagnostics: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let v = identity.version {
                Label("v\(v)", systemImage: "tag")
                    .labelStyle(.titleAndIcon)
            }
            if let f = identity.format {
                Text("format \(f)")
                    .foregroundStyle(.secondary)
            }
            if let t = identity.timestamp {
                Text(t, format: .dateTime)
                    .foregroundStyle(.secondary)
            }
            Label(identity.kind.rawValue, systemImage: kindSymbol(identity.kind))
                .labelStyle(.titleAndIcon)
            Label(identity.origin.rawValue, systemImage: "server.rack")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)

            if isUnifiOS {
                Label("UniFi OS", systemImage: "shippingbox")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.blue)
            }

            Spacer()

            if diagnosticCount > 0 {
                Button {
                    onShowDiagnostics()
                } label: {
                    Label("\(diagnosticCount) diagnostics", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func kindSymbol(_ k: Identity.Kind) -> String {
        switch k {
        case .full: "externaldrive"
        case .settingsOnly: "gearshape"
        case .siteExport: "square.and.arrow.up.on.square"
        case .unknown: "questionmark.diamond"
        }
    }
}

struct ErrorBar: View {
    let error: FatalBackupError
    var body: some View {
        Text(String(describing: error))
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
    }
}
