---
name: write-lua-plugin
description: Use when creating, updating, or testing Zay Lua 5.4 plugins (plugin.lua, init.lua, prompt.md, test.lua), zay.* bridge calls, permissions, or plugin tool schemas.
---

# Write Zay Lua Plugin

Zay plugins run in a sandboxed Lua 5.4 runtime (`src/lua/`) that registers model tools (`lua__<plugin>__<tool>`), subscribes to lifecycle events, and accesses the workspace through `zay.*` bridges. See `docs/plugins/README.md` for the full guide, `docs/plugins/api-reference.md` for exact signatures, and `plugins/packages/` for tested reference plugins.

## Layout and discovery

```text
<plugin-root>/<plugin-name>/
  plugin.lua    -- manifest (required)
  init.lua      -- entry point (required)
  prompt.md     -- optional model instructions (<=32 KB/plugin, <=64 KB total)
  test.lua      -- optional test_runner suite
```

Discovery roots: global `~/.config/zay/plugins/` (Windows probes `%APPDATA%\zay\plugins` first), project `plugins/` (loaded last, overrides global), and legacy `.zay/plugins/` fallback.

## Manifest (`plugin.lua`)

Request only needed permissions:

```lua
return {
  name = "my-plugin",
  version = "1.0.0",
  description = "What it does",
  permissions = {
    allow_os_execute = false, -- required for zay.run_bash / zay.run_shell
    allow_os_remove = false,  -- required for zay.move_path / zay.delete_path
    instruction_limit = 100000,
    memory_limit_mb = 16,
    timeout_ms = 5000,
  },
}
```

Limits reset per tool call or event dispatch; keep handlers bounded and match `timeout_ms` to any shell command timeouts.

## Entry point and handler contract (`init.lua`)

Register all tools during `init.lua` via `zay.register_tool(spec)`. Tool names must be `<=64` chars matching `^[a-z][a-z0-9_]*$`; JSON arguments arrive parsed in `params`.

```lua
zay.register_tool({
  name = "read_config",
  description = "Read a file inside the workspace",
  parameters = {
    path = { type = "string", description = "Relative file path" },
    -- Supported types: string, number, integer, boolean, object, array
    -- Optional schema keys: optional, nullable, enum, default
    max_size = { type = "integer", description = "Byte cap", optional = true },
  },
  handler = function(params)
    local res, err = zay.read_file(params.path, { max_size = params.max_size })
    if res == nil then
      return nil, "Error: " .. tostring(err or "read failed")
    end
    return res.content
  end,
})
```

**Return contract:** return a string on success, and `return nil, "Error: ..."` on operational failure. Returning `"Error: ..."` as a single string reports `success = true` to callers and `tool_call_finished`.

## Sandbox, bridges, and cwd

Standard `io`, `debug`, `package`, `loadfile`, `dofile`, `os.execute`, `os.remove`, and `os.rename` are blocked (`os.clock`, `os.date`, `os.time`, `os.difftime` stay available). Use `zay.*` bridges instead (full table in `docs/plugins/api-reference.md`):

- **Filesystem (`sanitizePath` cwd-confined):** `read_file`, `write_file` (atomic), `edit_file`, `search_files`, `find_files`, `list_dir`, `file_info`, `mkdir`, `copy_path`, plus `move_path`/`delete_path` (require `allow_os_remove = true`). Prefer these over shelling out.
- **Shell & Env:** `run_bash` / `run_shell` (require `allow_os_execute = true`; `run_bash` runs the shell safety classifier and hard-blocks unsafe forms), `shell_quote(s, dialect?)`, `get_env`, `get_cwd`, `get_project_root`. Always quote interpolated inputs with `zay.shell_quote`.
- **Git:** `git_status`, `git_diff`, `git_log`, `git_branch`, `git_add`, `git_commit`.
- **Modules, Events, JSON:** `zay.require(rel_path)` (plugin-dir confined, cached in `zay_loaded_modules`), `zay.on(event, fn)` (only `tool_call_started` and `tool_call_finished` fire in production), `zay.json_decode` / `zay.json_encode(val, { pretty = true })`.
- **Config & State:** `plugin.get_config()` returns a fresh table from `config.json` `plugins.<name>.settings` or `nil`. Top-level Lua globals `get_state()` / `set_state(state)` preserve in-memory state across reloads; for durable state, write JSON sidecars under `.zay/<plugin>/`.

**Effective cwd:** Bridges resolve against the active lane worktree or resumed session root (`bridge.resolvePluginCwd`). Keep Lua paths relative with forward slashes rather than backslashes or `git -C` workarounds.

## Testing

Add `test.lua` using `local test = test_runner` (`test.describe`, `test.it`, `test.assert`, `test.run()`), register its path in `build.zig` under `test-plugin`, and run `zig build test-plugin` (at least one `it` block is required; 0 tests fails).
