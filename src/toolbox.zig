//! The procedurally-generated tool box.
//!
//! Holds tools distilled from recurring agent behaviour as plain data records
//! that share one interpreter, so adding a tool needs no new native code. The
//! box is project-scoped (`<cwd>/.nova/tools.json`) and persists across
//! sessions. (The background distiller that *writes* the box is a later
//! increment; this module is the runtime that loads, searches, and runs it.)
//!
//! A generated tool is deliberately NOT a `common.Tool` — those carry Zig fn
//! pointers a model can't emit. It is a schema plus a bash `template`. `run`
//! binds each validated argument as an environment variable of the same name
//! and executes the template through the very same bash path the `bash` tool
//! uses (login-env overlay, truncation, spill-to-disk). Binding args as env
//! vars — never string-substituting them into the command — is what keeps a
//! generated tool from being a shell-injection vector.
//!
//! Discovery is indirect by design: `search_tools` matches a query against tool
//! names and hidden `keywords`; `execute_tool` dispatches by name. Neither the
//! box's contents nor the keywords ever enter the model's tool schema, so the
//! system prompt stays byte-stable as the box grows and the prompt cache
//! survives.

const std = @import("std");

const logger = @import("logger");

const bash_tool = @import("tools/bash.zig");
const common = @import("tools/common.zig");

const assert = std.debug.assert;

pub const Kind = common.Schema.Kind;

/// Generated tools run with a longer default budget than the interactive bash
/// tool (10s): they encode a proven, deliberate operation, not an exploratory
/// probe. A per-tool timeout can override this later.
const default_timeout_seconds: u32 = 30;

/// One argument a generated tool accepts. Bound into the template's environment
/// under `name`, so `name` must be a valid shell identifier.
pub const Param = struct {
    name: []const u8,
    kind: Kind = .string,
    description: []const u8 = "",
    required: bool = false,
};

/// One distilled tool: a searchable identity plus an executable bash template.
pub const GeneratedTool = struct {
    name: []const u8,
    description: []const u8 = "",
    /// Hidden search terms — matched by `search_tools`, never shown to the model.
    keywords: []const []const u8 = &.{},
    params: []const Param = &.{},
    /// Bash script run with every declared param bound as `$name`.
    template: []const u8,
    /// Eviction bookkeeping (used by the distiller in a later increment):
    /// lifetime invocations and turns since last use. Persisted so both
    /// survive a restart.
    uses: u32 = 0,
    idle_turns: u32 = 0,
};

pub const Toolbox = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Owns every string reachable from `tools` — grown on load/add, freed once
    /// at teardown. `tools`' backing array is `gpa`-owned separately.
    arena: std.heap.ArenaAllocator,
    /// Absolute path to `<cwd>/.nova/tools.json` (`gpa`-owned).
    path: []u8,
    tools: std.ArrayList(GeneratedTool) = .empty,
    /// Guards `tools` and `arena`. A spinlock (matching the background manager),
    /// which is fine because every critical section here is short and takes no
    /// I/O: the file write and the template execution both happen with the lock
    /// released. Contended by worker threads (run/search), the turn boundary
    /// (evict), and the distiller thread (add).
    mutex: std.atomic.Mutex = .unlocked,

    fn lockMutex(self: *Toolbox) void {
        while (!self.mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    /// Heap-allocate a box for `cwd` and load its persisted tools. The box is
    /// heap-allocated so its `arena`'s self-pointer stays put while agents
    /// borrow a `*Toolbox`. A missing or corrupt file is not fatal — the box
    /// simply starts empty; only OOM propagates.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) !*Toolbox {
        assert(cwd.len > 0);
        const self = try gpa.create(Toolbox);
        errdefer gpa.destroy(self);
        const path = try std.fs.path.join(gpa, &.{ cwd, ".nova", "tools.json" });
        self.* = .{ .gpa = gpa, .io = io, .arena = std.heap.ArenaAllocator.init(gpa), .path = path };
        // A missing or corrupt file leaves the box empty (`load` swallows those);
        // the only failure it surfaces is OOM, which is fatal.
        self.load() catch |err| {
            self.arena.deinit();
            gpa.free(path);
            return err;
        };
        return self;
    }

    pub fn deinit(self: *Toolbox) void {
        self.tools.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.free(self.path);
        self.* = undefined;
    }

    pub fn destroy(self: *Toolbox) void {
        const gpa = self.gpa;
        self.deinit();
        gpa.destroy(self);
    }

    /// Locate a tool by name. Caller must hold `mutex`; the returned pointer is
    /// only valid until the lock is released (a concurrent `add`/`evict` may move
    /// the backing array). Public `find` locks and is for single-threaded/test use.
    fn findLocked(self: *Toolbox, name: []const u8) ?*GeneratedTool {
        for (self.tools.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    pub fn find(self: *Toolbox, name: []const u8) ?*GeneratedTool {
        self.lockMutex();
        defer self.mutex.unlock();
        return self.findLocked(name);
    }

    /// Run generated tool `name` with `args_json` (the raw JSON object the model
    /// passed as `execute_tool`'s `args`). Returns null when no generated tool
    /// owns that name, so the caller can fall through to the native registry. A
    /// bad-arguments failure is returned as a normal failed `Output`, not an
    /// error — the model should see it and retry.
    ///
    /// The tool's template and parameter shape are snapshotted under the lock
    /// into a scratch arena; the lock is released before the (possibly slow)
    /// template execution, then re-acquired to bump usage. So a long-running
    /// generated tool never blocks searches or the distiller on another lane.
    pub fn run(
        self: *Toolbox,
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        name: []const u8,
        args_json: []const u8,
    ) common.Error!?common.Output {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const spec = blk: {
            self.lockMutex();
            defer self.mutex.unlock();
            const tool = self.findLocked(name) orelse return null;
            break :blk try snapshotSpec(scratch.allocator(), tool.*);
        };

        var parsed: ?std.json.Parsed(std.json.Value) = null;
        defer if (parsed) |p| p.deinit();
        var arg_obj: ?std.json.ObjectMap = null;
        const trimmed = std.mem.trim(u8, args_json, " \t\r\n");
        if (trimmed.len > 0) {
            const p = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch
                return try common.fail(gpa, "invalid JSON arguments", 2);
            parsed = p;
            if (p.value == .object) arg_obj = p.value.object;
        }

        for (spec.params) |param| {
            if (!param.required) continue;
            const present = if (arg_obj) |o| o.get(param.name) != null else false;
            if (!present) return try common.failFmt(gpa, 2, "missing required argument: {s}", .{param.name});
        }

        var env_map = try bash_tool.currentEnvMap(gpa, io);
        defer env_map.deinit();
        // Keep bound values alive across the run: `Environ.Map.put`'s ownership
        // is not something we rely on here.
        var owned: std.ArrayList([]u8) = .empty;
        defer {
            for (owned.items) |s| gpa.free(s);
            owned.deinit(gpa);
        }
        if (arg_obj) |o| {
            for (spec.params) |param| {
                const value = o.get(param.name) orelse continue;
                if (!std.process.Environ.Map.validateKeyForPut(param.name)) {
                    return try common.failFmt(gpa, 2, "argument name is not a valid shell variable: {s}", .{param.name});
                }
                const bound = try paramEnvValue(gpa, value);
                try owned.append(gpa, bound);
                try env_map.put(param.name, bound);
            }
        }

        self.markUsed(name);
        return try bash_tool.runCaptured(gpa, io, cwd, spec.template, &env_map, default_timeout_seconds);
    }

    /// A tool ran: reset its idle counter and bump its use count, then persist.
    /// Looked up afresh under the lock — the tool may have been evicted between
    /// the run's snapshot and here, in which case this is a no-op.
    fn markUsed(self: *Toolbox, name: []const u8) void {
        {
            self.lockMutex();
            defer self.mutex.unlock();
            const tool = self.findLocked(name) orelse return;
            tool.uses +|= 1;
            tool.idle_turns = 0;
        }
        self.save() catch {}; // best-effort; a failed persist must not fail the call
    }

    /// Add (or replace, by name) a tool, deep-copying its strings into the box's
    /// arena, then persist. Replacing orphans the old strings in the arena until
    /// teardown — acceptable, as replacement is rare. Thread-safe.
    pub fn add(self: *Toolbox, tool: GeneratedTool) !void {
        {
            self.lockMutex();
            defer self.mutex.unlock();
            const copy = try self.dupeTool(tool);
            if (self.findLocked(tool.name)) |existing| {
                existing.* = copy;
            } else {
                try self.tools.append(self.gpa, copy);
            }
        }
        self.save() catch {};
    }

    /// Remove a tool by name. Returns whether one matched. Thread-safe.
    pub fn remove(self: *Toolbox, name: []const u8) bool {
        const removed = blk: {
            self.lockMutex();
            defer self.mutex.unlock();
            for (self.tools.items, 0..) |t, i| {
                if (std.mem.eql(u8, t.name, name)) {
                    _ = self.tools.orderedRemove(i);
                    break :blk true;
                }
            }
            break :blk false;
        };
        if (removed) self.save() catch {};
        return removed;
    }

    /// Advance the turn clock: every tool's idle counter increments, and any tool
    /// idle for more than `max_idle_turns` is evicted. A tool used this turn was
    /// reset to 0 by `markUsed`, so it lands at 1 here. Returns the number
    /// evicted; persists only when something changed. Call once per turn boundary.
    pub fn tickTurnAndEvict(self: *Toolbox, max_idle_turns: u32) u32 {
        var evicted: u32 = 0;
        {
            self.lockMutex();
            defer self.mutex.unlock();
            var i: usize = 0;
            while (i < self.tools.items.len) {
                self.tools.items[i].idle_turns +|= 1;
                if (self.tools.items[i].idle_turns > max_idle_turns) {
                    logger.log("toolbox: evicting unused tool '{s}' (idle {d} turns)", .{ self.tools.items[i].name, self.tools.items[i].idle_turns });
                    _ = self.tools.orderedRemove(i);
                    evicted += 1;
                } else {
                    i += 1;
                }
            }
        }
        if (evicted > 0) self.save() catch {};
        return evicted;
    }

    /// Snapshot the names currently in the box (gpa-owned slice of gpa-owned
    /// strings) so the distiller thread can dedup against them without touching
    /// live state. Caller frees each name and the slice.
    pub fn snapshotNames(self: *Toolbox, gpa: std.mem.Allocator) ![][]const u8 {
        self.lockMutex();
        defer self.mutex.unlock();
        const out = try gpa.alloc([]const u8, self.tools.items.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |n| gpa.free(n);
            gpa.free(out);
        }
        for (self.tools.items) |t| {
            out[filled] = try gpa.dupe(u8, t.name);
            filled += 1;
        }
        return out;
    }

    fn dupeTool(self: *Toolbox, tool: GeneratedTool) !GeneratedTool {
        const a = self.arena.allocator();
        const keywords = try a.alloc([]const u8, tool.keywords.len);
        for (tool.keywords, 0..) |k, i| keywords[i] = try a.dupe(u8, k);
        const params = try a.alloc(Param, tool.params.len);
        for (tool.params, 0..) |p, i| params[i] = .{
            .name = try a.dupe(u8, p.name),
            .kind = p.kind,
            .description = try a.dupe(u8, p.description),
            .required = p.required,
        };
        return .{
            .name = try a.dupe(u8, tool.name),
            .description = try a.dupe(u8, tool.description),
            .keywords = keywords,
            .params = params,
            .template = try a.dupe(u8, tool.template),
            .uses = tool.uses,
            .idle_turns = tool.idle_turns,
        };
    }

    /// The model-facing result of `search_tools`: matching tools with their
    /// public description and parameter names. Hidden keywords are never
    /// emitted. `native` is the compile-time registry so bash and the meta-tools
    /// are discoverable alongside generated ones.
    pub fn searchText(
        self: *Toolbox,
        gpa: std.mem.Allocator,
        query: []const u8,
        native: []const common.Tool,
    ) common.Error![]u8 {
        self.lockMutex();
        defer self.mutex.unlock();
        // The builder writes into an Allocating writer, whose only failure mode
        // is a failed grow; fold that back into OOM to fit `common.Error`.
        return self.buildSearchText(gpa, query, native) catch |err| switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => |e| e,
        };
    }

    fn buildSearchText(
        self: *Toolbox,
        gpa: std.mem.Allocator,
        query: []const u8,
        native: []const common.Tool,
    ) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const w = &aw.writer;
        var hits: u32 = 0;

        for (native) |t| {
            if (std.mem.eql(u8, t.name, "search_tools")) continue; // don't return the searcher itself
            if (!nativeMatches(query, t)) continue;
            try w.print("- {s}: {s}\n", .{ t.name, summary(t.description) });
            hits += 1;
        }
        for (self.tools.items) |t| {
            if (!generatedMatches(query, t)) continue;
            try w.print("- {s}: {s}", .{ t.name, summary(t.description) });
            if (t.params.len > 0) {
                try w.writeAll(" (args: ");
                for (t.params, 0..) |p, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(p.name);
                    if (p.required) try w.writeAll("*");
                }
                try w.writeByte(')');
            }
            try w.writeByte('\n');
            hits += 1;
        }

        if (hits == 0) {
            return std.fmt.allocPrint(
                gpa,
                "No tools matched \"{s}\". Anything not covered can still be done with bash via execute_tool.",
                .{query},
            );
        }
        try w.writeAll("\nCall any of these with execute_tool: {\"name\": \"<tool>\", \"args\": {...}}. Required args are marked *.");
        return aw.toOwnedSlice();
    }

    /// Persist the current tools to `path`, creating `.nova/` if needed. Writes
    /// the whole file (the box is small); callers that must not fail on I/O
    /// should `catch {}`.
    pub fn save(self: *Toolbox) !void {
        // Serialise under the lock (fast, no I/O); write the file with the lock
        // released so a slow disk never blocks a run/search on another lane.
        const bytes = bytes: {
            self.lockMutex();
            defer self.mutex.unlock();
            var aw: std.Io.Writer.Allocating = .init(self.gpa);
            defer aw.deinit();
            try self.writeJson(&aw.writer);
            break :bytes try aw.toOwnedSlice();
        };
        defer self.gpa.free(bytes);

        if (std.fs.path.dirname(self.path)) |dir| {
            std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        }
        var file = try std.Io.Dir.createFile(.cwd(), self.io, self.path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, bytes);
    }

    fn load(self: *Toolbox) !void {
        const bytes = common.readFileBytes(self.gpa, self.io, self.path, 4 * 1024 * 1024) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return, // no file / unreadable → empty box
        };
        defer self.gpa.free(bytes);
        try self.parseInto(bytes);
    }

    fn parseInto(self: *Toolbox, bytes: []const u8) !void {
        const parsed = std.json.parseFromSlice(Persisted, self.gpa, bytes, .{ .ignore_unknown_fields = true }) catch return; // corrupt → empty
        defer parsed.deinit();
        for (parsed.value.tools) |pt| {
            if (pt.name.len == 0 or pt.template.len == 0) continue;
            const tool = try self.dupeFromPersisted(pt);
            try self.tools.append(self.gpa, tool);
        }
    }

    fn dupeFromPersisted(self: *Toolbox, pt: PersistedTool) !GeneratedTool {
        const a = self.arena.allocator();
        const keywords = try a.alloc([]const u8, pt.keywords.len);
        for (pt.keywords, 0..) |k, i| keywords[i] = try a.dupe(u8, k);
        const params = try a.alloc(Param, pt.params.len);
        for (pt.params, 0..) |pp, i| params[i] = .{
            .name = try a.dupe(u8, pp.name),
            .kind = kindFromString(pp.kind),
            .description = try a.dupe(u8, pp.description),
            .required = pp.required,
        };
        return .{
            .name = try a.dupe(u8, pt.name),
            .description = try a.dupe(u8, pt.description),
            .keywords = keywords,
            .params = params,
            .template = try a.dupe(u8, pt.template),
            .uses = pt.uses,
            .idle_turns = pt.idle_turns,
        };
    }

    fn writeJson(self: *Toolbox, w: *std.Io.Writer) !void {
        try w.writeAll("{\"tools\":[");
        for (self.tools.items, 0..) |t, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            try std.json.Stringify.value(t.name, .{}, w);
            try w.writeAll(",\"description\":");
            try std.json.Stringify.value(t.description, .{}, w);
            try w.writeAll(",\"keywords\":");
            try std.json.Stringify.value(t.keywords, .{}, w);
            try w.writeAll(",\"template\":");
            try std.json.Stringify.value(t.template, .{}, w);
            try w.writeAll(",\"params\":[");
            for (t.params, 0..) |p, pi| {
                if (pi > 0) try w.writeByte(',');
                try w.writeAll("{\"name\":");
                try std.json.Stringify.value(p.name, .{}, w);
                try w.writeAll(",\"kind\":");
                try std.json.Stringify.value(kindToString(p.kind), .{}, w);
                try w.writeAll(",\"description\":");
                try std.json.Stringify.value(p.description, .{}, w);
                try w.writeAll(",\"required\":");
                try std.json.Stringify.value(p.required, .{}, w);
                try w.writeByte('}');
            }
            try w.writeAll("],\"uses\":");
            try std.json.Stringify.value(t.uses, .{}, w);
            try w.writeAll(",\"idle_turns\":");
            try std.json.Stringify.value(t.idle_turns, .{}, w);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
};

const Persisted = struct {
    tools: []const PersistedTool = &.{},
};

const PersistedTool = struct {
    name: []const u8,
    description: []const u8 = "",
    keywords: []const []const u8 = &.{},
    params: []const PersistedParam = &.{},
    template: []const u8,
    uses: u32 = 0,
    idle_turns: u32 = 0,
};

const PersistedParam = struct {
    name: []const u8,
    kind: []const u8 = "string",
    description: []const u8 = "",
    required: bool = false,
};

pub fn kindFromString(s: []const u8) Kind {
    if (std.mem.eql(u8, s, "integer")) return .integer;
    if (std.mem.eql(u8, s, "object")) return .object;
    if (std.mem.eql(u8, s, "boolean")) return .boolean;
    return .string;
}

fn kindToString(kind: Kind) []const u8 {
    return switch (kind) {
        .string => "string",
        .integer => "integer",
        .object => "object",
        .boolean => "boolean",
    };
}

/// The minimal, self-contained copy of a tool needed to execute it: the
/// template plus each parameter's name and required-ness (all that validation
/// and env-binding need). Snapshotted into a scratch arena under the lock so the
/// execution below never dereferences live box state.
const RunSpec = struct {
    template: []const u8,
    params: []const SpecParam,
};

const SpecParam = struct {
    name: []const u8,
    required: bool,
};

fn snapshotSpec(a: std.mem.Allocator, tool: GeneratedTool) !RunSpec {
    const params = try a.alloc(SpecParam, tool.params.len);
    for (tool.params, 0..) |p, i| params[i] = .{ .name = try a.dupe(u8, p.name), .required = p.required };
    return .{ .template = try a.dupe(u8, tool.template), .params = params };
}

/// Render a JSON value as the string bound into the template's environment.
/// Scalars use their natural form; containers are re-serialised as compact JSON.
fn paramEnvValue(gpa: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => |s| gpa.dupe(u8, s),
        .integer => |n| std.fmt.allocPrint(gpa, "{d}", .{n}),
        .float => |f| std.fmt.allocPrint(gpa, "{d}", .{f}),
        .number_string => |s| gpa.dupe(u8, s),
        .bool => |b| gpa.dupe(u8, if (b) "true" else "false"),
        .null => gpa.dupe(u8, ""),
        else => blk: {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            // The only way an Allocating writer fails is a failed grow — i.e. OOM.
            std.json.Stringify.value(value, .{}, &aw.writer) catch return error.OutOfMemory;
            break :blk try aw.toOwnedSlice();
        },
    };
}

/// Case-insensitive, bidirectional substring match: a hit when either string
/// contains the other. Bidirectional so a broad query ("edit file") matches a
/// narrow keyword ("edit") and a narrow query ("edit") matches a broad name
/// ("edit_file"). An empty query matches everything (enumerate the box).
/// NOTE: `query` is treated as a literal substring, not yet a regex.
fn termMatch(field: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (field.len == 0) return false;
    return std.ascii.indexOfIgnoreCase(field, query) != null or
        std.ascii.indexOfIgnoreCase(query, field) != null;
}

fn nativeMatches(query: []const u8, tool: common.Tool) bool {
    if (termMatch(tool.name, query)) return true;
    for (tool.keywords) |k| if (termMatch(k, query)) return true;
    if (query.len > 0 and std.ascii.indexOfIgnoreCase(tool.description, query) != null) return true;
    return false;
}

fn generatedMatches(query: []const u8, tool: GeneratedTool) bool {
    if (termMatch(tool.name, query)) return true;
    for (tool.keywords) |k| if (termMatch(k, query)) return true;
    if (query.len > 0 and std.ascii.indexOfIgnoreCase(tool.description, query) != null) return true;
    return false;
}

/// First line of a description, capped, for one-line search output.
fn summary(description: []const u8) []const u8 {
    const line_end = std.mem.indexOfScalar(u8, description, '\n') orelse description.len;
    return description[0..@min(line_end, 160)];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testBox(gpa: std.mem.Allocator, io: std.Io) !Toolbox {
    return .{
        .gpa = gpa,
        .io = io,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .path = try gpa.dupe(u8, "/nonexistent/.nova/tools.json"),
    };
}

/// Swap a test box's dummy path for a writable one under `.zig-cache` so tests
/// that persist don't pollute the repo. Relative to cwd — fine for `save`, which
/// resolves against `.cwd()`.
fn replacePath(gpa: std.mem.Allocator, box: *Toolbox, name: []const u8) []u8 {
    gpa.free(box.path);
    return std.fmt.allocPrint(gpa, ".zig-cache/{s}/tools.json", .{name}) catch unreachable;
}

const sample_json =
    \\{"tools":[
    \\ {"name":"count_todos","description":"Count TODO markers under a path.",
    \\  "keywords":["todo","grep","count"],
    \\  "params":[{"name":"path","kind":"string","description":"Dir to scan","required":true}],
    \\  "template":"grep -rc TODO \"$path\" | wc -l","uses":3,"idle_turns":1}
    \\]}
;

test "parses persisted tools and finds by name" {
    const gpa = std.testing.allocator;
    var box = try testBox(gpa, std.testing.io);
    defer box.deinit();
    try box.parseInto(sample_json);

    try std.testing.expectEqual(@as(usize, 1), box.tools.items.len);
    const t = box.find("count_todos") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 3), t.uses);
    try std.testing.expectEqual(@as(usize, 1), t.params.len);
    try std.testing.expect(t.params[0].required);
    try std.testing.expect(box.find("nope") == null);
}

test "search matches hidden keyword but never emits keywords" {
    const gpa = std.testing.allocator;
    var box = try testBox(gpa, std.testing.io);
    defer box.deinit();
    try box.parseInto(sample_json);

    // "grep" is only a hidden keyword, not in the name/description.
    const text = try box.searchText(gpa, "grep", &.{});
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "count_todos") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "path*") != null); // required arg marked
    // The matched keyword itself must not leak into the model-facing output.
    try std.testing.expect(std.mem.indexOf(u8, text, "keyword") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"grep\"") == null);
}

test "search reports a clean miss" {
    const gpa = std.testing.allocator;
    var box = try testBox(gpa, std.testing.io);
    defer box.deinit();
    try box.parseInto(sample_json);

    const text = try box.searchText(gpa, "kubernetes", &.{});
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "No tools matched") != null);
}

test "run rejects a missing required argument without executing" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var box = try testBox(gpa, std.testing.io);
    defer box.deinit();
    try box.parseInto(sample_json);

    var out = (try box.run(gpa, std.testing.io, cwd, "count_todos", "{}")) orelse return error.TestFailed;
    defer out.deinit(gpa);
    try std.testing.expect(out.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, out.stderr, "missing required argument: path") != null);
}

test "run binds arguments as environment variables" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var box = try testBox(gpa, std.testing.io);
    defer box.deinit();
    // A template that just echoes its bound argument — proves env binding, not shell parsing.
    try box.parseInto(
        \\{"tools":[{"name":"greet","template":"printf '%s' \"$who\"",
        \\ "params":[{"name":"who","required":true}]}]}
    );

    var out = (try box.run(gpa, std.testing.io, cwd, "greet", "{\"who\":\"world\"}")) orelse return error.TestFailed;
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), out.code);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "world") != null);
    // Usage bookkeeping advanced.
    try std.testing.expectEqual(@as(u32, 1), box.find("greet").?.uses);
}

test "run returns null for an unknown tool" {
    const gpa = std.testing.allocator;
    var box = try testBox(gpa, std.testing.io);
    defer box.deinit();
    try std.testing.expect((try box.run(gpa, std.testing.io, "/tmp", "ghost", "{}")) == null);
}

test "arguments bind safely instead of injecting into the shell" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var box = try testBox(gpa, std.testing.io);
    defer box.deinit();
    try box.parseInto(
        \\{"tools":[{"name":"echo_arg","template":"printf '%s' \"$text\"",
        \\ "params":[{"name":"text","required":true}]}]}
    );

    // A value that would run `echo pwned` if it were substituted into the
    // command must be treated as literal data.
    var out = (try box.run(gpa, std.testing.io, cwd, "echo_arg", "{\"text\":\"$(echo pwned)\"}")) orelse return error.TestFailed;
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), out.code);
    // The literal survives verbatim — had it been substituted into the command,
    // the substitution would have run and left just "pwned".
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "$(echo pwned)") != null);
}

test "add inserts a tool and replacing by name keeps one entry" {
    const gpa = std.testing.allocator;
    var box = try testBox(gpa, std.testing.io);
    defer box.deinit();
    box.path = replacePath(gpa, &box, "toolbox-add-test");

    try box.add(.{ .name = "fmt", .description = "v1", .template = "echo one" });
    try std.testing.expectEqual(@as(usize, 1), box.tools.items.len);
    // Same name replaces rather than duplicating.
    try box.add(.{ .name = "fmt", .description = "v2", .template = "echo two" });
    try std.testing.expectEqual(@as(usize, 1), box.tools.items.len);
    try std.testing.expectEqualStrings("v2", box.find("fmt").?.description);
    _ = box.remove("fmt");
    try std.testing.expect(box.find("fmt") == null);
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, box.path) catch {};
}

test "tickTurnAndEvict evicts a tool idle past the threshold" {
    const gpa = std.testing.allocator;
    var box = try testBox(gpa, std.testing.io);
    defer box.deinit();
    box.path = replacePath(gpa, &box, "toolbox-evict-test");

    try box.add(.{ .name = "rare", .template = "echo hi" });
    // Threshold 3: idle climbs 1,2,3 (kept), then 4 > 3 evicts.
    try std.testing.expectEqual(@as(u32, 0), box.tickTurnAndEvict(3)); // -> 1
    try std.testing.expectEqual(@as(u32, 0), box.tickTurnAndEvict(3)); // -> 2
    try std.testing.expectEqual(@as(u32, 0), box.tickTurnAndEvict(3)); // -> 3
    try std.testing.expectEqual(@as(u32, 1), box.tickTurnAndEvict(3)); // -> 4, evicted
    try std.testing.expect(box.find("rare") == null);
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, box.path) catch {};
}

test "a used tool survives the turn tick" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var box = try testBox(gpa, std.testing.io);
    defer box.deinit();
    box.path = replacePath(gpa, &box, "toolbox-used-test");

    try box.add(.{ .name = "ping", .template = "printf ok" });
    _ = box.tickTurnAndEvict(2); // idle -> 1
    _ = box.tickTurnAndEvict(2); // idle -> 2
    // Use it: idle resets to 0.
    var out = (try box.run(gpa, std.testing.io, cwd, "ping", "{}")).?;
    out.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), box.find("ping").?.idle_turns);
    // Next tick brings it only to 1, well under the threshold — survives.
    try std.testing.expectEqual(@as(u32, 0), box.tickTurnAndEvict(2));
    try std.testing.expect(box.find("ping") != null);
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, box.path) catch {};
}

test "save round-trips through the file" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    const path = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "toolbox-test", "tools.json" });
    defer gpa.free(path);

    {
        var box: Toolbox = .{ .gpa = gpa, .io = std.testing.io, .arena = std.heap.ArenaAllocator.init(gpa), .path = try gpa.dupe(u8, path) };
        defer box.deinit();
        try box.parseInto(sample_json);
        try box.save();
    }
    {
        var box: Toolbox = .{ .gpa = gpa, .io = std.testing.io, .arena = std.heap.ArenaAllocator.init(gpa), .path = try gpa.dupe(u8, path) };
        defer box.deinit();
        try box.load();
        const t = box.find("count_todos") orelse return error.TestFailed;
        try std.testing.expectEqual(@as(u32, 3), t.uses);
        try std.testing.expectEqualStrings("grep -rc TODO \"$path\" | wc -l", t.template);
    }
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, path) catch {};
}
