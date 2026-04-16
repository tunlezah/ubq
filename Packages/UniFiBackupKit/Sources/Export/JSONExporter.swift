import Foundation

enum JSONExporter {
    static func render(
        _ ir: IntermediateRepresentation,
        preset: LLMPreset,
        includesSecrets: Bool
    ) -> String {
        var root: [String: Any] = [:]
        root["header"] = header(ir.header, preset: preset, includesSecrets: includesSecrets)
        root["sections"] = ir.sections.map { section -> [String: Any] in
            var obj: [String: Any] = [
                "kind": section.tag,
                "title": section.title,
                "fields": section.fields.map { pair in ["key": pair.0, "value": pair.1] },
            ]
            if let raw = section.rawJSON,
               let rawData = raw.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: rawData, options: []) {
                obj["raw"] = parsed
            }
            return obj
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func header(
        _ h: IntermediateRepresentation.Header,
        preset: LLMPreset,
        includesSecrets: Bool
    ) -> [String: Any] {
        var out: [String: Any] = [
            "producedBy": h.producedBy,
            "targetModel": preset.rawValue,
            "selectionCount": h.selectionCount,
            "redacted": h.redacted,
            "includesSecretsWarning": includesSecrets,
        ]
        if let v = h.version { out["version"] = v }
        if let f = h.format { out["format"] = f }
        if let t = h.timestamp {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            out["timestamp"] = fmt.string(from: t)
        }
        if let k = h.kind { out["kind"] = k.rawValue }
        if let o = h.origin { out["origin"] = o.rawValue }
        return out
    }
}
