#!/usr/bin/env python3
"""Check pinned package hashes; publish a new pin with --write --ref COMMIT."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


def read_git_blob(root: Path, ref: str, path: Path, parser: argparse.ArgumentParser) -> bytes:
    result = subprocess.run(
        ["git", "show", f"{ref}:{path.as_posix()}"],
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode:
        parser.error(f"cannot read committed package {ref}:{path}: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def extract_lua_version(data: bytes) -> str | None:
    match = re.search(r'version\s*=\s*"([^"]+)"', data.decode("utf-8", errors="replace"))
    return match.group(1) if match else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="refresh file sizes, hashes, and versions from pinned commits")
    parser.add_argument("--ref", help="published 40-character commit SHA for official file URLs")
    parser.add_argument("--check-head", action="store_true", help="fail if store.json metadata differs from HEAD")
    args = parser.parse_args()
    if args.ref and (not args.write or not re.fullmatch(r"[0-9a-fA-F]{40}", args.ref)):
        parser.error("--ref requires --write and a full commit SHA")
    if args.check_head and args.write:
        parser.error("--check-head cannot be combined with --write")
    root = Path(__file__).resolve().parents[1]
    catalog_path = root / "plugins/store.json"
    catalog = json.loads(catalog_path.read_text())
    changed = []
    head_drift = []
    for plugin in catalog["plugins"]:
        for entry in plugin["files"]:
            url = entry.get("url", "")
            match = re.fullmatch(
                r"https://raw\.githubusercontent\.com/ozgurulukir/zay/([0-9a-fA-F]{40})/(plugins/packages/[^?#]+)",
                url,
            )
            if match is None:
                parser.error(f"unsupported or unpinned package URL: {url}")
            ref = args.ref or match[1]
            path = Path("plugins/packages") / plugin["id"] / entry["path"]
            if path.as_posix() != match[2]:
                parser.error(f"package URL does not match catalog path: {url}")
            data = read_git_blob(root, ref, path, parser)
            size, digest = len(data), hashlib.sha256(data).hexdigest()
            if entry.get("size") != size or entry.get("sha256") != digest:
                changed.append(str(path))
                entry.update(size=size, sha256=digest)
            if entry["path"] == "plugin.lua":
                lua_version = extract_lua_version(data)
                if lua_version and plugin.get("version") != lua_version:
                    changed.append(f"{plugin['id']}:version ({plugin.get('version')} -> {lua_version})")
                    plugin["version"] = lua_version
            if args.check_head:
                head_data = read_git_blob(root, "HEAD", path, parser)
                head_size, head_digest = len(head_data), hashlib.sha256(head_data).hexdigest()
                if entry.get("size") != head_size or entry.get("sha256") != head_digest:
                    head_drift.append(str(path))
                if entry["path"] == "plugin.lua":
                    head_version = extract_lua_version(head_data)
                    if head_version and plugin.get("version") != head_version:
                        head_drift.append(f"{plugin['id']}:version ({plugin.get('version')} -> {head_version})")
            if args.ref:
                pinned = re.sub(
                    r"^(https://raw\.githubusercontent\.com/ozgurulukir/zay/)[^/]+(/plugins/packages/)",
                    lambda match: match[1] + args.ref + match[2],
                    url,
                )
                if pinned != url:
                    entry["url"] = pinned
    if args.write:
        catalog_path.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
    for path in changed:
        print(("Updated: " if args.write else "Stale: ") + path)
    for path in head_drift:
        print("Drift from HEAD: " + path)
    if head_drift:
        print("To sync: python3 scripts/sync-plugin-catalog.py --write --ref \"$(git rev-parse HEAD)\"")
    return 0 if args.write or (not changed and not head_drift) else 1


if __name__ == "__main__":
    raise SystemExit(main())
