# Project Review & Roadmap — August 2026

A deep review of UniFi Backup Inspector: where the implementation actually
stands against its own documentation, what the ecosystem looks like as of
August 2026, and a prioritised plan for making the app genuinely more useful
to UniFi owners — while keeping the offline-first posture.

Method: full code audit of `UniFiBackupKit` and the app layer, plus fresh
web research into the 2026 tool landscape, the UniFi Network 10.x backup
format, controller APIs, and community pain points. Sources are listed at
the bottom. Companion docs: `RESEARCH.md` (phase-1 forensics, Dec 2025),
`FORMAT.md`, `ARCHITECTURE.md`, `DECISIONS.md`, `DESIGN.md`.

---

## 1. Where the project stands

The foundation is strong and unusually well-documented:

* **Parser core is real.** Zero third-party dependencies, bounds-checked
  throughout, no force-unwraps on parse paths, structured diagnostics
  instead of crashes. The tolerant ZIP reader (local-header scan, data
  descriptors, CP-437/UTF-8 names) and the dual-layout loader (legacy
  `db.gz` stream *and* per-collection `.bson` entries) are ahead of most
  public tools.
* **`.unifi` container handling exists** for the two plain-ZIP shapes
  (embedded `.unf`; inline Network payload) — but see §3.3 for a third
  shape now documented in the wild that the app cannot open yet.
* **Redaction-on-export** (ADR-006) and the red-glow secrets UX (ADR-009)
  are implemented as designed.
* **Tests are genuine**: crypto round-trip, malformed-ZIP recovery, BSON
  type coverage + malformed rejection, marker handling, identity, nested
  redaction, export presets, and two end-to-end synthetic layouts.
* **CI is release-ready** (test → build → `.dmg`/`.zip` → tag-triggered
  release) — but **no release has ever been published**. No tags exist.

The biggest overall finding: the product is ~90% of a very good *viewer*,
while the documentation (and the ecosystem gap analysis in `RESEARCH.md`)
describe an *analysis tool*. The highest-value work is not more parsing —
it is analysis features on top of the model that already exists, plus
actually shipping.

---

## 2. Correctness fixes found in the audit

These are bugs in what exists today, ordered by user impact. All are
cheap relative to their value and should land before a public v1.0.

| # | Severity | Where | Problem | Fix sketch |
|---|---|---|---|---|
| 1 | High | `Identity.detectKind` (`Identity.swift:128`) | Per-collection `.bson` backups contain no `db_stat.gz`, so `hasStats` is always false → **full backups are misclassified as `settingsOnly`** | Treat `stat_*.bson` / `event_archive*.bson` entries (and loaded stat collections) as stats-presence signals |
| 2 | High | `SecretVault` (`SecretVault.swift:9,97`) | Registry misses UniFi secret fields: `x_authkey`, `x_adopt_password`, `x_ssh_password`, `x_ipsec_pre_shared_key` (site-to-site VPN PSK), WireGuard private keys. `inventory()` skips whole collections (`device`, `networkconf`, `user`, `portconf`) so the sidebar "Secrets" count undercounts | Redact any `x_`-prefixed field by default (UniFi's own sensitive-field convention) with a small benign allowlist; run `inventory()` over *every* collection incl. opaque ones |
| 3 | Medium | `TreeBuilder.build` (`Tree.swift:260`) | Records whose `site_id` doesn't match a parsed site are **silently invisible** — not in the tree, not exportable. Contradicts the project's own "surfacing data beats silently losing it" | Per-category "Unassigned" bucket for orphaned records; diagnostic when it's non-empty |
| 4 | Medium | `InspectorController` (`InspectorController.swift:104`) | Recents are in-memory only; the `files.bookmarks.app-scope` entitlement is declared but never used → recents die with the process and would be unreadable under sandbox anyway | Store security-scoped bookmarks in `UserDefaults`; wire the system Open Recent menu |
| 5 | Medium | `.unifi` detection (`Backup.swift:47`) | Console-generated `.unifi` files documented as **AES-256-CBC (IV-prepended) → gzip → tar** will fail the plain-ZIP check, then fail AES-128 `.unf` decrypt, and surface as "Not a UniFi Network backup" | See §3.3 — add the third container shape |
| 6 | Low | `InspectorController.exportToFile` (`:163`) | `try?` swallows file-write errors — user thinks the export saved | Surface the error in an alert |
| 7 | Low | `Gunzip` / `TolerantZipReader` | Absolute integer indexing (`gz[0]`, `base[cursor]`) is correct today because callers pass fresh zero-based `Data`, but breaks silently if ever handed a `Data` slice | Normalise via `startIndex` offsets or assert zero-based at entry |
| 8 | Low | `TolerantZipReader.findEndOfDeflatedPayload` | A `PK\x07\x08` byte sequence *inside* deflate payload can false-positive the descriptor scan (no CRC validation) | Validate candidate boundary by CRC32 or trial-inflate before accepting |

Performance issues in the same bucket (matter at real-world scale — the
`user` collection commonly holds thousands of rows):

* `selectedNodes` flattens the whole tree **per access** and is called from
  toolbar labels, menu-enabled state, and the export sheet
  (`InspectorController.swift:112`).
* `OutlineRow.matchesFilter` scans every raw BSON field of every visible
  row per keystroke with no debounce (`OutlinePane.swift:89`); `DESIGN.md`
  promised 120 ms debounce.
* The export sheet regenerates the **full export string on the main
  thread** on every option change, then shows 2,000 chars of it
  (`ExportSheet.swift:119`).
* `InspectorDetailPane.focusedNode` re-flattens the tree per render.

Fix pattern for all four: build a flat index (`[id: TreeNode]` +
parent/child maps) once per load, debounce search, move export preview
generation off the main actor.

---

## 3. Ecosystem reality check (August 2026)

Fresh research; this updates `RESEARCH.md` §5. Full source list at bottom.

### 3.1 The landscape moved in 2026

New tools since the Dec-2025 research pass:

| Tool | What it does | Why it matters here |
|---|---|---|
| **EvilBit-Labs/unifi_extract** (Go CLI, Jul 2026, active) | DFIR-grade: `.unf` + `.unifi`, Mongo→NDJSON, **site-export that re-encrypts to a valid importable `.unf`**, single-WLAN passphrase extraction. Its `DECRYPTION.md` is now the best public format doc | Proves site-scoped write-back is feasible; documents the `.unifi` AES-256 container |
| **mallianet/unifi-backup-explorer** (browser, Apr 2026) | One-click **audit report (PDF)**, credential-leak detection, 10.x-aware | Direct competitor to this app's analysis ambitions — browser-based, `.unf` only |
| **vlastocom/unifi_dump** (Python, Jul 2026) | `.unf`→JSON with **`--redact`** for safe sharing | Validates the sanitised-export idea |
| **ShaunLeslie/unifi-backup-reader** (browser, May 2026) | In-browser `.unf` + `.unifi` decode | |
| **enuno/unifi-mcp-server** (2026) | MCP server over the **live controller API** (create/list/download backups) | Does *not* parse backup files — the offline-backup MCP niche is open |
| Download-automation crop (octivi/unfbackup, konkele, Tom-Joad, ben-freke…) | Scheduled `.unf`/`.unifi` pull off the console | Evidence of demand for "get backups off the box" |

**What still doesn't exist anywhere: backup *diffing*.** A dedicated
search found zero tools that compare two `.unf` files. Nobody does
native-macOS, nobody does offline statistics, nobody does an MCP server
over backup *files*. Those are this project's open lanes; the browse-and-
export lane is getting crowded.

### 3.2 Format status (Network 10.x)

* Current release: **UniFi Network Application 10.6.101** (Aug 2026). The
  9.x → 10.x jump did **not** change the `.unf` container: same AES-128-CBC
  static key/IV, same inner ZIP, same concatenated-BSON `db.gz`. README's
  "v5.10 through v9.5.21+" claim should be re-stated as "v5.x through
  v10.x".
* Marker shape confirmed: `{__cmd:"select", collection:"X"}` — the current
  `detectMarker` (small doc with a `collection` string) already covers it.
* **UniFi 10.1 (Feb 2026) added per-application / settings-only console
  backups** — first product-level move toward selective backup, and another
  reason files with unfamiliar layouts will keep appearing. The dual-path
  loader is the right architecture; keep it schema-tolerant.
* **Version-parity restore rule confirmed**: a backup restores only into a
  Network version **equal or newer** than the one that produced it;
  forward-only schema migration, no downgrade path. (Feeds the Restore
  Advisor feature, §4.)
* **Top 2026 migration pain**: importing a full-controller `.unf` into a
  UniFi OS console **silently imports only the Default site**, and legacy
  firewall rules can vanish without warning. An inspector that *warns about
  exactly this* before the user hits restore would be uniquely useful.

### 3.3 `.unifi` has (at least) a third shape — and it's the common one

`ADR-012` treats `.unifi` as a plain unencrypted ZIP (two sub-shapes:
embedded `.unf`, or inline Network payload). Real files matching those
shapes evidently exist — the loader was built against them. But the format
documented by EvilBit-Labs (Aug 2026) and consistent with UniHosted's
behaviour is different:

* **AES-256-CBC, NoPadding, static 32-byte key** (published in
  `unifi_extract`'s `DECRYPTION.md`), **IV prepended** as the first 16
  bytes of the file;
* decrypts to **gzip → tar** (ustar + GNU long names), *not* ZIP;
* contents: `backup/metadata.json`, `backup/network/` (a directory holding
  `version`, `timestamp`, `system.properties`, `db.gz` — i.e. an inline
  Network payload *inside* the encryption), and `backup/ucore/database/`
  (a **PostgreSQL `pg_dump` directory-format dump** carrying UniFi OS
  users plus Protect/Access/Talk config).

A console-generated file of this shape currently fails every branch of
`Backup.load` and dies as "Not a UniFi Network backup". Detection order
should become:

1. `PK\x03\x04` at byte 0 → plain-ZIP `.unifi` (current paths A/B).
2. Trial AES-128 `.unf` decrypt → ZIP magic → `.unf` path.
3. Trial **AES-256 decrypt with IV = first 16 bytes** → gzip magic
   (`1f 8b`) → tar walk → parse `backup/network/` in place; surface
   `backup/ucore/` as metadata (browse later, §4 Tier 3).

Cost: a small tar reader (~150 LOC, fits the zero-dependency rule) plus a
second key constant in `UnfCrypto`. This turns the app's weakest claim
(".unifi supported") into an actual differentiator — only two public tools
handle it at all, neither of them native.

### 3.4 `.supp` support bundles are a near-free win

Same AES-128 key/IV as `.unf`, inner ZIP with a **known corrupt tail**
(the controller's compression bug) — which is precisely what
`TolerantZipReader` was built for. Contents: `system.properties`,
`support_info.json`, `devices/`, logs — including RADIUS credentials and
PSKs, so the redaction pipeline applies. Detect, decrypt, show entries +
a raw-file browser. Probably < 1 day of work on the existing code.

### 3.5 Round-trip / editing status

* Site-export **modify-and-re-encrypt works** (EvilBit demonstrates it):
  rebuild BSON stream → gzip → DEFLATE ZIP → AES-128 zero-padded.
* Full-controller autobackup edit → controller-accepted restore remains
  **unproven publicly**. `zhangyoufu#2` turns out to be about
  `mongorestore` refusing the stream format, not about the controller
  rejecting re-encrypted files — the "genuinely unsolved" framing in
  README should be softened.
* The safe, high-value applications of write-back are therefore:
  **(a) sanitised backup export** (secrets replaced, re-encrypted — makes
  shareable fixtures possible, which `fixtures/MANIFEST.md` laments) and
  **(b) "extract site as importable `.unf`"** — which directly answers the
  silent-partial-restore migration pain in §3.2. Both are site-scoped
  writes with an existing proof of feasibility. `BSONWriter` already
  exists in the package; missing pieces are a ZIP writer and golden
  round-trip tests.

---

## 4. Product roadmap

Ordered tiers; each item notes value/effort. "Offline" means no network,
ever — the default posture. §5 covers the one optional exception.

### Tier 1 — ship v1.0 (fix + polish + release)

1. **All §2 correctness fixes.**
2. **Search that works**: filter (hide, don't dim) with parent-path
   preservation, ⌘F focus, debounce, Escape to clear. `DESIGN.md` already
   specifies it.
3. **Statistics stop being a dead end**: a dedicated sidebar category
   (not "Other Collections"), stat collections grouped by granularity
   with row counts, and load *without* re-decrypting the whole file
   (cache the plaintext ZIP entries; parse stats on demand).
4. **Files category**: surface the ZIP entries the parser already holds —
   `system.properties` (typed key-value view), `sites/…`
   (`config.gateway.json`, portal assets, floor-plan images with
   QuickLook-style preview), `version`/`format`/`timestamp` raw. Zero new
   parsing; pure exposure of `rawEntries`.
5. **Cross-reference resolution**: the joins are all documented in
   `FORMAT.md` — render `network_id`, `usergroup_id`, `wlangroup_id`,
   `portconf_id`, firewall-group ids as **named, clickable links** instead
   of bare ObjectIds; back-links on the target ("used by 3 WLANs").
   This is the single biggest browse-experience upgrade available.
6. **Secret inventory panel**: the counts exist (`secretInventory`); add
   the drill-down view — every secret path, which record, reveal/copy,
   and an "export inventory (names only, no values)" action. The phase-1
   research called this a market gap; it's a sidebar section away.
7. **Sign + notarise + distribute**: Developer ID ($99/yr) + `notarytool`
   in CI, a Homebrew cask, screenshots in the README, and an actual
   tagged release. On macOS 15+ Gatekeeper, unsigned right-click-Open is
   materially harder than it used to be — notarisation is the difference
   between "tool someone links on r/UNIFI" and "tool nobody can open".
   Update stale README lines while at it (LICENSE exists; `.unifi` *is*
   parsed; supported-version range now v10.x).

### Tier 2 — v1.x differentiators (the analysis tool nobody else has)

8. **Backup diff** — the headline feature. Two backups in, one report
   out: devices added/removed/re-versioned, WLANs/PSK changes, networks,
   firewall rules (index-aware), port profiles, settings deltas — grouped
   by site, exportable in the existing text/JSON/Markdown pipeline, and
   diffable at the raw-BSON level for opaque collections. The model layer
   (stable ids everywhere) makes this mostly a tree-zip + render problem.
   Nothing in the ecosystem does this; it's also the natural companion to
   autobackups ("what changed since last Tuesday?").
9. **Config audit report** ("Health check") — offline lint over the
   mapped model. Initial rule set:
   * open/WEP/WPA1 WLANs; WPA2-only where WPA3-transition is available;
     short PSKs; guest WLANs without isolation
   * port-forwards exposing management ports (22/443/8443) or all-ports;
     firewall any/any accepts; UPnP enabled
   * admins without 2FA (`verification` collection present/absent),
     stale admin accounts
   * devices on old firmware relative to the backup's own era, adoption
     with default credentials where detectable
   * **restore-safety warnings**: non-default sites + legacy firewall
     rules that a UniFi OS console import will silently drop (§3.2)
   Render as a graded Markdown/PDF report through the existing exporter.
   mallianet proved demand in a browser; a native app can go deeper
   (cross-collection rules) and stays offline.
10. **Restore Advisor** — small but constantly needed: read the backup's
    version and say "restores into Network ≥ 10.1.x; will NOT restore
    into 9.x (forward-only migration); console import will only include
    the Default site — this backup has 3 sites". Pure offline logic over
    `Identity` + §3.2 rules.
11. **CSV export** — device/client/WLAN/firewall inventory tables for
    spreadsheets; the IR already flattens records, this is one more
    renderer plus column presets per collection.
12. **Charts on statistics** (Swift Charts): WAN throughput, per-AP client
    counts, top DPI apps from `stat_daily`/`stat_hourly` once stats
    loading is fixed. Offline stats visualisation exists nowhere else.
13. **Autobackup folder view**: open a folder of `autobackup_*.unf` (+
    `meta.json`), timeline sidebar, one-click diff of adjacent snapshots
    (pairs with #8).

### Tier 3 — expansion (still offline)

14. **`.unifi` AES-256 tar container** (§3.3) — required for console
    users; includes listing `backup/ucore/` contents and "export Postgres
    dump for `pg_restore`" without parsing it.
15. **`.supp` support bundles** (§3.4).
16. **Site export as importable `.unf`** + **sanitised backup export**
    (§3.5) — behind an explicit "experimental write" disclosure, with
    golden round-trip tests. Sanitised export also unblocks a public
    fixture corpus for this repo's own CI.
17. **CLI (`ubi`)** — `ubi decrypt|ls|cat|export|diff|audit` over the same
    package (ADR-014 anticipated this). Enables scripting/cron use and
    pairs with the download-automation tools users already run.
18. **Local MCP server (`ubi-mcp`)** — expose an *opened backup* to
    Claude/other MCP clients as tools (`list_collections`, `get_record`,
    `search`, `diff`, `audit`) over stdio, localhost-only. The existing
    LLM-export presets solve "paste a slice"; MCP solves "ask questions
    of the whole backup without pasting anything". The only UniFi MCP
    server out there talks to live controllers, not backup files — this
    lane is open, on-brand (data never leaves the machine), and cheap:
    the kit is already UI-free.
19. **UCore Postgres browsing** (`.unifi` deep parse) — directory-format
    `pg_dump` reader for the config tables (UniFi OS users incl. Argon2id
    hashes, Protect/Access/Talk config). Substantial; do after #14 proves
    demand.

### Tier 4 — bigger bets

20. **Optional controller connectivity** — §5.
21. **Multi-window / compare UX** — prerequisite polish for #8 at scale
    (today one shared `InspectorController` backs every window).
22. **Fleet features** (many backups, many sites over time) — only if the
    audience turns out to be MSPs rather than homelab owners.

---

## 5. Optional controller connectivity (design sketch)

*(Being finalised against API research — see §5 sources; the constraints
below are firm regardless of endpoint details.)*

Principles, honouring the project's identity:

* **Offline remains the default and the identity.** The connectivity
  feature is OFF until a user explicitly adds a controller; the app makes
  zero network calls otherwise, verifiable by its entitlements story.
* **Visible when active**: a persistent status chip ("Connected to
  <console> — last fetch 12:04") whenever a session exists; no background
  refresh, no telemetry, ever. Every fetch is user-initiated.
* **Scope it to what a backup inspector needs** — fetching backup files
  and comparing them. Not a controller admin client; no writes to the
  controller.
* **ADR required** (supersedes ADR-007's absolutism with a precise carve-
  out): add `com.apple.security.network.client` to the entitlements, and
  document why. If the no-network guarantee is considered marketing-
  critical, ship two build flavours (the entitlement is static per
  binary); otherwise one binary + honest docs.
* Credentials in **Keychain**, API-key auth preferred over passwords,
  self-signed TLS handled by pinning the console's cert on first use
  (trust-on-first-use with fingerprint display) rather than disabling
  validation.

Candidate capabilities, in value order:

1. **Fetch backup now** — trigger/download a fresh `.unf` from the
   controller and open it directly (no SSH, no web UI dance).
2. **Autobackup listing** — enumerate and download the console's rolling
   autobackups; combined with Tier-2 #13, this gives "timeline of my
   network" with zero manual file shuffling.
3. **Drift check** — fetch live config (read-only) and diff it against
   the opened backup using the same engine as #8: "what changed since
   this backup was taken".

---

## 6. LLM export refresh

The preset budgets in `Exporter.swift` are a generation stale. As of
August 2026 (advertised windows; *effective* quality-holding context is
~60–70% of advertised — budget against effective):

| Preset | Advertised context (Aug 2026) | Suggested slice budget (chars) |
|---|---|---|
| Claude (Sonnet/Opus/Fable 5 lines) | 1M tokens (Haiku 4.5: 200K) | ~1.6M (≈400K tokens) |
| GPT (GPT-5: 400K; 5.5/5.6: ~1M) | 400K–1M | ~1.0M (≈256K tokens) |
| Gemini (2.5/3.x mainstream) | 1M (10M headline tier unproven) | ~1.6M |
| Local (Llama 4 Maverick 1M / Scout 10M adv.; Qwen 3.5 262K; Mistral Large 3 256K) | 256K–1M realistic | ~400K (≈100K tokens) |

Recommendations beyond numbers:

* Make budgets **user-editable** (stored per preset) instead of hardcoded —
  the models will move again before the next release.
* Implement the **split-into-N-slices** writer the budget hint gestures at
  (currently it only appends a "consider splitting" warning).
* Fix the Claude preset's flat output: the IR carries `children: []`
  always, so the promised `<site><device>…` nesting never happens.
  Group selected records under their site/category when building the IR.
* Longer term, the MCP server (Tier 3 #18) obsoletes most manual
  copy-paste export flows.

---

## 7. Engineering hygiene

* **Fuzzing**: the parser consumes hostile input by design (encrypted
  files from anywhere). `UnfCipher → TolerantZip → Gunzip → BSONReader`
  is an ideal libFuzzer surface; Swift supports it natively
  (`-sanitize=fuzzer`). Add fuzz targets for ZIP, gzip, and BSON entry
  points, seeded from the synthetic fixtures. Given the org's security
  focus this is also good citizenship — this app will be fed untrusted
  backups.
* **Corpus drift CI**: `fixtures/MANIFEST.md` already describes the
  recipe — automate it. A scheduled workflow spins up
  `jacobalberty/unifi` / `linuxserver/unifi-network-application` on a
  Linux runner, provisions via the controller API, downloads a real
  backup, and runs the parser smoke test on a macOS runner. Catches
  format drift the week Ubiquiti ships it, not when a user files an
  issue. (10.1's per-app backups are exactly the kind of thing this
  catches.)
* **Golden-file export tests** per preset/format (CONTRIBUTING already
  asks for them; none exist).
* **Test the version claims**: a `ModelMappingTests` target is named in
  the docs but absent; the synthetic fixture should grow the collections
  the mapper strongly types (portconf, firewallgroup with members,
  routing, dpi) — several mappers currently have zero test coverage.
* **Doc cleanup**: README Limitations still says `.unifi` isn't parsed
  and LICENSE is "to be added"; ARCHITECTURE promises
  `AsyncStream<LoadEvent>`, `OpenDocumentController`, tri-state
  checkboxes, drag-out — either implement or trim to match reality.
  README's version table should say v10.x (§3.2).
* **App metadata**: `LSApplicationCategoryType` is `developer-tools`;
  `public.app-category.utilities` matches the audience better.

---

## 8. Suggested sequencing

Assuming solo/part-time development:

1. **v1.0 (2–4 weeks)** — §2 fixes, search, stats category, files
   category, cross-reference links, secret inventory panel, sign +
   notarise + cask + screenshots + first tagged release. *Outcome: the
   best UniFi backup viewer that exists, installable by normal people.*
2. **v1.1 (3–5 weeks)** — backup diff + autobackup folder timeline, CSV
   export, restore advisor. *Outcome: the only backup diff tool in the
   ecosystem.*
3. **v1.2 (3–5 weeks)** — config audit report, charts on stats,
   `.supp`, `.unifi` AES-256 container. *Outcome: analysis tool, not
   viewer; console (`UDM`) users fully served.*
4. **v2.0 (open-ended)** — CLI + MCP server, site-export/sanitised
   write-back (experimental), optional controller connectivity behind
   its ADR, UCore Postgres browsing.

Distribution note: submit to `wolffcatskyy/awesome-unifi` and post the
diff feature (not the viewer) to r/UNIFI / community.ui.com — the viewer
lane is crowded (§3.1); diff and audit are the story.

---

## Sources (August 2026 research pass)

Format & tools:
https://github.com/EvilBit-Labs/unifi_extract (and its `DECRYPTION.md`) ·
https://github.com/mallianet/unifi-backup-explorer ·
https://github.com/ShaunLeslie/unifi-backup-reader ·
https://github.com/vlastocom/unifi_dump ·
https://github.com/zhangyoufu/unifi-backup-decrypt (issues #2–#5) ·
https://github.com/Darknetzz/UniFi-Backup-Explorer ·
https://github.com/ThatKalle/unifi-reserata ·
https://www.unihosted.com/tools/backup-explorer ·
https://github.com/enuno/unifi-mcp-server ·
https://github.com/devondragon/unifi-network-ops ·
https://github.com/wolffcatskyy/awesome-unifi ·
https://reidanb.gitbook.io/home/blog/ubiquiti-.supp-file-decryption-key-found-method-to-inspect-support-and-configuration-packages ·
https://dev.to/kurtmc/unifi-autobackup-data-recovery-and-restore-1fc4

Product/community:
https://williehowe.com/2026/02/10/unifi-10-1-backup-changes/ ·
https://vninja.net/2026/07/17/migrating-from-unifi-uxg-lite-to-express-7/ ·
https://help.ui.com/hc/en-us/articles/360008976393-Backups-and-Migration-in-UniFi ·
https://cvefeed.io/vuln/detail/CVE-2026-54405

LLM context windows:
https://www.elvex.com/blog/context-length-comparison-ai-models-2026 ·
https://www.digitalapplied.com/blog/ai-context-window-comparison-2026-1m-to-10m-tokens ·
https://www.morphllm.com/llm-context-window-comparison
