# Releasing Nova

Nova ships as a single Zig binary. Cutting a release is a one-command operation:
tag the commit and push the tag — GitHub Actions does the rest.

## Versioning

The version is the **git tag** (the single source of truth). It is embedded into
the binary at build time and surfaced by `nova --version` and the settings
panel's About tab.

- **Release builds** (`.github/workflows/release.yml`) pass `-Dversion=<tag>`
  explicitly, so the binary reports exactly the tag.
- **Local builds** fall back to `git describe --tags --always --dirty`
  (e.g. `v0.2.0-beta.2-55-g338b78c-dirty`), or `dev` when git is unavailable or
  the directory is not a repo.

`nova --version` prints `nova <version>` and exits.

## Cutting a release

1. Make sure `main` is green (`zig build test`).
2. Tag the commit you want to ship and push the tag:

   ```bash
   git tag v0.3.0
   git push origin v0.3.0
   ```

3. The `release` workflow builds `ReleaseFast` binaries for **Windows** and
   **Linux** on native runners, embeds the tag as the version, computes SHA-256
   checksums, and creates a GitHub Release with both binaries and their
   `.sha256` files attached.

### Pre-releases

A tag containing `-` is treated as a pre-release and the resulting GitHub
Release is marked **pre-release**:

```bash
git tag v0.3.1-beta.1
git push origin v0.3.1-beta.1
```

## What the workflow produces

- `nova-linux-x86_64` + `nova-linux-x86_64.sha256`
- `nova-windows-x86_64.exe` + `nova-windows-x86_64.exe.sha256`

Verify a downloaded asset with:

```bash
sha256sum -c nova-linux-x86_64.sha256
./nova-linux-x86_64 --version   # prints the tag
```

## One-Line Installers

Users can install the latest release directly via the root installer scripts:

- **Linux / macOS:** `curl -fsSL https://raw.githubusercontent.com/ozgurulukir/nova-agent/main/install.sh | bash`
- **Windows (PowerShell):** `irm https://raw.githubusercontent.com/ozgurulukir/nova-agent/main/install.ps1 | iex`

The scripts automatically download the platform binary, verify the SHA256 checksum, place it in the user's PATH, and make it executable.

## Notes

- The workflow downloads Zig 0.16.0 directly from
  `ziglang.org/download/0.16.0/` (the `mlugg/setup-zig` action 404s on 0.16.0)
  and builds with `shell: bash` + a `VERSION` env var (PowerShell mangles dotted
  versions).
- Release notes are auto-generated from merged PRs
  (`generate_release_notes: true`).
