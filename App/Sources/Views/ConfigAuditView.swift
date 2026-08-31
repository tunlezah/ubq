import SwiftUI
import UniFiBackupKit

/// Config-audit sheet (ROADMAP Tier-2 #9). Renders the offline security /
/// hygiene lint (`ConfigAudit`) already computed by the controller: a severity
/// summary, an optional High+ filter, and findings grouped by category with a
/// recommendation callout and a "Reveal" jump for record-scoped findings.
struct ConfigAuditView: View {
    @Bindable var controller: InspectorController
    @Environment(\.dismiss) private var dismiss
    @State private var filter: AuditSeverityFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Config Audit")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let audit = controller.audit, !audit.findings.isEmpty {
                    Button("Copy Report") { controller.copyToPasteboard(audit.markdownReport()) }
                    Button("Save Report…") {
                        controller.saveReport(audit.markdownReport(), suggestedName: "unifi-audit.md")
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if let audit = controller.audit {
                auditContent(audit)
            } else {
                ContentUnavailableView(
                    "No backup loaded",
                    systemImage: "doc",
                    description: Text("Open a backup to run the audit.")
                )
                .frame(maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
    }

    @ViewBuilder
    private func auditContent(_ audit: ConfigAudit) -> some View {
        if audit.findings.isEmpty {
            ContentUnavailableView(
                "No issues found",
                systemImage: "checkmark.seal.fill",
                description: Text("The audit found no security or hygiene problems in this backup.")
            )
            .frame(maxHeight: .infinity)
        } else {
            severityChips(audit)

            Picker("Severity filter", selection: $filter) {
                Text("All").tag(AuditSeverityFilter.all)
                Text("High & Critical").tag(AuditSeverityFilter.highPlus)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)

            let groups = groupedFindings(audit)
            if groups.isEmpty {
                ContentUnavailableView(
                    "Nothing at this level",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("No findings match the current filter. Switch back to All to see everything.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { finding in
                                AuditFindingRow(finding: finding) { reveal(finding.recordId) }
                            }
                        } header: {
                            Text(group.category)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func severityChips(_ audit: ConfigAudit) -> some View {
        let summary = audit.summaryBySeverity
        return HStack(spacing: 8) {
            ForEach(ConfigAudit.Severity.allCases.reversed(), id: \.self) { sev in
                if let n = summary[sev], n > 0 {
                    AuditSeverityChip(severity: sev, count: n)
                }
            }
            Spacer()
        }
    }

    /// Applies the current filter, then groups by category preserving the
    /// severity-descending order the audit already sorts findings into (so the
    /// most severe categories float to the top and each group stays severity
    /// descending internally).
    private func groupedFindings(_ audit: ConfigAudit) -> [AuditGroup] {
        let items = filtered(audit.findings)
        var order: [String] = []
        var map: [String: [ConfigAudit.Finding]] = [:]
        for f in items {
            if map[f.category] == nil { order.append(f.category) }
            map[f.category, default: []].append(f)
        }
        return order.map { category in
            AuditGroup(
                category: category,
                items: (map[category] ?? []).sorted { $0.severity > $1.severity }
            )
        }
    }

    private func filtered(_ findings: [ConfigAudit.Finding]) -> [ConfigAudit.Finding] {
        switch filter {
        case .all: findings
        case .highPlus: findings.filter { $0.severity >= .high }
        }
    }

    private func reveal(_ recordId: String?) {
        guard let recordId else { return }
        controller.navigate(toId: recordId)
        dismiss()
    }
}

// MARK: - Model helpers

private enum AuditSeverityFilter: Hashable {
    case all
    case highPlus
}

private struct AuditGroup: Identifiable {
    var id: String { category }
    let category: String
    let items: [ConfigAudit.Finding]
}

/// SF Symbol + colour for a severity, shared by the chip and the finding row.
/// Colour is always paired with the symbol and the severity text label.
private func auditSymbol(_ severity: ConfigAudit.Severity) -> String {
    switch severity {
    case .critical: "exclamationmark.octagon.fill"
    case .high: "exclamationmark.triangle.fill"
    case .medium: "exclamationmark.circle.fill"
    case .low: "info.circle.fill"
    case .info: "info.circle"
    }
}

private func auditColor(_ severity: ConfigAudit.Severity) -> Color {
    switch severity {
    case .critical: .red
    case .high: .orange
    case .medium: .yellow
    case .low: .blue
    case .info: .secondary
    }
}

// MARK: - Rows

private struct AuditSeverityChip: View {
    let severity: ConfigAudit.Severity
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: auditSymbol(severity))
            Text("\(count) \(severity.rawValue)")
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(auditColor(severity))
        .background(
            Capsule().fill(auditColor(severity).opacity(0.16))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(severity.rawValue) severity")
    }
}

private struct AuditFindingRow: View {
    let finding: ConfigAudit.Finding
    var onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: auditSymbol(finding.severity))
                    .foregroundStyle(auditColor(finding.severity))
                Text(finding.severity.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(auditColor(finding.severity))
                Text(finding.title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                if finding.recordId != nil {
                    Button(action: onReveal) {
                        Label("Reveal", systemImage: "scope")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Reveal this record in the main window")
                }
            }

            Text(finding.detail)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let recommendation = finding.recommendation {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(Color.accentColor)
                    Text(recommendation)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.10))
                )
            }

            if let collection = finding.collection {
                Text(locationText(collection: collection, recordId: finding.recordId))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func locationText(collection: String, recordId: String?) -> String {
        if let recordId, !recordId.isEmpty {
            return "\(collection) · \(recordId)"
        }
        return collection
    }
}
