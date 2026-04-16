import Foundation

enum TextExporter {
    static func render(
        _ ir: IntermediateRepresentation,
        preset: LLMPreset,
        includesSecrets: Bool
    ) -> String {
        var out = ""
        out += banner(header: ir.header, preset: preset, includesSecrets: includesSecrets)
        out += "\n"
        for section in ir.sections {
            out += "─────────────────────────────────────────────────────────────\n"
            out += "\(section.tag.uppercased()): \(section.title)\n"
            out += "─────────────────────────────────────────────────────────────\n"
            for (k, v) in section.fields {
                out += "  \(k): \(v)\n"
            }
            out += "\n"
        }
        out += truncationNote(producedChars: out.count, preset: preset)
        return out
    }

    private static func banner(
        header ir: IntermediateRepresentation.Header,
        preset: LLMPreset,
        includesSecrets: Bool
    ) -> String {
        var out = "UNIFI BACKUP EXPORT\n"
        out += "===================\n"
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

    private static func truncationNote(producedChars: Int, preset: LLMPreset) -> String {
        if producedChars > preset.targetCharacterBudget {
            return "\n[note] This export is ~\(producedChars) characters, exceeding the suggested budget for \(preset.displayName) (~\(preset.targetCharacterBudget)). Consider splitting.\n"
        }
        return ""
    }
}
