# Decisions (ADR log)

Architectural Decision Records for non-obvious choices. Append-only.

## Format

Each ADR has: **context**, **decision**, **alternatives considered**,
**consequences**. Keep them short — if an ADR gets long, split it.

---

## ADR-001: Use CommonCrypto, not CryptoKit, for AES-128-CBC

**Context.** The `.unf` format is AES-128-CBC with no padding. Apple's modern
cryptography module, `CryptoKit`, only exposes authenticated ciphers (AES-GCM,
ChaChaPoly) and high-level key agreement — not raw CBC.

**Decision.** Use `CommonCrypto` via a thin Swift wrapper (`UnfCipher`).

**Alternatives considered.**
- `CryptoSwift` — adds a third-party dep for what is effectively 15 lines
  of `CCCrypt`. Rejected (see ADR-003).
- Writing AES by hand — rejected. Crypto primitives from the system library.
- `Security.framework` `SecTransform` — deprecated for new code.

**Consequences.** Requires an ObjC bridging header or `@preconcurrency
import CommonCrypto`. `CCCrypt` is thread-safe; `UnfCipher` is a pure
function. No state. Trivial to test.

---

## ADR-002: No third-party Swift BSON dependency

**Context.** Three candidate BSON libraries exist: `mongodb/swift-bson`
(abandoned 2022), `orlandos-nl/BSON` (maintained, pulls in SwiftNIO),
`tayloraswift/swift-bson` (active, Foundation-free, Swift 6 only). UniFi
uses only ~11 BSON type codes in configuration data.

**Decision.** Hand-roll a minimal read-only BSON decoder (~400-600 LOC) in
the `BSON` target of `UniFiBackupKit`.

**Alternatives considered.**
- Adopt `tayloraswift/swift-bson`. Attractive: active, minimal, Swift 6.
  Rejected because: our needs are narrower (we parse a stream, not random-
  access documents), we want zero SPM deps on the parser core, and
  controlling the decoder lets us implement streaming with zero per-doc
  allocations — critical for 500 MB stat collections.
- Adopt `orlandos-nl/BSON`. Rejected: transitive SwiftNIO pull-in is heavy
  for a macOS GUI app.
- Adopt `mongodb/swift-bson`. Rejected: abandoned, Swift 6 concurrency
  warnings, poor long-term fit.

**Consequences.** +~500 LOC to maintain, but it's bounded, testable in
isolation, and gives us exact control over streaming and ordering
preservation. If a future BSON library becomes a clear win, swap is local
to one target.

---

## ADR-003: Zero third-party Swift Package dependencies in v1

**Context.** ZIP parsing is the most likely candidate for a dep
(`ZIPFoundation`). Tempting to pull it in for the "malformed ZIP" quirk.

**Decision.** Write a tolerant streaming ZIP reader in
`TolerantZip` target. No external dependencies.

**Alternatives considered.**
- `ZIPFoundation` — handles data descriptors but has its own EOCD
  assumptions that fail on genuinely truncated `.unf` ZIPs (Darknetzz
  had to bypass similar limits).
- `minizip-ng` via SwiftPM Clang module — C dep, adds build complexity.

**Consequences.** +~300 LOC, but the reader is tuned exactly for the
UniFi quirks. We implement: local-file-header scan-forward, DEFLATE via
`Compression.framework`, streaming data descriptors (bit 3),
UTF-8/CP-437 filename handling. Reconsider if this grows past ~600 LOC or
if we need write support.

---

## ADR-004: Parse-all-eagerly for `ace`; opt-in for `ace_stat`

**Context.** `ace` (configuration) is typically < 10 MB decompressed and the
user wants to browse everything on open. `ace_stat` can be hundreds of MB
and loading it by default is a foot-gun (OOM, slow open).

**Decision.** On open, eagerly decompress + parse `db.gz` (`ace`).
`db_stat.gz` stays gzipped; the UI exposes a "Load statistics" button that
decompresses and streams into the tree.

**Consequences.** Fast open on any file. Clear affordance for the rare
user who wants stats. The tree has a disabled-but-visible "Statistics"
category until loaded, with size-preview from the ZIP entry header.

---

## ADR-005: Tree model with strongly-typed leaves + opaque fallback

**Context.** UniFi adds and renames collections across versions. A rigid
schema would break on every UniFi release. A fully generic "dict of dicts"
tree would lose all the value of a browseable UI.

**Decision.** Strongly-type the collections we care about for v1 (`site`,
`device`, `user`, `wlanconf`, `wlangroup`, `networkconf`, `portconf`,
`portforward`, `firewallrule`, `firewallgroup`, `routing`, `dpiapp`,
`dpigroup`, `admin`, `account`, `privilege`, `radiusprofile`,
`hotspotop`, `scheduletask`, `setting`, `tag`, `broadcastgroup`,
`voucher`, `guest`, `apgroup`). Any unrecognised collection surfaces as
an `OpaqueCollectionNode` with a generic Collection → Records → Fields
drill-down.

**Consequences.** Graceful degradation on schema evolution. User gets the
tidy view for known collections and still sees data for unknown ones.
Adding a new strongly-typed collection later is additive.

---

## ADR-006: Redaction is a render-time concern, not a parse-time one

**Context.** We need to reveal secrets to the user (they own the data) but
redact on export. Two options: wipe secrets at parse time and keep a
separate "real values" cache, or keep real values in memory and redact on
serialise.

**Decision.** Keep real values in the in-memory model. Redaction happens
inside `Exporter` before bytes leave process boundary
(clipboard/save-panel/file-url).

**Consequences.** In-memory model is sensitive and must not be written to
logs / crash reports / pasteboards. `os_log` policy: private by default
for any value. No third-party crash reporter (reinforces ADR-007).

---

## ADR-007: No telemetry, no analytics, no network calls

**Context.** The data is sensitive (WPA keys, RADIUS secrets, admin
hashes). A single off-by-one in a crash reporter could leak secrets to
a third party.

**Decision.** Zero network calls from the app. No Sentry, no Firebase,
no Crashlytics. No auto-update check. Strip `com.apple.security.network.*`
entitlements. App sandboxed.

**Consequences.** No remote diagnostics. Users report issues via GitHub.
This is a feature, not a limitation, for the target audience.

---

## ADR-008: Four LLM export presets (Claude / GPT / Gemini / Local)

**Context.** User request: export bias should match the target model.

**Decision.** Offer four presets. Shared IR → preset-specific renderer.
Default preset tracked in `AppStorage` but can be switched per-export.

**Preset choices.**
- **Claude** — Markdown with XML tags (`<site>`, `<device>`) around
  structural sections; Anthropic's prompt-engineering guidance favours
  this.
- **GPT** — Markdown with bold headings, code fences, numbered lists;
  OpenAI's chat style.
- **Gemini** — Markdown with deeper nested tables; Gemini tolerates
  richer structure.
- **Local** (Llama/Mistral/Qwen-class) — Compact, JSON-leaning, minimal
  prose, tight token budget; local models typically have 8k–32k windows.

**Consequences.** +1 UI control in the export sheet. The shared IR layer
means a fifth preset is ~1 day of work. If a new model family emerges,
we add a preset without touching the IR.

---

## ADR-009: Red-glow visual warning when "Include secrets" enabled — no modal

**Context.** User explicitly rejected a confirmation click. Needs visual
emphasis without friction.

**Decision.** When the "Include secrets" toggle is ON in the export sheet:
- The toggle itself shows a red glow (SwiftUI `.shadow(color: .red, …)` or
  `.overlay(Circle().stroke(.red))`).
- A helper line of red text appears beneath: "This export will contain
  secrets (WPA keys, admin hashes, RADIUS). Do not share this output."
- The export button background gains a subtle red tint via a
  `Material`-backed overlay.
- No modal, no confirmation click.

Accessibility: the helper text is announced by VoiceOver when the toggle
flips. Red is not the sole signal — an SF Symbol `exclamationmark.shield.fill`
is shown next to the toggle.

**Consequences.** The user can still do the dangerous thing in one click,
but the UI makes it unmissable. Matches the user's stated preference.

---

## ADR-010: macOS 15 minimum, macOS 26 features opt-in

**Context.** Liquid Glass materials are macOS 26 only. We want the modern
look but shouldn't exclude macOS 15 Sequoia users.

**Decision.** Deployment target macOS 15.0. Use `@available(macOS 26, *)`
blocks for Liquid Glass APIs with `.regularMaterial` / `.thinMaterial`
fallback. Build with Xcode 16+ / Swift 6.

**Consequences.** A user on macOS 15 sees translucent system materials;
a user on macOS 26 sees Liquid Glass. Same codebase. No feature gating
other than visual polish.

---

## ADR-011: Unsigned binary with right-click-Open docs; no Developer ID in v1

**Context.** CI runs unsigned for cost and simplicity. Gatekeeper blocks
unsigned apps from double-click launch.

**Decision.** Ship unsigned `.dmg`. Document in README:
1. Right-click → Open first time, OR
2. `xattr -d com.apple.quarantine /Applications/UnifiBackupInspector.app`.

Signing / notarisation is a post-v1 consideration; ADR to be added when
we go there.

**Consequences.** Power-user friction on first launch. Fine for target
audience (network admins). Documented prominently.

---

## ADR-012: `.unifi` superset — extract embedded `.unf` automatically

**Context.** UniFi OS "System Config Backup" files (`.unifi`) are a
superset wrapping a Network `.unf` plus UCore PostgreSQL tables plus
Protect/Access/Talk configs. Originally planned as out-of-scope (v2).

User requested v1 support. Research confirmed `.unifi` is a **plain
unencrypted ZIP** (starts with `PK\x03\x04`) containing an embedded
AES-encrypted `.unf` blob. The outer container is NOT AES-encrypted,
which is why zhangyoufu's tool fails (it applies AES from byte 0).

**Decision.** v1 detects `.unifi` by testing whether byte 0 is a ZIP
signature. If so: open as plain ZIP, locate the embedded `.unf` blob
(by extension, path, or trial-decrypt), decrypt it, and parse as
normal. UCore PostgreSQL tables and per-app configs are surfaced as
metadata diagnostics but not deeply parsed (v2 candidate).

**Alternatives considered.**
- Refuse `.unifi` entirely, document manual `.unf` extraction. Rejected:
  too much friction for UDM Pro / Dream Machine users, who are the
  majority of current deployments.
- Deep-parse the PostgreSQL dump. Deferred: requires pg_restore logic
  or custom-format parsing. The Network data inside the `.unf` covers
  the primary use case.

**Consequences.** UDM Pro / UDR / UCG-Ultra users can drop their
System Config Backup directly into the app without first extracting
the Network-only `.unf`. The identity bar shows a "UniFi OS" badge.
PostgreSQL data is not yet browseable — a follow-up for v2.

---

## ADR-013: Commit synthetic fixtures as Swift code, not binary blobs

**Context.** Unit tests need deterministic fixtures. Committing real
`.unf` files to git risks leaking private network data and pins the repo
to specific controller versions.

**Decision.** Synthetic fixtures are constructed programmatically in
Swift (hand-build BSON documents, wrap in gzip + ZIP + AES). Stored as
test code under `Tests/Fixtures/Synthetic/`.

**Consequences.** Fixtures are transparent and diff-able. Tests remain
fast. The one downside — synthetic fixtures don't cover every real-
world quirk — is addressed by the opt-in corpus smoke test that runs
against `fixtures/` (gitignored).

---

## ADR-014: SwiftPM local package for parser core, not a framework target

**Context.** The parser needs to be reusable headlessly.

**Decision.** `UniFiBackupKit/` is a local SwiftPM package referenced by
the Xcode project. Contains multiple targets (crypto, zip, bson, stream,
model, diagnostics, redaction, export). A separate executable target
(`ubi-cli`) can be added later that depends on the same package.

**Consequences.** Zero coupling to AppKit/SwiftUI. Can be tested with
`swift test` from the command line. CI doesn't need Xcode for unit
tests — though the full app build will, of course.
