Read file or directory contents. Prefer this over bash `cat`, `head`, `tail`, `less`, `ls`, `sed`, or `awk` for inspecting files.

Files return lines tagged with content-hash anchors, e.g. `#HL41th|def alpha():`. When you edit the file later, copy the anchor as `41th` (drop the `#HL`).

Directories return one entry per line; sub-directories end with `/`.

Selectors append to `path` (there are no separate offset/limit params):
- (none) — from line 1, up to 2000 lines.
- `:50` — from line 50 to the end.
- `:50-200` — lines 50 through 200.
- `:50+150` — 150 lines starting at line 50.
- `:raw` — verbatim text, no anchors.
- `:conflicts` — list every merge-conflict block.
