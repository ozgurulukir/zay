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
as two reproducible patch files. The **single source of truth** for their file
names, apply order, gated targets, and required `ZAY-LOCAL-PATCH` marker counts
is `tools/vendor-patches/manifest.txt`; the configure-time build gate, both
helpers below, and the release workflow all read it — do not restate that
metadata anywhere else.

### Linux and macOS (or Git Bash/WSL)

```bash
bash tools/apply-vaxis-patches.sh
```

Pass the vaxis directory printed by the build failure when it is resolved from
Zig's global cache instead of `zig-pkg/`:

```bash
bash tools/apply-vaxis-patches.sh "/path/from/the-build-error"
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

Both helpers are safe to re-run. For each manifest row, in order, they:

- delete stale `*.rej`/`*.orig` files, then **skip the row** when its gated
  targets already hold the required markers (idempotent no-op);
- otherwise apply with `patch -N -t -F 3 -p1` (the fuzz absorbs a few moved
  context lines), falling back to `git apply -p1` and then
  `git apply --3way` (a vaxis git checkout only);
- **hard-fail immediately** if any attempt leaves a `.rej` file — the tree is
  half-patched and must never pass verification. The message prints the `.rej`
  paths and points at "Bumping vaxis" below;
- verify every gated target's marker count before returning success.

You can verify the expected guards yourself, deriving the targets from the
manifest:

```bash
VAXIS_DIR="/path/to/vendored/vaxis"
while IFS='|' read -r p targets label; do
  case "$p" in ''|'#'*) continue;; esac
  # per-field trim: the format contract forbids padding, the parser tolerates it
  p=$(echo "$p" | xargs); targets=$(echo "$targets" | xargs); label=$(echo "$label" | xargs)
  IFS=',' read -ra pairs <<< "$targets"
  for pair in "${pairs[@]}"; do
    f="${pair%%=*}"; n="${pair##*=}"
    c=$(grep -c ZAY-LOCAL-PATCH "$VAXIS_DIR/$f")
    test "$c" -ge "$n" || echo "FAIL $f: found $c, need $n ($label)"
  done
done < tools/vendor-patches/manifest.txt
```

## Bumping vaxis

When `build.zig.zon`'s vaxis pin changes, the guards must be re-ported and the
patch files regenerated. The semantic port is manual (a human decides where each
guard lands in drifted code); the mechanical diff/verify shell is below.

```bash
# 1. Update the pin in build.zig.zon, then fetch — zig-pkg/<hash-from-zon>
#    is a PRISTINE copy of the new revision (option B: git clone + checkout
#    <new-pin-sha> into a scratch dir).
zig build --fetch
PRISTINE="zig-pkg/$(sed -n 's/.*\.hash = "\(vaxis-[^"]*\)".*/\1/p' build.zig.zon | head -n1)"
# 2. Work copy; hand-port each guard from the old patch's '+' lines
#    (or: patch -R the old patch on a copy of the drifted tree when only
#    context lines moved) until every manifest target holds its count.
#    DERIVE the patch's target files from the manifest (field 2) — never
#    restate them by hand:
INPUT_PATCH=vaxis-input-thread-retry.patch   # example: the multi-file patch
FILES=$(awk -F'|' -v p="$INPUT_PATCH" '$1 ~ p { gsub(/ /, "", $2); split($2, a, ","); for (i in a) print substr(a[i], 1, index(a[i], "=") - 1) }' tools/vendor-patches/manifest.txt)
#    Regenerate PER PATCH: each patch gets its own scratch repo + diff
#    scoped to exactly its manifest files. If one work tree holds both
#    patches' guards, path-scoping (`git diff -- <files>`) still splits them
#    correctly; when in doubt use two work copies.
cp -r "$PRISTINE" /tmp/vaxis-work
# 3. Regenerate with `git diff` in a SCRATCH REPO — the PRIMARY recipe.
#    Why NOT plain `diff -u --label`: it drops the `diff --git`/`index`
#    headers the current patches carry, killing `git apply`/`--3way`. Why NOT
#    `git diff --no-index`: it emits the paths AS SUPPLIED —
#      `diff --git a/pristine/src/... b/work/src/...`
#    — so `patch -p1`/`git apply -p1` would look for `pristine/src/...` and
#    the regenerated patch is NOT applicable to the vendored dir. A scratch
#    repo gives correct tree-relative headers `a/src/... b/src/...` PLUS real
#    `index` lines:
#
#    a. Stage the PRISTINE files at their tree-relative paths (from $FILES):
SCRATCH=$(mktemp -d)
git init -q "$SCRATCH"
for f in $FILES; do
  mkdir -p "$SCRATCH/$(dirname "$f")"
  cp "$PRISTINE/$f" "$SCRATCH/$f"
done
git -C "$SCRATCH" add -A
git -C "$SCRATCH" -c user.name=patch-regen -c user.email=noreply@local commit -qm pristine
#    b. Overwrite with the hand-fixed work copy — the SAME $FILES set for
#       THIS patch only. A multi-file patch (src/Loop.zig + src/tty.zig)
#       keeps both in the scratch repo so ONE `git diff` emits the combined
#       patch.
for f in $FILES; do
  cp "/tmp/vaxis-work/$f" "$SCRATCH/$f"
done
#    c. Emit. Scope the diff to THIS patch's files — if the work copy also
#       contains the OTHER patch's guards, path-scoping keeps each named
#       .patch file free of foreign changes:
#         focus patch: git -C "$SCRATCH" diff -- src/vxfw/App.zig
#         input patch: git -C "$SCRATCH" diff -- src/Loop.zig src/tty.zig
#       NOTE: `git diff` exits 1 when files differ — append `|| true`.
{ echo "# Zay local patch: <re-attach the header comment block from the old patch>";
 git -C "$SCRATCH" -c core.autocrlf=false diff -- $FILES || true; } > "tools/vendor-patches/$INPUT_PATCH"
#    Result headers: `diff --git a/src/vxfw/App.zig b/src/vxfw/App.zig`,
#    `index <pristine-blob>..<work-blob> 100644`, `--- a/... +++ b/...` —
#    `-p1`-applicable against the vendored dir AND `--3way`-capable (the
#    `index` lines hash the PRISTINE blobs). Result headers show ONLY this
#    patch's files.
#    d. Line endings: keep the .patch file LF-only. On Windows git warns
#    "LF will be replaced by CRLF" (core.autocrlf); the Zig/PS parsers are
#    \r-tolerant but `patch` context matching is NOT — regenerate with
#    `git -c core.autocrlf=false diff ...` (or gitattributes `*.patch -text`)
#    and verify the committed file has no CRLF: `file tools/vendor-patches/*.patch`
#    or `grep -c $'\r' <patch>` must be 0.
# 4. Verify: run the applier against a FRESH pristine copy — exit 0, no
#    *.rej, marker counts match the manifest, headers are tree-relative and
#    scoped to only this patch's files — then `zig build` passes its
#    configure gate.
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
vaxis, then runs `bash tools/apply-vaxis-patches.sh`, which reads
`tools/vendor-patches/manifest.txt` and verifies every `ZAY-LOCAL-PATCH` guard
before compiling. See [Releasing](RELEASING.md) for the tag and artifact
workflow.

## Troubleshooting

- **The error shows a path outside the repository:** pass that exact path as
  the helper argument (`bash tools/apply-vaxis-patches.sh "<path>"` or
  `.\tools\apply-vaxis-patches.ps1 -VaxisDir "<path>"`); Zig is resolving the
  dependency from its global cache.
- **`patch` reports that a hunk is already applied:** do not force it. The
  helper detects existing guards and applies only the missing patch.
- **A hunk cannot be applied:** the pinned vaxis revision has drifted. Follow
  [Bumping vaxis](#bumping-vaxis) to re-port the guards and regenerate the
  patch; the helper also prints this pointer when it leaves a `.rej` file.
- **The build still reports missing markers:** the patch was applied to a
  different vaxis directory than the one used by the build. Use the path from
  the latest build error and re-run the helper with it.
