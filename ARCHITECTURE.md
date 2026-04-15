# Architecture

Reference document for module layout and responsibilities. All design decisions
below follow from findings in `RESEARCH.md` and `FORMAT.md`. Non-obvious
choices and trade-offs live in `DECISIONS.md` as ADRs.

## Guiding principles

1. **Parser core is UI-free.** A pure Swift package (`UniFiBackupKit`) that
   can be consumed headlessly by a CLI, by tests, or by another app with no
   AppKit/SwiftUI dependency.
2. **No silent failures.** Every parse error is captured in a structured
   `Diagnostic` and surfaced in the UI — one weird collection does not break
   the whole file.
3. **Stream first, materialise lazily.** BSON streams are read via a cursor
   that yields one document at a time; large `ace_stat` collections are
   behind an explicit opt-in.
4. **Root-cause, not bypass.** When a ZIP is malformed, we repair
   (scan-forward on `PK\x03\x04`); we never `try?`-and-hope.
5. **Minimal surface.** No feature flags for hypothetical futures. If a
   feature isn't in Phase 4 scope, it doesn't exist yet.

## Top-level layout

```
UnifiBackupInspector.xcodeproj/
├─ App/                              # SwiftUI macOS app
│  ├─ UnifiBackupInspectorApp.swift  # @main, AppKit lifecycle bridge
│  ├─ Scene/
│  │   ├─ InspectorWindow.swift      # NavigationSplitView host
│  │   ├─ OpenDocumentController.swift
│  │   └─ RecentFilesStore.swift
│  ├─ Views/
│  │   ├─ SidebarView.swift          # category source list
│  │   ├─ TreeOutlineView.swift      # middle pane, hierarchical outline
│  │   ├─ DetailInspectorView.swift  # right pane, key-value + raw
│  │   ├─ ExportSheet.swift          # format picker, target model picker
│  │   ├─ SearchField.swift          # top-chrome live search
│  │   ├─ DiagnosticsPanel.swift     # parse-error surface
│  │   └─ VersionBadge.swift
│  ├─ Models/                        # UI-only view models
│  │   ├─ TreeNode.swift
│  │   ├─ SelectionState.swift
│  │   └─ ExportPreset.swift
│  ├─ Theme/
│  │   ├─ GlassMaterial.swift        # macOS 26 Liquid Glass + fallback
│  │   └─ SemanticColors.swift
│  └─ Resources/
│      └─ Assets.xcassets/
│
└─ Packages/
   └─ UniFiBackupKit/                # Local Swift package, no UI deps
      ├─ Package.swift
      ├─ Sources/
      │   ├─ UniFiBackupKit/         # umbrella target
      │   │   ├─ Backup.swift        # public façade
      │   │   ├─ BackupLoader.swift  # orchestrates decrypt → unzip → parse
      │   │   └─ Identity.swift      # version/format/timestamp metadata
      │   ├─ UnfCrypto/              # AES-128-CBC NoPadding over CommonCrypto
      │   │   └─ UnfCipher.swift
      │   ├─ TolerantZip/            # streaming ZIP reader
      │   │   ├─ TolerantZipReader.swift
      │   │   └─ ZipLocalHeader.swift
      │   ├─ Gunzip/                 # Compression.framework wrapper
      │   │   └─ Gunzip.swift
      │   ├─ BSON/                   # minimal read-only BSON decoder
      │   │   ├─ BSONDocument.swift
      │   │   ├─ BSONValue.swift
      │   │   ├─ BSONReader.swift    # cursor-based, no allocations per doc
      │   │   └─ ObjectId.swift
      │   ├─ BackupStream/           # the { collection: "..." } stream walker
      │   │   └─ CollectionStream.swift
      │   ├─ Model/                  # strongly-typed domain
      │   │   ├─ Site.swift
      │   │   ├─ Device.swift
      │   │   ├─ Client.swift
      │   │   ├─ Wlan.swift
      │   │   ├─ Network.swift
      │   │   ├─ Firewall.swift
      │   │   ├─ PortProfile.swift
      │   │   ├─ Admin.swift
      │   │   ├─ SystemProperties.swift
      │   │   └─ Tree.swift          # uniform navigable tree contract
      │   ├─ Diagnostics/            # structured error surface
      │   │   └─ Diagnostic.swift
      │   ├─ Redaction/              # secret detection + masking
      │   │   └─ SecretVault.swift
      │   └─ Export/                 # serialisers for export layer
      │       ├─ Exporter.swift      # public entry
      │       ├─ TextExporter.swift
      │       ├─ JSONExporter.swift
      │       ├─ MarkdownExporter.swift
      │       └─ LLMPreset.swift     # Claude / GPT / Gemini / Local bias
      └─ Tests/
          ├─ UnfCryptoTests/
          ├─ TolerantZipTests/
          ├─ BSONTests/
          ├─ CollectionStreamTests/
          ├─ ModelMappingTests/
          ├─ RedactionTests/
          ├─ ExportTests/
          └─ Fixtures/
              ├─ Synthetic/          # committed tiny hand-crafted fixtures
              └─ CorpusSmokeTests/   # optional, runs against fixtures/ if present
```

## Data flow

```
.unf URL
   │
   ▼
BackupLoader.open(url)
   │
   │ 1. UnfCipher.decrypt(_:)          (throws .truncatedAtBlockBoundary,
   │                                           .notZip, .decryptFailed)
   ▼
ZIP plaintext Data
   │
   │ 2. TolerantZipReader.read(_:)     (throws .unreadable,
   │                                    emits Diagnostic for each recovered entry)
   ▼
[String: Data] (entry name → bytes)
   │
   │ 3. Identity.parse(entries:)       (version, format, timestamp,
   │                                    origin heuristic from system.properties)
   │ 4. Gunzip + CollectionStream      (yields (collectionName, BSONDocument))
   ▼
Backup {
    identity: Identity
    sites: [Site]
    devices: [Device] ...
    unknownCollections: [String: [BSONDocument]]
    diagnostics: [Diagnostic]
    warnings: [Warning]            // truncated db_stat.gz, site-export, ...
}
   │
   ▼
UI: SidebarView → TreeOutlineView → DetailInspectorView
   │
   ▼
Exporter(backup).export(selection: TreeSelection,
                        format: .text / .json / .markdown,
                        preset: .claude / .gpt / .gemini / .localLLM,
                        redactSecrets: Bool)
```

## Error model

Three severities, all non-throwing from the UI's perspective:

| Severity | What it means | Example |
|---|---|---|
| `.info` | Surface as neutral note | "Settings-only export: no `db_stat.gz` present" |
| `.warning` | Parser continued; user should know | "Truncated `db_stat.gz` at offset 1,234,567 — statistics incomplete, config is fine" |
| `.error` | One subtree failed to parse; rest of backup is valid | "Collection `event_archive`: BSON length overrun at offset 12,345 — collection skipped" |

`Diagnostic` carries: severity, human message, byte offset (when applicable),
collection name (when applicable), and a machine-readable `code`. The UI
shows a badge on each affected category and a dedicated diagnostics panel.

**Fatal** (cannot open file at all): `NotUnfError`, `DecryptFailedError`,
`NotZipError`. These surface as a full-window error state with copyable
diagnostics; the app does not crash.

## Version detection

Strategy is ensemble, not single-signal:

1. Read `version` entry (trim BOM / whitespace / CRLF).
2. Read `format` entry if present.
3. Read `system.properties`; extract `unifi.version`, `db.mongo.uri` host
   (`localhost` vs a LAN address hint), install path (`/data/unifi/` →
   Cloud Key/UDM; `/var/lib/unifi/` → self-hosted Linux; Windows path →
   self-hosted Windows).
4. Inspect collection presence: missing `admin` + `account` → Site Export.
5. Emit `Identity { version, format?, timestamp, origin, kind }` where
   `kind ∈ { .full, .siteExport, .settingsOnly }`.

**No behaviour gating on `format`.** It is metadata only. Parsing adapts to
observed shape.

## Memory strategy

- The ciphertext is loaded whole (`.unf` files are rarely > 200 MB in
  practice; decryption is in-place).
- The plaintext ZIP is kept as `Data` — tolerant ZIP reader indexes entries
  without copying bytes; entry reads slice the backing buffer.
- `db.gz` is gunzipped into a single `Data`. `db_stat.gz` is **not** gunzipped
  until the user opts in from the UI ("Load statistics…" button).
- `CollectionStream` iterates the gunzipped buffer with an `Int` cursor, one
  BSON document at a time. Documents are parsed into `BSONDocument` which
  stores values as `[(String, BSONValue)]` (preserves order).
- For the largest stat collections (`stat_5minutes`, `stat_archive`), the
  stream is exposed as an `AsyncSequence` so the UI can render a row-count
  estimate and let the user cancel before loading everything.

## Redaction

- `SecretVault` knows the **field-name registry** of secrets:
  `x_passphrase`, `x_password`, `x_shadow`, `secret`, `backup_codes`,
  `radius.secret`, `api_key`, `cloud_access_key`, `cloud_secret_key`,
  `sso_password`, `hotspotop.x_password`, `tunnel.x_key`, `verification.secret`,
  and a handful of nested paths under `setting`.
- Redaction is **applied on export**, not on parse — in-memory model keeps
  real values so the UI can reveal on toggle.
- Default: redaction ON. UI "Include secrets" toggle, when enabled, paints
  the export sheet with a red glowing accent and red helper text
  ("This export will contain secrets — do not share"), with no extra
  confirmation click.

## LLM export presets

User picks a target model; preset shapes the output:

| Preset | Format bias | Token budget / slice | Notes |
|---|---|---|---|
| Claude | Markdown with fenced code blocks, XML-tagged sections (`<site>`, `<device>`) for structural clarity | 100k context → target ≤ 60k tokens/slice | Anthropic prefers XML-delimited context |
| GPT | Markdown with code fences, explicit headings, numbered lists | 128k context → target ≤ 80k tokens/slice | OpenAI's "chat" style |
| Gemini | Markdown, deeper nesting tolerated, richer tables | 1M+ context → target ≤ 200k tokens/slice | Gemini handles very long single-shot inputs |
| Local (Llama/Mistral-class) | Compact text, minimal repetition, prefers JSON blobs over prose | Typically 8k–32k context → target ≤ 6k tokens/slice | Assume tight window |

A shared core renders tree-selection into a language-agnostic intermediate
(label + value + kind) and each preset formats that IR.

## Tree model

`UniFiBackupKit.Tree` defines the uniform navigable tree that the UI
consumes. Shape:

```swift
public enum TreeNode: Identifiable, Hashable {
    case category(CategoryNode)     // top-level: "Sites", "Devices", "WLANs" …
    case site(SiteNode)
    case device(DeviceNode)
    case wlan(WlanNode)
    case network(NetworkNode)
    case firewallGroup(FirewallGroupNode)
    case rule(RuleNode)
    case client(ClientNode)
    case admin(AdminNode)
    case collection(OpaqueCollectionNode)   // unknown-to-us collections
    case record(OpaqueRecordNode)
    // ... see Sources/UniFiBackupKit/Model/Tree.swift
}
```

Where data is inherently hierarchical, the tree reflects it:
- `Sites` → `<site>` → `Devices` / `WLANs` / `Networks` / `Firewall` / …
- `Devices` → `<device>` → `Ports` / `Radios`
- `WLANs` → `<wlan group>` → `<wlan>`
- `Firewall` → `Rules` / `Groups` / `Port Forwards`

Opaque collections (never-seen before) render as a generic two-level
`Collection → Records` tree with every document shown as a key-value
drill-down. The app degrades gracefully on schema evolution.

## Concurrency

- `BackupLoader.open(url:)` is `async throws` and runs on a background
  actor. UI observes progress via an `AsyncStream<LoadEvent>`.
- `UniFiBackupKit` targets Swift 6 strict concurrency. All public types
  are `Sendable`; model types are immutable structs with value semantics.
- No `@MainActor` in the package. The UI layer pins observable objects to
  `@MainActor` at the binding site.

## Security posture

- Zero network calls. No analytics. No telemetry. No crash reporting SDKs.
- Zero bundled third-party binaries.
- Reads are read-only; the app never writes back into `.unf`.
- Decrypted plaintext lives only in memory; no temp files unless the user
  opts into the "Extract to folder…" debug feature (off by default, Phase 4
  stretch goal).
- `com.apple.security.app-sandbox = true`, with only user-selected-file
  read/write entitlements.
- Redaction default on. Red-glow visual emphasis when secrets would be
  included.

## Testing

- **Unit**: `UnfCryptoTests` (roundtrip decrypt/encrypt with known plaintext),
  `TolerantZipTests` (happy path + malformed EOCD + data descriptors),
  `BSONTests` (every supported type code + malformed-length rejection),
  `CollectionStreamTests` (marker handling + unknown-collection tolerance),
  `ModelMappingTests` (synthetic fixtures → strongly-typed model),
  `RedactionTests` (every secret path redacted),
  `ExportTests` (golden outputs per preset).
- **Synthetic fixtures**: `Fixtures/Synthetic/` — hand-authored tiny
  `.unf`-equivalent blobs built programmatically at test setup, committed
  as Swift source (not binary) so tests are transparent and diff-able.
- **Corpus smoke**: optional `CorpusSmokeTests` runs `BackupLoader.open(_:)`
  against every file in `fixtures/` and asserts no thrown errors + at least
  one recognised site. Skipped in CI by default (fixtures are gitignored).
- CI runs the unit suite. Corpus run is opt-in via env flag.

## Non-goals (explicit)

- Restoring backups. The tool is read-only.
- Editing backups. Round-tripping is a Phase 2+ consideration, not v1.
- Parsing `.unifi` (UniFi OS superset) — detect-and-decline only.
- Parsing `.ubv` (Protect video).
- Running or embedding MongoDB.
- Cloud sync, account login, SSO.
- Windows or Linux builds. macOS 15+ only (ideally macOS 26 for Liquid Glass).
