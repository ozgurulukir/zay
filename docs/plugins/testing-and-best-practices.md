## Resource Limits

| Limit | Default | Description |
|-------|---------|-------------|
| `instruction_limit` | 100,000 | Max Lua instructions before abort (`0` = unlimited) |
| `memory_limit_mb` | 16 | Max memory in MB |
| `timeout_ms` | 5,000 | Approximate timeout in ms |

These are **per-dispatch** budgets: the instruction count and timeout deadline are
reset before every tool handler call and every event callback, so they cap one call,
not the plugin's lifetime. The hook fires once per 1000 VM instructions, so a
`timeout_ms` deadline can overshoot slightly. Set a limit to `0` for unlimited;
negative values are clamped to `0`.

Set these in the manifest's `permissions` table:

```lua
permissions = {
  instruction_limit = 50000,
  memory_limit_mb = 32,
  timeout_ms = 10000,
}
```

## Sandbox

Plugins run in a restricted Lua environment. The following are available:

- **Safe functions**: `assert`, `error`, `getmetatable`, `ipairs`, `next`, `pairs`,
  `pcall`, `rawequal`, `rawlen`, `select`, `setmetatable`, `tonumber`, `tostring`,
  `type`, `xpcall`, `_VERSION`
- **Safe libraries**: `string`, `table`, `math`, `coroutine`, `utf8`
- **Safe os subset**: `os.clock()`, `os.date()`, `os.time()`, `os.difftime()`

The following are **blocked** by default: `io`, `debug`, `package`, `loadfile`,
`dofile`, `os.execute`, `os.remove`, `os.rename`.

Instead of blocked functions, use `zay.*` bridge functions:
- Use `zay.read_file()` instead of `io.open()`
- Use `zay.run_bash()` instead of `os.execute()`
- Use `zay.get_env()` instead of `os.getenv()`

## Testing

Zay includes a Lua test framework. Create test files using `describe`/`it`:

```lua
local test = test_runner

test.describe("my plugin", function()
  test.it("adds numbers", function()
    test.assert.equal(4, 2 + 2)
  end)

  test.it("handles errors", function()
    test.assert.error(function()
      error("boom")
    end)
  end)
end)

test.run()
```

Run tests with:

```bash
zig build test-plugin
```

## Example Plugins

See `plugins/` for complete, tested plugin packages. These mirror the tool
shapes models already know from Claude Code / OpenCode / Zed agents:

- **file-tools** — `read` (numbered lines, binary guard, paging),
  `write`, `edit` (with `replace_all`), `list_directory` (folders/files split)
- **search-tools** — `grep` (grouped output, regex via ripgrep fallback),
  `glob` (recursive filename match via `zay.find_files`)
- **path-tools** — `create_directory`, `copy_path`, `move_path`, `delete_path`
  (sandboxed alternatives to bash cp/mv/rm/mkdir)
- **git-tools** — `git_status`, `git_diff`, `git_log`, `git_branch`,
  `git_add`, `git_commit` (with commit-discipline guidance in `prompt.md`)
- **todo** — todo.txt-format task tracker with detailed plans. List tools:
  `todo_list`, `todo_add`, `todo_done`, `todo_delete`, `todo_prioritize`,
  `todo_write`. Plan tools (lazy-loaded so the list stays compact):
  `todo_get_plan`, `todo_set_plan`, `todo_check_step`. The task list persists to
  `.zay/todos.txt` (todo.txt standard, editable in any editor); detailed
  per-task plans live in a sidecar `.zay/todos/plans.json` keyed by a stable
  `id:N` tag. `todo_list` shows only a `[plan:N steps]` marker — plan bodies are
  fetched on demand via `todo_get_plan` to keep context small. The list store is
  re-read from disk at the start of every tool call, so external edits to
  `todos.txt` are reflected immediately (no event subscription).
- **file-watcher** — Event-driven plugin using `zay.on("tool_call_finished", ...)`
- **hello-world** — Minimal tool registration (demo)
- **modular-demo** — Multi-module plugin: `init.lua` pulls helper modules in via
  `zay.require` to demonstrate the plugin-scoped module loader
- **sitting-duck** — tree-sitter ASTs as SQL over the `duckdb` CLI + the
  `sitting_duck` community extension (auto-installed on first use): `ast_outline`
  (glob → symbol list with `node_id` handles), `ast_find_pattern` (structural
  search via code-skeleton patterns with `__NAME__` wildcards), `ast_get_source` (`node_id` → numbered source
  snippet), `ast_query` (read-only SQL over `read_ast()` — single
  SELECT/WITH statement; chained statements and dot-commands rejected).
  State lives in `.zay/sitting-duck/` (bootstrap marker + an opt-in
  `query.sql` debug artifact). Query text is sent through stdin and is not
  persisted by default. First example consuming `plugin.get_config()` and
  `zay.shell_quote`: binary resolution is
  `plugins.sitting-duck.settings.duckdb_path` →
  `ZAY_SITTING_DUCK_BIN` → `duckdb` on PATH. Linux-first.

Each plugin ships a `prompt.md` whose body is injected into the system prompt
(see the "prompt.md" section above), teaching the model when and how to use
the plugin's tools.

## Best Practices

1. **Use `zay.*` bridge functions** instead of blocked Lua libraries
2. **Prefer dedicated tools over bash** — `delete_path` over `run_bash("rm")`,
   `find_files` over `run_bash("find")`. The dedicated tools are sandboxed;
   `run_bash` runs unclassified.
3. **Handle errors gracefully** — return `nil, descriptive_message` for
   operational failures, not a successful string that merely starts with
   `Error:`
4. **Keep handlers fast** — events are dispatched synchronously
5. **Test with `test_runner`** — create `test.lua` in your plugin directory
6. **Ship a `prompt.md`** — teach the model when to use each tool
7. **Name tools with underscores** — `my_tool`, not `myTool`
8. **Return strings from handlers** — use `string` for success and
   `nil, message` for failure
