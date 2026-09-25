# Releasing Zay

Zay ships as a single Zig binary. Cutting a release is a one-command operation:
tag the commit and push the tag — GitHub Actions does the rest.

## Versioning

The version is the **git tag** (the single source of truth). It is embedded into
the binary at build time and surfaced by `zay --version` and the settings
panel's About tab.

- **Release builds** (`.github/workflows/release.yml`) pass `-Dversion=<tag>`
  explicitly, so the binary reports exactly the tag.
- **Local builds** fall back to `git describe --tags --always --dirty`
  (e.g. `v0.3.0-5-g338b78c-dirty`), or `dev` when git is unavailable or
  the directory is not a repo.

`zay --version` prints `zay <version>` and exits.

## Cutting a release

1. Make sure `main` is green (`zig build test`).
2. Bump `build.zig.zon`'s `.version` to the release version (e.g. `"0.9.11"`)
   and commit it. The release workflow's `version-check` job fails fast when the
   tag (minus its leading `v`) and `.version` disagree, so the package metadata
   cannot drift from the release. A pre-release tag such as `v0.9.12-beta.1`
   needs the matching `"0.9.12-beta.1"` in `.version`.
3. Tag the commit you want to ship and push the tag:

   ```bash
   git tag v0.3.0
   git push origin v0.3.0
   ```

4. The `release` workflow builds `ReleaseFast` binaries for **Windows** and
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

- `zay-linux-x86_64` + `zay-linux-x86_64.sha256`
- `zay-linux-x86_64.debug` + `zay-linux-x86_64.debug.sha256` (Linux debug sidecar —
  the workflow splits ~24 MB of DWARF out of the stripped ELF via `objcopy`, with a
  `.gnu_debuglink` CRC pointing at the sidecar so crash traces stay symbolizable)
- `zay-windows-x86_64.exe` + `zay-windows-x86_64.exe.sha256` (PE ships debug info in a
  sidecar natively)
- `zay-macos-aarch64` + `zay-macos-aarch64.sha256` (Apple Silicon; built on `macos-latest`)

Verify a downloaded asset with:

```bash
sha256sum -c zay-linux-x86_64.sha256
./zay-linux-x86_64 --version   # prints the tag
```

## One-Line Installers

Users can install the latest release directly via the root installer scripts:

- **Linux / macOS:** `curl -fsSL https://raw.githubusercontent.com/ozgurulukir/zay/main/install.sh | bash`
- **Windows (PowerShell):** `irm https://raw.githubusercontent.com/ozgurulukir/zay/main/install.ps1 | iex`

The scripts automatically download the platform binary, verify the SHA256 checksum, place it in the user's PATH, and make it executable.

## Notes

- The workflow downloads Zig 0.16.0 directly from
  `ziglang.org/download/0.16.0/` (the `mlugg/setup-zig` action 404s on 0.16.0)
  and builds with `shell: bash` + a `VERSION` env var (PowerShell mangles dotted
  versions).
- Before building, the workflow fetches the pinned libvaxis revision, which
  already contains the upstream fixes previously carried as local patches.
- Release notes are auto-generated from merged PRs
  (`generate_release_notes: true`).
