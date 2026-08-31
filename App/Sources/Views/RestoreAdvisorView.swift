import SwiftUI
import UniFiBackupKit

/// Restore-advisor sheet (ROADMAP Tier-2 #10). Surfaces the pure guidance
/// `RestoreAdvisor` derives from a backup's identity: the produced version, the
/// minimum controller version it can restore into, informational messages, and
/// prominent amber warnings — framed by a static reminder that UniFi restores
/// are forward-only.
struct RestoreAdvisorView: View {
    @Bindable var controller: InspectorController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Restore Advisor")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let advice = controller.restoreAdvice {
                    Button("Copy") { controller.copyToPasteboard(plainText(advice)) }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if let advice = controller.restoreAdvice {
                adviceContent(advice)
            } else {
                ContentUnavailableView(
                    "No backup loaded",
                    systemImage: "doc",
                    description: Text("Open a backup to see restore guidance.")
                )
                .frame(maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 480)
    }

    private func adviceContent(_ advice: RestoreAdvisor.Advice) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                versionSummary(advice)

                if !advice.messages.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(advice.messages.enumerated()), id: \.offset) { _, message in
                            RestoreInfoRow(text: message)
                        }
                    }
                }

                if !advice.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(advice.warnings.enumerated()), id: \.offset) { _, warning in
                            RestoreWarningRow(text: warning)
                        }
                    }
                }

                forwardOnlyExplainer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }

    private func versionSummary(_ advice: RestoreAdvisor.Advice) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "tag")
                        .foregroundStyle(.secondary)
                    Text("Backup version")
                    Spacer()
                    Text(advice.backupVersion.map { "v\($0)" } ?? "Unknown")
                        .font(.callout.weight(.semibold))
                }
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(.secondary)
                    if let minimum = advice.minimumRestoreVersion {
                        Text("Restores into UniFi Network ≥ \(minimum)")
                            .font(.callout.weight(.medium))
                    } else {
                        Text("Minimum restore version is unknown")
                            .font(.callout.weight(.medium))
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var forwardOnlyExplainer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.forward.circle.fill")
                .foregroundStyle(.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("UniFi restores are forward-only")
                    .font(.callout.weight(.semibold))
                Text("A backup restores only into a controller running the same or a newer UniFi Network version. A newer backup will not restore into an older controller — upgrade the target controller first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    private func plainText(_ advice: RestoreAdvisor.Advice) -> String {
        var lines: [String] = []
        if let v = advice.backupVersion { lines.append("Backup version: v\(v)") }
        if let m = advice.minimumRestoreVersion { lines.append("Minimum restore version: v\(m)") }
        lines.append(contentsOf: advice.messages)
        for w in advice.warnings { lines.append("WARNING: \(w)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Rows

private struct RestoreInfoRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
                .font(.callout)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Prominent amber warning row (`exclamationmark.triangle.fill` + tinted card),
/// so a warning never rests on colour alone.
private struct RestoreWarningRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.7), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: \(text)")
    }
}
