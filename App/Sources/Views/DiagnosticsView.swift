import SwiftUI
import UniFiBackupKit

struct DiagnosticsView: View {
    @Bindable var controller: InspectorController
    @Environment(\.dismiss) private var dismiss
    @State private var showInfo: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Diagnostics")
                    .font(.title2.weight(.semibold))
                Spacer()
                if infoCount > 0 {
                    Toggle("Show info (\(infoCount))", isOn: $showInfo)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                Button("Copy Report") { copyReport() }
                    .disabled(filteredDiagnostics.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if allDiagnostics.isEmpty {
                ContentUnavailableView(
                    "No diagnostics",
                    systemImage: "checkmark.seal",
                    description: Text("This backup parsed cleanly.")
                )
                .frame(maxHeight: .infinity)
            } else if filteredDiagnostics.isEmpty {
                ContentUnavailableView(
                    "No warnings or errors",
                    systemImage: "checkmark.seal",
                    description: Text("Only informational diagnostics were emitted. Flip the toggle above to see them.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(Array(filteredDiagnostics.enumerated()), id: \.offset) { _, d in
                    DiagnosticRow(diagnostic: d)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }

    private var allDiagnostics: [Diagnostic] {
        controller.backup?.diagnostics ?? []
    }

    private var filteredDiagnostics: [Diagnostic] {
        showInfo ? allDiagnostics : allDiagnostics.filter { $0.severity != .info }
    }

    private var infoCount: Int {
        allDiagnostics.lazy.filter { $0.severity == .info }.count
    }

    private func copyReport() {
        var out = "# UniFi Backup Inspector diagnostics\n\n"
        for d in filteredDiagnostics {
            out += "- [\(d.severity.rawValue)] `\(d.code.rawValue)` \(d.message)"
            if let coll = d.collection { out += " (collection `\(coll)`)" }
            if let off = d.offset { out += " at offset \(off)" }
            out += "\n"
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(out, forType: .string)
    }
}

struct DiagnosticRow: View {
    let diagnostic: Diagnostic
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(diagnostic.severity))
                .foregroundStyle(color(diagnostic.severity))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.message)
                    .font(.callout)
                HStack(spacing: 8) {
                    Text("`\(diagnostic.code.rawValue)`")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let coll = diagnostic.collection {
                        Text("collection: \(coll)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let off = diagnostic.offset {
                        Text("offset: \(off)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func symbol(_ s: Diagnostic.Severity) -> String {
        switch s {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(_ s: Diagnostic.Severity) -> Color {
        switch s {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}
