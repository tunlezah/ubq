# `.unf` File Format Reference

A clean, implementation-oriented description of the UniFi Network Controller
`.unf` backup file format. Distilled from `RESEARCH.md`. Read this once and
you have everything needed to build a parser. Companion: `RESEARCH.md` for
sources and the long-form derivation.

```
+----------------------------------------------------------------+
|  .unf file (one or more 16-byte AES blocks, no header)         |
|                                                                |
|   AES-128-CBC, NoPadding                                       |
|   key = "bcyangkmluohmars"   (16 ASCII bytes)                  |
|   IV  = "ubntenterpriseap"   (16 ASCII bytes)                  |
|                                                                |
|   v  decrypt                                                   |
|                                                                |
|  +----------------------------------------------------------+  |
|  |  ZIP archive (often with malformed EOCD / data-desc)     |  |
|  |                                                          |  |
|  |   version           plain ASCII, "8.0.24"                |  |
|  |   format            plain ASCII int, "7"   (sometimes)   |  |
|  |   timestamp         epoch ms OR ISO-8601 Z               |  |
|  |   system.properties Java properties, configuration       |  |
|  |   db.gz             gzipped concatenated BSON stream     |  |
|  |   db_stat.gz        gzipped concatenated BSON stream     |  |
|  |   sites/            optional per-site assets             |  |
|  |                                                          |  |
|  |   v  gunzip db.gz / db_stat.gz                           |  |
|  |                                                          |  |
|  |  +----------------------------------------------------+  |  |
|  |  | { collection: "site" }     ← marker                |  |  |
|  |  | { _id, name, desc, ... }                           |  |  |
|  |  | { _id, name, desc, ... }                           |  |  |
|  |  | { collection: "device" }   ← marker                |  |  |
|  |  | { _id, mac, model, ... }                           |  |  |
|  |  |  ...                                               |  |  |
|  |  +----------------------------------------------------+  |  |
|  +----------------------------------------------------------+  |
+----------------------------------------------------------------+
```

## Layer 1: AES Wrapper

| Field | Value |
|---|---|
| Algorithm | AES-128 |
| Mode | CBC |
| Padding | **None** (zero-padding semantics; trailing bytes are tolerated by the inner ZIP reader) |
| Key | `bcyangkmluohmars` — 16 raw ASCII bytes (hex `62 63 79 61 6e 67 6b 6d 6c 75 6f 68 6d 61 72 73`) |
| IV | `ubntenterpriseap` — 16 raw ASCII bytes (hex `75 62 6e 74 65 6e 74 65 72 70 72 69 73 65 61 70`) |
| Magic header | None — file is pure ciphertext from offset 0 |
| Auth tag | None — format is unauthenticated |
| Length invariant | Ciphertext length is always a multiple of 16 |

Identity check after decrypt: first four plaintext bytes are
`50 4B 03 04` (ZIP local-file-header signature, ASCII `PK\x03\x04`).

The key and IV have not changed across UniFi Network Application v5.10
through v9.5.21 (latest verified, December 2025). They are also reused
verbatim by the `.supp` support-bundle format.

### Swift recipe

Use `CommonCrypto` (CryptoKit does not expose raw CBC):

```swift
import CommonCrypto

func decryptUNF(_ ciphertext: Data) throws -> Data {
    let key: [UInt8] = Array("bcyangkmluohmars".utf8)
    let iv:  [UInt8] = Array("ubntenterpriseap".utf8)
    guard ciphertext.count % kCCBlockSizeAES128 == 0 else {
        throw UnfError.truncatedAtBlockBoundary(actual: ciphertext.count)
    }
    var out = Data(count: ciphertext.count)
    var moved = 0
    let status: CCCryptorStatus = out.withUnsafeMutableBytes { obuf in
        ciphertext.withUnsafeBytes { ibuf in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                    /* options: NO PKCS7 */ 0,
                    key, key.count, iv,
                    ibuf.baseAddress, ciphertext.count,
                    obuf.baseAddress, out.count, &moved)
        }
    }
    guard status == kCCSuccess else { throw UnfError.decryptFailed(status: status) }
    out.count = moved
    guard out.count >= 4, out[0] == 0x50, out[1] == 0x4B,
          out[2] == 0x03, out[3] == 0x04 else { throw UnfError.notZip }
    return out
}
```

## Layer 2: ZIP Container

The payload is a standard DEFLATE-or-stored ZIP, but routinely emitted with:

- **Streaming data descriptors** (general-purpose-flag bit 3) — local headers
  carry zero CRC/sizes; real values follow the compressed payload.
- **Truncated or absent EOCD record** — random-access readers reject; a
  forward-scanning streaming reader recovers.

You must use a tolerant ZIP reader. ZIPFoundation handles data descriptors;
fall back to scanning forward for `PK\x03\x04` signatures and reading entries
sequentially when the EOCD is unusable. Apple's `Compression` framework
alone is insufficient.

### Expected entries

| Entry | Type | Description |
|---|---|---|
| `version` | text | Controller version that produced the backup, e.g. `8.0.24`. May contain BOM, CRLF, or trailing whitespace — sanitise before parsing. |
| `format` | text | Backup format revision integer (e.g. `7`). Often missing on older builds. Display only; do not gate parsing on this. |
| `timestamp` | text | Either epoch milliseconds (older) or ISO-8601 with `Z` (newer). |
| `system.properties` | Java properties | Lines like `unifi.version=8.0.24`, `db.mongo.uri=mongodb://localhost:27117/ace`, `inform.host=…`. Use a real properties parser to handle backslash escapes (`\\` paths from Windows controllers). |
| `db.gz` | gzip → BSON stream | Primary configuration database (`ace`). See Layer 3. |
| `db_stat.gz` | gzip → BSON stream | Statistics database (`ace_stat`). Often huge. Lazy-load. |
| `sites/<siteId>/…` | misc | Per-site overrides: `config.gateway.json`, captive-portal HTML, floor-plan images. |

## Layer 3: Concatenated BSON Stream

After gunzipping `db.gz` / `db_stat.gz` you get a **single byte sequence of
length-prefixed BSON documents** — not the per-collection `<name>.bson +
<name>.metadata.json` layout that `mongodump` produces.

Logical collections are separated by **marker documents** of shape
`{ collection: "<name>" }`. Every subsequent document until the next marker
belongs to that collection.

### Reader algorithm

```
cursor = 0
currentCollection = "_unknown"
while cursor < buf.count:
    docLen = readInt32LE(buf, cursor)
    require 5 <= docLen <= 16*1024*1024
    require cursor + docLen <= buf.count
    doc = parseBSON(buf[cursor ..< cursor + docLen])
    if doc.fields == ["collection"] and doc["collection"] is String:
        currentCollection = doc["collection"]
    else:
        emit(currentCollection, doc)
    cursor += docLen
```

Stream-friendly: process documents one at a time; never materialise the
entire stat database in memory.

### BSON type codes you must support (UniFi-essential subset)

| Code | Type | Notes |
|---|---|---|
| `0x01` | double | IEEE 754 LE 8 bytes |
| `0x02` | string | int32 length (incl. trailing NUL) + UTF-8 + `\0` |
| `0x03` | embedded document | recurse |
| `0x04` | array | document with numeric string keys "0","1",… |
| `0x05` | binary | int32 length + 1-byte subtype + bytes (subtypes 0x00 generic and 0x04 UUID seen) |
| `0x07` | ObjectId | 12 raw bytes |
| `0x08` | bool | 1 byte (0/1) |
| `0x09` | UTC datetime | int64 ms since epoch |
| `0x0A` | null | no payload |
| `0x10` | int32 | 4 bytes LE |
| `0x12` | int64 | 8 bytes LE |

Decode `0x0B` regex and `0x11` timestamp defensively (rare). Decimal128
(`0x13`) and the deprecated codes do not appear.

### `ace` database — collections inventory

| Collection | Purpose | Key fields | Default-load? |
|---|---|---|---|
| `site` | Sites (logical tenants) | `_id`, `name`, `desc` | yes |
| `setting` | Per-site settings panels (one doc = one panel) | `site_id`, `key` | yes |
| `admin` | Controller admins (global) | `_id`, `name`, `email`, `x_shadow` | yes |
| `account` | RADIUS/802.1X accounts | `site_id`, `name`, `x_password`, `vlan` | yes |
| `privilege` | admin↔site role mapping | `admin_id`, `site_id`, `role` | yes |
| `device` | Adopted hardware | `_id`, `site_id`, `mac`, `model`, `type`, `version`, `port_overrides`, `radio_table`, `name` | yes |
| `user` | Known clients (MAC objects) | `_id`, `site_id`, `mac`, `hostname`, `name`, `is_guest`, `usergroup_id`, `fixed_ip`, `network_id` | yes |
| `usergroup` | Bandwidth/QoS groups | `site_id`, `name`, `qos_rate_max_up`, `qos_rate_max_down` | yes |
| `wlanconf` | WLAN/SSID configurations | `site_id`, `name` (SSID), `x_passphrase` (PSK), `security`, `wpa_mode`, `vlan`, `enabled`, `is_guest`, `wlangroup_id` | yes |
| `wlangroup` | WLAN groups assigned to APs | `site_id`, `name` | yes |
| `networkconf` | L2/L3 networks (VLANs, WAN, VPN) | `site_id`, `name`, `purpose`, `vlan`, `ip_subnet`, `dhcpd_*`, `is_nat` | yes |
| `portconf` | Switch port profiles | `site_id`, `name`, `native_networkconf_id`, `forward`, `poe_mode` | yes |
| `portforward` | Gateway NAT port forwards | `site_id`, `name`, `fwd`, `src`, `proto`, `dst_port`, `fwd_port`, `enabled` | yes |
| `firewallrule` | L3 firewall rules | `site_id`, `name`, `ruleset`, `rule_index`, `action`, `protocol`, `enabled` | yes |
| `firewallgroup` | Address/port groups | `site_id`, `name`, `group_type`, `group_members` | yes |
| `routing` | Static / policy routes | `site_id`, `name`, `static_network`, `static_next_hop`, `enabled` | yes |
| `dpiapp` / `dpigroup` | DPI app definitions | `site_id`, `name`, `apps[]`, `category_ids[]` | yes |
| `apgroup` | AP groupings | `site_id`, `name`, `device_macs[]` | yes |
| `radiusprofile` | External RADIUS profiles | `site_id`, `name`, `auth_servers[]`, `acct_servers[]` | yes |
| `hotspotop` | Captive-portal operators | `site_id`, `name`, `x_password` | yes |
| `voucher` | Hotspot vouchers | `site_id`, `code`, `duration`, `quota` | optional |
| `guest` | Guest authorisation ledger | `site_id`, `mac`, `start`, `end` | optional |
| `tag` | User/device tags | `site_id`, `name`, `member_table[]` | yes |
| `broadcastgroup` | Wake-on-WAN groups | `site_id`, `name`, `member_table[]` | yes |
| `scheduletask` | Scheduled actions | `site_id`, `cron_*`, `type` | yes |
| `dashboard` | Saved dashboard layouts | `_id`, `admin_id`, `widgets[]` | optional |
| `map` / `heatmap` / `heatmappoint` | Floor-plan + heatmap data | `site_id`, `name`, image refs | optional |
| `verification` | TOTP secrets | `admin_id`, `secret`, `backup_codes` | yes (mask by default) |
| `alarm` | Persisted alarms | `site_id`, `key`, `msg`, `time`, `archived` | optional |
| `event` | Rolling event log | `site_id`, `key`, `msg`, `time` | **opt-in** (large) |

Unknown collections **must** be tolerated and surfaced as opaque. UniFi adds
and renames collections across versions; the parser must never hardcode.

### `ace_stat` database — collections inventory

| Collection | Granularity | Default-load? |
|---|---|---|
| `stat_life` | lifetime counters | optional |
| `stat_monthly` | monthly rollups | optional |
| `stat_daily` | daily rollups | **opt-in** |
| `stat_hourly` | hourly rollups | **opt-in** (large) |
| `stat_5minutes` | 5-minute rollups | **opt-in** (huge) |
| `stat_archive` | long-term aggregates | **opt-in** (huge) |
| `stat_dpi` / `stat_sitedpi` | per-app DPI counters | **opt-in** |
| `stat_payment` / `stat_voucher` | hotspot finance | optional |
| `event_archive` | older events | **opt-in** (huge) |

All `ace_stat` collections share a common shape:
`{ site_id, o: "ap"|"user"|"gw"|"site", oid, time, bytes, tx_bytes, rx_bytes,
   tx_packets, rx_packets, num_sta, ... }`.

## Cross-collection Relationships (for UI joins)

```
site._id ─┐
          ├─ <anything with site_id>
          └─ ...

device.port_overrides[].portconf_id     → portconf._id
device.wlangroup_id                     → wlangroup._id
wlanconf.wlangroup_id                   → wlangroup._id
wlanconf.usergroup_id                   → usergroup._id
user.usergroup_id                       → usergroup._id
user.network_id                         → networkconf._id
firewallrule.src_firewallgroup_ids[]    → firewallgroup._id
firewallrule.dst_firewallgroup_ids[]    → firewallgroup._id
portconf.native_networkconf_id          → networkconf._id
portconf.voice_networkconf_id           → networkconf._id
privilege.admin_id                      → admin._id
privilege.site_id                       → site._id
dpigroup.dpiapp_ids[]                   → dpiapp._id
```

## Format Evolution Across Versions

| Controller | Extension | Notes | Confidence |
|---|---|---|---|
| ~3.x | `.unf` | Same AES wrapper. Single `db.gz`, `version`. No `format`, no `db_stat.gz`. | medium |
| 4.x | `.unf` | Same wrapper. `system.properties` appears. | medium |
| 5.x | `.unf` | `db_stat.gz` split standardised. Verified to v5.10.19 by Metasploit. | high |
| 6.x | `.unf` | Layout stable. `format` file appears in later builds. | high |
| 7.x | `.unf` | Stable. Darknetzz baseline. | very high |
| 8.x | `.unf` | Stable. Filename `autobackup_8.0.24_*.unf` documented. | very high |
| 9.x (2025–2026 current) | `.unf` | Verified to v9.5.21. AES key/IV unchanged. | very high |
| UniFi OS era (2024–2026) | `.unifi` (superset) | Different container; wraps a Network `.unf` plus UCore Postgres. **Out of scope.** | medium-high |

## Identity Check Workflow

```
1. file extension .unf?         ← weak hint; user may have renamed
2. file size % 16 == 0?         ← strict invariant
3. trial AES-CBC NoPadding decrypt with static key/IV
4. plaintext starts with PK\x03\x04?
5. tolerant-ZIP read succeeds, contains `version` and `db.gz`?
   → it's a UniFi Network backup
   → if `format` present, surface as metadata
   → if `admin`/`account` collections missing → label as Site Export
   → if outer file is .unifi (zip with `unifi-os/` etc.) → declare and refuse
```

## Known Quirks To Handle (test cases)

- BOM-prefixed `version` text (Windows-built controllers).
- CRLF line endings in `version` / `timestamp`.
- `timestamp` as epoch ms vs ISO-8601 Z.
- Embedded NUL bytes in `user.note` from copy-paste.
- NFC vs NFD Unicode for SSIDs/device names.
- Emoji SSIDs (valid UTF-8, surprises UI assumptions).
- Renamed collection (`wlanconf` ↔ `wlan_conf` historically).
- Streaming data descriptors in ZIP local headers.
- Pre-1980 timestamps in ZIP entries.
- Truncated `db_stat.gz` while `db.gz` is intact (Cloud Key full disk).
- `system.properties` with `\\` Windows paths needing `java.util.Properties`-
  compatible parsing.
