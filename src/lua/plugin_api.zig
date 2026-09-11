//! Plugin API bridge — exposes Zay's filesystem to Lua plugins.
//!
//! Each function is a C-callable `lua_CFunction` registered in the `zay`
//! table before the sandbox is created. Plugins call these instead of `io.*`,
//! which is blocked by the sandbox. All file operations go through
//! path validation (traversal guard) and size limits.
//!
//! ## Registered functions
//!
//! - `zay.read_file(path, opts?)` — read file with line range + metadata
//! - `zay.write_file(path, content)` — atomic file write
//! - `zay.edit_file(path, old_string, new_string)` — safe find-and-replace
//! - `zay.search_files(root, pattern, opts?)` — recursive grep
//! - `zay.find_files(root, pattern, opts?)` — recursive filename glob match
//! - `zay.list_dir(path)` — list directory contents
//! - `zay.file_info(path)` — file metadata
//! - `zay.mkdir(path)` — create a directory (recursive)
//! - `zay.copy_path(src, dst)` — copy a file
//! - `zay.move_path(src, dst)` — move/rename a file or directory
//! - `zay.delete_path(path, opts?)` — delete a file or directory
//! - `zay.run_bash(cmd, opts?)` — shell command execution
//! - `zay.get_env(name)` — environment variable reading
//! - `zay.get_cwd()` — current working directory
//! - `zay.get_project_root()` — project root
//! - `zay.register_tool(spec)` — register a tool for the AI model
//! - `zay.on(event, callback)` — subscribe to a lifecycle event

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const os = @import("../os.zig");
const State = @import("state.zig").State;
const bridge = @import("bridge.zig");
const bash_exec = @import("../tools/bash_exec.zig");
const pwsh_exec = @import("../tools/pwsh_exec.zig");
const bash_safety = @import("../tools/bash_safety.zig");
const sandbox_mod = @import("sandbox.zig");
pub const json_bridge = @import("bridges/json.zig");
pub const git_bridge = @import("bridges/git.zig");
pub const shell_bridge = @import("bridges/shell.zig");
pub const fs_bridge = @import("bridges/fs.zig");
pub const search_bridge = @import("bridges/search.zig");

pub const max_read_size = fs_bridge.max_read_size;
pub const max_search_results = search_bridge.max_search_results;
pub const find_files_default_max_results = search_bridge.find_files_default_max_results;
pub const search_line_truncate_bytes = search_bridge.search_line_truncate_bytes;

pub const lang_map = fs_bridge.lang_map;
pub const mime_map = fs_bridge.mime_map;


/// Retrieve the Io instance stored in the Lua registry.
pub const getIo = bridge.getIo;

/// ── zay.require(path) ───────────────────────────────────────────────
///
/// Loads a Lua module relative to the plugin's root directory.
/// Modules are confined to the plugin directory (INV-REQ-1) and cached
/// in `zay_loaded_modules` (INV-REQ-3).
pub fn requireModule(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const mod_path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("module path argument is required");
        return 2;
    };

    // Get plugin root directory from registry
    _ = c.lua_getfield(L_ptr, c.LUA_REGISTRYINDEX, "zay_plugin_dir");
    const plugin_dir_str = state.toString(-1);
    if (plugin_dir_str == null or plugin_dir_str.?.len == 0) {
        state.pop(1);
        state.pushNil();
        state.pushString("zay.require is only available within loaded plugins");
        return 2;
    }
    const plugin_dir = plugin_dir_str.?;
    const plugin_dir_owned = std.heap.page_allocator.dupe(u8, plugin_dir) catch {
        state.pop(1);
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(plugin_dir_owned);
    state.pop(1);

    // Normalize module path: strip leading "./" or ".\\" if present
    const clean_mod_path = if (std.mem.startsWith(u8, mod_path, "./") or std.mem.startsWith(u8, mod_path, ".\\"))
        mod_path[2..]
    else
        mod_path;

    // Resolve candidates:
    // 1. If clean_mod_path ends with ".lua": try plugin_dir/clean_mod_path
    // 2. Else: try plugin_dir/clean_mod_path.lua, plugin_dir/clean_mod_path/init.lua, plugin_dir/clean_mod_path
    const CandidateType = enum { direct, lua_ext, init_lua };
    const candidates: []const CandidateType = if (std.mem.endsWith(u8, clean_mod_path, ".lua"))
        &.{.direct}
    else
        &.{ .lua_ext, .init_lua, .direct };

    var found_path: ?[]u8 = null;
    defer if (found_path) |p| std.heap.page_allocator.free(p);

    for (candidates) |cand| {
        const cand_rel: []u8 = switch (cand) {
            .direct => std.heap.page_allocator.dupe(u8, clean_mod_path) catch continue,
            .lua_ext => std.fmt.allocPrint(std.heap.page_allocator, "{s}.lua", .{clean_mod_path}) catch continue,
            .init_lua => std.fmt.allocPrint(std.heap.page_allocator, "{s}/init.lua", .{clean_mod_path}) catch continue,
        };
        defer std.heap.page_allocator.free(cand_rel);

        const resolved = std.fs.path.resolve(std.heap.page_allocator, &.{ plugin_dir_owned, cand_rel }) catch continue;
        errdefer std.heap.page_allocator.free(resolved);

        // Confinement check (INV-REQ-1):
        if (!std.mem.startsWith(u8, resolved, plugin_dir_owned) or
            (resolved.len > plugin_dir_owned.len and resolved[plugin_dir_owned.len] != std.fs.path.sep))
        {
            std.heap.page_allocator.free(resolved);
            state.pushNil();
            state.pushString("access denied: cannot require module outside plugin directory");
            return 2;
        }

        // Check if file exists
        if (std.Io.Dir.accessAbsolute(io, resolved, .{})) |_| {
            found_path = resolved;
            break;
        } else |_| {
            std.heap.page_allocator.free(resolved);
        }
    }

    const resolved_path = found_path orelse {
        state.pushNil();
        state.pushString("module not found");
        return 2;
    };

    // Check registry table zay_loaded_modules
    _ = c.lua_getfield(L_ptr, c.LUA_REGISTRYINDEX, "zay_loaded_modules");
    const reg_tbl_idx = c.lua_gettop(L_ptr);

    const resolved_path_z = std.heap.page_allocator.dupeZ(u8, resolved_path) catch {
        c.lua_pop(L_ptr, 1);
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(resolved_path_z);

    _ = c.lua_getfield(L_ptr, reg_tbl_idx, resolved_path_z.ptr);
    if (!c.lua_isnil(L_ptr, -1)) {
        // Module is already loaded/cached. Remove the cache table from under the value.
        c.lua_remove(L_ptr, reg_tbl_idx);
        return 1;
    }
    // Pop the nil
    c.lua_pop(L_ptr, 1);

    // Read module file
    const content = readFileBytes(io, resolved_path, max_read_size) catch |err| {
        c.lua_pop(L_ptr, 1); // pop reg_tbl
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(content);

    // Load chunk
    const load_rc = c.luaL_loadbufferx(L_ptr, content.ptr, content.len, resolved_path_z.ptr, null);
    if (load_rc != c.LUA_OK) {
        c.lua_pop(L_ptr, 1); // pop reg_tbl
        // Error message is on top of stack from loadbuffer
        state.pushNil();
        c.lua_insert(L_ptr, -2); // swap so nil is 1st and err msg is 2nd
        return 2;
    }

    // Mark module as loading (boolean true sentinel to guard circular require)
    c.lua_pushboolean(L_ptr, 1);
    c.lua_setfield(L_ptr, reg_tbl_idx, resolved_path_z.ptr);

    // Execute chunk under pcall(0, 1)
    const run_rc = c.lua_pcallk(L_ptr, 0, 1, 0, 0, null);
    if (run_rc != c.LUA_OK) {
        // Clear cache on failure
        c.lua_pushnil(L_ptr);
        c.lua_setfield(L_ptr, reg_tbl_idx, resolved_path_z.ptr);
        c.lua_remove(L_ptr, reg_tbl_idx); // remove reg table
        // Error message is on top of stack
        state.pushNil();
        c.lua_insert(L_ptr, -2);
        return 2;
    }

    // Successful execution:
    // If the module returned nil, default to boolean true (standard Lua require convention)
    if (state.isNil(-1)) {
        c.lua_pop(L_ptr, 1);
        c.lua_pushboolean(L_ptr, 1);
    }

    // Cache the return value
    c.lua_pushvalue(L_ptr, -1);
    c.lua_setfield(L_ptr, reg_tbl_idx, resolved_path_z.ptr);

    // Remove the cache table, leaving the return value on top
    c.lua_remove(L_ptr, reg_tbl_idx);
    return 1;
}

pub const readFile = fs_bridge.readFile;
pub const writeFile = fs_bridge.writeFile;
pub const editFile = fs_bridge.editFile;
pub const EditFileError = fs_bridge.EditFileError;
pub const editFileSplice = fs_bridge.editFileSplice;
pub const listDir = fs_bridge.listDir;
pub const mkdir = fs_bridge.mkdir;
pub const copyPath = fs_bridge.copyPath;
pub const movePath = fs_bridge.movePath;
pub const deletePath = fs_bridge.deletePath;
pub const fileInfo = fs_bridge.fileInfo;
pub const countLines = fs_bridge.countLines;
pub const applyLineRange = fs_bridge.applyLineRange;
pub const writeFileAtomic = fs_bridge.writeFileAtomic;
pub const readFileBytes = fs_bridge.readFileBytes;
pub const statFileSize = fs_bridge.statFileSize;
pub const detectLanguage = fs_bridge.detectLanguage;
pub const getMimeType = fs_bridge.getMimeType;
pub const getExtension = fs_bridge.getExtension;

pub const searchFiles = search_bridge.searchFiles;
pub const findFiles = search_bridge.findFiles;
pub const matchGlob = search_bridge.matchGlob;
pub const globMatchSegment = search_bridge.globMatchSegment;
pub const FindCtx = search_bridge.FindCtx;
pub const walkAndMatch = search_bridge.walkAndMatch;
pub const walkAndSearch = search_bridge.walkAndSearch;
pub const fileNameMatches = search_bridge.fileNameMatches;


/// Best-effort plugin directory for the shell-block audit log; empty when the
/// Lua state carries no plugin (bridge unit tests). Borrowed from the Lua GC —
/// consumed synchronously by the log call before returning.
fn pluginDirBestEffort(L: *c.lua_State) []const u8 {
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "zay_plugin_dir");
    if (c.lua_isnil(L, -1)) {
        c.lua_pop(L, 1);
        return "";
    }
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len);
    const dir = if (ptr) |p| p[0..len] else "";
    c.lua_pop(L, 1);
    return dir;
}

/// The exec backend a plugin shell call routes to: `run_bash` always uses
/// bash (git-bash on Windows); `run_shell` uses the native shell (pwsh on
/// Windows, bash on POSIX).
const ShellBackend = enum { bash, pwsh };

/// Map a backend spawn failure to an actionable Lua-facing message. Only
/// `error.FileNotFound` (the backend binary is missing) is remapped — every
/// other error name (Timeout, StreamTooLong, …) is already meaningful to
/// plugin authors.
fn shellBackendErrorMessage(err: anyerror, backend: ShellBackend) []const u8 {
    if (err == error.FileNotFound) {
        return switch (backend) {
            .bash => "ShellUnavailable: bash not found (install Git Bash on Windows, or ensure bash is on PATH); consider zay.run_shell",
            .pwsh => "ShellUnavailable: pwsh not found (install PowerShell 7, or ensure powershell.exe is on PATH)",
        };
    }
    return @errorName(err);
}

pub const quoteShellArg = git_bridge.quoteShellArg;
pub const appendQuotedArg = git_bridge.appendQuotedArg;
pub const gitErrorString = git_bridge.gitErrorString;
pub const findGitRoot = git_bridge.findGitRoot;
pub const gitStatus = git_bridge.gitStatus;
pub const gitDiff = git_bridge.gitDiff;
pub const gitLog = git_bridge.gitLog;
pub const gitBranch = git_bridge.gitBranch;
pub const gitAdd = git_bridge.gitAdd;
pub const gitCommit = git_bridge.gitCommit;

pub const sanitizePath = shell_bridge.sanitizePath;
pub const shellQuote = shell_bridge.shellQuote;
pub const runBash = shell_bridge.runBash;
pub const runShell = shell_bridge.runShell;
pub const getEnv = shell_bridge.getEnv;
pub const getCwd = shell_bridge.getCwd;
pub const getProjectRoot = shell_bridge.getProjectRoot;

/// ── zay.think(prompt) ──────────────────────────────────────────────
///
/// Sends a prompt to the LLM and returns the response.
/// This is a stub implementation — full integration requires access to
/// the active AI client, which will be wired in a future phase.
/// For now, returns an error message indicating the feature is not yet available.
pub fn think(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    const prompt = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("prompt argument is required");
        return 2;
    };

    // Stub: full implementation requires threading the AI client into the
    // plugin API. The Lua registry only stores std.Io; we'd need to also
    // store a pointer to the LanguageModel for recursive LLM calls.
    // For now, return an informative message.
    _ = prompt;
    state.pushNil();
    state.pushString("zay.think() is not yet implemented — requires AI client integration");
    return 2;
}

/// ── zay.register_tool(spec) ─────────────────────────────────────────
///
/// Registers a tool that the AI model can call. The spec table must have:
///   name (string) — tool name (lowercase, underscores)
///   description (string) — description for the model
///   parameters (table) — parameter definitions
///   handler (function) — called with params when the model invokes the tool
///
/// Stores the spec in the Lua registry under "zay_tools" as a table of
/// { name, description, parameters, handler_ref } entries. The handler is
/// stored as a registry reference (luaL_ref) so it survives garbage collection.
/// Returns true on success.
/// Validate a tool name against Zay's convention: lowercase letter first,
/// then lowercase letters, digits, and underscores, max 64 chars. Provider
/// tool names must match `^[a-zA-Z0-9_-]+$`; this stricter rule keeps names
/// provider-safe and consistent.
fn isValidToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (!std.ascii.isLower(name[0])) return false;
    for (name) |ch| {
        if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '_') return false;
    }
    return true;
}

/// Validate an event name against the seven names emitted by
/// `events.Event.name()`. Unknown names would silently never fire.
fn isValidEventName(name: []const u8) bool {
    const valid = [_][]const u8{
        "turn_started",
        "turn_ended",
        "tool_call_started",
        "tool_call_finished",
        "response_received",
        "plugin_loaded",
        "plugin_unloaded",
    };
    for (valid) |v| {
        if (std.mem.eql(u8, name, v)) return true;
    }
    return false;
}

pub fn registerTool(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    // arg 1: spec table
    if (!state.isTable(1)) {
        state.pushNil();
        state.pushString("spec table argument is required");
        return 2;
    }

    std.log.debug("plugin.registerTool.start", .{});

    // Extract fields from spec
    const name = bridge.getTableString(&state, 1, "name") orelse {
        state.pushNil();
        state.pushString("spec.name is required");
        return 2;
    };
    // Fail fast on invalid tool names: provider tool names must match
    // `^[a-zA-Z0-9_-]+$`, and Zay's convention is lowercase + underscores.
    if (name.len == 0 or name.len > 64 or !isValidToolName(name)) {
        const msg = std.fmt.allocPrint(std.heap.page_allocator, "invalid tool name '{s}' (must be lowercase letters, digits, and underscores, starting with a letter, max 64 chars)", .{name}) catch {
            state.pushNil();
            state.pushString("invalid tool name");
            return 2;
        };
        defer std.heap.page_allocator.free(msg);
        state.pushNil();
        state.pushString(msg);
        return 2;
    }
    const description = bridge.getTableString(&state, 1, "description") orelse {
        state.pushNil();
        state.pushString("spec.description is required");
        return 2;
    };

    // Get the handler function and store it as a registry reference
    _ = c.lua_getfield(L_ptr, 1, "handler");
    if (!state.isFunction(-1)) {
        state.pop(1);
        state.pushNil();
        state.pushString("spec.handler must be a function");
        return 2;
    }
    const handler_ref = c.luaL_ref(L_ptr, c.LUA_REGISTRYINDEX);

    // Get or create the zay_tools table in the registry
    _ = c.lua_getfield(L_ptr, c.LUA_REGISTRYINDEX, "zay_tools");
    if (state.isNil(-1)) {
        state.pop(1);
        state.newTable();
        _ = c.lua_pushvalue(L_ptr, -1);
        _ = c.lua_setfield(L_ptr, c.LUA_REGISTRYINDEX, "zay_tools");
    }
    const tools_table = c.lua_gettop(L_ptr);

    // Count existing entries to get next index
    const next_idx = c.lua_rawlen(L_ptr, tools_table) + 1;

    // Create entry table: { name, description, parameters, handler_ref }
    state.newTable();
    state.pushString(name);
    _ = c.lua_setfield(L_ptr, -2, "name");
    state.pushString(description);
    _ = c.lua_setfield(L_ptr, -2, "description");

    // Copy parameters table from spec
    _ = c.lua_getfield(L_ptr, 1, "parameters");
    if (state.isTable(-1)) {
        _ = c.lua_setfield(L_ptr, -2, "parameters");
    } else {
        state.pop(1);
        state.newTable();
        _ = c.lua_setfield(L_ptr, -2, "parameters");
    }

    // Store handler_ref as integer
    state.pushInteger(@as(i64, @intCast(handler_ref)));
    _ = c.lua_setfield(L_ptr, -2, "handler_ref");

    // Append entry to tools table
    _ = c.lua_rawseti(L_ptr, tools_table, @as(c_int, @intCast(next_idx)));

    // Pop tools table
    state.pop(1);

    std.log.debug("plugin.registerTool.ok name={s}", .{name});
    state.pushBoolean(true);
    return 1;
}

/// ── zay.on(event, callback) ────────────────────────────────────────
///
/// Subscribes to a lifecycle event. Stores the callback as a registry
/// reference in the "zay_events" table keyed by event name.
/// Returns true on success.
pub fn onEvent(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    const event_name = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("event name argument is required");
        return 2;
    };

    // Fail fast on unknown event names — a typo would otherwise silently
    // never fire. Validate against the seven names in events.Event.name().
    if (!isValidEventName(event_name)) {
        const msg = std.fmt.allocPrint(std.heap.page_allocator, "unknown event '{s}' (valid: turn_started, turn_ended, tool_call_started, tool_call_finished, response_received, plugin_loaded, plugin_unloaded)", .{event_name}) catch {
            state.pushNil();
            state.pushString("unknown event");
            return 2;
        };
        defer std.heap.page_allocator.free(msg);
        state.pushNil();
        state.pushString(msg);
        return 2;
    }

    if (!state.isFunction(2)) {
        state.pushNil();
        state.pushString("callback must be a function");
        return 2;
    }

    // Store callback as registry reference
    const callback_ref = c.luaL_ref(L_ptr, c.LUA_REGISTRYINDEX);

    // Get or create zay_events table in registry
    _ = c.lua_getfield(L_ptr, c.LUA_REGISTRYINDEX, "zay_events");
    if (state.isNil(-1)) {
        state.pop(1);
        state.newTable();
        _ = c.lua_pushvalue(L_ptr, -1);
        _ = c.lua_setfield(L_ptr, c.LUA_REGISTRYINDEX, "zay_events");
    }
    const events_table = c.lua_gettop(L_ptr);

    // Get or create the event's sub-table
    _ = c.lua_getfield(L_ptr, events_table, event_name.ptr);
    if (state.isNil(-1)) {
        state.pop(1);
        state.newTable();
        _ = c.lua_pushvalue(L_ptr, -1);
        _ = c.lua_setfield(L_ptr, events_table, event_name.ptr);
    }
    const event_subtable = c.lua_gettop(L_ptr);

    // Append callback_ref to the event's sub-table
    const next_idx = c.lua_rawlen(L_ptr, event_subtable) + 1;
    state.pushInteger(@as(i64, @intCast(callback_ref)));
    _ = c.lua_rawseti(L_ptr, event_subtable, @as(c_int, @intCast(next_idx)));

    state.pop(2); // pop event_subtable and events_table

    state.pushBoolean(true);
    return 1;
}

/// Count registered tools in a Lua state by reading "zay_tools" from registry.
pub fn countTools(L: *c.lua_State) u32 {
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "zay_tools");
    defer c.lua_pop(L, 1);
    if (c.lua_isnil(L, -1)) return 0;
    return @intCast(c.lua_rawlen(L, -1));
}

/// Find the index of a registered tool by name in the Lua registry.
/// Returns the 1-based index used by `callToolHandler`, or null if not found.
pub fn findToolIndex(L: *c.lua_State, tool_name: []const u8) ?c_int {
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "zay_tools");
    defer c.lua_pop(L, 1);
    if (c.lua_isnil(L, -1)) return null;

    const tools_len = c.lua_rawlen(L, -1);
    var i: c_int = 1;
    while (i <= @as(c_int, @intCast(tools_len))) : (i += 1) {
        _ = c.lua_rawgeti(L, -1, i);
        _ = c.lua_getfield(L, -1, "name");
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len);
        const found = if (ptr) |p| std.mem.eql(u8, p[0..len], tool_name) else false;
        c.lua_pop(L, 2); // pop name string and entry table
        if (found) return i;
    }
    return null;
}

/// ── plugin.get_config() ──────────────────────────────────────────────
///
/// Returns the plugin's configured settings as a fresh table, or nil when the
/// plugin has no config entry or no settings. The settings JSON string is
/// stored in the registry (`sandbox.settings_registry_key`) by the manager at
/// load time; re-parsing per call yields a fresh table, so plugin-side
/// mutation cannot corrupt the stored view. Malformed or non-object settings
/// return `nil, "get_config: settings must be a JSON object"`.
pub fn pluginGetConfig(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    // Absent slot → unconfigured → plain nil.
    _ = c.lua_getfield(L_ptr, c.LUA_REGISTRYINDEX, sandbox_mod.settings_registry_key);
    if (c.lua_isnil(L_ptr, -1)) {
        c.lua_pop(L_ptr, 1);
        state.pushNil();
        return 1;
    }
    var len: usize = 0;
    const ptr = c.lua_tolstring(L_ptr, -1, &len);
    const json = if (ptr) |p| p[0..len] else "";
    c.lua_pop(L_ptr, 1);

    // Parse first, push second: the object-vs-non-object verdict must be known
    // before anything lands on the stack (a JSON array also decodes to a Lua
    // table, so a post-push type check cannot distinguish it from an object).
    const gpa = std.heap.page_allocator;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch {
        state.pushNil();
        state.pushString("get_config: settings must be a JSON object");
        return 2;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        state.pushNil();
        state.pushString("get_config: settings must be a JSON object");
        return 2;
    }
    pushJsonValue(L_ptr, gpa, parsed.value) catch {
        state.pushNil();
        state.pushString("get_config: out of memory");
        return 2;
    };
    return 1;
}

// ── zay.json_decode / zay.json_encode ──────────────────────────────
//
// Plugins had no way to parse or emit JSON: incoming tool params are
// auto-parsed by `callToolHandler` (pushJsonToLua), but a plugin reading a
// JSON file or building structured output had to hand-roll a parser or shell
// out to `jq`. These two bridges close that gap by reusing the existing
// std.json ↔ Lua value conversion.
//
// - `zay.json_decode(str)` reuses `pushJsonValue` (Zig JSON Value → Lua).
// - `zay.json_encode(value, opts?)` traverses the Lua value with lua_next and
//   writes JSON to an allocating writer. Tables with contiguous 1..N integer
//   keys serialize as arrays; everything else (mixed/non-int keys) is an
//   object. This mirrors how Lua itself treats tables: there is no array/map
//   distinction, so the encoder infers it from the key shape.

pub const jsonDecode = json_bridge.jsonDecode;
pub const jsonEncode = json_bridge.jsonEncode;
pub const pushJsonValue = json_bridge.pushJsonValue;
pub const pushJsonToLua = json_bridge.pushJsonToLua;
pub const luaValueToJsonString = json_bridge.luaValueToJsonString;

/// Call a registered tool handler by index. Pushes the params table onto
/// the Lua stack, calls the handler, and returns the result string.
/// The caller must keep the Lua state alive during the call.
/// Returns the handler's return value as a string (owned by caller).
pub fn callToolHandler(
    L: *c.lua_State,
    gpa: std.mem.Allocator,
    tool_index: c_int,
    params_json: []const u8,
) ![]u8 {
    // Get zay_tools[index].handler_ref
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "zay_tools");
    if (c.lua_isnil(L, -1)) {
        c.lua_pop(L, 1);
        return error.NoToolsRegistered;
    }
    _ = c.lua_rawgeti(L, -1, tool_index);
    _ = c.lua_getfield(L, -1, "handler_ref");
    var isnum: c_int = 0;
    const handler_ref = @as(c_int, @intCast(c.lua_tointegerx(L, -1, &isnum)));
    c.lua_pop(L, 2); // pop handler_ref and entry table

    // Get the handler function from registry
    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, handler_ref);

    // Parse JSON params into a Lua table so handlers can use table access
    // (e.g. params.depth, params.pattern) instead of manual JSON parsing.
    pushJsonToLua(L, gpa, params_json) catch {
        c.lua_newtable(L);
    };

    // Reset the per-dispatch instruction budget and timeout deadline so the
    // limits mean "per tool call", not "per session" (T1/T2).
    sandbox_mod.resetInstructionBudget(L);

    // Call handler(params_json)
    const rc = c.lua_pcallk(L, 1, 1, 0, 0, null);
    if (rc != c.LUA_OK) {
        const err_msg = c.lua_tolstring(L, -1, null);
        const msg = if (err_msg) |p| std.mem.sliceTo(p, 0) else "unknown error";
        const result = try std.fmt.allocPrint(gpa, "Lua tool error: {s}", .{msg});
        c.lua_pop(L, 1); // pop error
        c.lua_pop(L, 1); // pop tools table
        return result;
    }

    // Get result string
    var len: usize = 0;
    const result_ptr = c.lua_tolstring(L, -1, &len);
    const result = if (result_ptr) |p| try gpa.dupe(u8, p[0..len]) else try gpa.dupe(u8, "");

    c.lua_pop(L, 2); // pop result and tools table
    return result;
}

// ── Tests ────────────────────────────────────────────────────────────

test "fileNameMatches: empty pattern matches everything (regression for SIGABRT)" {
    // Used to be `fp[1..]` which panicked (index-out-of-bounds) on `""`,
    // crashing the agent when a plugin passed an empty file_pattern
    // (Lua treats "" as truthy, so project-info/search-tool forwarded it).
    try std.testing.expect(fileNameMatches("anything.lua", ""));
    try std.testing.expect(fileNameMatches("Makefile", ""));
}

test "fileNameMatches: star glob strips leading star" {
    try std.testing.expect(fileNameMatches("main.lua", "*.lua"));
    try std.testing.expect(fileNameMatches("vendor/init.lua", "*.lua"));
    try std.testing.expect(!fileNameMatches("main.zig", "*.lua"));
}

test "fileNameMatches: bare suffix matches verbatim" {
    try std.testing.expect(fileNameMatches("main.lua", ".lua"));
    try std.testing.expect(fileNameMatches("config.json", "json"));
    try std.testing.expect(!fileNameMatches("config.json", ".lua"));
}

test "fileNameMatches: star-only pattern matches everything" {
    try std.testing.expect(fileNameMatches("anything.lua", "*"));
    try std.testing.expect(fileNameMatches("README", "*"));
}

test "detectLanguage: known extensions" {
    try std.testing.expectEqualStrings("zig", detectLanguage("main.zig", ""));
    try std.testing.expectEqualStrings("lua", detectLanguage("init.lua", ""));
    try std.testing.expectEqualStrings("python", detectLanguage("script.py", ""));
    try std.testing.expectEqualStrings("javascript", detectLanguage("app.js", ""));
    try std.testing.expectEqualStrings("markdown", detectLanguage("README.md", ""));
}

test "detectLanguage: shebang detection" {
    try std.testing.expectEqualStrings("script", detectLanguage("script", "#!/usr/bin/env bash"));
}

test "detectLanguage: unknown extension" {
    try std.testing.expectEqualStrings("text", detectLanguage("file.xyz", ""));
}

test "getMimeType: known types" {
    try std.testing.expectEqualStrings("text/x-lua", getMimeType("test.lua"));
    try std.testing.expectEqualStrings("application/json", getMimeType("config.json"));
    try std.testing.expectEqualStrings("text/markdown", getMimeType("README.md"));
}

test "getMimeType: unknown extension" {
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("file.xyz"));
}

test "getExtension: extracts extension" {
    try std.testing.expectEqualStrings("zig", getExtension("main.zig"));
    try std.testing.expectEqualStrings("lua", getExtension("init.lua"));
}

test "getExtension: no extension" {
    try std.testing.expectEqualStrings("", getExtension("Makefile"));
}

test "countLines: empty text" {
    try std.testing.expectEqual(@as(u32, 1), countLines(""));
}

test "countLines: single line" {
    try std.testing.expectEqual(@as(u32, 1), countLines("hello world"));
}

test "countLines: multiple lines" {
    try std.testing.expectEqual(@as(u32, 3), countLines("line1\nline2\nline3"));
}

test "applyLineRange: no range returns full content" {
    const content = "line1\nline2\nline3";
    try std.testing.expectEqualStrings(content, applyLineRange(content, null, null));
}

test "applyLineRange: start_line only" {
    const content = "line1\nline2\nline3\nline4";
    try std.testing.expectEqualStrings("line2\nline3\nline4", applyLineRange(content, 2, null));
}

test "applyLineRange: start and end" {
    const content = "line1\nline2\nline3\nline4";
    try std.testing.expectEqualStrings("line2\nline3", applyLineRange(content, 2, 3));
}

test "applyLineRange: past end returns empty" {
    const content = "line1\nline2";
    try std.testing.expectEqualStrings("", applyLineRange(content, 10, null));
}

test "registerTool + countTools: sandboxed state" {
    const sandbox = @import("sandbox.zig");

    // Create a sandboxed state with Io (so registerPluginApi is called).
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    // Before registration, there should be 0 tools.
    try std.testing.expectEqual(@as(u32, 0), countTools(L.handle));

    // Register a tool via Lua code (same as what init.lua does).
    const ok = L.doString(
        \\zay.register_tool({
        \\  name = "test_tool",
        \\  description = "A test tool",
        \\  parameters = {
        \\    foo = { type = "string", description = "A foo param" },
        \\  },
        \\  handler = function(params) return "ok" end,
        \\})
    );
    if (!ok) {
        const err = L.getErrorMessage();
        std.debug.print("Lua error: {s}\n", .{err orelse "unknown"});
        L.pop(1);
    }
    try std.testing.expect(ok);

    // After registration, countTools should see 1 tool.
    try std.testing.expectEqual(@as(u32, 1), countTools(L.handle));
}

test "registerTool rejects invalid tool names (T6)" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    // Uppercase, space, colon, empty, and over-long names are all rejected.
    try expectLuaOk(&L,
        \\local function try(name)
        \\  local ok, err = zay.register_tool({
        \\    name = name, description = "d",
        \\    handler = function() return "x" end,
        \\  })
        \\  assert(ok == nil, "should reject: " .. tostring(name))
        \\  assert(err ~= nil and err:find("invalid tool name") ~= nil, tostring(err))
        \\end
        \\try("BadName")
        \\try("has space")
        \\try("has:colon")
        \\try("")
        \\try(string.rep("a", 65))
        \\return "OK"
    );

    // A valid lowercase/underscore name still registers.
    try expectLuaOk(&L,
        \\local ok, err = zay.register_tool({
        \\  name = "valid_tool_2", description = "d",
        \\  handler = function() return "x" end,
        \\})
        \\assert(ok == true, tostring(err))
        \\return "OK"
    );
    try std.testing.expectEqual(@as(u32, 1), countTools(L.handle));
}

test "onEvent rejects unknown event names (T6)" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    // A typo'd event name must fail fast, not silently never fire.
    try expectLuaOk(&L,
        \\local ok, err = zay.on("turn_strated", function() end)
        \\assert(ok == nil, "unknown event should fail")
        \\assert(err ~= nil and err:find("unknown event") ~= nil, tostring(err))
        \\return "OK"
    );

    // All seven valid names are accepted.
    try expectLuaOk(&L,
        \\local names = {
        \\  "turn_started", "turn_ended", "tool_call_started",
        \\  "tool_call_finished", "response_received",
        \\  "plugin_loaded", "plugin_unloaded",
        \\}
        \\for _, n in ipairs(names) do
        \\  local ok, err = zay.on(n, function() end)
        \\  assert(ok == true, n .. ": " .. tostring(err))
        \\end
        \\return "OK"
    );
}

// ── zay.write_file / writeFileAtomic tests ──────────────────────────
//
// writeFileAtomic is the shared write+rename core behind both zay.write_file
// and zay.edit_file; the Lua-level tests exercise the binding surface
// (argument validation, path sanitization, and a real write under cwd).

test "writeFileAtomic writes, overwrites, and leaves no temp file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // std.testing.tmpDir lives under <cwd>/.zig-cache/tmp/<sub_path>.
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const target = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "write-test.txt" });
    defer gpa.free(target);

    // First write creates the file.
    try writeFileAtomic(io, target, "hello");
    {
        const content = try readFileBytes(io, target, 4096);
        defer std.heap.page_allocator.free(content);
        try std.testing.expectEqualStrings("hello", content);
    }

    // A second write replaces the whole content atomically.
    try writeFileAtomic(io, target, "hello world");
    {
        const content = try readFileBytes(io, target, 4096);
        defer std.heap.page_allocator.free(content);
        try std.testing.expectEqualStrings("hello world", content);
    }

    // The temp file was renamed away — nothing is left behind. The tmp name
    // is now `<path>.<8-hex>.tmp`, so check for any stray `*.tmp` in the dir.
    const dir = std.fs.path.dirname(target) orelse ".";
    var dir_handle = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer dir_handle.close(io);
    // Freshly opened dir — skip the reset-seek that testing.io's threaded
    // vtable can't do on a dir fd (BADF).
    var it = dir_handle.iterateAssumeFirstIteration();
    while (try it.next(io)) |entry| {
        try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".tmp"));
    }
}

test "zay.write_file validates its arguments" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    try expectLuaOk(&L,
        \\local ok, err = zay.write_file()
        \\assert(ok == nil, "missing path should fail")
        \\assert(err == "path argument is required", tostring(err))
        \\local ok2, err2 = zay.write_file("x.txt")
        \\assert(ok2 == nil, "missing content should fail")
        \\assert(err2 == "content argument is required", tostring(err2))
        \\return "OK"
    );
}

test "zay.write_file rejects traversal and invalid paths without writing" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    try expectLuaOk(&L,
        \\local ok, err = zay.write_file("../escape.txt", "x")
        \\assert(ok == nil, "path traversal should fail")
        \\assert(err == "PathTraversal", tostring(err))
        \\local p = "bad" .. string.char(0) .. "path.txt"
        \\local ok2, err2 = zay.write_file(p, "x")
        \\assert(ok2 == nil, "nul byte should fail")
        \\assert(err2 == "InvalidPath", tostring(err2))
        \\return "OK"
    );
}

test "zay.write_file writes content to a path under cwd" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // sanitizePath resolves relative paths against cwd and rejects writes that
    // escape it; the tmp dir sits under <cwd>/.zig-cache/tmp so a relative path
    // reaches it.
    const rel = try std.fmt.allocPrintSentinel(gpa, ".zig-cache/tmp/{s}/lua-write.txt", .{&tmp.sub_path}, 0);
    defer gpa.free(rel);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const target = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "lua-write.txt" });
    defer gpa.free(target);

    const chunk = try std.fmt.allocPrintSentinel(gpa, "local ok, err = zay.write_file(\"{s}\", \"hello from lua\")\nassert(ok == true, tostring(err))\nreturn \"OK\"", .{rel}, 0);
    defer gpa.free(chunk);

    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L, chunk);

    // The file exists with the exact content written from Lua.
    const content = try readFileBytes(io, target, 4096);
    defer std.heap.page_allocator.free(content);
    try std.testing.expectEqualStrings("hello from lua", content);
}

// ── S3: edit_file / read_file size-limit tests ───────────────────────

test "editFile refuses to edit a file over 1 MB and leaves it byte-identical" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const target = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "big-edit.txt" });
    defer gpa.free(target);

    // Write a file just over the 1 MB cap.
    const big = try gpa.alloc(u8, max_read_size + 100);
    defer gpa.free(big);
    @memset(big, 'x');
    try writeFileAtomic(io, target, big);

    // editFile must return an error and leave the file untouched.
    try std.testing.expectError(error.FileTooLarge, editFileSplice(io, target, "x", "y"));

    const after = try readFileBytes(io, target, max_read_size + 200);
    defer std.heap.page_allocator.free(after);
    try std.testing.expectEqual(big.len, after.len);
    try std.testing.expectEqualStrings(big, after);
}

test "readFile exposes truncation on a file over 1 MB" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const target = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "big-read.txt" });
    defer gpa.free(target);

    const big = try gpa.alloc(u8, max_read_size + 100);
    defer gpa.free(big);
    @memset(big, 'x');
    try writeFileAtomic(io, target, big);

    const content = try readFileBytes(io, target, max_read_size);
    defer std.heap.page_allocator.free(content);
    try std.testing.expectEqual(@as(usize, max_read_size), content.len);
    try std.testing.expectEqual(@as(u64, big.len), try statFileSize(io, target));

    // Drive the Lua surface: read_file must expose truncated/full_size/size
    // so a plugin can detect the head-truncation and page around it (S3).
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    const lua_target = try forwardSlashDup(gpa, target);
    defer gpa.free(lua_target);
    const chunk = try std.fmt.allocPrintSentinel(gpa,
        \\local r = zay.read_file("{s}", {{}})
        \\assert(type(r) == "table", "read_file returns a table")
        \\assert(r.truncated == true, "truncated flag set for >1MB file")
        \\assert(r.full_size == {d}, "full_size is the on-disk size, got " .. tostring(r.full_size))
        \\assert(r.size <= {d}, "size is the bytes returned (capped)")
        \\assert(r.size == #r.content, "size matches content length")
        \\return "OK"
    , .{ lua_target, big.len, max_read_size }, 0);
    defer gpa.free(chunk);
    try expectLuaOk(&L, chunk);
}

test "readFile clamps a negative max_size without panicking" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const target = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "neg-max.txt" });
    defer gpa.free(target);
    try writeFileAtomic(io, target, "hello");

    // A negative max_size used to be `@intCast(v)` on the raw i64 — a cast
    // panic in safe builds, a wrap to ~2^64 in ReleaseFast. It must now clamp.
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    const lua_target = try forwardSlashDup(gpa, target);
    defer gpa.free(lua_target);
    const chunk = try std.fmt.allocPrintSentinel(gpa,
        \\local r = zay.read_file("{s}", {{ max_size = -1 }})
        \\assert(type(r) == "table", "clamped read returns a table")
        \\return "OK"
    , .{lua_target}, 0);
    defer gpa.free(chunk);
    try expectLuaOk(&L, chunk);
}

// ── zay.json_decode / zay.json_encode tests ────────────────────────
//
// Each test drives the bridge through real Lua code (doString) and asserts
// inside Lua, returning a sentinel string ("OK") on success. This avoids
// fragile manual stack inspection from Zig and exercises the exact path a
// plugin takes. A failing assertion makes doString return false, surfacing
// the Lua error message via getErrorMessage.

/// Duplicate a filesystem path replacing every backslash with a forward slash,
/// so it can be interpolated safely into a Lua string literal. A Windows path
/// like `C:\work\zay` carries `\w`/`\n` sequences that Lua mangles (or rejects
/// for invalid escapes like `\G`) when embedded verbatim. Windows accepts
/// forward slashes, so the replacement is lossless for path resolution.
fn forwardSlashDup(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, path.len);
    for (path, 0..) |byte, index| {
        out[index] = if (byte == '\\') '/' else byte;
    }
    return out;
}

/// Helper: run a Lua chunk that must end by returning the literal "OK".
/// On failure, prints the Lua error so the test failure is debuggable.
fn expectLuaOk(L: *State, chunk: [:0]const u8) !void {
    const ok = L.doString(chunk);
    if (!ok) {
        const err = L.getErrorMessage();
        std.debug.print("Lua error: {s}\n", .{err orelse "unknown"});
        L.pop(1);
        try std.testing.expect(ok);
    }
    // The chunk pushes "OK" onto the stack on success.
    var len: usize = 0;
    const ptr = c.lua_tolstring(L.handle, -1, &len);
    const got = if (ptr) |p| p[0..len] else "";
    defer c.lua_pop(L.handle, 1);
    try std.testing.expectEqualStrings("OK", got);
}

test "json_decode: object becomes Lua table" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local t = zay.json_decode('{"a": 1, "b": "hi"}')
        \\assert(type(t) == "table", "expected table")
        \\assert(t.a == 1, "a should be 1")
        \\assert(t.b == "hi", "b should be hi")
        \\return "OK"
    );
}

test "json_decode: array becomes 1-indexed table" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local arr = zay.json_decode('[10, 20, 30]')
        \\assert(arr[1] == 10, "arr[1] should be 10")
        \\assert(arr[2] == 20, "arr[2] should be 20")
        \\assert(arr[3] == 30, "arr[3] should be 30")
        \\return "OK"
    );
}

test "json_decode: primitives (null/bool/number/string)" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\assert(zay.json_decode('null') == nil, "null -> nil")
        \\assert(zay.json_decode('true') == true, "true -> true")
        \\assert(zay.json_decode('false') == false, "false -> false")
        \\assert(zay.json_decode('42') == 42, "int -> number")
        \\assert(zay.json_decode('3.5') == 3.5, "float -> number")
        \\assert(zay.json_decode('"word"') == "word", "string -> string")
        \\return "OK"
    );
}

test "json_decode: malformed input returns nil + error" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local v, err = zay.json_decode('{bad json')
        \\assert(v == nil, "malformed should yield nil")
        \\assert(type(err) == "string" and #err > 0, "error string expected")
        \\return "OK"
    );
}

test "json_encode: object table to JSON" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local s = zay.json_encode({ a = 1, b = "hi" })
        \\assert(type(s) == "string", "encode returns string")
        \\-- object key order is not guaranteed; check both pairs round-trip
        \\local back = zay.json_decode(s)
        \\assert(back.a == 1 and back.b == "hi", "round-trip preserves values")
        \\return "OK"
    );
}

test "json_encode: array table to JSON bracket" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local s = zay.json_encode({ 10, 20, 30 })
        \\assert(s:sub(1, 1) == "[", "array starts with [")
        \\assert(s:sub(-1) == "]", "array ends with ]")
        \\local back = zay.json_decode(s)
        \\assert(back[1] == 10 and back[2] == 20 and back[3] == 30, "round-trip")
        \\return "OK"
    );
}

test "json_encode: pretty option indents output" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local compact = zay.json_encode({ a = 1 })
        \\local pretty = zay.json_encode({ a = 1 }, { pretty = true })
        \\assert(not compact:find("\n", 1, true), "compact has no newline")
        \\assert(pretty:find("\n", 1, true) ~= nil, "pretty has newlines")
        \\assert(pretty:find("  ", 1, true) ~= nil, "pretty has indent")
        \\return "OK"
    );
}

test "json_encode: escapes quotes and special chars in strings" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local s = zay.json_encode({ msg = 'he said "hi"\nbye' })
        \\assert(s:find('\\"', 1, true), "quotes escaped")
        \\assert(s:find('\\n', 1, true), "newline escaped")
        \\-- round-trip must recover the original string
        \\local back = zay.json_decode(s)
        \\assert(back.msg == 'he said "hi"\nbye', "round-trip preserves escapes")
        \\return "OK"
    );
}

test "json_encode: nested table (object with array value)" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local s = zay.json_encode({ name = "x", items = { 1, 2 } })
        \\local back = zay.json_decode(s)
        \\assert(back.name == "x", "scalar field preserved")
        \\assert(type(back.items) == "table", "nested table preserved")
        \\assert(back.items[1] == 1 and back.items[2] == 2, "array preserved")
        \\return "OK"
    );
}

test "json round-trip: decode then encode preserves structure" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local original = '{"id": 7, "steps": [{"text": "a", "done": true}]}'
        \\local decoded = zay.json_decode(original)
        \\local encoded = zay.json_encode(decoded)
        \\local redecoded = zay.json_decode(encoded)
        \\assert(redecoded.id == 7, "top-level scalar preserved")
        \\assert(redecoded.steps[1].text == "a", "nested object.text preserved")
        \\assert(redecoded.steps[1].done == true, "nested object.done preserved")
        \\return "OK"
    );
}

// ── glob matcher unit tests ──────────────────────────────────────────

test "matchGlob: empty pattern matches everything" {
    try std.testing.expect(matchGlob("a.zig", ""));
    try std.testing.expect(matchGlob("src/foo.ts", ""));
}

test "matchGlob: literal pattern matches verbatim" {
    try std.testing.expect(matchGlob("main.zig", "main.zig"));
    try std.testing.expect(!matchGlob("main.zig", "main.lua"));
}

test "matchGlob: star within segment" {
    try std.testing.expect(matchGlob("main.zig", "*.zig"));
    try std.testing.expect(matchGlob("a.ts", "*.ts"));
    try std.testing.expect(!matchGlob("a.js", "*.ts"));
}

test "matchGlob: star does not cross separator" {
    try std.testing.expect(!matchGlob("src/a.ts", "*.ts"));
    try std.testing.expect(matchGlob("a.ts", "*"));
}

test "matchGlob: double-star spans directories" {
    try std.testing.expect(matchGlob("src/a.zig", "**/*.zig"));
    try std.testing.expect(matchGlob("src/nested/b.zig", "**/*.zig"));
    try std.testing.expect(matchGlob("a.zig", "**/*.zig"));
    try std.testing.expect(!matchGlob("a.lua", "**/*.zig"));
}

test "matchGlob: double-star under prefix" {
    try std.testing.expect(matchGlob("src/nested/a.ts", "src/**/*.ts"));
    try std.testing.expect(matchGlob("src/a.ts", "src/**/*.ts"));
    try std.testing.expect(!matchGlob("lib/a.ts", "src/**/*.ts"));
}

test "matchGlob: single-char question mark" {
    try std.testing.expect(matchGlob("a.ts", "?.ts"));
    try std.testing.expect(matchGlob("ab.ts", "a?.ts"));
    try std.testing.expect(!matchGlob("abc.ts", "a?.ts"));
}

test "matchGlob: trailing double-star matches remainder" {
    try std.testing.expect(matchGlob("src/a/b/c", "src/**"));
    try std.testing.expect(matchGlob("src", "src/**"));
    try std.testing.expect(!matchGlob("lib/a", "src/**"));
}

// ── P0: shell-injection regression tests ──────────────────────────────
//
// The git bridges (`gitDiff`/`gitLog`/`gitCommit`) previously embedded
// plugin-supplied strings into a `bash -c` command, letting a malicious plugin
// break out of quotes. Each test drives the exact escaping/stdin path the
// bridges now use and asserts an injection payload leaves no side effect.

/// Run a shell command, discarding its output and any error. For best-effort
/// test cleanup (`rm -rf`) where the result is irrelevant; keeps call sites a
/// single line instead of repeating the bind/deinit/discard ladder.
fn ignoreRun(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, command: []const u8) void {
    var result = bash_exec.run(gpa, io, cwd, command) catch return;
    result.deinit(gpa);
}

/// True when `git` is on PATH (so the git-backed injection tests can run).
fn gitAvailable() bool {
    if (std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "git", "--version" },
    })) |r| {
        std.testing.allocator.free(r.stdout);
        std.testing.allocator.free(r.stderr);
        return true;
    } else |_| return false;
}

/// Create an empty git repo under `/tmp/zay-inject-test`, returning the path.
/// Caller frees the path; the dir is removed via the shell. Sets a deterministic
/// identity so `git commit` does not refuse to run.
fn makeInjectionTestRepo(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const dir = try std.fs.path.join(gpa, &.{ "/tmp", "zay-inject-test" });
    errdefer gpa.free(dir);
    ignoreRun(gpa, io, "/tmp", "rm -rf zay-inject-test");
    var result = try bash_exec.run(
        gpa,
        io,
        "/tmp",
        "mkdir -p zay-inject-test && git -C zay-inject-test init -q && " ++
            "git -C zay-inject-test config user.email t@t && " ++
            "git -C zay-inject-test config user.name t",
    );
    result.deinit(gpa);
    return dir;
}

/// True iff the file at `absolute_path` exists. Routed through the shell so the
/// test does not depend on a specific Dir API name for absolute paths.
fn fileExists(gpa: std.mem.Allocator, io: std.Io, absolute_path: []const u8) bool {
    const cmd = std.fmt.allocPrint(gpa, "test -f {s}", .{absolute_path}) catch return false;
    defer gpa.free(cmd);
    var result = bash_exec.run(gpa, io, "/tmp", cmd) catch return false;
    defer result.deinit(gpa);
    return result.code == 0;
}

test "shellQuote: plain argument is wrapped in single quotes" {
    const gpa = std.testing.allocator;
    const quoted = try quoteShellArg(gpa, "src/main.zig", false);
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings("'src/main.zig'", quoted);
}

test "shellQuote: embedded quote is escaped (injection vector neutralized)" {
    const gpa = std.testing.allocator;
    const quoted = try quoteShellArg(gpa, "x'; rm -rf ~; #", false);
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings("'x'\\''; rm -rf ~; #'", quoted);
}

test "shellQuote: empty argument becomes two quotes" {
    const gpa = std.testing.allocator;
    const quoted = try quoteShellArg(gpa, "", false);
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings("''", quoted);
}

test "gitCommit: injection payload stays a literal commit message (stdin path)" {
    // Gate on OS first (before gitAvailable): on Windows these tests spawn a
    // real `bash`/git via bash_exec with /tmp paths, which is unsupported.
    if (os.is_windows) return error.SkipZigTest;
    if (!gitAvailable()) return;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = try makeInjectionTestRepo(gpa, io);
    defer {
        ignoreRun(gpa, io, "/tmp", "rm -rf zay-inject-test");
        gpa.free(dir);
    }

    // The injection vector from the plan: a quote-break-out attempt. With the
    // old `-m "{msg}"` it would run `touch /tmp/pwned_zay`; with `-F -` +
    // stdin it must become the literal commit subject.
    const marker = "/tmp/pwned_zay_commit";
    ignoreRun(gpa, io, "/tmp", "rm -f pwned_zay_commit");
    const payload = "x\"; touch " ++ marker ++ "; #";
    var result = try bash_exec.runWithOptions(gpa, io, .{
        .cwd = dir,
        .command = "git add -A && git commit -F -",
        .stdin = payload,
    });
    result.deinit(gpa);

    // The marker file must NOT exist: the payload never reached the shell.
    try std.testing.expect(!fileExists(gpa, io, marker));
    ignoreRun(gpa, io, "/tmp", "rm -f pwned_zay_commit");
}

test "gitDiff: injection payload stays a literal pathspec (shellQuote path)" {
    // See gitCommit: OS-gate first so it's counted as skipped on Windows.
    if (os.is_windows) return error.SkipZigTest;
    if (!gitAvailable()) return;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = try makeInjectionTestRepo(gpa, io);
    defer {
        ignoreRun(gpa, io, "/tmp", "rm -rf zay-inject-test");
        gpa.free(dir);
    }

    // A commit so `git diff` has something to diff against.
    var setup = try bash_exec.run(gpa, io, dir, "echo a > f && git add -A && git commit -q -m init");
    setup.deinit(gpa);

    const marker = "/tmp/pwned_zay_diff";
    ignoreRun(gpa, io, "/tmp", "rm -f pwned_zay_diff");
    // The quote-break-out payload, funneled through `shellQuote` exactly as
    // `gitDiff` does, must become one inert pathspec.
    const quoted = try quoteShellArg(gpa, "x'; touch " ++ marker ++ "; #", false);
    defer gpa.free(quoted);
    const cmd = try std.fmt.allocPrint(gpa, "git diff -- {s}", .{quoted});
    defer gpa.free(cmd);
    var result = try bash_exec.runWithOptions(gpa, io, .{
        .cwd = dir,
        .command = cmd,
    });
    result.deinit(gpa);

    try std.testing.expect(!fileExists(gpa, io, marker));
    ignoreRun(gpa, io, "/tmp", "rm -f pwned_zay_diff");
}

test "RunOptions.stdin bypasses shell interpretation" {
    // The stdin path passes the payload verbatim to the child, so shell
    // metacharacters in it are data, not syntax. Confirm `cat` echoes the
    // payload untouched (no command-substitution, no quoting collapse).
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var result = try bash_exec.runWithOptions(gpa, std.testing.io, .{
        .cwd = cwd,
        .command = "cat",
        .stdin = "a$(touch /tmp/pwned_zay_stdin)b",
    });
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("a$(touch /tmp/pwned_zay_stdin)b", result.stdout);
    ignoreRun(gpa, std.testing.io, "/tmp", "rm -f pwned_zay_stdin");
}

// ── B2-Zig: negative table integers clamp before the u32 cast ───────

test "searchFiles clamps a negative max_results without panicking" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    // A negative max_results used to be `@intCast(v)` on the raw i64 — a cast
    // panic in safe builds. It must now clamp to 1 and return a normal result.
    try expectLuaOk(&L,
        \\local r = zay.search_files(".", "no-such-pattern-xyz", { max_results = -1 })
        \\assert(type(r) == "table", "clamped search returns a table")
        \\return "OK"
    );
}

test "findFiles clamps a negative max_results without panicking" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local r = zay.find_files(".", "no-such-glob-xyz", { max_results = -1 })
        \\assert(type(r) == "table", "clamped find returns a table")
        \\return "OK"
    );
}

test "runBash clamps a negative timeout without panicking" {
    if (os.is_windows) return error.SkipZigTest;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local r = zay.run_bash("true", { timeout = -1 })
        \\assert(type(r) == "table", "clamped run_bash returns a table")
        \\assert(r.code == 0, "true exits 0")
        \\return "OK"
    );
}

test "runBash pipes opts.stdin to the child (P4)" {
    if (os.is_windows) return error.SkipZigTest;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local r = zay.run_bash("cat", { stdin = "hello stdin" })
        \\assert(type(r) == "table", "stdin run returns a table")
        \\assert(r.stdout == "hello stdin", "stdout echoes stdin: " .. tostring(r.stdout))
        \\assert(r.code == 0, "cat exits 0")
        \\
        \\-- No stdin: the child's stdin is simply absent/closed.
        \\local r2 = zay.run_bash("printf ok")
        \\assert(r2.stdout == "ok", "plain run unaffected")
        \\return "OK"
    );
}

// ── shell safety gate (P5) ───────────────────────────────────────────

test "runBash blocks unsafe commands via the local matcher (P5)" {
    // No classifier URL configured (null slot): the always-armed local
    // matcher must still block destructive commands.
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    bridge.bash_classifier_url_slot = null;
    try expectLuaOk(&L,
        \\local r, err = zay.run_bash("rm -rf /")
        \\assert(r == nil, "unsafe command returns nil")
        \\assert(string.find(err, "UnsafeShellBlocked", 1, true) ~= nil, "error carries UnsafeShellBlocked: " .. tostring(err))
        \\return "OK"
    );
}

test "runBash safety gate holds with a configured-but-unreachable classifier (P5)" {
    // classify falls back to the local matcher on fetch failure, so an
    // unreachable URL blocks locally-matched destructive commands just the
    // same; safe commands are unaffected with the slot set. NOTE: the local
    // matcher covers root-target deletion forms (`rm -rf /`-class), not every
    // destructive spelling — the remote classifier covers the full surface.
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    const prev = bridge.bash_classifier_url_slot;
    defer bridge.bash_classifier_url_slot = prev;
    bridge.bash_classifier_url_slot = "http://127.0.0.1:1/classify";
    if (os.is_windows) return error.SkipZigTest;

    try expectLuaOk(&L,
        \\local r, err = zay.run_bash("rm -rf /")
        \\assert(r == nil, "locally-matched unsafe command still blocked with a down classifier")
        \\assert(string.find(err, "UnsafeShellBlocked", 1, true) ~= nil, "got: " .. tostring(err))
        \\local ok = zay.run_bash("printf fine")
        \\assert(type(ok) == "table" and ok.stdout == "fine", "safe command passes")
        \\return "OK"
    );
}

test "runBash and run_shell reject an empty command before any spawn (P5)" {
    // The guard is backend-independent and fires before classify and before
    // either backend's command.len > 0 assert.
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local r1, e1 = zay.run_bash("")
        \\assert(r1 == nil, "empty command returns nil")
        \\assert(e1 == "command argument must not be empty", "got: " .. tostring(e1))
        \\local r2, e2 = zay.run_shell("")
        \\assert(r2 == nil and e2 == "command argument must not be empty", "run_shell guards too")
        \\return "OK"
    );
}

// ── shell_quote + ShellUnavailable mapping (P7) ──────────────────────

test "quoteShellArg posix and pwsh rules" {
    const gpa = std.testing.allocator;

    // POSIX: wrap in '...', escape ' as '\''.
    {
        const q = try quoteShellArg(gpa, "a'b", false);
        defer gpa.free(q);
        try std.testing.expectEqualStrings("'a'\\''b'", q);
    }
    {
        const q = try quoteShellArg(gpa, "", false);
        defer gpa.free(q);
        try std.testing.expectEqualStrings("''", q);
    }
    {
        const q = try quoteShellArg(gpa, "plain", false);
        defer gpa.free(q);
        try std.testing.expectEqualStrings("'plain'", q);
    }

    // pwsh: wrap in '...', double ' as ''.
    {
        const q = try quoteShellArg(gpa, "a'b", true);
        defer gpa.free(q);
        try std.testing.expectEqualStrings("'a''b'", q);
    }
    {
        const q = try quoteShellArg(gpa, "plain", true);
        defer gpa.free(q);
        try std.testing.expectEqualStrings("'plain'", q);
    }
}

test "quoteShellArg posix output survives a real shell round-trip" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const original = "it's a $HOME `test` \"double\"";

    const q = try quoteShellArg(gpa, original, false);
    defer gpa.free(q);
    const command = try std.fmt.allocPrint(gpa, "printf %s {s}", .{q});
    defer gpa.free(command);
    var r = try bash_exec.runWithOptions(gpa, std.testing.io, .{ .cwd = "/tmp", .command = command });
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings(original, r.stdout);
    try std.testing.expect(r.code == 0);
}

test "shellBackendErrorMessage maps only FileNotFound" {
    try std.testing.expect(std.mem.indexOf(u8, shellBackendErrorMessage(error.FileNotFound, .bash), "ShellUnavailable: bash not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, shellBackendErrorMessage(error.FileNotFound, .pwsh), "ShellUnavailable: pwsh not found") != null);
    try std.testing.expectEqualStrings("Timeout", shellBackendErrorMessage(error.Timeout, .bash));
    try std.testing.expectEqualStrings("StreamTooLong", shellBackendErrorMessage(error.StreamTooLong, .pwsh));
}

test "zay.shell_quote dialects and error contract (P7)" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\assert(zay.shell_quote("a'b") == "'a'\\''b'", "default is posix")
        \\assert(zay.shell_quote("a'b", "posix") == "'a'\\''b'")
        \\assert(zay.shell_quote("") == "''", "empty string quotes to ''")
        \\assert(zay.shell_quote(nil, "posix") == nil, "missing string arg: nil+err")
        \\
        \\-- On POSIX, native == posix; the pwsh doubling rule is only
        \\-- observable on Windows (covered by a Windows-gated test).
        \\local native = zay.shell_quote("x y", "native")
        \\assert(native == "'x y'", "native == posix on POSIX")
        \\
        \\local v, err = zay.shell_quote("x", "bogus")
        \\assert(v == nil, "unknown dialect yields nil")
        \\assert(err == "shell_quote: dialect must be \"posix\" or \"native\"", "got: " .. tostring(err))
        \\return "OK"
    );
}

test "zay.shell_quote native dispatches to pwsh rules on Windows (P7)" {
    if (!os.is_windows) return error.SkipZigTest;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\assert(zay.shell_quote("a'b", "native") == "'a''b'", "pwsh doubles quotes")
        \\return "OK"
    );
}

// ── M-symlink: sanitizePath realpath re-check ────────────────────────

test "sanitizePath rejects a symlink escaping the project root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    // The tmp dir lives under <cwd>/.zig-cache/tmp/<sub>; create a symlink
    // inside it pointing at /tmp (outside the project root).
    const link_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(link_dir);
    const link_path = try std.fs.path.join(gpa, &.{ link_dir, "escape" });
    defer gpa.free(link_path);
    std.Io.Dir.cwd().createDirPath(io, link_dir) catch {};
    const link_z = try std.fmt.allocPrintSentinel(gpa, "{s}", .{link_path}, 0);
    defer gpa.free(link_z);
    const target_z = try std.fmt.allocPrintSentinel(gpa, "{s}", .{"/tmp"}, 0);
    defer gpa.free(target_z);
    _ = std.c.symlink(target_z, link_z); // skip if symlink unsupported

    // Create a real file in /tmp so realpath resolves the final component.
    const marker = try std.fmt.allocPrintSentinel(gpa, "{s}", .{"/tmp/zay_symlink_marker"}, 0);
    defer gpa.free(marker);
    var mf = std.Io.Dir.createFileAbsolute(io, "/tmp/zay_symlink_marker", .{}) catch return;
    mf.close(io);
    defer std.Io.Dir.deleteFileAbsolute(io, "/tmp/zay_symlink_marker") catch {};

    // Reading through the symlink must be rejected.
    const target = try std.fs.path.join(gpa, &.{ link_path, "zay_symlink_marker" });
    defer gpa.free(target);
    try std.testing.expectError(error.PathTraversal, sanitizePath(io, target));
}

test "sanitizePath allows a nonexistent new-file path (realpath-failure fallback)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const new_file = try std.fs.path.join(gpa, &.{ dir, "brand-new.txt" });
    defer gpa.free(new_file);

    // The file does not exist yet; realpath fails and the lexical verdict holds.
    const resolved = try sanitizePath(io, new_file);
    defer std.heap.page_allocator.free(resolved);
    try std.testing.expect(std.mem.endsWith(u8, resolved, "brand-new.txt"));
}

// ── S4: git bridges return nil + error outside a repo ────────────────
//
// The bridges previously pushed only stdout, so in a non-repo dir `git status
// --porcelain` exited 128 with empty stdout and the plugin received "" instead
// of nil — the nil-check in git-tools never fired and the model was told the
// tree was clean. These tests drive the real git binary (a hard dependency of
// the bridge) in a temp dir that is NOT a repo, and in a fresh repo.

test "gitStatus returns nil + error outside a repo" {
    // See gitCommit: OS-gate first so it's counted as skipped on Windows.
    if (os.is_windows) return error.SkipZigTest;
    if (!gitAvailable()) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = try std.fs.path.join(gpa, &.{ "/tmp", "zay-git-notrepo" });
    defer gpa.free(dir);
    ignoreRun(gpa, io, "/tmp", "rm -rf zay-git-notrepo && mkdir -p zay-git-notrepo");

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    // The bridge runs git in cwd (repo root), which IS a repo here. To test the
    // non-repo path we invoke the underlying command in the temp dir directly.
    var result = try bash_exec.run(gpa, io, dir, "git status --porcelain");
    defer result.deinit(gpa);
    try std.testing.expect(result.code != 0);
    try std.testing.expect(result.stdout.len == 0);
    const err = gitErrorString(result.stderr, result.code);
    try std.testing.expect(err.len > 0);
    ignoreRun(gpa, io, "/tmp", "rm -rf zay-git-notrepo");
}

test "gitErrorString prefers stderr over generic exit code" {
    try std.testing.expectEqualStrings("fatal: not a git repository", gitErrorString("fatal: not a git repository\n", 128));
    try std.testing.expect(std.mem.indexOf(u8, gitErrorString("", 128), "code 128") != null);
}

test "git bridges return strings inside a repo (S4 success path)" {
    // See gitCommit: OS-gate first so it's counted as skipped on Windows.
    if (os.is_windows) return error.SkipZigTest;
    if (!gitAvailable()) return;

    // A dedicated fixture repo keeps the bridges hermetic: the live repo
    // root's `git diff` grows with the working tree's uncommitted state and
    // overflows the bounded capture (StreamTooLong) after a big change.
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const test_dir = ".zig-cache/test_git_bridges_repo";
    std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, test_dir);
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    var init = bash_exec.run(gpa, io, test_dir, "git init -q -b zay-bridges-test && git config user.email t@t && git config user.name t") catch return;
    defer init.deinit(gpa);
    if (init.code != 0) return error.SkipZigTest;

    var commit = bash_exec.run(gpa, io, test_dir, "git commit --allow-empty -m initial") catch return;
    defer commit.deinit(gpa);
    if (commit.code != 0) return error.SkipZigTest;

    const abs_test_dir = try std.fs.path.resolve(gpa, &.{test_dir});
    defer gpa.free(abs_test_dir);

    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    bridge.plugin_cwd_slot = abs_test_dir;
    defer bridge.plugin_cwd_slot = null;

    try expectLuaOk(&L,
        \\local s = zay.git_status()
        \\assert(type(s) == "string", "git_status returns a string in a repo, got " .. type(s))
        \\local d, derr = zay.git_diff()
        \\assert(type(d) == "string", "git_diff returns a string in a repo, got " .. type(d) .. " err: " .. tostring(derr))
        \\local l = zay.git_log(1)
        \\assert(type(l) == "string", "git_log returns a string in a repo, got " .. type(l))
        \\local b = zay.git_branch()
        \\assert(type(b) == "string", "git_branch returns a string in a repo, got " .. type(b))
        \\return "OK"
    );
}

test "plugin_api: deletePath removes regular file, empty dir, and recursive tree" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const test_base = ".zig-cache/test_delete_path_fixture";
    std.Io.Dir.cwd().deleteTree(io, test_base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, test_base);
    defer std.Io.Dir.cwd().deleteTree(io, test_base) catch {};

    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    // 1. Create and delete regular file
    const file_rel = test_base ++ "/sample.txt";
    var file = try std.Io.Dir.cwd().createFile(io, file_rel, .{});
    file.close(io);

    try expectLuaOk(&L,
        \\local ok, err = zay.delete_path(".zig-cache/test_delete_path_fixture/sample.txt")
        \\assert(ok == true, "delete file failed: " .. tostring(err))
        \\return "OK"
    );

    // 2. Create and delete empty directory
    const dir_rel = test_base ++ "/empty_dir";
    try std.Io.Dir.cwd().createDirPath(io, dir_rel);

    try expectLuaOk(&L,
        \\local ok, err = zay.delete_path(".zig-cache/test_delete_path_fixture/empty_dir")
        \\assert(ok == true, "delete empty dir failed: " .. tostring(err))
        \\return "OK"
    );

    // 3. Create and delete recursive tree
    const tree_rel = test_base ++ "/tree_dir";
    try std.Io.Dir.cwd().createDirPath(io, tree_rel ++ "/sub");
    var subfile = try std.Io.Dir.cwd().createFile(io, tree_rel ++ "/sub/nested.txt", .{});
    subfile.close(io);

    try expectLuaOk(&L,
        \\local ok, err = zay.delete_path(".zig-cache/test_delete_path_fixture/tree_dir", { recursive = true })
        \\assert(ok == true, "delete tree failed: " .. tostring(err))
        \\return "OK"
    );
}

test "plugin_api: sanitizePath respects bridge.plugin_cwd_slot" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const fake_worktree = ".zig-cache/test_fake_worktree";
    std.Io.Dir.cwd().deleteTree(io, fake_worktree) catch {};
    try std.Io.Dir.cwd().createDirPath(io, fake_worktree);
    defer std.Io.Dir.cwd().deleteTree(io, fake_worktree) catch {};

    const abs_worktree = try std.fs.path.resolve(gpa, &.{fake_worktree});
    defer gpa.free(abs_worktree);

    bridge.plugin_cwd_slot = abs_worktree;
    defer {
        bridge.plugin_cwd_slot = null;
    }

    const sanitized = try sanitizePath(io, "file.txt");
    defer std.heap.page_allocator.free(sanitized);

    try std.testing.expect(std.mem.startsWith(u8, sanitized, abs_worktree));
}

test "plugin_api: findGitRoot finds directory .git and file .git worktree" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const test_dir = ".zig-cache/test_git_root_fixture";
    std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, test_dir);
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    // 1. Directory .git
    const dir_repo = test_dir ++ "/dir_repo";
    try std.Io.Dir.cwd().createDirPath(io, dir_repo ++ "/.git");
    try std.Io.Dir.cwd().createDirPath(io, dir_repo ++ "/src/nested");

    const abs_dir_nested = try std.fs.path.resolve(gpa, &.{ root, dir_repo ++ "/src/nested" });
    defer gpa.free(abs_dir_nested);

    const root1 = try findGitRoot(io, abs_dir_nested);
    defer std.heap.page_allocator.free(root1);

    const abs_dir_repo = try std.fs.path.resolve(gpa, &.{ root, dir_repo });
    defer gpa.free(abs_dir_repo);
    try std.testing.expectEqualStrings(abs_dir_repo, root1);

    // 2. File .git (worktree mock)
    const file_repo = test_dir ++ "/file_repo";
    try std.Io.Dir.cwd().createDirPath(io, file_repo ++ "/src/nested");
    var gitfile = try std.Io.Dir.cwd().createFile(io, file_repo ++ "/.git", .{});
    gitfile.close(io);

    const abs_file_nested = try std.fs.path.resolve(gpa, &.{ root, file_repo ++ "/src/nested" });
    defer gpa.free(abs_file_nested);

    const root2 = try findGitRoot(io, abs_file_nested);
    defer std.heap.page_allocator.free(root2);

    const abs_file_repo = try std.fs.path.resolve(gpa, &.{ root, file_repo });
    defer gpa.free(abs_file_repo);
    try std.testing.expectEqualStrings(abs_file_repo, root2);
}

test "plugin_api: get_cwd and get_project_root respect bridge.plugin_cwd_slot" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const test_dir = ".zig-cache/test_slot_ctx";
    std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, test_dir);
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    // Create a fixture: <repo>/.git + <repo>/nested
    const repo = test_dir ++ "/repo";
    try std.Io.Dir.cwd().createDirPath(io, repo ++ "/.git");
    try std.Io.Dir.cwd().createDirPath(io, repo ++ "/nested");

    const abs_nested = try std.fs.path.resolve(gpa, &.{ root, repo ++ "/nested" });
    defer gpa.free(abs_nested);
    const abs_repo = try std.fs.path.resolve(gpa, &.{ root, repo });
    defer gpa.free(abs_repo);

    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    bridge.plugin_cwd_slot = abs_nested;
    defer bridge.plugin_cwd_slot = null;

    try expectLuaOk(&L,
        \\local cwd = zay.get_cwd()
        \\assert(type(cwd) == "string", "get_cwd failed")
        \\local root = zay.get_project_root()
        \\assert(type(root) == "string", "get_project_root failed")
        \\return "OK"
    );
}

test "plugin_api: git read bridges run in bridge.plugin_cwd_slot cwd" {
    if (os.is_windows) return error.SkipZigTest;
    if (!gitAvailable()) return;

    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const test_dir = ".zig-cache/test_git_slot_cwd";
    std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, test_dir);
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    // Init a git repo with a dedicated branch name.
    var init = bash_exec.run(gpa, io, test_dir, "git init -q -b zay-slot-test && git config user.email t@t && git config user.name t") catch return;
    defer init.deinit(gpa);
    if (init.code != 0) return error.SkipZigTest;

    var commit = bash_exec.run(gpa, io, test_dir, "git commit --allow-empty -m initial") catch return;
    defer commit.deinit(gpa);
    if (commit.code != 0) return error.SkipZigTest;

    const abs_test_dir = try std.fs.path.resolve(gpa, &.{test_dir});
    defer gpa.free(abs_test_dir);

    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    bridge.plugin_cwd_slot = abs_test_dir;
    defer bridge.plugin_cwd_slot = null;

    try expectLuaOk(&L,
        \\local branch = zay.git_branch()
        \\assert(branch == "zay-slot-test", "expected zay-slot-test, got " .. tostring(branch))
        \\local status = zay.git_status()
        \\assert(type(status) == "string", "git_status failed")
        \\local log = zay.git_log(1)
        \\assert(type(log) == "string", "git_log failed")
        \\local diff = zay.git_diff()
        \\assert(type(diff) == "string", "git_diff failed")
        \\return "OK"
    );
}

test "plugin_api: globMatchSegment handles Windows backslashes and forward slashes interchangeably" {
    // 1. Windows path with forward-slash glob pattern
    try std.testing.expect(globMatchSegment("src\\tools\\bash.zig", "src/**/*.zig"));
    try std.testing.expect(globMatchSegment("src\\tools\\bash.zig", "src/*/*.zig"));
    try std.testing.expect(globMatchSegment("src\\tools\\bash.zig", "**/*.zig"));
    try std.testing.expect(globMatchSegment("src\\tools\\bash.zig", "src/tools/bash.zig"));

    // 2. Windows path with backslash glob pattern
    try std.testing.expect(globMatchSegment("src\\tools\\bash.zig", "src\\**\\*.zig"));
    try std.testing.expect(globMatchSegment("src\\tools\\bash.zig", "src\\*\\*.zig"));

    // 3. POSIX path with forward-slash pattern
    try std.testing.expect(globMatchSegment("src/tools/bash.zig", "src/**/*.zig"));
    try std.testing.expect(globMatchSegment("src/tools/bash.zig", "**/*.zig"));

    // 4. Non-matching paths
    try std.testing.expect(!globMatchSegment("src\\tools\\bash.zig", "src/*.zig"));
    try std.testing.expect(!globMatchSegment("src\\tools\\bash.zig", "lib/**/*.zig"));
}

test "plugin_api: run_shell executes native shell on current OS" {
    const io = std.testing.io;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{ .allow_os_execute = true }, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    try expectLuaOk(&L,
        \\local res, err = zay.run_shell("echo zay_shell_ok")
        \\assert(res ~= nil, "run_shell failed: " .. tostring(err))
        \\assert(res.code == 0, "run_shell exited with non-zero code: " .. tostring(res.code))
        \\assert(string.find(res.stdout, "zay_shell_ok") ~= nil, "stdout did not contain expected message: " .. tostring(res.stdout))
        \\return "OK"
    );
}

test "plugin_api: zay.require loads modules, caches results, and rejects breakouts" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const test_plugin_dir = ".zig-cache/test_multi_file_plugin";
    std.Io.Dir.cwd().deleteTree(io, test_plugin_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, test_plugin_dir);
    defer std.Io.Dir.cwd().deleteTree(io, test_plugin_dir) catch {};

    // 1. Create helper.lua
    var buf: [4096]u8 = undefined;
    var helper_file = try std.Io.Dir.cwd().createFile(io, test_plugin_dir ++ "/helper.lua", .{});
    var w1 = helper_file.writer(io, &buf);
    try w1.interface.writeAll(
        \\local M = { count = 1 }
        \\function M.add(a, b) return a + b end
        \\return M
    );
    try w1.interface.flush();
    helper_file.close(io);

    // 2. Create submod/init.lua
    try std.Io.Dir.cwd().createDirPath(io, test_plugin_dir ++ "/submod");
    var submod_file = try std.Io.Dir.cwd().createFile(io, test_plugin_dir ++ "/submod/init.lua", .{});
    var w2 = submod_file.writer(io, &buf);
    try w2.interface.writeAll(
        \\return { name = "submodule" }
    );
    try w2.interface.flush();
    submod_file.close(io);

    const abs_plugin_dir = try std.fs.path.resolve(gpa, &.{ root, test_plugin_dir });
    defer gpa.free(abs_plugin_dir);

    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    // Set plugin directory in registry
    _ = c.lua_pushlstring(L.handle, abs_plugin_dir.ptr, abs_plugin_dir.len);
    c.lua_setfield(L.handle, c.LUA_REGISTRYINDEX, "zay_plugin_dir");

    // Test relative require and caching
    try expectLuaOk(&L,
        \\local helper1 = zay.require("./helper")
        \\assert(type(helper1) == "table", "expected table, got " .. type(helper1))
        \\assert(helper1.add(10, 20) == 30, "add failed")
        \\
        \\-- Modify table to verify caching
        \\helper1.count = 42
        \\local helper2 = zay.require("helper.lua")
        \\assert(helper2.count == 42, "cache failed: did not get same instance")
        \\
        \\-- Require submod/init.lua
        \\local submod = zay.require("submod")
        \\assert(submod.name == "submodule", "submod require failed")
        \\
        \\-- Reject breakout attempt
        \\local outside, err = zay.require("../outside")
        \\assert(outside == nil, "breakout should have failed")
        \\assert(string.find(err, "access denied") ~= nil, "unexpected error: " .. tostring(err))
        \\
        \\return "OK"
    );
}

test "plugin_api: zay.git_add and selective zay.git_commit validate arguments" {
    const io = std.testing.io;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    // git_add requires files argument
    try expectLuaOk(&L,
        \\local ok, err = zay.git_add()
        \\assert(ok == nil, "git_add without args should fail")
        \\assert(string.find(err, "files argument is required") ~= nil, "unexpected error: " .. tostring(err))
        \\
        \\local ok2, err2 = zay.git_commit()
        \\assert(ok2 == nil, "git_commit without message should fail")
        \\assert(string.find(err2, "commit message argument is required") ~= nil, "unexpected error: " .. tostring(err2))
        \\
        \\return "OK"
    );
}

// ── plugin.get_config (P1) ───────────────────────────────────────────

/// Seed the settings registry slot exactly the way `PluginManager.loadOne`
/// does: `lua_pushlstring` (copies into the Lua GC) + `lua_setfield`.
fn seedSettingsSlot(L: *State, json: []const u8) void {
    _ = c.lua_pushlstring(L.handle, json.ptr, json.len);
    _ = c.lua_setfield(L.handle, c.LUA_REGISTRYINDEX, sandbox_mod.settings_registry_key);
}

test "plugin.get_config decodes object settings into a fresh table" {
    const io = std.testing.io;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    seedSettingsSlot(&L, "{\"theme\":\"dark\",\"retries\":3}");

    try expectLuaOk(&L,
        \\local cfg = plugin.get_config()
        \\assert(type(cfg) == "table", "settings decode to a table")
        \\assert(cfg.theme == "dark", "string field readable")
        \\assert(cfg.retries == 3, "number field readable")
        \\cfg.theme = "mutated"
        \\local cfg2 = plugin.get_config()
        \\assert(cfg2.theme == "dark", "fresh table per call: mutation does not leak")
        \\return "OK"
    );
}

test "plugin.get_config returns nil when unconfigured" {
    const io = std.testing.io;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    // No settings slot seeded — the unconfigured default.
    try expectLuaOk(&L,
        \\assert(plugin.get_config() == nil, "unconfigured plugin gets nil")
        \\return "OK"
    );
}

test "plugin.get_config rejects malformed and non-object settings" {
    const io = std.testing.io;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    seedSettingsSlot(&L, "not json at all");
    try expectLuaOk(&L,
        \\local v, err = plugin.get_config()
        \\assert(v == nil, "malformed settings yield nil")
        \\assert(err == "get_config: settings must be a JSON object", "got: " .. tostring(err))
        \\return "OK"
    );

    // A JSON scalar also decodes to a Lua value — the object check must
    // reject it before the push.
    seedSettingsSlot(&L, "42");
    try expectLuaOk(&L,
        \\local v, err = plugin.get_config()
        \\assert(v == nil, "scalar settings yield nil")
        \\assert(err == "get_config: settings must be a JSON object", "got: " .. tostring(err))
        \\return "OK"
    );

    // A JSON array decodes to a Lua table — it must be rejected too.
    seedSettingsSlot(&L, "[1,2]");
    try expectLuaOk(&L,
        \\local v, err = plugin.get_config()
        \\assert(v == nil, "array settings yield nil")
        \\assert(err == "get_config: settings must be a JSON object", "got: " .. tostring(err))
        \\return "OK"
    );
}
