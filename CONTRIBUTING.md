# Contributing

Short, opinionated guide. Read `RESEARCH.md`, `FORMAT.md`, and
`ARCHITECTURE.md` first — they'll answer most "why does it work this way"
questions.

## Dev setup

```sh
brew install xcodegen
git clone https://github.com/tunlezah/ubq
cd ubq

# Parser-only (fast, no Xcode):
cd Packages/UniFiBackupKit
swift build
swift test

# App:
cd ../../App
xcodegen generate
open UnifiBackupInspector.xcodeproj
```

macOS 15+ and Xcode 16+ are required.

## House rules

* **Root-cause over quick-fix.** If a `.unf` opens weirdly, understand why
  before adding a special case. Update `FORMAT.md` if you learn something
  new about the format; update `RESEARCH.md` if a new risk surfaces.
* **No third-party runtime dependencies.** `UniFiBackupKit` is
  Apple-frameworks-only. If you *truly* need a dep, open a PR with an
  ADR in `DECISIONS.md` explaining why.
* **No telemetry, no network, ever.** See ADR-007.
* **No secrets in logs / temp files / pasteboards by accident.** See
  `Redaction/SecretVault.swift`; extend the registry when you meet a
  new secret field.
* **Every non-obvious choice lands in `DECISIONS.md` as an ADR.**

## Adding support for a new controller version

The parser is deliberately schema-tolerant: unknown collections surface as
`OpaqueCollection` nodes. You only need to do work when you want to
*strongly type* a collection that has just appeared or been renamed.

### Recipe

1. **Acquire a fixture** that exposes the new collection. Drop into
   `fixtures/` (gitignored) and add a provenance row to
   `fixtures/MANIFEST.md`.
2. **Inspect** with the app — the `Other Collections` category will show
   it in opaque form, so you can see field names and types.
3. **Add a domain type** in `Packages/UniFiBackupKit/Sources/UniFiModel/DomainTypes.swift`.
4. **Add a mapper method** in `ModelMapper.swift`; dispatch on the
   collection name in `map(_:)`.
5. **Hook it into the tree** in `Tree.swift` — decide whether the
   collection belongs under a per-site category or a controller-wide one.
6. **Add unit tests** in `Tests/ModelTests/` or extend `SyntheticFixture`
   to emit the new collection.
7. **Update `FORMAT.md`'s inventory table.**

### Strong-typing policy

* Fields that are `_id`, `site_id`, a handful of first-class scalar
  identifiers → type them.
* Deep nested structures with many optional fields → leave in
  `rawDocument` and rely on the inspector's detail pane + export to
  surface them.
* Don't try to type *everything* — the goal is navigability, not a
  full ORM.

## Adding a new LLM preset

Open `Packages/UniFiBackupKit/Sources/Export/Exporter.swift`. Add a case
to the `LLMPreset` enum and supply:

* `displayName`
* `targetCharacterBudget`
* `usesXMLSections` (if you want Claude-style tagged sections)

If the new preset needs structural behaviour that can't be expressed
by those knobs, extend the IR renderers carefully. Don't duplicate
format-specific rendering logic per preset — add a preset-aware
branching point and keep the happy paths shared.

## Adding a new export format

Add a case to `ExportFormat`, implement a new
`Sources/Export/<Name>Exporter.swift` that takes the
`IntermediateRepresentation`, and wire the dispatch in `Exporter.export`.
Add a golden-output test in `Tests/ExportTests/`.

## PR checklist

* [ ] `swift test` passes.
* [ ] New behaviour has a test (unit or integration fixture).
* [ ] Touched the format? Updated `FORMAT.md`.
* [ ] Added a runtime dep? Added an ADR in `DECISIONS.md`.
* [ ] Added a new secret field name? Extended `SecretVault.secretFieldNames`.
* [ ] No new network calls, crash-reporter SDKs, or analytics.

## Filing issues

Include:

* Controller version that produced the backup (from the identity bar).
* `format` value if present.
* A minimal repro — ideally a synthetic fixture in Swift, not a real backup.
* The diagnostics panel "Copy Report" output.

Do **not** attach real `.unf` files to public issues. They contain your
network's WPA keys, admin hashes, RADIUS secrets, etc., and the static
AES key means anyone who reads the issue can open them.
