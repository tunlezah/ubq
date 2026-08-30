import Foundation

/// Flat, spreadsheet-friendly rendering (ROADMAP Tier-2 #11): one CSV table
/// per collection ("tag"), rather than the single hierarchical document the
/// other formats produce. Records are gathered from the whole IR — including
/// anything nested under a container's `children` — since a table has no
/// concept of nesting; only the grouping by tag survives.
enum CSVExporter {
    static func render(
        _ ir: IntermediateRepresentation,
        preset: LLMPreset,
        budget: Int,
        includesSecrets: Bool
    ) -> String {
        var out = headerComment(ir.header, preset: preset, includesSecrets: includesSecrets)
        out += "\n"

        let records = flatten(ir.sections)
        var order: [String] = []
        var groups: [String: [IntermediateRepresentation.Section]] = [:]
        for record in records {
            if groups[record.tag] == nil {
                order.append(record.tag)
                groups[record.tag] = []
            }
            groups[record.tag]?.append(record)
        }

        let tables = order.compactMap { tag in
            groups[tag].map { table(tag: tag, records: $0) }
        }
        out += tables.joined(separator: "\n")

        if out.count > budget {
            out += "\n# NOTE: this export is ~\(out.count) characters, exceeding the suggested budget for \(preset.displayName) (~\(budget)). Consider splitting.\n"
        }
        return out
    }

    /// Depth-first walk collecting every section that actually carries a
    /// record (has fields and/or a raw document) — skipping pure grouping
    /// wrappers (e.g. a `.siteChildCategory` with no own document) which
    /// exist only to nest their children.
    private static func flatten(_ sections: [IntermediateRepresentation.Section]) -> [IntermediateRepresentation.Section] {
        var out: [IntermediateRepresentation.Section] = []
        for section in sections {
            if !section.fields.isEmpty || section.rawJSON != nil {
                out.append(section)
            }
            out.append(contentsOf: flatten(section.children))
        }
        return out
    }

    /// One CSV table for a single collection: a `# <tag>` comment line, a
    /// header row of the union of field keys (first-seen order across the
    /// group's records), then one data row per record.
    private static func table(tag: String, records: [IntermediateRepresentation.Section]) -> String {
        var keyOrder: [String] = []
        var seenKeys = Set<String>()
        for record in records {
            for (key, _) in record.fields where !seenKeys.contains(key) {
                seenKeys.insert(key)
                keyOrder.append(key)
            }
        }

        var out = "# \(tag)\n"
        out += keyOrder.map(csvCell).joined(separator: ",") + "\n"
        for record in records {
            var valueByKey: [String: String] = [:]
            for (key, value) in record.fields { valueByKey[key] = value }
            let row = keyOrder.map { csvCell(valueByKey[$0] ?? "") }
            out += row.joined(separator: ",") + "\n"
        }
        return out
    }

    /// RFC-4180 quoting: wrap in quotes and double any internal quote if the
    /// cell contains a comma, a quote, or a newline.
    private static func csvCell(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return s
    }

    private static func headerComment(
        _ h: IntermediateRepresentation.Header,
        preset: LLMPreset,
        includesSecrets: Bool
    ) -> String {
        var out = "# UniFi Backup Export (CSV)\n"
        if let note = h.partNote { out += "# \(note)\n" }
        if includesSecrets {
            out += "# WARNING: This export INCLUDES secrets (WPA keys, admin hashes, RADIUS shared secrets, TOTP). Do not share.\n"
        }
        out += "# producedBy: \(h.producedBy)\n"
        out += "# targetModel: \(preset.displayName)\n"
        if let v = h.version { out += "# version: \(v)\n" }
        if let f = h.format { out += "# format: \(f)\n" }
        if let t = h.timestamp {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            out += "# timestamp: \(fmt.string(from: t))\n"
        }
        out += "# selectionCount: \(h.selectionCount)\n"
        out += "# redacted: \(h.redacted)\n"
        return out
    }
}
