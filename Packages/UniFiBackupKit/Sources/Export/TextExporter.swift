import Foundation

enum TextExporter {
    static func render(
        _ ir: IntermediateRepresentation,
        preset: LLMPreset,
        budget: Int,
        includesSecrets: Bool
    ) -> String {
        var out = ""
        out += banner(header: ir.header, preset: preset, includesSecrets: includesSecrets)
        out += "\n"
        for section in ir.sections {
            out += render(section: section, depth: 0)
        }
        out += truncationNote(producedChars: out.count, budget: budget, preset: preset)
        return out
    }

    /// Renders one section and, recursively, its nested children, indenting
    /// two spaces per nesting level.
    private static func render(
        section: IntermediateRepresentation.Section,
        depth: Int
    ) -> String {
        let indent = String(repeating: "  ", count: depth)
        var out = ""
        out += "\(indent)─────────────────────────────────────────────────────────────\n"
        out += "\(indent)\(section.tag.uppercased()): \(section.title)\n"
        out += "\(indent)─────────────────────────────────────────────────────────────\n"
        for (k, v) in section.fields {
            out += "\(indent)  \(k): \(v)\n"
        }
        out += "\n"
        for child in section.children {
            out += render(section: child, depth: depth + 1)
        }
        return out
    }

    private static func banner(
        header ir: IntermediateRepresentation.Header,
        preset: LLMPreset,
        includesSecrets: Bool
    ) -> String {
        var out = "UNIFI BACKUP EXPORT\n"
        out += "===================\n"
        if let note = ir.partNote { out += "Part               : \(note)\n" }
        if let v = ir.version { out += "Controller version : \(v)\n" }
        if let f = ir.format { out += "Backup format      : \(f)\n" }
        if let t = ir.timestamp {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            out += "Backup timestamp   : \(f.string(from: t))\n"
        }
        if let k = ir.kind { out += "Backup kind        : \(k.rawValue)\n" }
        if let o = ir.origin { out += "Origin             : \(o.rawValue)\n" }
        out += "Selection count    : \(ir.selectionCount)\n"
        out += "Target model       : \(preset.displayName)\n"
        out += "Redacted           : \(ir.redacted)\n"
        if includesSecrets {
            out += "\n⚠  This export INCLUDES secrets (WPA keys, admin hashes, RADIUS,\n"
            out += "   TOTP). Do not share.\n"
        }
        return out
    }

    private static func truncationNote(producedChars: Int, budget: Int, preset: LLMPreset) -> String {
        if producedChars > budget {
            return "\n[note] This export is ~\(producedChars) characters, exceeding the suggested budget for \(preset.displayName) (~\(budget)). Consider splitting.\n"
        }
        return ""
    }
}
