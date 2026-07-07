"""Fuzzy file search over the project via fff (Fast File Finder)."""

from __future__ import annotations

from itertools import islice
from pathlib import Path


def search(query, path=".", limit=20):
    """Fuzzy-find files whose paths match ``query`` under ``path``.

    Prints matching paths relative to ``path``, best match first, and returns
    them as a list. This matches file *paths* only — for content matches use
    ``grep``/``rg`` through bash instead.
    """
    from fff import FileFinder

    base = str(Path(path).resolve())
    with FileFinder(base, watch=False) as finder:
        finder.wait_for_scan_blocking(timeout_ms=15000)
        result = finder.search(query)
        matches = []
        if result:
            matches = [item.relative_path for item in islice(result.items, limit)]
    for match in matches:
        print(match)
    if not matches:
        print(f"No files matched {query!r} under {base}")
    return matches
