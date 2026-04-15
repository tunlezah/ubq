import Foundation
import UniFiBSON
import UniFiModel
import Redaction

/// Serialisation format for an export.
public enum ExportFormat: String, Hashable, Sendable, CaseIterable, Codable {
    case text
    case json
    case markdown

    public var displayName: String {
        switch self {
        case .text: "Plain text"
        case .json: "JSON"
        case .markdown: "Markdown"
        }
    }

    public var fileExtension: String {
        switch self {
        case .text: "txt"
        case .json: "json"
        case .markdown: "md"
        }
    }
}

/// Target LLM, which biases structural choices and token-budget hints.
public enum LLMPreset: String, Hashable, Sendable, CaseIterable, Codable {
    case claude
    case gpt
    case gemini
    case localModel

    public var displayName: String {
        switch self {
        case .claude: "Claude (Anthropic)"
        case .gpt: "GPT (OpenAI)"
        case .gemini: "Gemini (Google)"
        case .localModel: "Local (Llama / Mistral / Qwen)"
        }
    }

    /// Approximate target character budget per export slice. Conservative; the
    /// UI displays the projected character count and the user can still grow
    /// it. Rule-of-thumb 4 chars/token.
    public var targetCharacterBudget: Int {
        switch self {
        case .claude: 240_000       // ~60k tokens, within Claude's context
        case .gpt: 320_000          // ~80k tokens
        case .gemini: 800_000       // ~200k tokens
        case .localModel: 24_000    // ~6k tokens, tight local windows
        }
    }

    /// Whether the Markdown exporter should wrap structural sections in
    /// XML-ish tags (`<site>`, `<device>`) — Anthropic prefers this.
    public var usesXMLSections: Bool {
        self == .claude
    }
}

/// The user's selection of tree nodes to export, plus runtime options.
public struct ExportRequest: Sendable {
    public var nodes: [TreeNode]
    public var format: ExportFormat
    public var preset: LLMPreset
    public var includeSecrets: Bool
    public var identity: Identity?
    public var filename: String?

    public init(
        nodes: [TreeNode],
        format: ExportFormat,
        preset: LLMPreset,
        includeSecrets: Bool,
        identity: Identity? = nil,
        filename: String? = nil
    ) {
        self.nodes = nodes
        self.format = format
        self.preset = preset
        self.includeSecrets = includeSecrets
        self.identity = identity
        self.filename = filename
    }
}

/// Front door for serialising a selection. Dispatches to a per-format writer
/// sharing a common intermediate representation (IR).
public enum Exporter {
    public static func export(_ request: ExportRequest) -> String {
        let ir = IntermediateRepresentation.from(
            request.nodes,
            identity: request.identity,
            redact: !request.includeSecrets
        )
        switch request.format {
        case .text:
            return TextExporter.render(ir, preset: request.preset, includesSecrets: request.includeSecrets)
        case .json:
            return JSONExporter.render(ir, preset: request.preset, includesSecrets: request.includeSecrets)
        case .markdown:
            return MarkdownExporter.render(ir, preset: request.preset, includesSecrets: request.includeSecrets)
        }
    }

    public static func suggestedFilename(for request: ExportRequest) -> String {
        if let base = request.filename, !base.isEmpty {
            return "\(base).\(request.format.fileExtension)"
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate]
        let stamp = iso.string(from: Date())
        let versionSegment: String = {
            guard let v = request.identity?.version else { return "" }
            return "-v\(v)"
        }()
        let secretSegment = request.includeSecrets ? "-INCLUDES-SECRETS" : ""
        return "unifi-backup-\(stamp)\(versionSegment)\(secretSegment).\(request.format.fileExtension)"
    }
}
