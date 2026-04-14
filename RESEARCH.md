# UniFi Backup Inspector — Phase 1 Research

> Compiled from five parallel forensics passes across community sources, GitHub
> projects, and reverse-engineered tool source code. Every claim is sourced.
> All decisions in `ARCHITECTURE.md` and `DECISIONS.md` derive from this file.

## TL;DR

A `.unf` file is an **AES-128-CBC encrypted ZIP** with a **single hardcoded
key/IV that has not changed from UniFi Network Application v5.10 through
v9.5.21** (verified December 2025). The file alone is sufficient to decrypt
— no controller key material, no passphrase, no per-site secret. Inside the
ZIP sits a **single concatenated BSON stream** (`db.gz`, gunzipped) that uses
collection-marker documents to delimit logical MongoDB collections. The
ecosystem of existing tools is small, fragmented, and stops at "decrypted ZIP
on the kerb" — leaving a clear gap for a native macOS browse-and-export app.

## 1. Format Identity

| Property | Value | Source confidence |
|---|---|---|
| Container | AES-128-CBC encrypted blob, no magic header | Very high |
| Inner format | ZIP archive (often with malformed EOCD / streaming data descriptors) | Very high |
| Cipher | AES/CBC/NoPadding | Very high |
| Key (ASCII) | `bcyangkmluohmars` (16 bytes, AES-128) | Very high |
| IV (ASCII) | `ubntenterpriseap` (16 bytes) | Very high |
| Key derivation | None — hardcoded constants in the Java controller | Very high |
| Length invariant | Ciphertext length is always a multiple of 16 | Very high |
| Plaintext starts with | `PK\x03\x04` (ZIP local-file-header signature) | Very high |
| Key rotation across versions | None observed across v5.10 → v9.5.21 (~7 years) | Very high |

The constants come from decompiled `ace.jar`. Four independent reimplementations
(zhangyoufu, ThatKalle, Darknetzz, Metasploit) quote byte-for-byte identical
values.

### Sister formats (declined gracefully, not parsed)

| Extension | Origin | What we do |
|---|---|---|
| `.unifi` | UniFi OS console "System Config Backup" — superset wrapping Network's `.unf` plus Protect/Access/Talk/Connect plus UCore PostgreSQL tables | Detect, label, refuse to parse as Network backup. Out of v1 scope. |
| `.ubv` | UniFi Protect raw video file | Detect, refuse with explanation. |
| `.supp` | UniFi support bundle (same AES scheme, different inner ZIP) | Out of scope; could share decrypt code if we extended later. |

## 2. Inside the Decrypted ZIP

The plaintext ZIP commonly contains:

| Path | Purpose | Always present? |
|---|---|---|
| `db.gz` | gzip-compressed BSON stream of the `ace` MongoDB database (config) | Yes |
| `db_stat.gz` | gzip-compressed BSON stream of the `ace_stat` database (statistics) | No — absent on settings-only exports and pre-5.x backups |
| `version` | Plain ASCII controller version (e.g. `8.0.24`, `9.5.21`) | Yes (since 3.x) |
| `format` | Plain ASCII integer — backup format revision (e.g. `7`, `8`) | Mostly (often missing on older builds) |
| `timestamp` | Backup creation time, **either** epoch ms **or** ISO-8601 Z string | Yes |
| `system.properties` | Java properties: ports, DB URIs, UUIDs, install-paths | Usually |
| `sites/` | Per-site overrides: `config.gateway.json`, portal assets, maps | Conditional |

The "malformed ZIP" quirk is not corruption — it is the controller's writer
relying on streaming data-descriptor records (general-purpose-flag bit 3) and
sometimes truncating the EOCD. **Assume every ZIP needs tolerant reading.**

## 3. Embedded MongoDB Layout

`db.gz` and `db_stat.gz` are **NOT** standard `mongodump` output. There is no
per-collection `.bson` file with a `.metadata.json` companion. After
gunzipping, you get **one continuous stream of length-prefixed BSON
documents**. Logical collections are separated by special marker documents:

```
{ collection: "<name>" }   ← marker document (header)
{ ...row 1... }
{ ...row 2... }
{ collection: "<next-name>" }
{ ...row 1... }
...
```

Reader algorithm:

1. Gunzip to a memory-mapped buffer (do not eager-load on huge stat dumps).
2. At cursor: read int32 LE length, parse `length` bytes as one BSON document.
3. If document has a single `collection` field → switch active collection.
4. Otherwise → it's a row in the current collection.
5. Advance cursor by `length`. Repeat to EOF.

Two databases: `ace` (configuration, ~30-40 collections) and `ace_stat`
(time-series, ~10 stat collections). Full inventory in `FORMAT.md`.

## 4. BSON Type Coverage Required

Of the 22 BSON type codes, UniFi configuration data uses 11. The deprecated
codes (`0x06`, `0x0C`–`0x0F`, `0xFF`, `0x7F`) and decimal128 (`0x13`) do not
appear. Minimum viable type set:

`0x01` double · `0x02` string · `0x03` document · `0x04` array · `0x05` binary
(subtypes 0x00 generic, 0x04 UUID) · `0x07` ObjectId · `0x08` bool · `0x09`
UTC datetime · `0x0A` null · `0x10` int32 · `0x12` int64

Regex (`0x0B`) and timestamp (`0x11`) appear rarely; decode defensively but
they're not on the critical path.

## 5. Existing Tools — What's Out There, What's Missing

| Tool | Reach | Strength | Weakness |
|---|---|---|---|
| zhangyoufu/unifi-backup-decrypt | Most-cited; bash + openssl | Auditable, tiny, still works on v9.x | Stops at decrypted ZIP. No `.unifi`. No browse. |
| Darknetzz/UniFi-Backup-Explorer | Browser (newest serious entrant, Dec 2025) | Privacy-preserving, BSON→JSON conversion | One maintainer, version-drift open issue, no `.unifi` |
| ThatKalle/unifi-reserata | Go CLI, cross-platform binary | Single binary | **Author's own open issue: produces corrupted output ZIPs (unfixed 2+ years)** |
| UniHosted Backup Explorer | Hosted web (commercial) | Only tool that handles `.unifi` + Postgres + per-site extraction | Closed-source, owned by competitor hosting vendor |
| darrenpmeyer gist | Recipe / tutorial | Pedagogical | Manual every step |
| peterM/Ubiquiti-Unifi-Data-Exporter | C# desktop (5y stale) | Schema-aware export | Needs live controller, not file-based, abandoned |

**Identified gap**: no native macOS app; nothing built around "browse +
selectively export for AI ingestion"; no diff; no secret-inventory; no signed
binary.

## 6. Risk Catalog (must-handle vs nice-to-handle vs accept)

| # | Risk | Mitigation | Priority |
|---|---|---|---|
| 1 | Wrong format dropped in (`.unifi`, `.ubv`, random ZIP) | Magic-byte + length-divisible-by-16 + trial-decrypt + expected-files check | must |
| 2 | Ciphertext length not multiple of 16 (truncated) | Detect before decrypt; precise error | must |
| 3 | Malformed ZIP EOCD / missing central directory | Use streaming/scan-forward ZIP reader | must |
| 4 | Truncated `db.gz` (gzip Z_BUF_ERROR) | Hard-fail with byte offset of first read failure | must |
| 5 | Truncated `db_stat.gz` | Soft-warn; render config from `db.gz` regardless | nice |
| 6 | BSON length field would overflow buffer | Bounds-check every doc length before slice | must |
| 7 | Site Export mistaken for full backup | Detect missing `admin`/`account` collections; label appropriately | must |
| 8 | Renamed/removed collections across versions | Iterate by name presence, never by hardcoded index; surface unknowns | must |
| 9 | BOM / CRLF / trailing newline in `version` / `timestamp` | Trim whitespace, strip BOM, parse epoch-or-ISO flexibly | must |
| 10 | UTF-8 decoding errors in user-provided strings | Strict decode with `\uFFFD` substitution; keep raw bytes for export | must |
| 11 | CP-437 vs UTF-8 ZIP filenames | Honour GP-flag bit 11; CP-437 fallback | nice |
| 12 | Unicode NFC/NFD inconsistencies in SSIDs/names | Normalise to NFC for search/display; preserve original for export | nice |
| 13 | Controller version not strict semver (`8.1.127-beta.3`) | Tolerant version parser; string-compare fallback | nice |
| 14 | Gigabyte-scale stat collections | Stream-parse, mmap input, lazy-load stat collections behind opt-in | must |
| 15 | Backup older than v5.x with legacy collection schema | Detect `version`; warn "legacy schema may have missing fields" | nice |
| 16 | Autobackup truncated (Cloud Key full disk) | Detect missing gzip trailer; suggest "source filesystem may have been full" | nice |
| 17 | Secrets disclosure (PSKs, RADIUS, admin hashes) | Default-mask in UI; explicit reveal; never write to `Console.app` | must |
| 18 | User-renamed `.unf` → `.txt` (AV workaround) | Sniff by magic, not extension | must |
| 19 | `.unifi` superset opened by mistake | Detect, label, offer to extract embedded `.unf` if feasible (v2+) | nice |
| 20 | `format` field bumped without schema change (or vice-versa) | Display only; never gate parsing on `format` value | nice |
| 21 | BSON over-16 MB document (rare in stats) | Streaming reader with no per-doc allocation cap | nice |
| 22 | Embedded null bytes in user notes/aliases | Preserve in raw export, escape for UI display | nice |
| 23 | Windows-built `system.properties` with `\\` escapes | Use a real properties parser (handles escapes) | nice |
| 24 | Self-hosted vs Cloud Key vs UDM origin | Surface as metadata badge from `system.properties` | nice |
| 25 | Force-cast/optional-bang anywhere in parser | Compile-error policy: parser is `throws`-based, no `!` | must |
| 26 | Unknown / never-seen collection appears | Treat as opaque; show its document tree without strong typing | must |

## 7. Implementation Recipe (validated against three reference impls)

```swift
// Pseudocode — full code in UniFiBackupKit Swift package.
let cipher = Data(contentsOf: unfURL)
guard cipher.count % 16 == 0 else { throw .truncatedAtBlockBoundary }

// AES-128-CBC NoPadding via CommonCrypto (CryptoKit lacks raw CBC).
let plain = try CCCrypt(decrypt, AES, options: 0,
    key:  Array("bcyangkmluohmars".utf8),
    iv:   Array("ubntenterpriseap".utf8),
    data: cipher)

guard plain.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { throw .notZip }

// Tolerant ZIP read — fallback to scan-forward on EOCD failure.
let entries = try TolerantZIP.read(plain)
let version = String(bytes: entries["version"]!, encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    .replacingOccurrences(of: "\u{FEFF}", with: "")

// Gunzip db.gz → walk concatenated BSON stream w/ collection markers.
let dbBytes = try Gzip.decompress(entries["db.gz"]!)
var collections: [String: [BSONDocument]] = [:]
var current = "_unknown"
var cursor = 0
while cursor < dbBytes.count {
    let len = Int(dbBytes.readInt32LE(at: cursor))
    guard len >= 5, cursor + len <= dbBytes.count else { throw .bsonOverrun(at: cursor) }
    let doc = try BSON.parse(dbBytes[cursor..<cursor+len])
    if doc.fields.count == 1, let name: String = doc["collection"] {
        current = name
    } else {
        collections[current, default: []].append(doc)
    }
    cursor += len
}
```

## 8. Open Questions for the User

1. **Sample corpus.** Phase 2 cannot proceed without real `.unf` files
   spanning multiple controller versions. Please drop them under `fixtures/`
   (gitignored) and add provenance to `fixtures/MANIFEST.md`. Ideal coverage:
   one v5.x, one v6.x or v7.x, one v8.x, one current v9.x, plus a Site Export
   if you have one and ideally a `.unifi` superset for the detect-and-decline
   path.
2. **AI-friendly export bias.** Is the typical downstream LLM Claude
   (Anthropic), GPT, or local? This affects token-budget targets in the export
   layer (we'll default to ~8k tokens / collection-slice if unspecified).
3. **Secret redaction default.** "Always redact PSKs/RADIUS/x_shadow on
   export unless toggled off" — agree as default? (Strongly recommended.)

## Source Index (consolidated)

### Decryption / format
- https://github.com/zhangyoufu/unifi-backup-decrypt
- https://github.com/zhangyoufu/unifi-backup-decrypt/issues/2
- https://github.com/Darknetzz/UniFi-Backup-Explorer
- https://github.com/ThatKalle/unifi-reserata
- https://github.com/ChrisBHammond/UnifiUNFDecoder
- https://github.com/rapid7/metasploit-framework/blob/master/modules/post/multi/gather/ubiquiti_unifi_backup.rb
- https://gist.github.com/darrenpmeyer/44f853ac52201fff046c1146acaaac64
- https://www.incredigeek.com/home/extract-unifi-unf-backup-file/

### BSON / MongoDB
- https://bsonspec.org/spec.html
- https://github.com/mongodb/mongo-tools/blob/master/mongodump/metadata_dump.go
- https://github.com/orlandos-nl/BSON
- https://github.com/tayloraswift/swift-bson
- https://github.com/mongodb/swift-bson
- https://rmoff.net/2018/03/27/cloning-ubiquitis-mongodb-instance-to-a-separate-server/

### Schema / domain
- https://github.com/Art-of-WiFi/UniFi-API-client
- https://gist.github.com/AmazingTurtle/e8a68a0cbe501bae15343aacbf42a1d8
- https://help.ui.com/hc/en-us/articles/205202580
- https://help.ui.com/hc/en-us/articles/360008976393-Backups-and-Migration-in-UniFi

### Failure modes / community
- https://community.ui.com/questions/unf-controller-backup-file-format/3086d8d7-6be8-428f-8462-512179e53c39
- https://community.ui.com/questions/UDM-Pro-backup-unf-or-unifi-i-cant-get-a-unifi-file/591a1be5-ac9c-49c9-94b0-d30eb2fbacf4
- https://community.ui.com/questions/Unable-to-Restore-Unifi-Controller-due-to-Version-Mismatch/55d44f0f-078b-448c-817c-51c914b2d400
- https://community.ui.com/questions/UCK2-to-UDM-Pro-Migration-Stuck-with-backup-restore-due-to-network-application-backup-version-misma/068e8ab9-968e-4280-a4f9-3c4f45d814c3
- https://community.ui.com/questions/UniFi-network-controller-errors-and-corrupted-backups/9b4f834b-204a-4a09-88cd-9ea3ea3948d5
- https://community.ui.com/questions/unf-is-not-a-valid-backup/ad38e716-0aca-49be-a028-a57a369385c9
- https://help.cloudunifi.com/unifi/migrating-sites-with-site-export-wizard/
- https://forums.lawrencesystems.com/t/decrypt-inspect-unifi-backups-in-your-browser/20591
- https://www.unihosted.com/tools/backup-explorer
