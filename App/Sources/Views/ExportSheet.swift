import SwiftUI
import UniFiBackupKit

struct ExportSheet: View {
    @Bindable var controller: InspectorController
    @Environment(\.dismiss) private var dismiss
    @State private var preview: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            GroupBox("Format") {
                Picker("", selection: $controller.exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            GroupBox("Target model") {
                Picker("", selection: $controller.exportPreset) {
                    ForEach(LLMPreset.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Text(budgetHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Secrets") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $controller.includeSecrets) {
                        Text("Include secrets in export")
                    }
                    .toggleStyle(.checkbox)
                    .tint(.red)

                    if controller.includeSecrets {
                        SecretWarningBanner()
                    } else {
                        Text("Secrets (WPA PSKs, admin hashes, RADIUS shared secrets, TOTP) will be replaced with `<redacted>`.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Preview") {
                ScrollView {
                    Text(preview.isEmpty ? "(select items to export)" : String(preview.prefix(2000)))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 140, idealHeight: 220)
                .background(Color.black.opacity(0.05))
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button {
                    controller.exportToPasteboard()
                    dismiss()
                } label: {
                    Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .tint(controller.includeSecrets ? .red : .accentColor)

                Button {
                    controller.exportToFile()
                    dismiss()
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.includeSecrets ? .red : .accentColor)
            }
        }
        .padding(22)
        .frame(minWidth: 560, minHeight: 520)
        .onAppear(perform: regeneratePreview)
        .onChange(of: controller.exportFormat) { _, _ in regeneratePreview() }
        .onChange(of: controller.exportPreset) { _, _ in regeneratePreview() }
        .onChange(of: controller.includeSecrets) { _, _ in regeneratePreview() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Export \(controller.selectedNodes.count) item\(controller.selectedNodes.count == 1 ? "" : "s")")
                .font(.title3.weight(.semibold))
            if let v = controller.backup?.identity.version {
                Text("From controller v\(v)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var budgetHint: String {
        let budget = controller.exportPreset.targetCharacterBudget
        let count = preview.count
        let over = count > budget
        let overBit = over ? " — current export is ~\(count) chars, over budget; consider splitting." : ""
        return "Suggested budget: ~\(budget) characters\(overBit)"
    }

    private func regeneratePreview() {
        preview = Exporter.export(controller.currentExportRequest())
    }
}

/// The red-glow warning banner surfaced when "Include secrets" is on. Per
/// ADR-009, there is no second confirmation click — the visual emphasis is
/// the safeguard.
struct SecretWarningBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("This export will contain secrets")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                Text("WPA passphrases, admin password hashes, RADIUS shared secrets, TOTP secrets. Do not share this output.")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.red.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.red.opacity(0.9), lineWidth: 1)
                )
                .shadow(color: .red.opacity(0.55), radius: 10)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: this export will include secrets. Do not share.")
    }
}
