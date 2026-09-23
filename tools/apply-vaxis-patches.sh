#!/usr/bin/env bash
# Manifest-driven applier for the vendored-vaxis `ZAY-LOCAL-PATCH` guards.
#
# POSIX counterpart to tools/apply-vaxis-patches.ps1. Both read
# tools/vendor-patches/manifest.txt (the single source of truth for patch files,
# gated targets, apply order, and required marker counts), resolve the fetched
# vaxis copy, apply each patch with a fuzz/`git apply` fallback chain, and verify
# the per-target marker counts. Re-running is a no-op once the guards are present.
#
# Usage: bash tools/apply-vaxis-patches.sh ["<vaxis-dir>"]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_ROOT="$REPO_ROOT/tools/vendor-patches"
MANIFEST="$PATCH_ROOT/manifest.txt"

# Trims leading/trailing whitespace without spawning a command.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

marker_count() {
  local file="$1" count
  if [ ! -f "$file" ]; then
    printf '0'
    return 0
  fi
  count="$(grep -c 'ZAY-LOCAL-PATCH' "$file" || true)"
  printf '%s' "${count:-0}"
}

# Emits "<path>\t<required>" for each comma-separated pair in a manifest target
# field. Malformed pairs abort the whole script (fail fast at the boundary).
iter_targets() {
  local targets="$1" pair path count
  IFS=',' read -ra pairs <<< "$targets"
  for pair in "${pairs[@]}"; do
    pair="$(trim "$pair")"
    if [ -z "$pair" ] || [ "${pair#*=}" = "$pair" ]; then
      echo "malformed manifest target '$pair' (expected 'path=count')" >&2
      exit 1
    fi
    path="$(trim "${pair%%=*}")"
    count="$(trim "${pair##*=}")"
    if [ -z "$path" ] || [ -z "$count" ]; then
      echo "malformed manifest target '$pair' (empty path or count)" >&2
      exit 1
    fi
    case "$count" in
      '' | *[!0-9]*)
        echo "malformed marker count '$count' (expected an integer)" >&2
        exit 1
        ;;
    esac
    printf '%s\t%s\n' "$path" "$count"
  done
}

# Manifest rows (parallel arrays; field 2 comma-split lazily via iter_targets).
PATCH_FILES=()
PATCH_TARGETS=()
PATCH_LABELS=()

parse_manifest() {
  if [ ! -f "$MANIFEST" ]; then
    echo "Vendor patch manifest not found: $MANIFEST" >&2
    exit 1
  fi
  local line=0 raw trimmed f1 f2 f3 f4 patch_file targets label
  while IFS= read -r raw || [ -n "$raw" ]; do
    line=$((line + 1))
    trimmed="$(trim "$raw")"
    [ -z "$trimmed" ] && continue
    case "$trimmed" in
      \#*) continue ;;
    esac
    # Field 1 is the patch file; split off at most 3 fields and reject a 4th.
    IFS='|' read -r f1 f2 f3 f4 <<< "$trimmed"
    patch_file="$(trim "${f1:-}")"
    targets="$(trim "${f2:-}")"
    label="$(trim "${f3:-}")"
    if [ -n "${f4:-}" ] || [ -z "$patch_file" ] || [ -z "$targets" ] || [ -z "$label" ]; then
      echo "Malformed manifest row at $MANIFEST:$line (expected 3 '|'-separated fields)" >&2
      exit 1
    fi
    # Validate the target pairs now so a malformed row aborts in this shell.
    iter_targets "$targets" >/dev/null
    PATCH_FILES+=("$patch_file")
    PATCH_TARGETS+=("$targets")
    PATCH_LABELS+=("$label")
  done < "$MANIFEST"
  if [ "${#PATCH_FILES[@]}" -eq 0 ]; then
    echo "No patch rows found in $MANIFEST" >&2
    exit 1
  fi
}

resolve_vaxis_dir() {
  local requested="${1:-}" hash base dir ok target_path
  if [ -n "$requested" ]; then
    (cd "$requested" && pwd)
    return 0
  fi

  # 1. Hash match: the zig-pkg dir name equals build.zig.zon's vaxis .hash.
  if [ -f "$REPO_ROOT/build.zig.zon" ]; then
    hash="$(sed -n 's/.*\.hash = "\(vaxis-[^"]*\)".*/\1/p' "$REPO_ROOT/build.zig.zon" | head -n1)"
    if [ -n "$hash" ] && [ -d "$REPO_ROOT/zig-pkg/$hash" ]; then
      (cd "$REPO_ROOT/zig-pkg/$hash" && pwd)
      return 0
    fi
  fi

  # 2. Content-signature scan across the local and global package caches.
  local roots=("$REPO_ROOT/zig-pkg")
  roots+=("${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}/p")
  roots+=("${XDG_CACHE_HOME:-$HOME/.cache}/zig/p")
  if [ -n "${LOCALAPPDATA:-}" ]; then
    roots+=("$LOCALAPPDATA/zig/p")
  fi

  local candidates=() i
  for base in "${roots[@]}"; do
    [ -d "$base" ] || continue
    for dir in "$base"/vaxis-*; do
      [ -d "$dir" ] || continue
      [ -f "$dir/src/vaxis.zig" ] || continue
      ok=1
      for i in "${!PATCH_TARGETS[@]}"; do
        while IFS=$'\t' read -r target_path _; do
          if [ ! -f "$dir/$target_path" ]; then
            ok=0
            break
          fi
        done < <(iter_targets "${PATCH_TARGETS[$i]}")
        if [ "$ok" -eq 0 ]; then
          break
        fi
      done
      if [ "$ok" -eq 1 ]; then
        candidates+=("$dir")
      fi
    done
  done

  if [ "${#candidates[@]}" -eq 0 ]; then
    echo "No fetched vaxis directory was found (scanned repo zig-pkg, ZIG_GLOBAL_CACHE_DIR, LOCALAPPDATA). Run 'zig build --fetch' first, then pass the path printed by the build as argument 1." >&2
    exit 1
  fi
  if [ "${#candidates[@]}" -gt 1 ]; then
    echo "More than one vaxis directory was found. Re-run with an explicit path argument:" >&2
    printf '%s\n' "${candidates[@]}" >&2
    exit 1
  fi
  printf '%s' "${candidates[0]}"
}

assert_no_rejects() {
  local patch_file="$1" dir="$2" rej
  rej="$(find "$dir" -name '*.rej' -type f 2>/dev/null || true)"
  if [ -n "$rej" ]; then
    echo "Patch '$patch_file' left .rej files - hunks could not be applied:" >&2
    printf '%s\n' "$rej" >&2
    echo "regeneration recipe: docs/BUILDING.md \"Bumping vaxis\"" >&2
    exit 1
  fi
}

apply_row() {
  local patch_file="$1" dir="$2"
  local patch_path="$PATCH_ROOT/$patch_file"
  local rc
  if [ ! -f "$patch_path" ]; then
    echo "Patch file not found: $patch_path" >&2
    exit 1
  fi

  # 1. patch(1): -N (forward, tolerate already-applied), -t (batch, never
  #    prompt), -F 3 (fuzz for a few moved context lines), -p1.
  if have_cmd patch; then
    echo "Applying $patch_file with patch ..."
    set +e
    patch -N -t -F 3 -p1 -d "$dir" < "$patch_path"
    rc=$?
    set -e
    assert_no_rejects "$patch_file" "$dir"
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
  fi

  # 2. git apply: atomic per file, strictly context-checked; works outside a repo.
  if have_cmd git; then
    echo "Applying $patch_file with git apply ..."
    set +e
    (cd "$dir" && git apply -p1 --whitespace=nowarn "$patch_path")
    rc=$?
    set -e
    assert_no_rejects "$patch_file" "$dir"
    if [ "$rc" -eq 0 ]; then
      return 0
    fi

    # 3. git apply --3way: needs the patch's `index` blobs, so only for a vaxis
    #    git checkout (the package cache has no .git).
    if [ -d "$dir/.git" ]; then
      echo "Applying $patch_file with git apply --3way ..."
      set +e
      (cd "$dir" && git apply --3way -p1 --whitespace=nowarn "$patch_path")
      rc=$?
      set -e
      assert_no_rejects "$patch_file" "$dir"
      if [ "$rc" -eq 0 ]; then
        return 0
      fi
    fi
  fi

  echo "Could not apply $patch_file to $dir. Regeneration recipe: docs/BUILDING.md \"Bumping vaxis\"" >&2
  exit 1
}

main() {
  parse_manifest
  local target_dir row_i patch_file targets label
  target_dir="$(resolve_vaxis_dir "${1:-}")"

  for row_i in "${!PATCH_FILES[@]}"; do
    patch_file="${PATCH_FILES[$row_i]}"
    targets="${PATCH_TARGETS[$row_i]}"
    label="${PATCH_LABELS[$row_i]}"

    # Stale rejects/backups poison failure detection; the vendor copy is
    # gitignored and regenerable, so drop them before checking or applying.
    find "$target_dir" -name '*.rej' -type f -delete 2>/dev/null || true
    find "$target_dir" -name '*.orig' -type f -delete 2>/dev/null || true

    local already=1 summary="" target_path tcount full found
    while IFS=$'\t' read -r target_path tcount; do
      full="$target_dir/$target_path"
      if [ ! -f "$full" ]; then
        echo "The selected vaxis directory is missing '$full'." >&2
        exit 1
      fi
      found="$(marker_count "$full")"
      if [ -z "$summary" ]; then
        summary="$target_path=$found"
      else
        summary="$summary, $target_path=$found"
      fi
      [ "$found" -ge "$tcount" ] || already=0
    done < <(iter_targets "$targets")

    if [ "$already" -eq 1 ]; then
      echo "$label already present ($summary)"
      continue
    fi

    apply_row "$patch_file" "$target_dir"

    while IFS=$'\t' read -r target_path tcount; do
      found="$(marker_count "$target_dir/$target_path")"
      if [ "$found" -lt "$tcount" ]; then
        echo "$label verification failed: $target_dir/$target_path shows $found of $tcount markers." >&2
        exit 1
      fi
    done < <(iter_targets "$targets")
  done

  echo "vaxis patches are ready in $target_dir"
}

main "$@"
