# Building Zay from source

This guide is for people who want to compile Zay locally. If you only want to
run Zay, use a release binary or one of the installers described in the root
README.

## Requirements

- Zig 0.16.0
- Git 2.20 or newer
- Bash or PowerShell 7+
- Network access for the first dependency fetch
- On Windows, Git for Windows (the PowerShell helper uses its bundled
  `patch.exe`)

## Clone and fetch dependencies

```bash
git clone https://github.com/ozgurulukir/zay.git
cd zay
zig build --fetch
```

On a pristine checkout, the last command can stop with a message saying that
the vendored vaxis copy is missing `ZAY-LOCAL-PATCH` guards. That is expected:
Zig has fetched the pinned upstream dependency, and Zay deliberately refuses to
compile it until the two local patches have been applied. If the command fails
for a network or dependency-resolution error instead, fix that error first.

## Apply the pinned vaxis patches

The vaxis dependency is fetched pristine and lives outside the tracked source
tree (`zig-pkg/` or Zig's global package cache). Zay keeps the required changes
as two reproducible patch files:

- `tools/vendor-patches/vaxis-focus-handler.patch` protects session switches
  from an empty focus path.
- `tools/vendor-patches/vaxis-input-thread-retry.patch` keeps the Windows input
  thread alive and wakes it reliably during shutdown; it also drops repeated
  standalone modifier records so a held Ctrl key cannot starve TUI timers.

### Linux and macOS (or Git Bash/WSL)

Use the vaxis directory printed by the build failure:

```bash
VAXIS_DIR="/path/from/the-build-error"
patch -p1 -d "$VAXIS_DIR" < tools/vendor-patches/vaxis-focus-handler.patch
patch -p1 -d "$VAXIS_DIR" < tools/vendor-patches/vaxis-input-thread-retry.patch
```

### Windows PowerShell

PowerShell users do not need WSL or Git Bash. Run the checked-in helper from
the repository root:

```powershell
.\tools\apply-vaxis-patches.ps1
```

If the build printed a dependency path outside `zig-pkg`, pass that exact path:

```powershell
.\tools\apply-vaxis-patches.ps1 -VaxisDir "C:\path\from\the-build-error"
```

The helper is safe to re-run: it detects existing guards, applies only the
missing patch, and verifies both marker counts before returning success. The
patches are additive, so applying them to the resolved vaxis copy does not
modify Zay's tracked files.

You can verify the expected guards before rebuilding:

```bash
test "$(grep -c ZAY-LOCAL-PATCH "$VAXIS_DIR/src/vxfw/App.zig")" -eq 2
test "$(grep -c ZAY-LOCAL-PATCH "$VAXIS_DIR/src/Loop.zig")" -eq 4
```

## Build, test, and install

After the patches are applied, the normal commands work:

```bash
zig build
zig build test
zig build install -Doptimize=ReleaseFast --prefix "$HOME/.local"
```

The configure step checks the patch markers on every build. If a later
`zig build --fetch`, cache cleanup, or vaxis revision change replaces the
dependency with a pristine copy, re-apply both patches before building again.

The release workflow performs this same sequence automatically: it fetches
vaxis, applies both checked-in patches, verifies the marker counts, and then
builds the release binaries. See [Releasing](RELEASING.md) for the tag and
artifact workflow.

## Troubleshooting

- **The error shows a path outside the repository:** use that exact path as
  `VAXIS_DIR`; Zig is resolving the dependency from its global cache.
- **`patch` reports that a hunk is already applied:** do not force it. Check
  the marker counts above; the dependency may already be patched.
- **A hunk cannot be applied:** confirm that the pinned vaxis revision from
  `build.zig.zon` is in use. A vaxis revision change requires reviewing and
  updating the checked-in patch before shipping it.
- **The build still reports missing markers:** the patch was applied to a
  different vaxis directory than the one used by the build. Use the path from
  the latest error and verify the counts again.
