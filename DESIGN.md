# UI Design

Visual and interaction design for UniFi Backup Inspector. Written before any
SwiftUI code so layout, materials, and affordances are decided up front.
Companion to `ARCHITECTURE.md`.

## Design language

- **Liquid Glass** on macOS 26 via the new materials API; translucent system
  materials (`.regularMaterial`, `.thinMaterial`) on macOS 15.
- **Restrained palette.** Primary chrome is system neutrals. Accents are
  semantic: info-blue, success-green, warning-amber, danger-red. No brand
  colour; we lean on the system.
- **SF Symbols only** for iconography. No custom icons in v1 beyond the app
  icon.
- **Monospaced where data is data.** Keys in the inspector, BSON values,
  exported fences — all `SF Mono`. Prose is `SF Pro`.
- **No custom chrome**. Window titlebar, sidebar, toolbar — all native.

## Window layout

```
┌───────────────────────────────────────────────────────────────────────────────┐
│  UniFi Backup Inspector                      [v1.0.0]   [Open…]  [Export…]   │
├──────────────┬─────────────────────────────────┬──────────────────────────────┤
│              │ 🔎 Search everything…            │  🛈  device · U6-Enterprise  │
│  📂 Overview │                                  │                              │
│  🏠 Sites    │ ▾ Site: HQ                       │  mac              aa:bb:cc… │
│  📡 Devices  │    ▾ Devices (14)                │  model            U6-Ent     │
│  📶 WLANs    │       ▸ U6-Enterprise  aa:bb:cc  │  type             uap        │
│  🌐 Networks │       ▸ USW-48-PoE     dd:ee:ff  │  version          6.6.74     │
│  🧱 Firewall │       ▸ USW-24         11:22:33  │  adopted          true       │
│  🔌 Port Cfg │    ▸ WLANs (5)                   │  site_id          001a…     │
│  👤 Clients  │    ▸ Networks (9)                │  ports            48         │
│  🧑 Admins   │    ▸ Firewall (32 rules)         │  radios           2          │
│  🛡  RADIUS  │ ▸ Site: Branch                   │                              │
│  🎟  Vouchers│                                  │  ─── Raw (BSON) ───          │
│  📜 Settings │                                  │  { _id: ObjectId(...)        │
│              │                                  │    mac:  "aa:bb:cc:dd:…"     │
│  ⚙ Statistics (opt-in)                          │    ...  }                    │
│     [Load statistics]                           │                              │
│                                                 │  ⚠ 1 diagnostic              │
│  ⚠ Diagnostics (3)                              │                              │
│                                                 │                              │
├──────────────┴─────────────────────────────────┴──────────────────────────────┤
│  Identity: v9.0.108  •  format 8  •  2025-12-14 14:32 UTC  •  Full backup    │
└───────────────────────────────────────────────────────────────────────────────┘
```

### Three-pane `NavigationSplitView`

1. **Sidebar (left, ~200pt).** Source list of categories. Translucent
   sidebar material. Icons via SF Symbols. Count badges on the right
   (e.g. "Devices 14"). The "Statistics" entry is rendered in a reduced
   style until the user loads stats; "Diagnostics" has a red badge count
   when anything went wrong.
2. **Outline (middle, ~360pt, resizable).** Hierarchical outline view
   showing the selected category's tree. Nodes are disclosable (chevron).
   Checkboxes appear when the user enters "Select for export" mode
   (toggle on toolbar). Indent matches real hierarchy (Site → Devices →
   Ports).
3. **Inspector (right, flexible).** Two-up: a structured key-value view
   on top (pretty values, SF symbols for bools, coloured chips for
   enums), and a raw BSON panel below (monospaced, foldable). Secrets
   are masked by default with an inline `[Reveal]` affordance.

## Toolbar (window chrome)

- `Open…` (⌘O) — file picker
- `Export…` (⌘⇧E) — enabled when any selection exists, opens export sheet
- `Select for export` toggle — turns on checkboxes in the outline
- `Search` field (⌘F) — live filters the outline
- `Version badge` (pinned right) — app version from Info.plist
- Overflow: `Open Recent ▸`, `Reveal file in Finder`, `Show Diagnostics`

## Materials & vibrancy

- Sidebar: `.sidebar` material (macOS 15+), upgrade to Liquid Glass on
  macOS 26.
- Outline pane: system window background, selection uses
  `Color.accentColor.opacity(0.15)`.
- Inspector: subtle `.regularMaterial` card inside a larger plain
  background, gives a "document-in-viewport" feel.
- Hover: `.foregroundStyle(.primary)` row → `.tint` on hover, with a 1pt
  rounded selection indicator. Drag-hover on the whole window while
  dragging a `.unf` shows a full-window `.thinMaterial` overlay with a
  large "Drop to open" hint.

## Search

- Live `.onChange(of: searchText)` with `.searchable()` in the outline.
- Scope: collection name, document `_id`, any string field, any
  field-name. Uses NFC normalisation so emoji / diacritic SSIDs match
  either form.
- Empty result: inline hint "No matches in 14 devices / 5 WLANs / …" —
  shows scope so the user understands what they're filtering.
- Keyboard: ⌘F focuses; ⌘G / ⌘⇧G cycle matches; `Escape` clears.

## Selection for export

- Toolbar toggle enables checkboxes on every tree row.
- Selecting a parent selects all descendants by default; a tristate
  `[—]` indicator shows partial selection.
- Selection count displayed in the Export button: `Export… (14 items)`.

## Export sheet

```
┌──────────────── Export 14 items ────────────────┐
│                                                  │
│  Format     (●) Plain text                       │
│             ( ) JSON                             │
│             ( ) Markdown                         │
│                                                  │
│  Target     ( ) Claude       (●) GPT             │
│  model      ( ) Gemini       ( ) Local (Llama,   │
│                                      Mistral…)   │
│                                                  │
│  [ ]  Include secrets                            │
│                                                  │
│             ┌─────────────────────────────────┐  │
│             │ Action                          │  │
│             │   [Copy to Clipboard] [Save…]   │  │
│             └─────────────────────────────────┘  │
│                                                  │
│            Preview (first 2,000 chars): ─────┐   │
│            ```markdown                       │   │
│            # Backup export                   │   │
│            ...                               │   │
│            ```                               │   │
│            ───────────────────────────────────    │
│                                  [Cancel]   [OK] │
└──────────────────────────────────────────────────┘
```

### Red-glow state when "Include secrets" is ON

```
  [✓]  Include secrets                             ← toggle with red glow
   🛡  This export will contain secrets (WPA keys,
       admin hashes, RADIUS secrets). Do not share.
                                           ← red helper text
  [ Copy to Clipboard ] [ Save… ]
      ↑ subtle red tint on the button row
```

- Toggle: `.tint(.red)` + `.shadow(color: .red.opacity(0.6), radius: 8)`.
- Helper text: red, bold, with `exclamationmark.shield.fill`.
- Action buttons: red-tinted `.thinMaterial` overlay.
- Announced by VoiceOver as "Include secrets, on — warning, export will
  contain secrets."
- **No confirmation click.** Per product direction.

## Diagnostics panel

A slide-out sheet anchored to the sidebar's "Diagnostics" entry:

```
  ⚠ Diagnostics (3)
  ─────────────────────────────────────────────
  ⚠  warning   Truncated db_stat.gz at offset
              1,234,567. Statistics incomplete;
              configuration is fine.

  ⨯  error     Collection `event_archive`: BSON
              length overrun at offset 12,345.
              This collection was skipped.

  🛈  info      Site Export detected. admin and
              account collections absent by design.
  ─────────────────────────────────────────────
  [Copy report]   [Show in log]
```

Each row is copyable; the whole panel serialises to a Markdown report.

## Keyboard navigation

- ⌘O / ⌘W / ⌘S — Open, Close, Save export
- ⌘F — Search
- ⌘⇧E — Export sheet
- Arrow keys — navigate outline
- Space — toggle disclosure
- ⌘1/⌘2/⌘3 — focus sidebar / outline / inspector
- ⌘⌥S — toggle "Select for export" mode

Full VoiceOver coverage: each outline row has a label
(`"Device, U6-Enterprise, MAC aa:bb:cc:..., selected"`), each badge has a
descriptive label, and the red-glow state announces its warning.

## Accessibility

- `Reduce Motion`: disable the drag-hover material fade; use 100 ms
  cross-fade instead.
- `Increase Contrast`: disable vibrancy, switch outline selection from
  tinted to bordered, bump text weight.
- Dynamic Type: sidebar labels and inspector key names respect
  `@Environment(\.dynamicTypeSize)`.
- Colour is never the sole signal — every red-glow pairs with an SF
  Symbol (`exclamationmark.shield.fill`), every "diagnostics" count pairs
  with `ⓘ` / `⚠` / `⨯`.

## Empty / error states

- **No file open**: centred translucent card, "Drop a `.unf` file here, or
  [Open…]", with the recent files list below.
- **File not recognised** (not `.unf`, bad AES, wrong format): full-
  window error card with the specific reason, a "Copy diagnostics" button,
  and a "Try another file…" CTA. Never a modal dialog.
- **Partial parse**: file opens normally with a persistent warning banner
  at the bottom of the window: "3 collections failed to parse. See
  Diagnostics."

## Drag & drop

- File drag onto dock icon: opens.
- File drag anywhere in window: full-window `.thinMaterial` hint overlay
  "Drop to open backup"; dropping replaces current file.
- Drag out from the inspector: the selected subtree drags as an attached
  text representation (useful for dropping into a chat/note app), using
  the current export format and redaction setting.

## Window chrome details

- Unified titlebar/toolbar style (`.toolbarBackground(.visible, for:
  .windowToolbar)`).
- Title: backup filename. Subtitle: one-line identity badge
  (`v9.0.108 · Full · 2025-12-14 14:32 UTC`).
- Toolbar item for the app version badge, right-aligned, small weight,
  click to show "About UniFi Backup Inspector".

## Performance feel

- Open `.unf` animates in under 200 ms for any typical file (< 50 MB).
- Outline rows recycle with `@Observable` view models so scrolling 10k
  stat rows stays smooth.
- Search is debounced 120 ms; no spinner needed unless a background scan
  exceeds 500 ms.

## What we explicitly don't do (yet)

- No dashboard / graphical visualisation of stats.
- No "restore to controller" button.
- No edit / write-back.
- No cloud anything.
- No comparison between two backups (v2 candidate).
- No site / WLAN / device thumbnails (v2 candidate).
