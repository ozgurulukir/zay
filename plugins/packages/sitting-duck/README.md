# sitting-duck

Query tree-sitter ASTs with SQL, straight from Zay. The plugin wraps the
`duckdb` CLI and its `sitting_duck` community extension, which exposes parsed
syntax trees as SQL tables — so structural questions ("where are all the
`defer` calls?", "which functions exceed 200 lines?") become plain `SELECT`s.

## Tools

| Tool | What it does |
|------|--------------|
| `ast_outline` | glob → symbol list with `node_id` handles |
| `ast_find_pattern` | structural search: code-skeleton patterns with `__NAME__` wildcards (zig: `fn __FN__(__) void {}`, python: `def __F__(__):`, ruby: `def __FN__(__)`) |
| `ast_get_source` | `node_id` → numbered source snippet |
| `ast_query` | read-only SQL over `read_ast()` (single `SELECT`/`WITH`) |

They are exposed to the model as `lua__sitting-duck__<tool>`.

## Requirements

- **Zay 0.5.0+** — uses the `plugin.get_config()` / `zay.shell_quote()`
  bridge surface.
- **duckdb CLI** — the plugin never installs this itself; pick one:

  ```bash
  curl https://install.duckdb.org | sh   # official script (Linux/macOS)
  brew install duckdb                    # Homebrew
  ```

  or download the single binary from <https://duckdb.org/install/>. The
  plugin finds it via `plugins.sitting-duck.settings.duckdb_path` →
  `ZAY_SITTING_DUCK_BIN` env var → `duckdb` on `PATH`, in that order.
- **Internet on first use** — the `sitting_duck` community extension is
  `INSTALL`ed automatically by the plugin on the first tool call, through
  duckdb's own community-extension mechanism — no manual step (and no reason
  to pre-install: `INSTALL` is idempotent, so doing it yourself only skips
  the one-time download). Success is cached in
  `.zay/sitting-duck/state.json` and re-verified once per session, so a
  duckdb upgrade triggers a re-install (the extension is built per DuckDB
  release).
- **Cross-platform shell note.** POSIX uses `/dev/null`; Windows uses the
  `run_bash` Git Bash bridge and DuckDB's native `NUL` device. On Windows,
  install Git Bash and keep DuckDB on `PATH` or configure its native executable
  path explicitly.

## Install

1. Install the plugin directory using your normal Zay plugin installation
   workflow (from your Zay checkout). Do not use a recursive shell copy as a
   general file-operation workaround; use the dedicated path/file tools when
   operating from inside Zay.

   Project-local alternative: `.zay/plugins/sitting-duck/` inside a repo
   (overrides a global plugin with the same name). On Windows the global
   directory is `%APPDATA%\zay\plugins\`.

2. Make sure duckdb is reachable. If it is not on `PATH`, point Zay at it —
   either in `~/.config/zay/config.json`:

   ```json
   {
     "plugins": {
       "sitting-duck": {
         "settings": { "duckdb_path": "/usr/local/bin/duckdb" }
       }
     }
   }
   ```

   (on Windows, a native path such as `C:/tools/duckdb/duckdb.exe` is also
   accepted; forward slashes avoid shell-quoting surprises.) An
   escaped-JSON-string `settings` form also works — see
   `docs/CONFIG.md`), or via the environment:

   ```bash
   export ZAY_SITTING_DUCK_BIN=/usr/local/bin/duckdb
   ```

3. Restart Zay — plugins and their settings are read once at startup.

## Verify

Run `/plugins` in Zay and check that `sitting-duck` is enabled, then ask the
model something like *"outline the symbols in `src/**/*.zig` with
ast_outline"*. The first call bootstraps the extension; later calls are fast.

## Notes

- All plugin state lives under `.zay/sitting-duck/` in the active workspace:
  the bootstrap marker (`state.json`) and, only when
  `debug_query_artifact=true`, the `query.sql` debug artifact. Query text is
  sent through stdin and is not persisted by default. Deleting the directory
  is safe — the plugin re-bootstraps on the next call.
- `ast_query` accepts a single read-only statement; chained statements and
  dot-commands are rejected.
- Paths are confined to the active workspace (relative paths only, no `..`, no `~`,
  no absolute paths); see `prompt.md` for the full tool contracts.
