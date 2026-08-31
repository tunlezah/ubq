import SwiftUI
import UniFiBackupKit

struct ExportSheet: View {
    @Bindable var controller: InspectorController
    @Environment(\.dismiss) private var dismiss
    @State private var preview: String = ""
    @State private var sliceCount: Int = 1
    @State private var splitStatus: String?

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
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $controller.exportPreset) {
                        ForEach(LLMPreset.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    HStack(spacing: 8) {
                        Text("Character budget:")
                            .font(.callout)
                        TextField("", text: budgetTextBinding)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Stepper("", value: budgetIntBinding, in: 0...1_000_000, step: 500)
                            .labelsHidden()
                        Button("Reset to Default") {
                            controller.setBudgetOverride(nil, for: controller.exportPreset)
                            regeneratePreview()
                        }
                        .controlSize(.small)
                        .disabled(controller.budgetOverride(for: controller.exportPreset) == nil)
                        Spacer(minLength: 0)
                    }

                    Text("Default for \(controller.exportPreset.displayName): \(controller.exportPreset.targetCharacterBudget) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        Text(preview.isEmpty ? "(select items to export)" : String(preview.prefix(2000)))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 140, idealHeight: 220)
                    .background(Color.black.opacity(0.05))

                    HStack(alignment: .top) {
                        Text(budgetFeedback)
                            .font(.caption)
                            .foregroundStyle(isOverBudget ? .red : .secondary)
                        Spacer(minLength: 8)
                        if isOverBudget {
                            Button {
                                performSplit()
                            } label: {
                                Label("Split into \(sliceCount) Files…", systemImage: "square.grid.2x2")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if let splitStatus {
                        Text(splitStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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

    // MARK: - Budget editing

    /// Effective character budget for the currently selected preset: the
    /// stored per-preset override if one exists, else the preset's default.
    private var effectiveBudget: Int {
        controller.budgetOverride(for: controller.exportPreset) ?? controller.exportPreset.targetCharacterBudget
    }

    /// Text-field binding onto the controller's stored override. Typing a
    /// positive integer sets the override; clearing the field (or entering
    /// `0`) clears it, falling back to the preset default.
    private var budgetTextBinding: Binding<String> {
        Binding<String>(
            get: { String(effectiveBudget) },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let parsed = Int(trimmed), parsed > 0 {
                    controller.setBudgetOverride(parsed, for: controller.exportPreset)
                } else {
                    controller.setBudgetOverride(nil, for: controller.exportPreset)
                }
                regeneratePreview()
            }
        )
    }

    /// Stepper convenience onto the same stored override, in 500-character
    /// increments. Stepping down to 0 clears the override.
    private var budgetIntBinding: Binding<Int> {
        Binding<Int>(
            get: { effectiveBudget },
            set: { newValue in
                let clamped = max(0, newValue)
                controller.setBudgetOverride(clamped == 0 ? nil : clamped, for: controller.exportPreset)
                regeneratePreview()
            }
        )
    }

    // MARK: - Preview / budget feedback

    private var isOverBudget: Bool {
        !preview.isEmpty && preview.count > effectiveBudget
    }

    private var budgetFeedback: String {
        guard !preview.isEmpty else {
            return "Suggested budget: ~\(effectiveBudget) characters"
        }
        let count = preview.count
        if count > effectiveBudget {
            return "Current export is ~\(count) characters — over the \(effectiveBudget) character budget by \(count - effectiveBudget)."
        }
        return "Current export is ~\(count) characters, within the \(effectiveBudget) character budget."
    }

    private func regeneratePreview() {
        let request = controller.currentExportRequest()
        preview = Exporter.export(request)
        sliceCount = Exporter.exportSlices(request).count
        splitStatus = nil
    }

    /// Splits the current export across multiple files sized to the
    /// effective budget and saves each one via the controller's save panel.
    /// If the export already fits in one slice, just reports that.
    private func performSplit() {
        let request = controller.currentExportRequest()
        let slices = Exporter.exportSlices(request)
        guard slices.count > 1 else {
            splitStatus = "Export already fits in a single file; nothing to split."
            return
        }

        let suggested = Exporter.suggestedFilename(for: request)
        let ext = controller.exportFormat.fileExtension
        let suffix = ".\(ext)"
        let base = suggested.hasSuffix(suffix) ? String(suggested.dropLast(suffix.count)) : suggested

        for (index, slice) in slices.enumerated() {
            controller.saveReport(slice, suggestedName: "\(base)-part\(index + 1)\(suffix)")
        }
        splitStatus = "Saved \(slices.count) files."
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
