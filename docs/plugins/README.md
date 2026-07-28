# Nova Plugin Development Guide

Nova supports extending its capabilities through Lua plugins. Plugins can register
custom tools, subscribe to lifecycle events, access the filesystem, run shell commands,
interact with git, and store persistent state.

## Quick Start

Create a plugin directory with two files:

```
~/.config/nova/plugins/my-plugin/
  plugin.lua    -- manifest (required)
  init.lua      -- entry point (required)
```

### plugin.lua (manifest)

```lua
return {
  name = "my-plugin",
  version = "1.0.0",
  author = "Your Name",
  description = "Does something useful",
  license = "MIT",
  permissions = {
    file_access = false,
    network_access = false,
    require_others = false,
  },
}
```

### init.lua (entry point)

```lua
nova.register_tool({
  name = "hello",
  description = "A friendly greeting",
  parameters = {
    name = { type = "string", description = "Who to greet" },
  },
  handler = function(params)
    -- params is a Lua table (JSON parsed automatically)
    return "Hello, " .. (params.name or "World") .. "!"
  end,
})
```

**Tool naming:** Tools are exposed to the AI model as `lua__<plugin>__<tool>`
(e.g. `lua__my-plugin__hello`). The prefix is added automatically.

**Parameters:** JSON arguments from the AI model are automatically parsed into
a Lua table before the handler is called. Access `params.param_name` directly.

## Plugin Discovery

Nova discovers plugins from two directories:

| Directory | Scope |
|-----------|-------|
| `~/.config/nova/plugins/` | Global — available in all projects |
| `.nova/plugins/` | Project — overrides global plugins with the same name |

Each subdirectory containing a `plugin.lua` file is treated as a plugin.

## Plugin API — `nova` Bridge Functions

### Filesystem

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `nova.read_file(path, opts?)` | `path`, `opts.start_line`, `opts.end_line`, `opts.max_size` | `{path, content, size, lines, language, mime_type}` | Read file with metadata |
| `nova.write_file(path, content)` | `path`, `content` | `true` or `nil` | Atomic file write |
| `nova.edit_file(path, old, new)` | `path`, `old_string`, `new_string` | `true` or `nil` | Find-and-replace |
| `nova.search_files(root, pattern, opts?)` | `root`, `pattern`, `opts.file_pattern`, `opts.case_sensitive`, `opts.max_results` | `{query, total_matches, results, truncated}` | Recursive grep |
| `nova.list_dir(path)` | `path` | `{path, files, directories, total_items}` | Directory listing |
| `nova.file_info(path)` | `path` | `{size, type, extension, language, mime_type}` | File metadata |

### Shell & Environment

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `nova.run_bash(cmd, opts?)` | `cmd`, `opts.cwd`, `opts.timeout` | `{stdout, stderr, code}` | Shell command execution |
| `nova.get_env(name)` | `name` | `string` or `nil` | Environment variable |
| `nova.get_cwd()` | — | `string` | Current working directory |
| `nova.get_project_root()` | — | `string` | Git repo root or cwd |

### Git

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `nova.git_status()` | — | `string` | Git status (porcelain) |
| `nova.git_diff(path?)` | `path` (optional) | `string` | Git diff |
| `nova.git_log(n)` | `n` (default 10) | `string` | Recent commits |
| `nova.git_branch()` | — | `string` | Current branch name |
| `nova.git_commit(msg)` | `msg` | `{success, output}` | Create commit |

### Plugin System

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `nova.register_tool(spec)` | `spec.name`, `spec.description`, `spec.parameters`, `spec.handler` | `true` | Register a tool |
| `nova.on(event, callback)` | `event`, `callback` | `true` | Subscribe to event |
| `nova.think(prompt)` | `prompt` | _(stub)_ | Recursive LLM call (not yet implemented) |

### `plugin.get_config()`

Returns the plugin's settings from `config.json` as a Lua table, or `nil` if
no settings are configured. Settings are set in the `plugins` section:

```json
{
  "plugins": {
    "my-plugin": {
      "enabled": true,
      "settings": "{\"theme\":\"dark\",\"max_results\":20}"
    }
  }
}
```

### `plugin.get_state()` / `plugin.set_state(state)`

Persist state across plugin reloads. State is a string (JSON recommended).

```lua
-- Save state
function get_state()
  return require("json").encode(my_state_table)
end

-- Restore state
function set_state(state)
  my_state_table = require("json").decode(state)
end
```

## Permissions

Plugins declare required permissions in their manifest. Permissions are granted
at load time and cannot be changed at runtime.

| Permission | Description | Default |
|------------|-------------|---------|
| `file_access` | Allow file read/write via `io.*` | `false` |
| `network_access` | Allow network access | `false` |
| `require_others` | Allow requiring other plugins | `true` |
| `allow_rawget_rawset` | Allow `rawget`/`rawset` (sandbox escape risk) | `false` |
| `allow_os_execute` | Allow `os.execute` | `false` |
| `allow_os_exit` | Allow `os.exit` | `false` |
| `allow_os_remove` | Allow `os.remove`/`os.rename` | `false` |

Embedded plugins (shipped with Nova) always get full access.

## Resource Limits

| Limit | Default | Description |
|-------|---------|-------------|
| `instruction_limit` | 100,000 | Max Lua instructions before abort |
| `memory_limit_mb` | 16 | Max memory in MB |
| `timeout_ms` | 5,000 | Approximate timeout in ms |

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
`dofile`, `rawget`, `rawset`, `os.execute`, `os.exit`, `os.remove`, `os.rename`.

Instead of blocked functions, use `nova.*` bridge functions:
- Use `nova.read_file()` instead of `io.open()`
- Use `nova.run_bash()` instead of `os.execute()`
- Use `nova.get_env()` instead of `os.getenv()`

## Testing

Nova includes a Lua test framework. Create test files using `describe`/`it`:

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

See `examples/plugins/` for complete examples:

- **hello-world** — Minimal tool registration
- **file-watcher** — Event-driven plugin using `nova.on()`
- **custom-search** — Tool with configurable settings
- **read-tool** — File reading with line range, language detection, git status
- **write-tool** — File writing, editing, git-aware write+stage
- **search-tool** — Recursive grep with ripgrep fallback

## Best Practices

1. **Use `nova.*` bridge functions** instead of blocked Lua libraries
2. **Declare only needed permissions** in manifest — least privilege
3. **Handle errors gracefully** — return descriptive error strings
4. **Keep handlers fast** — events are dispatched synchronously
5. **Test with `test_runner`** — create `test.lua` in your plugin directory
6. **Use `plugin.get_config()`** for user-configurable settings
7. **Name tools with underscores** — `my_tool`, not `myTool`
8. **Return strings from handlers** — the model reads the return value
