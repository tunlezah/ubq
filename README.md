# UniFi Backup Inspector

A native macOS app for opening UniFi Network Controller `.unf` backup files,
browsing their contents in a structured tree, and exporting any slice as text,
JSON, or Markdown — shaped for pasting into an LLM.

* **Local-first.** No network calls. No telemetry. No crash reporting.
  Your WPA keys stay on your machine.
* **Reads every version.** UniFi Network Application v5.10 through v9.5.21+
  share one static AES-128-CBC key; a single parser covers them all.
* **Nothing to crash.** Malformed ZIP, truncated gzip, unknown collections —
  each surfaces as a structured diagnostic. The parser never crashes on
  bad input.
* **Selectively export for AI analysis.** Per-LLM presets (Claude, GPT,
  Gemini, local) bias Markdown/JSON/text output at export time.
* **Default-redacted.** PSKs, admin hashes, RADIUS secrets, TOTP secrets
  are redacted by default. Reveal-in-UI is one click; exporting with
  secrets shows an unmissable red warning banner.

## Screenshots

`// Paste captures of the three-pane NavigationSplitView, the export sheet,
// and the diagnostics view once the first build is published.`

See `DESIGN.md` for the full layout spec.

## Supported controller versions

| Controller | Status | Notes |
|---|---|---|
| UniFi Network Application v5.x — v9.x | ✅ full support | Static AES key unchanged; parser verified against public tools. |
| Legacy v3.x / v4.x | ⚠️ best-effort | Schema is older; some collections may surface as opaque. |
| UniFi OS `.unifi` console backup | ❌ out of scope (detected + labelled) | Wraps a `.unf` plus UCore PostgreSQL; handle the Network export separately (Settings → System → Advanced). |
| UniFi Protect `.ubv` | ❌ not a backup | Raw video files; we don't touch them. |

## Install

Grab the latest release from the
[Releases page](https://github.com/tunlezah/ubq/releases). Either artefact
works:

* `UnifiBackupInspector.dmg` — drag into `/Applications`.
* `UnifiBackupInspector.zip` — unzip and copy the `.app` to `/Applications`.

### First-launch (unsigned binary)

The build is **unsigned**. macOS Gatekeeper refuses unsigned apps by default.

**Right-click-Open (recommended):**

1. Drag `UnifiBackupInspector.app` into `/Applications`.
2. In Finder, **right-click** → **Open**. Confirm the dialog.
3. Launch normally thereafter.

**Or, in a terminal:**

```sh
xattr -d com.apple.quarantine /Applications/UnifiBackupInspector.app
open /Applications/UnifiBackupInspector.app
```

### System requirements

* macOS 15 Sequoia or later (macOS 26 for full Liquid Glass materials).
* Apple Silicon.

## Using it

1. **Open** a `.unf` — drag onto the window, ⌘O, File → Open, or pass as
   a CLI argument to the app bundle.
2. **Browse** in the three-pane view: categories on the left, outline in
   the middle, detail on the right. Live search with ⌘F.
3. **Select for export** — toolbar toggle enables checkboxes on outline
   rows. Select individual records or whole subtrees.
4. **Export** — ⌘⇧E. Choose:
   * **Format** — plain text, JSON, or Markdown.
   * **Target model** — Claude (XML-tagged sections), GPT
     (headings + tables), Gemini (deeper nesting), or Local (compact).
   * **Include secrets?** — off by default. When on, the entire action
     row turns red, with an unmissable warning. No confirmation dialog;
     the visual emphasis is the safeguard.
5. **Copy** to clipboard or **Save…** to a file. The suggested filename
   includes the controller version and flags secret-inclusion.

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘O | Open a `.unf` file |
| ⌘F | Focus search |
| ⌘⇧E | Open export sheet |
| ⌘⌥S | Toggle selection mode |
| Space | Expand / collapse node |
| Arrow keys | Navigate outline |

## Limitations

* **No restore.** The app is read-only.
* **No `.unifi` parsing.** Detected, labelled, refused — extract the
  inner `.unf` from Network → System → Advanced first. Planned for v2.
* **Statistics not loaded by default.** Click "Load statistics…" in the
  sidebar to decompress `db_stat.gz`. Large controllers' stat databases
  can be hundreds of MB.
* **No writing / round-trip.** Exports are one-way. Editing `.unf` is
  genuinely unsolved (see zhangyoufu/unifi-backup-decrypt#2).

## Security model

* Zero network requests.
* No third-party SDKs at runtime (no analytics, crash reporters, update
  checkers).
* Decrypted data lives in memory only. No temp files.
* Sandboxed with only `com.apple.security.files.user-selected.read-write`.
* Redaction is on by default; the "Include secrets" toggle visually
  flags exports that carry PSKs / hashes / shared secrets.
* The static AES-128-CBC key used to decrypt `.unf` has been public
  since ~2017 and is embedded in Ubiquiti's own `ace.jar`. This tool is
  for **owners of their own backups** — use it on data you control.

## Repository layout

```
.
├── App/                          # SwiftUI macOS app (XcodeGen project)
│   ├── project.yml               # Xcode project spec (generated → .xcodeproj)
│   ├── Sources/                  # Scene, Views, ViewModels, Theme
│   └── Resources/                # Info.plist, entitlements, assets
├── Packages/
│   └── UniFiBackupKit/           # UI-free parser core (SwiftPM)
│       ├── Sources/
│       │   ├── UnfCrypto/        # AES-128-CBC NoPadding
│       │   ├── TolerantZip/      # Streaming ZIP, EOCD-tolerant
│       │   ├── Gunzip/           # gzip ↔ Compression.framework
│       │   ├── UniFiBSON/        # Minimal read-only BSON
│       │   ├── BackupStream/     # Collection-marker stream walker
│       │   ├── UniFiModel/       # Strongly-typed domain + tree + identity
│       │   ├── Diagnostics/      # Errors, warnings, info notes
│       │   ├── Redaction/        # Secret field registry
│       │   ├── Export/           # Text / JSON / Markdown + LLM presets
│       │   └── UniFiBackupKit/   # Public façade
│       └── Tests/                # Unit + integration + synthetic fixture
├── fixtures/                     # Real .unf samples (gitignored)
│   ├── MANIFEST.md
│   └── synthetic/                # Synthetic samples as Swift code
├── .github/workflows/build.yml   # CI: test → build .app → .dmg → release on tag
├── RESEARCH.md                   # Phase 1 forensics + risk catalog
├── FORMAT.md                     # Implementation-oriented format spec
├── ARCHITECTURE.md               # Module boundaries + data flow
├── DECISIONS.md                  # ADR log
├── DESIGN.md                     # UI/UX design notes
└── CONTRIBUTING.md               # How to add a parser-version strategy
```

## Building from source

Prerequisites: macOS 15+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
git clone https://github.com/tunlezah/ubq
cd ubq

# Run the parser's unit tests (no app needed)
cd Packages/UniFiBackupKit
swift test

# Build the app
cd ../../App
xcodegen generate
open UnifiBackupInspector.xcodeproj
```

Or, headless:

```sh
cd App
xcodegen generate
xcodebuild -project UnifiBackupInspector.xcodeproj \
           -scheme UnifiBackupInspector \
           -configuration Release \
           CODE_SIGNING_ALLOWED=NO \
           build
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). In short: add a new parser-version
strategy by extending `UniFiModel/ModelMapper.swift`; file layout is
intentionally additive so new collections slot in without disturbing
existing ones.

## Further reading

* `FORMAT.md` — the `.unf` format, soup to nuts, with a diagram and a
  collection inventory.
* `RESEARCH.md` — Phase 1 forensics, cited; includes a 26-item risk
  catalog and links to every public tool in the space.
* `ARCHITECTURE.md` — module boundaries, data flow, memory strategy.
* `DECISIONS.md` — architectural decisions as ADRs.
* `DESIGN.md` — UI/UX design, mockups, keyboard + accessibility.

## Legal

The AES-128-CBC key used by UniFi is hardcoded in Ubiquiti's controller JAR
and has been public since at least 2017. Reading your own backups with it
is legitimate interoperability use. Do **not** distribute other people's
`.unf` files — the static key means their network secrets are exposed to
anyone holding the file. This tool is local-first precisely because of
that sensitivity.

No Ubiquiti intellectual property is redistributed here. This project is
not affiliated with, endorsed by, or sponsored by Ubiquiti Inc.

## License

MIT. See `LICENSE` (to be added in a subsequent commit).
