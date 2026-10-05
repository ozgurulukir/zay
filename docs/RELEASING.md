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
2. Bump `build.zig.zon`'s `.version` to the release version (e.g. `"0.10.7"`)
   and commit it. The release workflow's `version-check` job fails fast when the
   tag (minus its leading `v`) and `.version` disagree, so the package metadata
   cannot drift from the release. A pre-release tag such as `v0.10.8-beta.1`
   needs the matching `"0.10.8-beta.1"` in `.version`.
3. Tag the commit you want to ship and push the tag:

   ```bash
   git tag v0.10.7
   git push origin v0.10.7
   ```

4. The `release` workflow builds `ReleaseFast` binaries for **Linux**,
   **Windows**, and **macOS** on native runners — the Linux and Windows entries
   are cross-targeted to `x86_64-linux-musl` and `x86_64-windows`, while macOS
   builds for its own host triple. Each build embeds the tag as the version,
   computes SHA-256 checksums, and creates a GitHub Release with all three
   binaries and their `.sha256` files attached.

### Pre-releases

A tag containing `-` is treated as a pre-release and the resulting GitHub
Release is marked **pre-release**:

```bash
git tag v0.10.8-beta.1
git push origin v0.10.8-beta.1
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

## Portability checks before tagging

- **Release CI builds macOS and Windows — verify portability before tagging.** `release.yml` publishes on any `v*` tag push, so a POSIX-portability slip breaks the release after the fact (2026-09-12: `std.posix.kill(pid, 0)` in `src/os.zig` — a `comptime_int` does not coerce to libc's translated `SIG` enum on macOS; invisible in native builds because the non-Linux arm is never analyzed on Linux). Before tagging changes to OS-layer code (`src/os.zig` etc.), force cross-target semantic analysis: `zig test -target aarch64-macos -lc --test-no-exec src/<file>.zig` and `zig test -target x86_64-windows --test-no-exec src/<file>.zig` (plain `zig build-obj` is NOT enough — lazy analysis skips everything). `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast` full-graph cross-compiles locally, but macOS cannot link locally (no SDK frameworks) — only analysis checks are possible there. If a release run fails before publishing, re-point the tag (`git push origin :refs/tags/vX.Y.Z`, delete local, re-tag at the fix, push) rather than re-running the workflow. See [Cutting a release](#cutting-a-release) for the tagging process.
