---
description: File read/write/edit/list tools — the primary way to work with files.
---

Use the `file-tools` plugin for ALL file operations. These tools are
path-traversal protected and atomic — prefer them over `bash` for any file
read, write, edit, or listing.

## When to use each tool

- `lua__file-tools__read` — Read a file's contents with numbered lines
  (`N: <content>`). Use this before editing any file, and to answer "what is
  in this file?". Supports `offset`/`limit` for paging large files; refuses
  binary files.
- `lua__file-tools__write` — Create a new file or fully overwrite an existing
  one. Use this when you have the complete intended content.
- `lua__file-tools__edit` — Replace occurrences of a string in an existing
  file. Use this for surgical changes. Pass `replace_all=true` to replace
  every occurrence (e.g. a rename across a file).
- `lua__file-tools__list_directory` — List a directory's contents with
  folders and files in separate sorted sections. Use this to explore a
  directory; for recursive filename search use `glob` instead.

## Guidelines

- **Read before edit.** Never guess file contents. Always call `read` first so
  your `old_string` matches the file exactly — include enough surrounding
  context to make it unique.
- **Prefer `edit` over `write` for modifying existing files.** `write`
  overwrites the entire file, which risks dropping content you did not intend
  to remove.
- **Avoid tiny repeated slices.** When reading a file, read a large enough
  window (e.g. 100+ lines) rather than 30-line chunks. If you need more
  context, read a larger window.
- **Line-number prefix decoding.** `read` output is `N: <content>`. When
  constructing `old_string` for `edit`, strip the `N: ` prefix — everything
  after the space is the real file content. Preserve exact indentation.
- **Edit failure modes.** The edit FAILS if `old_string` is not found, and
  (unless `replace_all`) FAILS if `old_string` appears multiple times. Provide
  more surrounding lines to disambiguate, or set `replace_all=true`.
- **Never proactively create documentation files** (`*.md`, `README`) unless
  the user explicitly asks.
- **For large files**, pass `offset` to page through sections; the footer
  tells you the next offset to use.
- **1 MB read cap.** `read` refuses to inline more than 1 MB of a file and
  appends `[file truncated: showing first 1 MB of N bytes]`; page the rest with
  `bash sed -n` when you need beyond the cap.
- **Relative paths** resolve against the project root; absolute paths must
  stay inside the project.
