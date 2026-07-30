# Nova Plugin API Reference

## `nova` Global Table

The `nova` table is the primary API surface for plugins. It is injected into
the plugin's sandboxed environment at load time.

### `nova.register_tool(spec)`

Register a tool that the AI model can invoke.

**Parameters:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Tool identifier (lowercase, underscores). Must be unique within the plugin. Exposed to the AI model as `lua__<plugin>__<name>`. |
| `description` | string | yes | Natural language description of what the tool does. The model uses this to decide when to call the tool. |
| `parameters` | table | yes | JSON Schema-like parameter definitions. Each key is a parameter name, each value is a table with `type`, `description`, and optional `optional` fields. |
| `handler` | function | yes | Called with `(params)` when the model invokes the tool. `params` is a Lua table — JSON arguments from the model are automatically parsed. Must return a string. |

**Parameter schema:**

```lua
{
  name = {
    type = "string",       -- "string", "number", "boolean"
    description = "...",   -- Description for the model
    optional = true,       -- If true, the model may omit this parameter
  },
}
```

**Returns:** `true` on success, `nil` on error.

---

### `nova.on(event_name, callback)`

Subscribe to a lifecycle event.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `event_name` | string | The event to subscribe to (see Events below). |
| `callback` | function | Function to call when the event fires. Receives a data table. |

**Returns:** `true` on success, `nil` on error.

**Events:**

| Event | Data Fields | Description |
|-------|-------------|-------------|
| `turn_started` | `{}` | A new agent turn has started. |
| `turn_ended` | `{}` | An agent turn has ended. |
| `tool_call_started` | `{name, call_id}` | A tool execution began. |
| `tool_call_finished` | `{name, call_id, success}` | A tool execution completed. |
| `response_received` | `{}` | A response was received from the LLM. |
| `plugin_loaded` | `{name}` | A plugin was loaded. |
| `plugin_unloaded` | `{name}` | A plugin was unloaded. |

---

### `nova.unsubscribe(event_name, callback)`

Unsubscribe a callback from an event. Both `event_name` and the exact callback
function reference must match.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `event_name` | string | The event to unsubscribe from. |
| `callback` | function | The callback function to remove. |

**Returns:** `true` if the callback was found and removed, `false` otherwise.

---

## `plugin` Global Table

The `plugin` table provides access to plugin-specific functionality.

### `plugin.get_config()`

Returns the plugin's configuration from `config.json`, or `nil` if no
configuration is set.

**Returns:** A Lua table parsed from the `settings` JSON string in the
plugin's config entry, or `nil`.

**Example config.json:**

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

**Example usage:**

```lua
local config = plugin.get_config()
local theme = config.theme or "light"
```

---

### `plugin.get_state()`

Called by Nova to retrieve the plugin's persistent state before a reload.
The plugin should return a string (JSON recommended).

**Returns:** A string representing the plugin's state, or `nil` if no state.

---

### `plugin.set_state(state)`

Called by Nova to restore the plugin's persistent state after a reload.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `state` | string | The state string previously returned by `get_state()`. |

---

## `test_runner` Module

A minimal test framework for Lua plugins. See `docs/plugins/README.md` for usage.

### `test_runner.describe(name, fn)`

Define a test suite.

### `test_runner.it(name, fn)`

Define a single test case (must be inside `describe()`).

### `test_runner.assert`

Assertion table with methods:

| Method | Description |
|--------|-------------|
| `is_true(value, msg)` | Assert value is truthy |
| `is_false(value, msg)` | Assert value is falsy |
| `equal(expected, actual, msg)` | Assert equality |
| `not_equal(a, b, msg)` | Assert inequality |
| `matches(pattern, str, msg)` | Assert string matches Lua pattern |
| `error(fn, msg_pattern, msg)` | Assert function raises an error |
| `has_key(key, tbl, msg)` | Assert table has a key |
| `contains(sub, str, msg)` | Assert string contains substring |

### `test_runner.run()`

Run all registered test suites. Returns `true` if all tests pass.

---

## `nova` Bridge Functions

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

### JSON

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `nova.json_decode(str)` | JSON `string` | Lua value or `nil, err` | Parse JSON into a native Lua value (objects → tables, arrays → 1-indexed tables). |
| `nova.json_encode(value, opts?)` | any value, `opts.pretty` | JSON `string` or `nil, err` | Serialize a Lua value to JSON. Contiguous 1..N integer keys → array; otherwise object. `pretty=true` → indent_2. |

These bridges let plugins parse and emit structured data without hand-rolling a
parser or shelling out to `jq`. `json_decode` reuses Nova's `std.json` parser;
`json_encode` traverses the Lua value and infers array vs object from key shape.
