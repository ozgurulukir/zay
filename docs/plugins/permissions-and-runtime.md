## Plugin Discovery

Zay discovers plugins from these directories:

| Directory | Scope |
|-----------|-------|
| `~/.config/zay/plugins/` | Global — available in all projects (on Windows, `%APPDATA%\zay\plugins` is probed first, falling back to `.config\zay\plugins`) |
| `plugins/` | Project-local plugins; `plugins/packages/` contains distribution/catalog packages |
| `.zay/plugins/` | Project-local plugins — read as a fallback for existing projects |

Each subdirectory containing a `plugin.lua` file is treated as a plugin.

## Plugin Store

Open `/plugins` in the TUI. The Store tab always includes the Zay GitHub
catalog; when running from a Zay checkout it uses `plugins/store.json`, and
otherwise it fetches the same catalog from the repository. Plugin packages and
their catalog live together under `plugins/`. Press `a`, enter another HTTP(S)
catalog URL, and press Enter to save it and refresh the catalog list. Select a
plugin and press Enter to stage it into the user's global plugin directory.
Use Tab to move among Installed, Store, and Sources. Sources shows custom
catalog status, including stale cached entries and fetch errors. Press Space
to disable or re-enable a source, `x` to remove it, and `r` to retry catalog
refresh.
Store URLs are persisted globally in `plugin-stores.json` under Zay's platform
config directory; installing from a checkout does not make the checkout dirty.
In the Installed tab, press Space to enable or disable a plugin for the current
project; restart Zay to apply the change. Press `x` to remove a disabled global
installation after restarting to unload it, and confirm with `y`. Project
plugins are not deleted by the Store removal action.

Remote catalogs use explicit file URLs and must include `plugin.lua` and
`init.lua` for each plugin. Catalogs and files have bounded sizes, relative
package paths, and safe plugin IDs; installs are published only after all
files are validated. Restart Zay to activate a newly installed plugin.
Same-project sessions reuse the loaded plugin set. A guarded cross-project
resume rediscovers project plugins only when no lane turn is active.

### Plugin prompts

A directory containing `plugin.lua` may provide `prompt.md` instructions.
These use the manifest name for enablement and are included only for the
active physical copy loaded by the runtime. Disabled, invalid, failed-init,
and shadowed copies do not contribute tool instructions. A directory with
`prompt.md` and no manifest is intentionally supported as standalone prompt
content. Same-project lanes clone the assembled prompt inputs; plugin
changes take effect at restart or the guarded project-switch boundary.

## Plugin API — `zay` Bridge Functions

### Filesystem

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `zay.read_file(path, opts?)` | `path`, `opts.start_line`, `opts.end_line`, `opts.max_size` | `{path, content, size, lines, truncated, full_size, language, mime_type}` | Read file with metadata (`truncated`/`full_size` are set when the read cap clipped the body) |
| `zay.write_file(path, content)` | `path`, `content` | `true` or `nil` | Atomic file write |
| `zay.edit_file(path, old, new)` | `path`, `old_string`, `new_string` | `true` or `nil` | Find-and-replace (first occurrence) |
| `zay.search_files(root, pattern, opts?)` | `root`, `pattern`, `opts.file_pattern`, `opts.case_sensitive`, `opts.max_results` | `{query, total_matches, results, truncated}` | Recursive content grep (substring) |
| `zay.find_files(root, pattern, opts?)` | `root`, `pattern` (glob), `opts.max_results` | `{root, total_matches, truncated, results}` | Recursive filename glob match |
| `zay.list_dir(path)` | `path` | `{path, files, directories, total_items}` | Directory listing (single level). `files`/`directories` are **arrays of plain name strings**, not tables |
| `zay.file_info(path)` | `path` | `{size, type, extension, language, mime_type}` | File metadata |
| `zay.mkdir(path)` | `path` | `true` or `nil` | Create directory (recursive, with parents) |
| `zay.copy_path(src, dst)` | `source_path`, `destination_path` | `true` or `nil` | Copy a single file |
| `zay.move_path(src, dst)` | `source_path`, `destination_path` | `true` or `nil` | Move/rename a file or directory |
| `zay.delete_path(path, opts?)` | `path`, `opts.recursive` | `true` or `nil` | Delete file or directory (recursive opt-in) |

Result rows: `search_files` → `{file, line, content}` (content truncated to 200 bytes per line); `find_files` → `{path, name}`. On a mid-walk failure the bridge returns partial data with an `error` string field and **no** `truncated` field — check `result.error` before trusting `results`.

All filesystem functions validate paths through `sanitizePath`: relative paths
resolve against the active workspace/effective cwd and are **rejected if they
escape it**. This
makes the dedicated path ops (`mkdir`/`copy_path`/`move_path`/`delete_path`)
safer and more precise than shell-outs: `zay.run_bash` commands pass through
the shell safety classifier (destructive forms are hard-blocked with
`UnsafeShellBlocked` — see the API reference), but the dedicated tools carry
no shell-quoting or classification burden at all. Prefer them for file
operations.

`zay.find_files` supports glob patterns: `**` (spans directories), `*`
(within a segment), `?` (single char). Example: `find_files(".", "**/*.zig")`
matches every `.zig` file at any depth. gitignore is NOT honored.

### Shell & Environment

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `zay.run_bash(cmd, opts?)` | `cmd`, `opts.cwd`, `opts.timeout`, `opts.stdin` | `{stdout, stderr, code}` | Bash command execution, gated by the shell safety classifier |
| `zay.run_shell(cmd, opts?)` | `cmd`, `opts.cwd`, `opts.timeout`, `opts.stdin` | `{stdout, stderr, code}` | Platform-native shell (pwsh on Windows, bash on POSIX), same gate |
| `zay.shell_quote(s, dialect?)` | `s`, `dialect` (`"posix"` default, `"native"`) | `string` or `nil, err` | Quote one argument for a shell command line — use it for every interpolated value |
| `zay.get_env(name)` | `name` | `string` or `nil` | Environment variable |
| `zay.get_cwd()` | — | `string` | Current working directory |
| `zay.get_project_root()` | — | `string` | Git repo root or cwd |

### Git

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `zay.git_status()` | — | `string` | Git status (porcelain) |
| `zay.git_diff(path?)` | `path` (optional) | `string` | Git diff |
| `zay.git_log(n)` | `n` (default 10) | `string` | Recent commits |
| `zay.git_branch()` | — | `string` | Current branch name |
| `zay.git_add(files)` | one path `string` or array of paths | `{success, output}` | Stage files for commit |
| `zay.git_commit(msg, opts?)` | `msg`, `opts.files`, `opts.staged_only` | `{success, output}` | Create commit; with neither option it runs `git add -A` first (see the API reference) |

### Plugin System

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `zay.register_tool(spec)` | `spec.name`, `spec.description`, `spec.parameters`, `spec.handler` | `true` | Register a tool |
| `zay.on(event, callback)` | `event`, `callback` | `true` | Register a callback; only tool-call events currently fire |
| `zay.require(mod_path)` | module path relative to the plugin dir | module table | Load another Lua module from the plugin directory (cached; circular requires safe) |
| `zay.think(prompt)` | `prompt` | _(stub)_ | Recursive LLM call (not yet implemented) |

### JSON

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `zay.json_decode(str)` | JSON `string` | Lua value (table/string/number/boolean/nil) or `nil, err` | Parse JSON into a native Lua value. Objects → tables, arrays → 1-indexed tables. |
| `zay.json_encode(value, opts?)` | any Lua value, `opts.pretty` (bool) | JSON `string` or `nil, err` | Serialize a Lua value to JSON. Tables with contiguous 1..N integer keys become arrays `[...]`; others become objects `{...}`. Empty tables serialize as `[]`. Set `opts.pretty = true` for indent_2 output (human-editable files). Functions/userdata/threads (no JSON form) emit `null`. |

Use these instead of hand-rolling a JSON parser or shelling out to `jq`. They
round-trip cleanly: `json_decode(json_encode(t))` recovers `t` for data tables.
Note: Lua tables have no array/map distinction, so the encoder infers it from the
key shape — a table with non-integer or sparse keys serializes as an object.

### Events

`zay.on(event_name, callback)` registers a callback for an event. The callback
receives a `data` table whose shape depends on the event. Events are emitted by
the agent loop at tool-call boundaries and delivered to every active plugin.
Only `tool_call_started` and `tool_call_finished` are currently emitted in
production; the other five accepted event names do not currently fire.

| Event | `data` shape | When it fires |
|-------|--------------|---------------|
| `turn_started` | `{}` | A new agent turn starts *(not currently emitted)* |
| `turn_ended` | `{}` | An agent turn ends *(not currently emitted)* |
| `tool_call_started` | `{ name, call_id }` | A tool call begins |
| `tool_call_finished` | `{ name, call_id, success }` | A tool call completes |
| `response_received` | `{}` | A response was received from the LLM *(not currently emitted)* |
| `plugin_loaded` | `{ name }` | A plugin was loaded *(not currently emitted)* |
| `plugin_unloaded` | `{ name }` | A plugin was unloaded *(not currently emitted)* |

```lua
zay.on("tool_call_finished", function(data)
  if data.name == "lua__file-tools__write" and data.success then
    -- track that a file was written this turn
  end
end)
```

Callbacks run synchronously on the agent worker thread, at the boundary
between tool calls (after the plugin's own handler has returned), so it is safe
to read/write the plugin's own Lua state.

### Plugin state persistence (reload)

State persistence across plugin reloads uses **global functions**, not a
`plugin.*` namespace. Define top-level `get_state()` and `set_state(state)`
functions in your `init.lua`. `PluginManager` calls them at reload time:

```lua
-- Return a string (JSON recommended) to be saved.
function get_state()
  return encode_state(my_state_table)
end

-- Receive the previously-saved string.
function set_state(state)
  my_state_table = decode_state(state)
end
```

This state is in-memory only and is lost on restart. For durable state, write
a file sidecar (`.zay/<plugin>/state.json` via `zay.write_file` +
`zay.json_encode`) — the pattern the `todo` example plugin uses.

### Plugin configuration

`plugin.get_config()` returns your plugin's `config.json` settings as a table
(or `nil` when unconfigured). `plugin` is a reserved global name. Settings are
read once at App start — set `"enabled": false` in config.json to skip loading
a plugin entirely; either way, restart Zay to apply config changes. See the
API reference for the full contract and `docs/CONFIG.md` for both settings
forms (escaped JSON string or inline object).

## Permissions

Plugins declare permissions in their manifest. Permissions are granted at load
time and cannot be changed at runtime. Only the two `allow_*` keys actually
gate runtime behavior; the first three are **advisory metadata** — declared
intent for readers and review — because the sandbox never exposes `io.*` or
sockets to any plugin regardless of what it declares.

| Permission | Description | Default | Enforced |
|------------|-------------|---------|----------|
| `file_access` | Declares the plugin reads/writes files (via `zay.*` bridges) | `false` | advisory only — `io.*` is never exposed |
| `network_access` | Declares the plugin needs network access | `false` | advisory only — no network API exists in the sandbox |
| `require_others` | Declares the plugin may `require()` modules | `true` | advisory only — `zay.require` is always scoped to the plugin's own directory |
| `allow_os_execute` | Allow `os.execute` | `false` | yes |
| `allow_os_remove` | Allow `os.remove`/`os.rename` (routed to sandboxed `deletePath`/`movePath`) | `false` | yes |

Embedded plugins (shipped with Zay) always get full access.
