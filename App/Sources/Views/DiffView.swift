import SwiftUI
import UniFiBackupKit

/// Compare-two-backups sheet (ROADMAP Tier-2 #8, #13).
///
/// Two modes, driven purely by controller state:
///   * no second backup loaded → a chooser (panel buttons + discovered
///     autobackups) so the user can pick something to compare against;
///   * a computed `BackupDiff` → an identity header plus a per-collection,
///     lazily-expanded delta list.
struct DiffView: View {
    @Bindable var controller: InspectorController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare Backups")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let diff = controller.diff {
                    Button {
                        controller.clearSecondary()
                    } label: {
                        Label("Choose Different…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Pick a different backup to compare against")
                    Button("Copy Report") { controller.copyToPasteboard(diff.markdownReport()) }
                    Button("Save Report…") {
                        controller.saveReport(diff.markdownReport(), suggestedName: "unifi-diff.md")
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if let diff = controller.diff {
                diffSummary(diff)
                Divider()
                diffBody(diff)
            } else {
                chooser
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 560)
    }

    // MARK: - Chooser (no second backup yet)

    private var primaryName: String {
        controller.sourceURL?.lastPathComponent ?? "current backup"
    }

    @ViewBuilder
    private var chooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Comparing against")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(primaryName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await controller.openSecondaryWithPanel() }
                } label: {
                    Label("Choose second backup…", systemImage: "doc.badge.plus")
                }
                Button {
                    Task { await controller.openFolderWithPanel() }
                } label: {
                    Label("Open autobackup folder…", systemImage: "folder")
                }
            }

            if let err = controller.secondaryError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(String(describing: err))
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.10))
                )
            }

            if controller.folderBackups.isEmpty {
                ContentUnavailableView(
                    "No second backup selected",
                    systemImage: "square.on.square.dashed",
                    description: Text("Choose another backup file, or open a folder of .unf autobackups to compare against.")
                )
                .frame(maxHeight: .infinity)
            } else {
                Text("Autobackups (newest first)")
                    .font(.headline)
                List(controller.folderBackups, id: \.self) { url in
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(url.path)
                        Spacer()
                        Button("Compare") {
                            Task { await controller.openSecondary(url: url) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Identity summary header

    private func diffSummary(_ diff: BackupDiff) -> some View {
        HStack(alignment: .center, spacing: 14) {
            identityColumn("Current", diff.leftIdentity)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            identityColumn("Compared", diff.rightIdentity)
            Spacer()
            if diff.isEmpty {
                Label("Identical", systemImage: "equal.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Label(
                    "\(diff.totalChanges) change\(diff.totalChanges == 1 ? "" : "s")",
                    systemImage: "plusminus.circle.fill"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func identityColumn(_ label: String, _ identity: Identity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Image(systemName: "tag")
                    .font(.caption)
                Text(identity.version.map { "v\($0)" } ?? "v?")
                    .font(.callout.weight(.medium))
            }
            if let t = identity.timestamp {
                Text(t, format: .dateTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Delta body

    @ViewBuilder
    private func diffBody(_ diff: BackupDiff) -> some View {
        if diff.isEmpty {
            ContentUnavailableView(
                "No differences",
                systemImage: "checkmark.seal",
                description: Text("These two backups have identical configuration.")
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(diff.collectionDeltas) { cd in
                    DisclosureGroup {
                        ForEach(cd.deltas) { delta in
                            DiffDeltaRow(delta: delta) { reveal(delta.recordId) }
                        }
                    } label: {
                        collectionHeader(cd)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func collectionHeader(_ cd: BackupDiff.CollectionDelta) -> some View {
        HStack(spacing: 10) {
            Text(cd.collection)
                .font(.callout.weight(.semibold))
            Spacer()
            if cd.added > 0 { countLabel("+\(cd.added)", .green) }
            if cd.removed > 0 { countLabel("−\(cd.removed)", .red) }
            if cd.modified > 0 { countLabel("~\(cd.modified)", .orange) }
        }
    }

    private func countLabel(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(color)
    }

    private func reveal(_ recordId: String) {
        controller.navigate(toId: recordId)
        dismiss()
    }
}

// MARK: - Rows

/// One record's delta: colour + SF Symbol keyed to the change kind, its title,
/// a "Reveal" affordance, and (for modifications) a compact before/after table.
private struct DiffDeltaRow: View {
    let delta: BackupDiff.RecordDelta
    var onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text(delta.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !delta.recordId.isEmpty {
                    Text(delta.recordId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button(action: onReveal) {
                    Label("Reveal", systemImage: "scope")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Reveal this record in the main window")
            }

            if delta.kind == .modified && !delta.fieldChanges.isEmpty {
                DiffFieldTable(changes: delta.fieldChanges)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch delta.kind {
        case .added: "plus.circle.fill"
        case .removed: "minus.circle.fill"
        case .modified: "pencil.circle.fill"
        }
    }

    private var color: Color {
        switch delta.kind {
        case .added: .green
        case .removed: .red
        case .modified: .orange
        }
    }
}

/// Compact `path | before → after` table for a modified record. Before renders
/// in a red hue, after in green; the arrow between them carries the direction so
/// colour is never the only signal. Long values truncate with a full-value help
/// tooltip.
private struct DiffFieldTable: View {
    let changes: [BackupDiff.FieldChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(changes.enumerated()), id: \.offset) { _, fc in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(fc.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 170, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(fc.path)
                    Text(fc.before ?? "—")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(fc.before ?? "—")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(fc.after ?? "—")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(fc.after ?? "—")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 26)
        .padding(.top, 1)
    }
}
