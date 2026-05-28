Reads the content at the specified filesystem path.

<instruction>
Use `read` for inspecting files and directories. Prefer this over the bash tool for commands like `cat`, `head`, `tail`, `less`, `more`, `ls`, `sed -n`, or `awk NR` when the goal is inspection.

## Parameters

- `path` — file path (required). Append a selector for line ranges, raw mode, or conflict inspection.

## Selectors

- _(no suffix)_ — read from the start, up to {{DEFAULT_LIMIT}} lines, with content-hash anchors.
- `:50` — read from line 50 onward with anchors.
- `:50-200` — read lines 50-200 with anchors.
- `:50+150` — read 150 lines starting at line 50 with anchors.
- `:20+1` — read exactly one line with an anchor.
- `:raw` — read verbatim text without anchors.
- `:conflicts` — return a one-line-per-block index of every merge conflict in the file.

# Filesystem

- Reading a directory path returns its entries, one per line; directories are suffixed with `/`.
- Reading a file with an omitted or explicit line selector returns lines prefixed with content-hash anchors: `#HL41th|def alpha():`. The `#HL` marker disambiguates anchored lines from arbitrary file content.
- Use anchors exactly as shown when calling `edit_file` (copy `41th`, not `#HL41th`).

</instruction>

<critical>
- You MUST always include the `path` parameter — never call `read` with an empty argument object `{}`.
- For specific line ranges, append the selector to `path` (e.g. `path="src/foo.ts:50-200"`, `path="src/foo.ts:50+150"`).
- Do not pass separate `offset` or `limit` fields; line selection belongs in the `path` suffix.
</critical>
