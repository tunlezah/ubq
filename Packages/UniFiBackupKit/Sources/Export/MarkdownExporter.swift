import Foundation

enum MarkdownExporter {
    static func render(
        _ ir: IntermediateRepresentation,
        preset: LLMPreset,
        budget: Int,
        includesSecrets: Bool
    ) -> String {
        var out = ""
        out += header(ir.header, preset: preset, includesSecrets: includesSecrets)
        out += "\n"
        let useXML = preset.usesXMLSections
        for section in ir.sections {
            out += render(section: section, useXML: useXML, depth: 2)
        }
        if out.count > budget {
            out += "\n> ⚠ This export is ~\(out.count) characters, exceeding the suggested budget for \(preset.displayName) (~\(budget)). Consider splitting.\n"
        }
        return out
    }

    /// Renders one section and, recursively, its nested children. `depth`
    /// only matters for non-XML presets: each nesting level goes one heading
    /// level deeper (`##`, `###`, …, capped at `######`). The XML style
    /// nests naturally via `<tag>…</tag>` wrapping instead.
    private static func render(
        section: IntermediateRepresentation.Section,
        useXML: Bool,
        depth: Int
    ) -> String {
        var out = ""
        if useXML {
            out += "<\(section.tag) title=\"\(escape(section.title))\">\n\n"
        } else {
            let level = String(repeating: "#", count: min(max(depth, 1), 6))
            out += "\(level) \(titleCase(section.tag)): \(section.title)\n\n"
        }
        if !section.fields.isEmpty {
            out += "| Key | Value |\n|---|---|\n"
            for (k, v) in section.fields {
                out += "| \(k) | \(escapeTableCell(v)) |\n"
            }
            out += "\n"
        }
        if let raw = section.rawJSON {
            out += "```json\n\(raw)\n```\n\n"
        }
        for child in section.children {
            out += render(section: child, useXML: useXML, depth: depth + 1)
        }
        if useXML {
            out += "</\(section.tag)>\n\n"
        }
        return out
    }

    private static func header(
        _ h: IntermediateRepresentation.Header,
        preset: LLMPreset,
        includesSecrets: Bool
    ) -> String {
        var out = "# UniFi Backup Export\n\n"
        if let note = h.partNote {
            out += "> \(escape(note))\n\n"
        }
        if includesSecrets {
            out += "> ⚠ **This export INCLUDES secrets** (WPA keys, admin hashes, RADIUS shared secrets, TOTP). Do not share.\n\n"
        }
        out += "| Field | Value |\n|---|---|\n"
        out += "| Produced by | \(h.producedBy) |\n"
        out += "| Target model | \(preset.displayName) |\n"
        if let v = h.version { out += "| Controller version | \(v) |\n" }
        if let f = h.format { out += "| Backup format | \(f) |\n" }
        if let t = h.timestamp {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            out += "| Backup timestamp | \(f.string(from: t)) |\n"
        }
        if let k = h.kind { out += "| Backup kind | \(k.rawValue) |\n" }
        if let o = h.origin { out += "| Origin | \(o.rawValue) |\n" }
        out += "| Selection count | \(h.selectionCount) |\n"
        out += "| Redacted | \(h.redacted) |\n"
        return out
    }

    private static func titleCase(_ s: String) -> String {
        s.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeTableCell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
         .replacingOccurrences(of: "\n", with: " ")
    }
}
