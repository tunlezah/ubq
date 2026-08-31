import SwiftUI
import UniformTypeIdentifiers
import UniFiBackupKit

/// The three-pane inspector window.
struct InspectorWindow: View {
    @Bindable var controller: InspectorController
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(controller: controller)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
            } content: {
                OutlinePane(controller: controller)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 540)
            } detail: {
                InspectorDetailPane(controller: controller)
            }
            .toolbar { toolbar }

            bottomBar
        }
        .frame(minWidth: 900, minHeight: 560)
        .overlay { loadingOverlay }
        .sheet(isPresented: $controller.showExportSheet) {
            ExportSheet(controller: controller)
                .frame(minWidth: 560, minHeight: 560)
        }
        .sheet(isPresented: $controller.showDiagnostics) {
            DiagnosticsView(controller: controller)
                .frame(minWidth: 560, minHeight: 420)
        }
        .sheet(isPresented: $controller.showDiff) {
            DiffView(controller: controller)
                .frame(minWidth: 760, minHeight: 560)
        }
        .sheet(isPresented: $controller.showAudit) {
            ConfigAuditView(controller: controller)
                .frame(minWidth: 640, minHeight: 520)
        }
        .sheet(isPresented: $controller.showRestoreAdvisor) {
            RestoreAdvisorView(controller: controller)
                .frame(minWidth: 520, minHeight: 420)
        }
        .sheet(isPresented: $controller.showSecretInventory) {
            SecretInventoryView(controller: controller)
                .frame(minWidth: 560, minHeight: 460)
        }
        .sheet(isPresented: $controller.showFiles) {
            FilesView(controller: controller)
                .frame(minWidth: 720, minHeight: 500)
        }
        .sheet(isPresented: $controller.showStatistics) {
            StatisticsView(controller: controller)
                .frame(minWidth: 640, minHeight: 480)
        }
        .alert(
            "Couldn't load statistics",
            isPresented: Binding(
                get: { controller.statsError != nil },
                set: { if !$0 { controller.statsError = nil } }
            ),
            presenting: controller.statsError
        ) { _ in
            Button("OK", role: .cancel) { controller.statsError = nil }
        } message: { err in
            Text(String(describing: err))
        }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { controller.exportError != nil },
                set: { if !$0 { controller.exportError = nil } }
            ),
            presenting: controller.exportError
        ) { _ in
            Button("OK", role: .cancel) { controller.exportError = nil }
        } message: { msg in
            Text(msg)
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
            .help("Open a .unf / .unifi / .supp backup file (⌘O)")
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
            Button {
                controller.showDiff = true
            } label: {
                Label("Compare", systemImage: "arrow.left.arrow.right.square")
            }
            .disabled(controller.backup == nil)
            .help("Compare against another backup (⌘⇧D)")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                controller.showAudit = true
            } label: {
                Label("Audit", systemImage: "checkmark.shield")
            }
            .disabled(controller.backup == nil)
            .help("Run the configuration audit")
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
            IdentityBar(
                identity: b.identity,
                warnings: b.warnings,
                diagnostics: b.diagnostics,
                isUnifiOS: b.isUnifiOSBackup,
                isSupportBundle: b.isSupportBundle,
                isConsoleBackup: b.isUnifiOSConsoleBackup,
                containerNote: b.containerNote,
                auditHighCount: auditHighCount,
                onShowDiagnostics: { controller.showDiagnostics = true },
                onShowAudit: { controller.showAudit = true }
            )
        } else if let err = controller.loadError {
            ErrorBar(error: err)
        }
    }

    private var auditHighCount: Int {
        guard let audit = controller.audit else { return 0 }
        return (audit.summaryBySeverity[.high] ?? 0) + (audit.summaryBySeverity[.critical] ?? 0)
    }

    @ViewBuilder
    private var loadingOverlay: some View {
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
    let diagnostics: [Diagnostic]
    let isUnifiOS: Bool
    let isSupportBundle: Bool
    let isConsoleBackup: Bool
    let containerNote: String?
    let auditHighCount: Int
    var onShowDiagnostics: () -> Void
    var onShowAudit: () -> Void

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

            if isConsoleBackup {
                Label("UniFi OS console", systemImage: "shippingbox.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.blue)
            } else if isUnifiOS {
                Label("UniFi OS", systemImage: "shippingbox")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.blue)
            }
            if isSupportBundle {
                Label("Support bundle", systemImage: "lifepreserver")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.blue)
            }

            Spacer()

            if auditHighCount > 0 {
                Button(action: onShowAudit) {
                    Label("\(auditHighCount) audit", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("\(auditHighCount) high-severity audit findings")
            }

            if !diagnostics.isEmpty {
                Button(action: onShowDiagnostics) {
                    Label("\(diagnostics.count) diagnostics", systemImage: badgeSymbol)
                        .foregroundStyle(badgeColor)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .topLeading) {
            if let note = containerNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .offset(y: -14)
                    .lineLimit(1)
                    .help(note)
            }
        }
    }

    private var problemCount: Int {
        diagnostics.lazy.filter { $0.severity != .info }.count
    }

    private var badgeSymbol: String {
        if diagnostics.contains(where: { $0.severity == .error }) { return "xmark.octagon.fill" }
        if problemCount > 0 { return "exclamationmark.triangle.fill" }
        return "info.circle"
    }

    private var badgeColor: Color {
        if diagnostics.contains(where: { $0.severity == .error }) { return .red }
        if problemCount > 0 { return .orange }
        return .secondary
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
