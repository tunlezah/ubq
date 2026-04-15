# Fixture Manifest

Real `.unf` backup samples live in this directory and are **gitignored** to avoid
committing private network configuration data. Synthetic, hand-crafted
fixtures used by unit tests live under `fixtures/synthetic/` and **are**
committed.

When adding a real sample, append a row below documenting:

| File | Controller version | Source / provenance | Encryption | Notes |
|------|--------------------|---------------------|------------|-------|
| _example_unifi-os-9.0.108.unf_ | UniFi Network 9.0.108 (UniFi OS) | Self-captured | Yes (AES) | Multi-site, ~12 devices |

Keep notes here whenever a sample exposes a new edge case (a collection your
parser hadn't seen, a version variant, an encoding quirk).

## Why no public fixtures are committed

A Phase 1 fixture hunt (see `RESEARCH.md`) confirmed that **no public `.unf`
test fixtures exist** in the ecosystem. Every decryption-tool repo
(zhangyoufu, Darknetzz, ThatKalle, ChrisBHammond) deliberately omits sample
backups because the static AES key makes every `.unf` a potential leak of
SSIDs, WPA PSKs, RADIUS secrets, and admin password hashes. Any `.unf` you
find in the wild should be treated as an inadvertent leak, not a sanitised
fixture.

Instead, this project covers its deterministic test surface via **synthetic
fixtures constructed programmatically in Swift** (see ADR-013 in
`DECISIONS.md` and the `Tests/Fixtures/Synthetic/` target in
`UniFiBackupKit`). Real-world samples live here only when the user provides
them; they augment but never replace the synthetic corpus.

### Generating your own clean fixtures

If you want to grow the real-world corpus:

1. Run `linuxserver/docker-unifi-network-application` or `jacobalberty/unifi`
   in Docker.
2. Adopt a single virtual device, set SSID `TEST-FIXTURE-N` and PSK
   `testtesttest`, add a few dummy WLANs and firewall rules.
3. Download the backup from Settings → System → Backup.
4. Drop the file into this directory and add a manifest row above.
5. Repeat across controller versions (7.5.x, 8.0.x, 8.6.x, 9.0.x, 9.5.x) to
   cover known format boundaries.
