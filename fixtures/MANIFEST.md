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
