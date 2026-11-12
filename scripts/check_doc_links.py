#!/usr/bin/env python3
"""Check that relative links and heading anchors in the repo docs resolve.

Scans AGENTS.md, README.md, and every Markdown file under docs/ (dated plan
snapshots under docs/plans/ are excluded on purpose: they record what was true
when written). Verifies that each internal link target exists on disk and that
a `path#anchor` target's anchor matches a real heading, using GitHub's slug
rules so the check matches what a reader lands on.

Exit code 0 = all links resolve; 1 = at least one broken link.
"""

import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Files and trees scanned for links. docs/plans/ holds dated planning
# snapshots, so its links are historical records, not live documentation.
SCAN_ROOTS = ["AGENTS.md", "README.md", "docs"]
SKIP_DIRS = {"plans"}

# `path#L42` is GitHub's source-line permalink style: valid for code files on
# github.com, never a heading anchor.
LINE_PERMALINK_RE = re.compile(r"^L\d+$")

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
FENCE_RE = re.compile(r"^(?:```+|~~~+)\s*\S*\s*$")


def strip_fenced_blocks(text):
    """Remove fenced code blocks so example links inside them are not checked."""
    out_lines = []
    in_fence = False
    for line in text.splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            out_lines.append(line)
    return "\n".join(out_lines)


def github_slug(heading_text):
    """Slugify a heading the way GitHub does for #anchor links."""
    text = heading_text.strip().lower()
    # Drop everything except letters, digits, spaces, hyphens, underscores.
    text = re.sub(r"[^a-z0-9 _\-]", "", text)
    return text.replace(" ", "-")


def heading_slugs(path):
    """Return the set of GitHub-style slugs for every heading in a file."""
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        body = strip_fenced_blocks(handle.read())
    slugs = set()
    for line in body.splitlines():
        match = HEADING_RE.match(line)
        if match:
            slugs.add(github_slug(match.group(2)))
    return slugs


def iter_markdown_files():
    """Enumerate git-tracked Markdown files inside the scan roots.

    Tracking matters for CI parity: untracked work-in-progress files are not
    part of the tree a fresh checkout builds, so they are not checked.
    """
    tracked = subprocess.run(
        ["git", "ls-files", "-z"], cwd=REPO_ROOT, check=True, capture_output=True
    ).stdout.decode("utf-8").split("\0")
    for path in tracked:
        if not path.endswith(".md"):
            continue
        if not any(path == root or path.startswith(root.rstrip("/") + "/") for root in SCAN_ROOTS):
            continue
        if any(part in SKIP_DIRS for part in path.split("/")):
            continue
        yield path


def check_file(path, slugs_cache, failures):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        body = strip_fenced_blocks(handle.read())
    for match in LINK_RE.finditer(body):
        target = match.group(1)
        if target.startswith(("http://", "https://", "mailto:", "<")):
            continue
        anchor = None
        if "#" in target:
            path_part, anchor = target.split("#", 1)
        else:
            path_part = target
        if anchor is not None and LINE_PERMALINK_RE.match(anchor):
            continue
        if path_part == "":
            # Same-file anchor: verify against this file's headings.
            if anchor is not None and github_slug(anchor) not in slugs_cache.setdefault(
                path, heading_slugs(path)
            ):
                print(f"{path}: broken same-file anchor #{anchor}")
                failures.append(path)
            continue
        resolved = os.path.normpath(os.path.join(os.path.dirname(path), path_part))
        if not os.path.exists(resolved):
            print(f"{path}: missing target {target}")
            failures.append(path)
            continue
        if anchor is not None and not os.path.isdir(resolved):
            target_slugs = slugs_cache.setdefault(resolved, heading_slugs(resolved))
            if github_slug(anchor) not in target_slugs:
                print(f"{path}: broken anchor {target} (no heading slugifies to {github_slug(anchor)})")
                failures.append(path)


def main():
    failures = []
    slugs_cache = {}
    for path in iter_markdown_files():
        check_file(path, slugs_cache, failures)
    if failures:
        print(f"\n{len(failures)} broken link(s) found")
        return 1
    print("all doc links resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
