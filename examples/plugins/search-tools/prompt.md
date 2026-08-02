---
description: Content search (grep) and filename search (glob) tools.
---

Use the `search-tools` plugin to locate code and files across the project.

## When to use each tool

- `lua__search-tools__grep` — Search the **contents** of files for a text
  pattern. Returns matches grouped by file (`path:` header + indented
  `Line N: <content>` entries). Use this to find where a symbol, string, or
  API is used.
- `lua__search-tools__glob` — Find **files by name** using a glob pattern
  (`**/*.zig`, `src/**/*.ts`). Returns matching paths. Use this when you know
  the filename or extension but not the location.

## Guidelines

- **Batch your searches.** You can call `grep` and `glob` multiple times in a
  single response. When exploring, run several searches at once rather than
  one at a time.
- **Narrow before widening.** If `grep` returns too many matches, add an
  `include` glob filter (e.g. `"*.zig"`) before raising `max_results`. Filtering
  by file type is cheaper than fetching more matches.
- **Substring vs regex.** By default `grep` matches the pattern as a **literal
  substring** using Nova's built-in search — no external tools, but it skips
  only dotfiles, so gitignored dirs (vendor/, zig-cache/) are scanned too. Set
  `regex=true` for full regular expressions (e.g. `func\s+\w+`, `mcp__|lua__`);
  regex runs via ripgrep, respects `.gitignore`, and needs `rg` installed.
- **Counting matches.** If you need the number of matches within files (not the
  matches themselves), use `bash` with `rg --count` directly instead of this
  tool.
- **After finding a match**, read the surrounding lines (via `read` or
  `lua__file-tools__read`) before deciding to edit — the match line rarely has
  enough context on its own.
- **Use `glob` for file discovery, `list_directory` for structure.** `glob`
  searches recursively by name; `lua__file-tools__list_directory` shows one
  level's folders and files.
- **Default search root** is the project root. Pass `path` to scope a search to
  a subdirectory.
