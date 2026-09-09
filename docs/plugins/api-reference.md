# Zay Plugin API Reference

## `zay` Global Table

The `zay` table is the primary API surface for plugins. It is injected into
the plugin's sandboxed environment at load time.

### `zay.register_tool(spec)`

Register a tool that the AI model can invoke.

**Parameters:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Tool identifier (lowercase, underscores). Must be unique within the plugin. Exposed to the AI model as `lua__<plugin>__<name>`. |
| `description` | string | yes | Natural language description of what the tool does. The model uses this to decide when to call the tool. |
| `parameters` | table | no | JSON Schema-like parameter definitions. Each key is a parameter name, each value is a parameter-schema table (below). Omitted or empty → the tool takes no parameters. |
| `handler` | function | yes | Called with `(params)` when the model invokes the tool. `params` is a Lua table — JSON arguments from the model are automatically parsed. Must return a string. |

**Parameter schema:**

```lua
{
  count = {
    type = "number",       -- "string", "number", "integer", "boolean", "object", "array"
    description = "...",   -- Description for the model
    optional = true,       -- If true, the model may omit this parameter
    nullable = true,       -- If true, the model may pass JSON null (strict mode emits ["<type>","null"])
    enum = { "low", "high" },        -- Allowed values, surfaced to the model
    default = "10",        -- JSON fragment recorded in the schema (informational)
  },
}
```

**Returns:** `true` on success, `nil` on error.

---

### `zay.on(event_name, callback)`

Subscribe to a lifecycle event.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `event_name` | string | The event to subscribe to (see Events below). |
| `callback` | function | Function to call when the event fires. Receives a data table. |

**Returns:** `true` on success, `nil` on error.

**Events:**

Only `tool_call_started` and `tool_call_finished` are currently emitted in
production (by the agent around each tool dispatch). The other five are
subscribable but not currently emitted — they stay in the allow-list for
forward compatibility.

| Event | Data Fields | Description |
|-------|-------------|-------------|
| `turn_started` | `{}` | A new agent turn has started. *(not currently emitted)* |
| `turn_ended` | `{}` | An agent turn has ended. *(not currently emitted)* |
| `tool_call_started` | `{name, call_id}` | A tool execution began. |
| `tool_call_finished` | `{name, call_id, success}` | A tool execution completed. |
| `response_received` | `{}` | A response was received from the LLM. *(not currently emitted)* |
| `plugin_loaded` | `{name}` | A plugin was loaded. *(not currently emitted)* |
| `plugin_unloaded` | `{name}` | A plugin was unloaded. *(not currently emitted)* |

---

## `plugin` Global Table

The `plugin` table provides access to plugin-specific functionality. `plugin`
is a reserved global name for plugins — do not use it as a variable.

### `plugin.get_config()`

Returns the plugin's configured settings as a **fresh table on every call**,
or `nil` when the plugin has no config entry or no settings.

- Settings come from the plugin's `config.json` entry and are read once at
  App start (restart Zay to apply config changes). Both settings forms work
  (see `docs/CONFIG.md`): an escaped JSON string, or an inline JSON object.
- `plugins.<name>.enabled: false` means the plugin is never loaded at all —
  `get_config()` is moot for it.
- Malformed or non-object settings (e.g. a JSON array) return
  `nil, "get_config: settings must be a JSON object"`.
- Mutation is safe: each call re-parses the stored settings, so changing the
  returned table never corrupts the stored view (but also never persists).

**Example config.json:**

```json
{
  "plugins": {
    "my-plugin": {
      "enabled": true,
      "settings": { "theme": "dark", "max_results": 20 }
    }
  }
}
```

**Example usage:**

```lua
local config = plugin.get_config()
local theme = config and config.theme or "light"
```

### Plugin state (no `plugin.get_state`/`set_state` bridges)

There is no `plugin.get_state()`/`plugin.set_state()` bridge. The reload flow
calls the plugin's **top-level Lua globals** `get_state()`/`set_state(state)`
(`PluginManager.reload`), and that state is in-memory only — it is lost when
Zay restarts. For durable state, write a file sidecar under the project
(e.g. `.zay/<plugin>/state.json` via `zay.write_file`/`zay.json_encode`)
— this is the blessed pattern; the `todo` example plugin uses it.

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

## `zay` Bridge Functions

### Filesystem

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `zay.read_file(path, opts?)` | `path`, `opts.start_line`, `opts.end_line`, `opts.max_size` | `{path, content, size, lines, truncated, full_size, language, mime_type}` | Read file with metadata (`truncated`/`full_size` are set when the read cap clipped the body) |
| `zay.write_file(path, content)` | `path`, `content` | `true` or `nil` | Atomic file write (temp + rename) |
| `zay.edit_file(path, old, new)` | `path`, `old_string`, `new_string` | `true` or `nil` | Find-and-replace (first occurrence); refuses files over the 1 MB read cap (`nil, "…FileTooLarge…"`-class error) |
| `zay.search_files(root, pattern, opts?)` | `root`, `pattern`, `opts.file_pattern`, `opts.case_sensitive`, `opts.max_results` | `{query, total_matches, results, truncated}` | Recursive content search (grep); `max_results` default 50, hard cap 200 |
| `zay.find_files(root, pattern, opts?)` | `root`, `pattern`, `opts.max_results` | `{root, total_matches, truncated, results}` | Recursive filename glob (`**`, `*`, `?`); `max_results` default 100, hard cap 200; dotfile entries are skipped |
| `zay.list_dir(path)` | `path` | `{path, files, directories, total_items}` | Directory listing |
| `zay.file_info(path)` | `path` | `{size, type, extension, language, mime_type}` | File metadata |
| `zay.mkdir(path)` | `path` | `true` or `nil` | Create directory recursively |
| `zay.copy_path(src, dst)` | `src`, `dst` | `true` or `nil` | Copy a single file |
| `zay.move_path(src, dst)` | `src`, `dst` | `true` or `nil` | Move/rename file or directory |
| `zay.delete_path(path, opts?)` | `path`, `opts.recursive` | `true` or `nil` | Delete file or directory safely |

### Shell & Environment

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `zay.run_shell(cmd, opts?)` | `cmd`, `opts.cwd`, `opts.timeout`, `opts.stdin` | `{stdout, stderr, code}` | Platform-native shell (`pwsh.exe` on Windows, `bash` on POSIX) |
| `zay.run_bash(cmd, opts?)` | `cmd`, `opts.cwd`, `opts.timeout`, `opts.stdin` | `{stdout, stderr, code}` | Bash command execution (git-bash on Windows) |
| `zay.shell_quote(s, dialect?)` | `s`, `dialect` (`"posix"` default, or `"native"`) | quoted `string` or `nil, err` | Quote one argument for a shell command line (see below) |
| `zay.get_env(name)` | `name` | `string` or `nil` | Environment variable |
| `zay.get_cwd()` | — | `string` | Effective cwd of the current dispatch/event callback — a lane worktree root, or a resumed session's cwd; outside dispatch (init.lua load) the process cwd |
| `zay.get_project_root()` | — | `string` | Git root of the effective cwd (worktree root in a worktree, matching `git rev-parse --show-toplevel`) |

**`opts.stdin`** (string): bytes written to the child's stdin, then closed —
e.g. `zay.run_bash("cat", { stdin = "hello" })` returns
`{ stdout = "hello", code = 0 }`.

**`opts.timeout`** is in seconds: default 30, maximum 3600.

**Shell safety gate.** Every `run_bash`/`run_shell` command is classified by
the same shell-safety checker as the built-in `bash` tool *before* it runs.
A rejected command returns
`nil, "UnsafeShellBlocked: command rejected by Zay's shell safety classifier; use the built-in bash tool for destructive commands"`.
There is no approval flow at the plugin bridge — the channel for destructive
work is the model-facing built-in `bash` tool, where the user can approve.
When no remote classifier is reachable (or none is configured), an always-armed
local pattern matcher still blocks obviously destructive forms (`rm -rf /`-
class, fork bombs, and their PowerShell spellings); plugin shell calls made
outside tool dispatch (e.g. during `init.lua` load, where no executor context
exists) are classified by that local backstop only. An empty command string
returns `nil, "command argument must not be empty"` before anything spawns.
If the shell binary itself is missing, the call returns one of
`"ShellUnavailable: bash not found (install Git Bash on Windows, or ensure bash is on PATH); consider zay.run_shell"`
or
`"ShellUnavailable: pwsh not found (install PowerShell 7, or ensure powershell.exe is on PATH)"`.

**`zay.shell_quote(s, dialect?)`** quotes one argument so it reaches the
shell as a single inert word — this is the injection defense on the plugin
path, and it keeps the *intended* command equal to the *classified* command.
Always quote interpolated values instead of concatenating raw strings:

- `"posix"` (default): wrap in `'...'`, escape embedded `'` as `'\''` —
  correct for `run_bash` on both platforms (git-bash on Windows is a POSIX
  shell).
- `"native"`: the `run_shell` interpreter's rule — identical to posix on
  POSIX; on Windows (PowerShell) escape `'` as `''`.
- Any other dialect returns `nil, "shell_quote: dialect must be \"posix\" or \"native\""`.

```lua
local q = zay.shell_quote(user_input)
local r = zay.run_bash("grep -c " .. q .. " src/*.zig")
```

### Git

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `zay.git_status()` | — | `string` | Git status (porcelain) |
| `zay.git_diff(path?)` | `path` (optional) | `string` | Git diff |
| `zay.git_log(n)` | `n` (default 10) | `string` | Recent commits |
| `zay.git_branch()` | — | `string` | Current branch name |
| `zay.git_add(files)` | `files` (string or array) | `{success, output}` | Stage specific files or patterns |
| `zay.git_commit(msg, opts?)` | `msg`, `opts.files`, `opts.staged_only`, `opts.stage_all` | `{success, output}` | Create commit (selective or staged) |

### Lane & session awareness

All filesystem bridges (`read_file`, `write_file`, `edit_file`, `search_files`,
`find_files`, `list_dir`, `file_info`, `mkdir`, `copy_path`, `move_path`,
`delete_path` — path confinement resolves against the effective cwd via
`sanitizePath`) plus the git and shell bridges (`zay.git_status`,
`zay.git_diff`, `zay.git_log`, `zay.git_branch`, `zay.git_add`,
`zay.git_commit`, `zay.get_cwd`, `zay.get_project_root`, `zay.run_shell`,
`zay.run_bash`) operate on the **effective cwd** automatically — no
`git -C <path>` workarounds needed. The effective cwd is:

- A **lane worktree root** when the call is made from a lane worker agent.
- The **resumed session's project root** after a cross-project `/resume`.
- The **process cwd** (Zay's launch directory) when called outside tool
  dispatch (e.g. during `init.lua` load).

A lane/session descriptor table (id, branch, main-repo path) is a possible
future addition.

### Plugin System & Modular Code

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `zay.require(mod_path)` | `mod_path` | `any` | Load relative Lua module with caching and directory confinement |
| `zay.register_tool(spec)` | `spec.name`, `spec.description`, `spec.parameters`, `spec.handler` | `true` | Register a tool |
| `zay.on(event, callback)` | `event`, `callback` | `true` | Subscribe to event |
| `zay.think(prompt)` | `prompt` | _(stub)_ | Recursive LLM call (not yet implemented) |

### JSON

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `zay.json_decode(str)` | JSON `string` | Lua value or `nil, err` | Parse JSON into a native Lua value (objects → tables, arrays → 1-indexed tables). |
| `zay.json_encode(value, opts?)` | any value, `opts.pretty` | JSON `string` or `nil, err` | Serialize a Lua value to JSON. Contiguous 1..N integer keys → array; otherwise object. `pretty=true` → indent_2. |

These bridges let plugins parse and emit structured data without hand-rolling a
parser or shelling out to `jq`. `json_decode` reuses Zay's `std.json` parser;
`json_encode` traverses the Lua value and infers array vs object from key shape.

---

## Platform Support Matrix

Windows runtime support is in progress (tracked in issues #26–#29); the matrix
below reflects the current state of the bridge.

| Bridge | POSIX | Windows |
|--------|-------|---------|
| `zay.run_bash` | bash | git-bash candidates (`bash.exe` next to git, then `bash` on PATH); if none is found → `ShellUnavailable: bash not found …` |
| `zay.run_shell` | bash | `pwsh.exe`, falling back to `powershell.exe`; stdin is delivered via `$input`; if neither is found → `ShellUnavailable: pwsh not found …` |
| `zay.shell_quote` | `"posix"` and `"native"` behave identically | `"posix"` for `run_bash` (git-bash is POSIX); `"native"` applies the PowerShell `''` rule for `run_shell` |
| Path confinement (`opts.cwd`, path bridges) | cwd-confinement + symlink realpath re-check | cwd-confinement (lexical verdict; the realpath re-check is POSIX-only) |
| Shell safety gate | local matcher always armed; remote classifier when configured | same, and pwsh destructive patterns (`Remove-Item -Recurse -Force …`) are covered by the local matcher too |

Note for command authors: flags like `-init /dev/null` must be spelled with
`NUL` on Windows (`-init NUL`) — `/dev/null` does not exist there.

---

## Testing Plugins

See `docs/plugins/README.md` for the `test.lua` convention and
`zig build test-plugin`. When writing Zig-side tests for bridge behavior,
platform-specific paths are gated with `if (os.is_windows) return error.SkipZigTest;`
(the established convention in `src/lua/plugin_api.zig`); Lua-side `test.lua`
files should stick to portable constructs (no real process spawns) so the
same suite runs on every platform.
