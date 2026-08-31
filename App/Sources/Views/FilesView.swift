import SwiftUI
import AppKit
import UniFiBackupKit

/// Browses the raw archive entries (`controller.backup!.rawEntries`) that
/// would otherwise never surface in the UI — every file the ZIP/tar
/// container carried, not just the ones the model mapper understood
/// (ROADMAP Tier-1 #4). Read-only; nothing here is ever written back.
struct FilesView: View {
    @Bindable var controller: InspectorController
    @Environment(\.dismiss) private var dismiss
    @State private var selectedName: String?

    private var entryNames: [String] {
        (controller.backup?.entryNames ?? []).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Archive Files")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(entryNames.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if entryNames.isEmpty {
                ContentUnavailableView(
                    "No archive entries",
                    systemImage: "doc.zipper",
                    description: Text("This backup exposed no raw archive files to browse.")
                )
                .frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    entryList
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
                    detailPane
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 500)
        .onAppear {
            if selectedName == nil { selectedName = entryNames.first }
        }
    }

    private var entryList: some View {
        List(entryNames, id: \.self, selection: $selectedName) { name in
            FileRow(
                name: name,
                size: controller.backup?.entrySizes[name] ?? 0
            )
            .tag(name)
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let name = selectedName, let data = controller.backup?.rawEntries[name] {
            EntryDetailView(name: name, data: data)
        } else {
            ContentUnavailableView(
                "Select a file",
                systemImage: "doc",
                description: Text("Choose an entry on the left to view it.")
            )
        }
    }
}

// MARK: - Row

private struct FileRow: View {
    let name: String
    let size: Int

    var body: some View {
        Label {
            HStack {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(FileKind.humanReadableSize(size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: FileKind.symbolName(for: name))
        }
    }
}

// MARK: - Entry kind

private enum FileKind {
    static func symbolName(for name: String) -> String {
        let base = (name as NSString).lastPathComponent.lowercased()
        if base.hasSuffix(".json") { return "curlybraces" }
        if base.hasSuffix(".properties") { return "list.bullet.rectangle" }
        if base.hasSuffix(".gz") { return "doc.zipper" }
        if base.hasSuffix(".bson") { return "shippingbox" }
        if base.hasSuffix(".png") || base.hasSuffix(".jpg") || base.hasSuffix(".jpeg") || base.hasSuffix(".gif") {
            return "photo"
        }
        if ["version", "format", "timestamp"].contains(base) { return "doc.text" }
        return "doc.questionmark"
    }

    static func humanReadableSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Detail viewer

private struct EntryDetailView: View {
    let name: String
    let data: Data

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 8) {
                Text(name)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Divider()
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var baseName: String {
        (name as NSString).lastPathComponent.lowercased()
    }

    @ViewBuilder
    private var content: some View {
        if baseName == "system.properties" || baseName.hasSuffix(".properties") {
            PropertiesTable(entries: PropertiesParser.parse(data))
        } else if baseName.hasSuffix(".json") {
            Text(JSONPreview.prettyPrint(data) ?? "<not valid UTF-8, \(data.count) bytes>")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        } else if ["version", "format", "timestamp"].contains(baseName), let text = String(data: data, encoding: .utf8) {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        } else if baseName.hasSuffix(".png") || baseName.hasSuffix(".jpg") || baseName.hasSuffix(".jpeg"),
                  let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 480, maxHeight: 480)
        } else {
            BinaryPreview(data: data)
        }
    }
}

private struct PropertiesTable: View {
    let entries: [PropertiesParser.Entry]

    var body: some View {
        if entries.isEmpty {
            Text("(no key=value pairs found)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.key)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 260, alignment: .leading)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(entry.value)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    Divider()
                }
            }
        }
    }
}

private struct BinaryPreview: View {
    let data: Data

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("<binary, \(data.count) bytes>")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("First \(min(data.count, 64)) bytes (hex):")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(hexPreview)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var hexPreview: String {
        data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

// MARK: - Parsing helpers

private enum PropertiesParser {
    struct Entry: Identifiable {
        let id = UUID()
        let key: String
        let value: String
    }

    /// Minimal Java-properties-style parser: `key=value` (or `key:value`)
    /// lines, blank lines and `#`/`!` comments skipped, a handful of common
    /// backslash escapes unescaped. Not a full spec implementation — this is
    /// a read-only viewer, not a properties editor.
    static func parse(_ data: Data) -> [Entry] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        var entries: [Entry] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            guard let sepIndex = findSeparator(in: line) else { continue }
            let rawKey = String(line[line.startIndex..<sepIndex])
            let afterSep = line.index(after: sepIndex)
            let rawValue = afterSep < line.endIndex ? String(line[afterSep...]) : ""
            entries.append(Entry(key: unescape(rawKey), value: unescape(rawValue)))
        }
        return entries
    }

    /// First unescaped `=` or `:`.
    private static func findSeparator(in line: String) -> String.Index? {
        var escaped = false
        var idx = line.startIndex
        while idx < line.endIndex {
            let c = line[idx]
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "=" || c == ":" {
                return idx
            }
            idx = line.index(after: idx)
        }
        return nil
    }

    private static func unescape(_ s: String) -> String {
        var result = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                switch chars[i + 1] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                case "=": result.append("=")
                case ":": result.append(":")
                case " ": result.append(" ")
                default: result.append(chars[i + 1])
                }
                i += 2
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

private enum JSONPreview {
    /// Best-effort pretty-print: valid JSON is re-serialized sorted/indented;
    /// text that merely decodes as UTF-8 but isn't valid JSON is shown as-is;
    /// non-UTF-8 data yields `nil` so the caller can show a byte count.
    static func prettyPrint(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return text
        }
        return pretty
    }
}
