# Example Plugins Walkthrough

This guide walks through selected example plugins included with Zay (the
full set — `hello-world`, `file-tools`, `search-tools`, `path-tools`,
`git-tools`, `todo`, `file-watcher`, `modular-demo`, `sitting-duck` — lives
in `examples/plugins/`). Each demonstrates a different aspect of the plugin
API.

## 1. Hello World — Minimal Tool Plugin

**Location:** `examples/plugins/hello-world/`

The simplest possible plugin. Registers two tools that the AI model can call.

### plugin.lua

```lua
return {
  name = "hello-world",
  version = "1.0.0",
  author = "Zay",
  description = "A minimal example plugin that registers a greeting tool",
  license = "MIT",
  permissions = {
    require_others = false,
  },
}
```

The manifest declares the plugin's identity and permissions. Since this plugin
doesn't access the filesystem or network, all permissions are at their defaults.

### init.lua

```lua
zay.register_tool({
  name = "greet",
  description = "Returns a friendly greeting",
  parameters = {
    name = {
      type = "string",
      description = "The name to greet",
    },
  },
  handler = function(params)
    local person = params.name or "World"
    return "Hello, " .. person .. "!"
  end,
})
```

Key points:
- `zay.register_tool()` is the primary API for exposing functionality to the AI model
- The `name` must be unique within the plugin (the system prefixes it as `lua__<plugin>__<name>`)
- `parameters` follows JSON Schema conventions — each key is a parameter name
- The `handler` receives a Lua table of parameter values (JSON parsed automatically) and returns a string
- Parameters declared without `optional = true` are required

### test.lua

```lua
local test = test_runner

test.describe("hello-world plugin", function()
  test.it("greets by name", function()
    test.assert.equal("Hello, Alice!", "Hello, Alice!")
  end)
  -- ... more tests ...
end)
```

Run with: `zig build test-plugin`

## 2. File Watcher — Event-Driven Plugin

**Location:** `examples/plugins/file-watcher/`

Demonstrates subscribing to lifecycle events using `zay.on()`.

### plugin.lua

```lua
-- require_others is advisory pending enforcement (T3); file_access is
-- omitted because this plugin does no file I/O of its own.
permissions = {
  require_others = false,
}
```

This plugin tracks file operations **by tool name** from the event stream, so
it needs no `file_access` — there is no I/O of its own.

### init.lua

```lua
-- Per-kind counters derived from tool_call_finished events.
local event_counts = {
  write = 0, edit = 0, delete = 0, rename = 0, copy = 0,
}

-- Classify a fully-qualified tool name (`lua__<plugin>__<tool>`) into a
-- file-operation kind, or nil if it isn't a file operation we track.
local function classify(name)
  if name == "lua__file-tools__write" then return "write" end
  if name == "lua__file-tools__edit" then return "edit" end
  if name == "lua__path-tools__delete_path" then return "delete" end
  if name == "lua__path-tools__move_path" then return "rename" end
  if name == "lua__path-tools__copy_path" then return "copy" end
  return nil
end

-- Count successful file-operation tool calls by kind.
zay.on("tool_call_finished", function(data)
  if not data.success then return end
  local kind = classify(data.name)
  if kind then
    event_counts[kind] = event_counts[kind] + 1
  end
end)
```

The plugin also registers two tools: `file_stats` (reports the counters) and
`track_file_op` (records a manual entry). Because the `tool_call_finished`
payload carries only `name`/`call_id`/`success` — no args, no paths —
event-driven tracking can only classify by the fully-qualified tool name.

Key points:
- `zay.on()` subscribes to lifecycle events
- The callback receives a `data` table with event-specific fields
- Multiple callbacks can subscribe to the same event
- Events are dispatched synchronously — keep handlers fast

Available events (only `tool_call_started` and `tool_call_finished` are
currently emitted in production; the others are subscribable but not
currently emitted):

| Event | data fields | When it fires |
|-------|-------------|---------------|
| `turn_started` | `{}` | Agent turn begins *(not currently emitted)* |
| `turn_ended` | `{}` | Agent turn ends *(not currently emitted)* |
| `tool_call_started` | `{name, call_id}` | Tool execution starts |
| `tool_call_finished` | `{name, call_id, success}` | Tool execution completes |
| `response_received` | `{}` | LLM response received *(not currently emitted)* |
| `plugin_loaded` | `{name}` | Plugin loaded *(not currently emitted)* |
| `plugin_unloaded` | `{name}` | Plugin unloaded *(not currently emitted)* |

## 3. Configurable Tool — authoring pattern

This is an **authoring pattern**, not a shipped example directory. It shows
how a plugin reads its configuration and applies defaults at runtime.

### plugin.lua

The manifest can be minimal — permissions are advisory metadata (only the
`allow_*` keys gate runtime behavior; see the
[development guide](README.md#permissions)), and this pattern needs none.

### init.lua

```lua
local config = plugin.get_config() or {}

local settings = {
  max_results = config.max_results or 10,
  case_sensitive = config.case_sensitive or false,
  default_pattern = config.default_pattern or "*.lua",
}
```

Key points:
- `plugin.get_config()` returns the plugin's settings as a fresh table
- Both config forms work: an inline JSON object or an escaped JSON string
- `plugin.get_config()` returns `nil` when unconfigured — apply defaults
- Settings are read once at App start (restart to apply changes)

### Configuring the plugin

In `~/.config/zay/config.json` or `.zay/config.json` (inline-object form
shown; the escaped-string form also works):

```json
{
  "plugins": {
    "my-search": {
      "enabled": true,
      "settings": { "max_results": 20, "case_sensitive": true, "default_pattern": "*.zig" }
    }
  }
}
```

Plugin configuration stays opaque to the config system — the plugin's Lua
code is responsible for validating its own settings and applying defaults.

## 4. File Tools — the model's read/write/edit surface

**Location:** `examples/plugins/file-tools/`

The largest example: registers `read`, `write`, `edit`, and `list_directory`,
mirroring the tool shapes models already know (numbered lines, continuation
hints, grouped directory listings) so the model needs no re-training.

### init.lua (excerpt — `read`)

```lua
zay.register_tool({
  name = "read",
  description = "Read a file's contents with line numbers. Returns each line as `N: <content>` (1-indexed). Supports offset/limit for paging large files. Refuses binary files. Use this before editing any file and to answer 'what is in this file?'",
  parameters = {
    path = {
      type = "string",
      description = "File path to read (relative to project root or absolute)",
    },
    offset = { type = "integer", description = "Line number to start reading from (1-indexed, optional)", optional = true },
    limit = { type = "integer", description = "Maximum number of lines to read (default 2000)", optional = true },
  },
  handler = function(params)
    ...
    local result = zay.read_file(params.path, {})
    if result == nil then
      return "Error: could not read " .. params.path
    end

    -- Binary guard: extension blacklist + null-byte sniff on a sample.
    local ext = extension(result.path)
    if is_binary(ext, result.content:sub(1, 1024)) then
      return "Error: cannot read binary file: " .. result.path
    end

    -- Split into numbered lines, applying offset/limit.
    ...
  end,
})
```

Key points:
- `read` paginates (`offset`/`limit`, default 2000 lines), renders `N: <line>`
  output, and guards against binary files (extension blacklist + null-byte
  sniff) before reading
- `write` wraps the atomic `zay.write_file` (temp + rename); its description
  encodes commit discipline ("ALWAYS prefer editing existing files … Read the
  file first before overwriting")
- `edit` counts non-overlapping occurrences of the search string and supports
  `replace_all`
- `list_directory` returns grouped folders/files output

## 5. Path Tools — sandboxed file operations

**Location:** `examples/plugins/path-tools/`

Registers `create_directory`, `copy_path`, `move_path`, and `delete_path` —
sandboxed alternatives to bash `cp`/`mv`/`rm`/`mkdir`. Every operation goes
through Zay's path validator (`sanitizePath`), so traversal outside the
project root is rejected. That is the point of the example: `zay.run_bash`
commands do pass the shell-safety classifier, but that gate only blocks
destructive patterns — it does not confine paths, so a plain `cp` could still
write outside the project root. The dedicated bridges carry no shell-quoting
or classification burden at all.

Key points:
- Prefer dedicated path bridges over shell-outs for file operations
- Confinement is the project root of the **effective cwd** (lane-aware —
  see the [API reference](api-reference.md))
- `delete_path` is recursive only via explicit `opts.recursive`

## 6. Search Tools — grep with a ripgrep backend

**Location:** `examples/plugins/search-tools/`

Registers `grep` (content search) and `glob` (filename search via
`zay.find_files`). `grep` has two backends: literal substring search through
Zay's built-in `zay.search_files` — self-contained, no external binary —
and, with `regex = true`, ripgrep via `zay.run_bash`, because
`search_files` is substring-only and Lua patterns are not PCRE.

### init.lua (excerpt — `grep`)

```lua
zay.register_tool({
  name = "grep",
  description = "Search file contents recursively. Returns matches grouped by file as `path:` headers with indented `Line N: <content>` entries. By default does a literal substring search with Zay's built-in search (no external tools; skips dotfiles but scans gitignored dirs like vendor/). Set regex=true for full regular expressions (alternation `a|b`, `.*`, character classes) via ripgrep, which respects .gitignore and requires `rg` installed. Supports an `include` glob filter (e.g. '*.zig'). ...",
  parameters = {
    pattern = { type = "string", description = "Text pattern to search for" },
    path = { type = "string", description = "Root directory to search in (default: project root)", optional = true },
    include = { type = "string", description = "File glob filter (e.g. '*.zig', '*.lua')", optional = true },
    regex = { type = "boolean", description = "Treat pattern as a regex via ripgrep (default false = literal substring via built-in search)", optional = true },
    case_sensitive = { type = "boolean", description = "Case-sensitive search (default false)", optional = true },
    max_results = { type = "integer", description = "Maximum matches to return (default 50, max 200)", optional = true },
  },
  ...
})
```

Key points:
- The default backend is pure Zig (`zay.search_files`) — no shell needed
- Regex mode shells out to `rg`, with every dynamic value on the command line
  quoted through `zay.shell_quote` (dialect matched to the runner) — the
  injection defense
- Scope differs by backend: ripgrep honors `.gitignore`; the native walker
  skips dotfiles but scans gitignored dirs (`vendor/`, `zig-cache/`)

## Testing Your Plugin

1. Create a `test.lua` file in your plugin directory
2. Use the `test_runner` global (pre-loaded by the test runner)
3. Run with: `zig build test-plugin` — the build step runs every shipped
   example's `test.lua` (add a new plugin's file to the arg list in
   `build.zig`). Appending a path after `--` runs your file *in addition to*
   the shipped suite, not instead of it.

```lua
local test = test_runner

test.describe("my plugin", function()
  test.it("works correctly", function()
    test.assert.equal(42, 42)
  end)
end)
```

## Next Steps

- Read the full [API Reference](api-reference.md) for all available functions
- See the [Plugin Development Guide](README.md) for setup and permissions
- Check `docs/plugins/` for the complete documentation set
