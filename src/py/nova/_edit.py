"""Targeted text edits with unique-match validation."""

from __future__ import annotations

import difflib
from pathlib import Path

from nova._display import emit_diff


class EditError(Exception):
    """A targeted edit could not be applied. The file is left untouched."""


def edit(path, old_text=None, new_text=None, *, edits=None):
    """Apply exact-match replacements to a text file.

    Either a single replacement::

        edit("src/main.py", "old code", "new code")

    or several at once::

        edit("src/main.py", edits=[("old a", "new a"), ("old b", "new b")])

    Every ``old`` must occur exactly once in the original file and must not
    overlap another edit's match. All edits are validated before anything is
    written, so a failure leaves the file untouched. Line endings and encoding
    are preserved byte-for-byte outside the replaced spans.
    """
    if edits is None:
        if old_text is None or new_text is None:
            raise EditError("edit() needs old_text and new_text, or edits=[(old, new), ...]")
        edits = [(old_text, new_text)]
    elif old_text is not None or new_text is not None:
        raise EditError("edit() takes old_text/new_text or edits=[...], not both")
    edits = [(str(old), str(new)) for old, new in edits]
    if not edits:
        raise EditError("edits[] is empty")

    target = Path(path)
    if not target.is_file():
        raise EditError(f"{path}: no such file")
    before = target.read_bytes().decode("utf-8")

    spans = []
    for old, new in edits:
        if not old:
            raise EditError(f"{path}: oldText is empty")
        count = before.count(old)
        if count == 0:
            raise EditError(f"{path}: oldText not found{_near_miss(before, old)}")
        if count > 1:
            raise EditError(
                f"{path}: oldText appears {count} times; "
                "add surrounding context to make it unique"
            )
        start = before.index(old)
        spans.append((start, start + len(old), new))
    spans.sort()
    for (_, prev_end, _), (next_start, _, _) in zip(spans, spans[1:]):
        if next_start < prev_end:
            raise EditError(f"{path}: edits overlap; merge them into one replacement")

    after = before
    for start, end, new in reversed(spans):
        after = after[:start] + new + after[end:]
    target.write_bytes(after.encode("utf-8"))

    removed = sum(old.count("\n") + 1 for old, _ in edits)
    added = sum(new.count("\n") + 1 for _, new in edits)
    print(f"Edited {path}: {len(edits)} replacement(s), +{added} -{removed} lines.")
    emit_diff(_render_diff(str(path), before, after))


def _render_diff(path, before, after):
    """A display diff: the path, then unified hunks without ---/+++ headers
    (they would take the +/- colors meant for content lines)."""
    hunks = difflib.unified_diff(
        before.splitlines(), after.splitlines(), fromfile=path, tofile=path, lineterm=""
    )
    lines = [line for line in hunks if not line.startswith(("---", "+++"))]
    return "\n".join([path] + lines)


def _near_miss(content, old):
    """Point at a line that matches oldText's first line modulo whitespace,
    the most common reason an exact match fails."""
    probe = next((line.strip() for line in old.splitlines() if line.strip()), None)
    if probe is None:
        return ""
    for number, line in enumerate(content.splitlines(), 1):
        if line.strip() == probe:
            return (
                f"; a close match near line {number} differs only in whitespace "
                "- copy the text exactly as it appears in the file"
            )
    close = difflib.get_close_matches(probe, content.splitlines(), n=1, cutoff=0.8)
    if close:
        return f"; closest line in the file is {close[0].strip()!r}"
    return ""
