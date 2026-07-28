---
name: write-lua-plugin
description: Guide to writing Nova Lua plugins for the Nova Agent. Learn how to create tools, access filesystem/shell/git, handle permissions, debug, and structure Lua plugin projects.
---

# Write Nova Lua Plugin

Write a Lua plugin that extends Nova's capabilities. Plugins run in a sandboxed Lua 5.4 environment and can register tools, subscribe to events, access the filesystem, run shell commands, and interact with git.

## Plugin Structure

```
~/.config/nova/plugins/<plugin-name>/
  plugin.lua    -- manifest (required)
  init.lua      -- entry point (required)
```

## Manifest (`plugin.lua`)

```lua
return {
  name = "my-plugin",           -- required, unique identifier
  version = "1.0.0",            -- required, semver
  author = "Your Name",         -- optional
  description = "What it does", -- optional
  license = "MIT",              -- optional
  permissions = {                -- optional, defaults shown
    file_access = false,
    network_access = false,
    require_others = true,
    allow_rawget_rawset = false,
    allow_os_execute = false,
    allow_os_exit = false,
    allow_os_remove = false,
    instruction_limit = 100000,
    memory_limit_mb = 16,
    timeout_ms = 5000,
  },
}
```

## Entry Point (`init.lua`)

Register tools using `nova.register_tool()`:

```lua
nova.register_tool({
  name = "my_tool",                    -- lowercase, underscores
  description = "What the tool does", -- for the AI model
  parameters = {                       -- JSON Schema-like
    param_name = {
      type = "string",                 -- "string", "number", "boolean"
      description = "Description",
      optional = true,                 -- default: false (required)
    },
  },
  handler = function(params)
    -- params is a Lua table with parameter values (JSON parsed automatically)
    -- Must return a string
    return "result"
  end,
})
```

**Tool naming:** Tools are exposed to the AI model as `lua__<plugin>__<tool>` (e.g.
`lua__my-plugin__my_tool`). The prefix is added automatically — use short,
descriptive names in `register_tool`.

**Parameters:** The JSON arguments from the AI model are automatically parsed
into a Lua table before the handler is called. You can access `params.param_name`
directly — no manual JSON parsing needed.

## Available Bridge Functions (18 total)

### Filesystem (no permission needed)
- `nova.read_file(path, opts?)` → `{path, content, size, lines, language, mime_type}`
  - opts: `start_line`, `end_line`, `max_size` (default 1MB)
- `nova.write_file(path, content)` → `true` or `nil`
  - Atomic write (temp file + rename)
- `nova.edit_file(path, old_string, new_string)` → `true` or `nil`
  - Find-and-replace first occurrence
- `nova.search_files(root, pattern, opts?)` → `{query, total_matches, results, truncated}`
  - opts: `file_pattern`, `case_sensitive`, `max_results` (max 200)
- `nova.list_dir(path)` → `{path, files[], directories[], total_items}`
- `nova.file_info(path)` → `{size, type, extension, language, mime_type}`

### Shell & Environment (no permission needed)
- `nova.run_bash(cmd, opts?)` → `{stdout, stderr, code}`
  - opts: `cwd` (default: cwd), `timeout` (default: 10s)
  - Safe execution via Nova's bash_exec — no `os.execute` needed
- `nova.get_env(name)` → `string` or `nil`
- `nova.get_cwd()` → `string`
- `nova.get_project_root()` → `string` (git repo root or cwd)

### Git (no permission needed)
- `nova.git_status()` → `string` (porcelain format)
- `nova.git_diff(path?)` → `string`
- `nova.git_log(n)` → `string` (default n=10)
- `nova.git_branch()` → `string`
- `nova.git_commit(msg)` → `{success, output}`

### Plugin System
- `nova.register_tool(spec)` → `true` — register a tool for the AI model
- `nova.on(event, callback)` → `true` — subscribe to lifecycle event
  - Events: `turn_started`, `turn_ended`, `tool_call_started`, `tool_call_finished`, `response_received`, `plugin_loaded`, `plugin_unloaded`
- `nova.think(prompt)` → _(stub, not yet implemented)_

### Plugin Config
- `plugin.get_config()` → table or nil (from `config.json` `plugins.<name>.settings`)
- `plugin.get_state()` / `plugin.set_state(state)` — persist state across reloads

## Parameter Schema

```lua
parameters = {
  name = {
    type = "string",       -- "string" | "number" | "boolean"
    description = "...",   -- for the AI model
    optional = true,       -- if true, model may omit
  },
}
```

## Best Practices

1. **Use `nova.*` bridge functions** instead of blocked Lua libraries (`io`, `os.execute`, etc.)
2. **Declare only needed permissions** — least privilege principle
3. **Return descriptive strings** from handlers — the AI model reads the return value
4. **Handle errors gracefully** — return error strings, don't crash
5. **Keep event handlers fast** — events are dispatched synchronously
6. **Name tools with underscores** — `my_tool`, not `myTool`
7. **Use `plugin.get_config()`** for user-configurable settings
8. **Test with `test_runner`** — create `test.lua` in your plugin directory

## Example: Read + Git Status Tool

```lua
nova.register_tool({
  name = "read",
  description = "Read file contents with line range and language detection",
  parameters = {
    path = { type = "string", description = "File path" },
    start_line = { type = "number", description = "Starting line", optional = true },
    end_line = { type = "number", description = "Ending line", optional = true },
  },
  handler = function(params)
    local result = nova.read_file(params.path, {
      start_line = params.start_line,
      end_line = params.end_line,
    })
    if result == nil then
      return "Error: could not read " .. params.path
    end
    return string.format("File: %s\nSize: %d\nLanguage: %s\n\n%s",
      result.path, result.size, result.language, result.content)
  end,
})

nova.register_tool({
  name = "git_status",
  description = "Get git status for the current repository",
  parameters = {},
  handler = function()
    local status = nova.git_status()
    local branch = nova.git_branch()
    return string.format("Branch: %s\n\n%s", branch or "unknown", status)
  end,
})
```

## Example: Bash + Write Tool

```lua
nova.register_tool({
  name = "build",
  description = "Run a build command and return the result",
  parameters = {
    command = { type = "string", description = "Build command to run" },
  },
  handler = function(params)
    local result = nova.run_bash(params.command, { timeout = 60 })
    if result.code == 0 then
      return "Build succeeded:\n" .. result.stdout
    else
      return "Build failed (code " .. result.code .. "):\n" .. result.stderr
    end
  end,
})

nova.register_tool({
  name = "write_and_stage",
  description = "Write content to a file and stage it with git",
  parameters = {
    path = { type = "string", description = "File path" },
    content = { type = "string", description = "Content to write" },
  },
  handler = function(params)
    local ok = nova.write_file(params.path, params.content)
    if not ok then return "Error: could not write" end
    local result = nova.run_bash("git add " .. params.path, {})
    if result.code == 0 then
      return string.format("Wrote and staged %s", params.path)
    end
    return string.format("Wrote %s but git add failed: %s", params.path, result.stderr)
  end,
})
```

## Testing

Create `test.lua` in your plugin directory:

```lua
local test = test_runner

test.describe("my plugin", function()
  test.it("works correctly", function()
    test.assert.equal(4, 2 + 2)
  end)
end)

test.run()
```

Run: `zig build test-plugin`

## See Also

- `docs/plugins/README.md` — full plugin development guide
- `docs/plugins/api-reference.md` — complete API reference
- `docs/plugins/examples.md` — example walkthroughs
- `examples/plugins/` — example plugin source code
