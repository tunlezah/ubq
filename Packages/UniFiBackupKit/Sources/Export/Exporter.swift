import Foundation
import UniFiBSON
import UniFiModel
import Redaction

/// Serialisation format for an export.
public enum ExportFormat: String, Hashable, Sendable, CaseIterable, Codable {
    case text
    case json
    case markdown
    case csv

    public var displayName: String {
        switch self {
        case .text: "Plain text"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .csv: "CSV"
        }
    }

    public var fileExtension: String {
        switch self {
        case .text: "txt"
        case .json: "json"
        case .markdown: "md"
        case .csv: "csv"
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
    ///
    /// Refreshed August 2026 against effective (not headline-advertised)
    /// context — see ROADMAP.md §6. These are just the defaults: a caller
    /// that wants a user-edited value should set `ExportRequest.budgetOverride`
    /// rather than mutate this table, since the models will move again before
    /// the next refresh.
    public var targetCharacterBudget: Int {
        switch self {
        case .claude: 1_600_000     // ~400k tokens, effective window of a ~1M-token-class model
        case .gpt: 1_000_000        // ~256k tokens
        case .gemini: 1_600_000     // ~400k tokens
        case .localModel: 400_000   // ~100k tokens, realistic local-model window
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
    /// User-edited character budget, overriding `preset.targetCharacterBudget`
    /// when present. `nil` (the default) keeps the preset's built-in default.
    public var budgetOverride: Int?

    public init(
        nodes: [TreeNode],
        format: ExportFormat,
        preset: LLMPreset,
        includeSecrets: Bool,
        identity: Identity? = nil,
        filename: String? = nil,
        budgetOverride: Int? = nil
    ) {
        self.nodes = nodes
        self.format = format
        self.preset = preset
        self.includeSecrets = includeSecrets
        self.identity = identity
        self.filename = filename
        self.budgetOverride = budgetOverride
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
        let budget = effectiveBudget(for: request)
        return render(ir: ir, request: request, budget: budget)
    }

    /// Renders the same selection as a series of standalone documents, each
    /// under the effective character budget where that's achievable at
    /// top-level-section granularity. Sections are partitioned greedily, in
    /// selection order, so this returns as few slices as possible; a single
    /// small selection returns exactly one element (equivalent to `export`,
    /// modulo the "part i of n" note that's added only once there's more than
    /// one slice).
    public static func exportSlices(_ request: ExportRequest) -> [String] {
        let ir = IntermediateRepresentation.from(
            request.nodes,
            identity: request.identity,
            redact: !request.includeSecrets
        )
        let budget = effectiveBudget(for: request)

        var partitions: [[IntermediateRepresentation.Section]] = []
        var current: [IntermediateRepresentation.Section] = []
        var currentSize = 0
        for section in ir.sections {
            let sectionSize = render(
                ir: IntermediateRepresentation(header: ir.header, sections: [section]),
                request: request,
                budget: budget
            ).count
            if !current.isEmpty && currentSize + sectionSize > budget {
                partitions.append(current)
                current = []
                currentSize = 0
            }
            current.append(section)
            currentSize += sectionSize
        }
        partitions.append(current)

        let total = partitions.count
        return partitions.enumerated().map { index, sections in
            let sliceHeader = total > 1
                ? withPartNote(ir.header, note: "part \(index + 1) of \(total)")
                : ir.header
            return render(
                ir: IntermediateRepresentation(header: sliceHeader, sections: sections),
                request: request,
                budget: budget
            )
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

    // MARK: - Shared helpers

    private static func effectiveBudget(for request: ExportRequest) -> Int {
        max(1, request.budgetOverride ?? request.preset.targetCharacterBudget)
    }

    private static func render(
        ir: IntermediateRepresentation,
        request: ExportRequest,
        budget: Int
    ) -> String {
        switch request.format {
        case .text:
            return TextExporter.render(ir, preset: request.preset, budget: budget, includesSecrets: request.includeSecrets)
        case .json:
            return JSONExporter.render(ir, preset: request.preset, budget: budget, includesSecrets: request.includeSecrets)
        case .markdown:
            return MarkdownExporter.render(ir, preset: request.preset, budget: budget, includesSecrets: request.includeSecrets)
        case .csv:
            return CSVExporter.render(ir, preset: request.preset, budget: budget, includesSecrets: request.includeSecrets)
        }
    }

    private static func withPartNote(
        _ header: IntermediateRepresentation.Header,
        note: String
    ) -> IntermediateRepresentation.Header {
        IntermediateRepresentation.Header(
            version: header.version,
            format: header.format,
            timestamp: header.timestamp,
            origin: header.origin,
            kind: header.kind,
            redacted: header.redacted,
            selectionCount: header.selectionCount,
            producedBy: header.producedBy,
            partNote: note
        )
    }
}
