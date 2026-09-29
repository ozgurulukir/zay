//! Session-scoped tool-result cache (#5).
//!
//! The model re-issues identical read-only commands turn after turn
//! (`git status`, `cat` a config, `ls` a directory); each re-run burns time
//! and tokens for byte-identical output. This cache dedupes those calls
//! within one session, with a deliberately conservative policy so it can
//! never change program behavior:
//!
//!   - ONLY single, read-only shell commands are cached — no shell
//!     metacharacters (`; | & > < $ \`` newline), first verb on a read-only
//!     allowlist (vcs tools only with read-only subcommands). Anything else
//!     bypasses the cache entirely.
//!   - A command that is NOT read-only CLEARS the cache before running: any
//!     mutation may have changed what earlier outputs captured.
//!   - The cache key is the COMMAND string, not the whole arguments JSON —
//!     the model's `description` varies between identical commands.
//!   - Cached hits are visibly marked so the model knows the output may be
//!     stale and can force freshness by running a mutating command.
//!   - Background jobs (`run_in_background`) are never cached — the output
//!     of a job-start call must never replay.
//!
//! Failed commands (exit != 0) are not stored: failures are frequently
//! transient (a file being written, a flaky grep) and re-running is the
//! useful behavior.

const std = @import("std");
const common = @import("common.zig");

const log = std.log.scoped(.result_cache);

/// Entry count cap. FIFO eviction — "cache once per session" semantics make
/// recency unimportant at this scale.
const max_entries: usize = 24;
/// Total cached stdout+stderr bytes across entries.
const max_total_bytes: usize = 768 * 1024;

/// First tokens whose single-invocation form cannot mutate state. VCS tools
/// are gated further by `vcs_readonly_subcommands`.
///
/// Deliberately EXCLUDED despite being mostly read-only: `find`
/// (`-delete`/`-exec` mutate), `sort` (`-o` writes), `hostname` (setter
/// form), `date` (`-s` sets the clock), `xargs`/`awk`/`sed` (arbitrary
/// side effects). When in doubt, leave it out — a missed cache hit costs a
/// re-run; a wrongly cached mutation silently replays stale state.
const read_only_verbs = [_][]const u8{
    "ls",       "cat",           "head",        "tail",     "wc",           "file",        "stat",
    "du",       "df",            "pwd",         "which",    "where",        "whoami",      "uname",
    "id",       "printenv",      "echo",        "grep",     "egrep",        "fgrep",       "rg",
    "fd",       "diff",          "cmp",         "uniq",     "cut",          "jq",          "dir",
    "type",
    // PowerShell read cmdlets (names arrive in any casing).
        "get-childitem", "get-content", "get-item", "get-location", "get-process", "select-string",
    "get-date", "get-command",
    // VCS drivers — subcommand-gated below.
      "git",         "hg",       "svn",
};

/// `git`-family subcommands that only ever read. `branch`/`tag`/`remote`/
/// `config` have mutating forms and are deliberately excluded.
const vcs_readonly_subcommands = [_][]const u8{
    "status", "log",      "diff",     "show",       "blame",    "rev-parse", "describe",
    "reflog", "ls-files", "shortlog", "merge-base", "annotate", "cat",
};

/// Argument fragments that turn a nominally read-only command into a writer
/// (`git diff --output=f.patch`, `jq` filter side effects stay out by verb).
const forbidden_argument_fragments = [_][]const u8{
    "--output", "-output=",
};

/// Shell metacharacters that make a command non-single (or enable command
/// substitution, whose inner command is unanalyzable).
const forbidden_metachars = ";|&><$`\n\r";

/// True when `command` is a single read-only invocation the cache may
/// deduplicate. Pure lexer-level analysis — no filesystem lookups, so it is
/// deterministic and safe to call from any thread.
pub fn isReadOnlyShellCommand(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t");
    if (trimmed.len == 0) return false;
    for (forbidden_metachars) |mc| {
        if (std.mem.indexOfScalar(u8, trimmed, mc) != null) return false;
    }
    // Nominally read-only commands with writer forms (`git diff --output=…`)
    // are rejected by fragment before the verb allowlist runs.
    for (forbidden_argument_fragments) |frag| {
        if (std.mem.indexOf(u8, trimmed, frag) != null) return false;
    }

    var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");
    const verb = normalizeVerb(tokens.next() orelse return false) orelse return false;

    var verb_buf: [64]u8 = undefined;
    if (verb.len >= verb_buf.len) return false;
    const verb_lower = std.ascii.lowerString(&verb_buf, verb);

    const is_vcs = std.mem.eql(u8, verb_lower, "git") or
        std.mem.eql(u8, verb_lower, "hg") or
        std.mem.eql(u8, verb_lower, "svn");
    if (is_vcs) {
        const sub_raw = tokens.next() orelse return false;
        const sub = normalizeVerb(sub_raw) orelse return false;
        var sub_buf: [64]u8 = undefined;
        if (sub.len >= sub_buf.len) return false;
        const sub_lower = std.ascii.lowerString(&sub_buf, sub);
        for (vcs_readonly_subcommands) |ro| {
            if (std.mem.eql(u8, sub_lower, ro)) return true;
        }
        return false;
    }

    for (read_only_verbs) |ro| {
        if (std.mem.eql(u8, verb_lower, ro)) return true;
    }
    return false;
}

/// Strip any path prefix and a `.exe` suffix so `/usr/bin/git`, `git.exe`,
/// and `git` compare equal. Returns null for quoted/odd first tokens (the
/// cache simply bypasses those).
fn normalizeVerb(token: []const u8) ?[]const u8 {
    if (token.len == 0) return null;
    if (token[0] == '"' or token[0] == '\'') return null;
    var name = token;
    if (std.mem.lastIndexOfAny(u8, name, "/\\")) |slash| name = name[slash + 1 ..];
    if (name.len > 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".exe")) {
        name = name[0 .. name.len - 4];
    }
    if (name.len == 0) return null;
    return name;
}

const Entry = struct {
    key: []u8,
    output: common.Output,
};

pub const ResultCache = struct {
    gpa: std.mem.Allocator,
    /// Insertion-ordered; index 0 is evicted first.
    entries: std.ArrayList(Entry) = .empty,
    map: std.StringHashMapUnmanaged(usize) = .empty,
    total_bytes: usize = 0,

    pub fn init(gpa: std.mem.Allocator) ResultCache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ResultCache) void {
        for (self.entries.items) |*entry| {
            self.gpa.free(entry.key);
            entry.output.deinit(self.gpa);
        }
        self.entries.deinit(self.gpa);
        self.map.deinit(self.gpa);
        self.total_bytes = 0;
    }

    /// Drop every cached result. Called before a mutating command runs.
    pub fn clear(self: *ResultCache) void {
        for (self.entries.items) |*entry| {
            self.gpa.free(entry.key);
            entry.output.deinit(self.gpa);
        }
        self.entries.clearRetainingCapacity();
        self.map.clearRetainingCapacity();
        self.total_bytes = 0;
    }

    pub const ShellLookup = union(enum) {
        /// Cached output (owned dupe, prefixed with a cache marker).
        hit: common.Output,
        /// Read-only and not yet cached — caller executes and calls
        /// `storeShell` with the result.
        miss: void,
        /// Not cacheable. Returned for unparseable arguments, non-read-only
        /// commands (which also CLEAR the cache — a mutation may invalidate
        /// every earlier capture), and background requests.
        bypass: void,
    };

    /// Cache lookup for a shell-tool call. `arguments_json` is the model's
    /// raw arguments string; only its `command` field keys the cache.
    pub fn lookupShell(self: *ResultCache, arguments_json: []const u8) ShellLookup {
        var parsed = parseShellArgs(self.gpa, arguments_json) catch return .bypass;
        defer parsed.deinit(self.gpa);

        if (parsed.background) return .bypass;
        if (!isReadOnlyShellCommand(parsed.command)) {
            // A command that can mutate invalidates everything captured
            // before it.
            self.clear();
            return .bypass;
        }
        if (self.map.get(parsed.command)) |index| {
            const entry = &self.entries.items[index];
            var dup = dupeOutput(self.gpa, &entry.output) catch return .miss;
            markCached(self.gpa, &dup) catch {
                dup.deinit(self.gpa);
                return .miss;
            };
            log.info("tool result cache hit ({d}B command)", .{parsed.command.len});
            return .{ .hit = dup };
        }
        return .miss;
    }

    /// Store the result of a read-only shell call (a `lookupShell` miss).
    /// Failures (exit != 0) are not stored. Best-effort: cache-cap or
    /// allocation pressure simply drops the entry.
    pub fn storeShell(self: *ResultCache, arguments_json: []const u8, output: *const common.Output) void {
        if (output.code != 0) return;
        var parsed = parseShellArgs(self.gpa, arguments_json) catch return;
        defer parsed.deinit(self.gpa);
        if (parsed.background or !isReadOnlyShellCommand(parsed.command)) return;
        if (self.map.contains(parsed.command)) return;

        const key = self.gpa.dupe(u8, parsed.command) catch return;
        const dup = dupeOutput(self.gpa, output) catch {
            self.gpa.free(key);
            return;
        };
        self.total_bytes += outputFootprint(&dup);
        self.entries.append(self.gpa, .{ .key = key, .output = dup }) catch {
            self.total_bytes -= outputFootprint(&dup);
            self.gpa.free(key);
            var mut = dup;
            mut.deinit(self.gpa);
            return;
        };
        self.map.put(self.gpa, key, self.entries.items.len - 1) catch {
            const removed = self.entries.pop().?;
            self.total_bytes -= outputFootprint(&removed.output);
            self.gpa.free(removed.key);
            var mut = removed.output;
            mut.deinit(self.gpa);
            return;
        };
        self.evictOverCap();
    }

    fn evictOverCap(self: *ResultCache) void {
        while (self.entries.items.len > max_entries or
            (self.total_bytes > max_total_bytes and self.entries.items.len > 0))
        {
            const removed = self.entries.orderedRemove(0);
            _ = self.map.remove(removed.key);
            self.total_bytes -= outputFootprint(&removed.output);
            self.gpa.free(removed.key);
            var mut = removed.output;
            mut.deinit(self.gpa);
        }
        // `orderedRemove` shifted indices — rebuild the map.
        self.map.clearRetainingCapacity();
        for (self.entries.items, 0..) |entry, i| {
            self.map.put(self.gpa, entry.key, i) catch return;
        }
    }
};

/// Parsed shell-tool arguments. Owns the command copy (the parsed JSON it
/// came from is freed inside `parseShellArgs`).
const ShellArgs = struct {
    command: []u8,
    background: bool,

    fn deinit(self: *ShellArgs, gpa: std.mem.Allocator) void {
        gpa.free(self.command);
    }
};

const ShellArgsJson = struct {
    command: ?[]const u8 = null,
    run_in_background: ?bool = null,
};

fn parseShellArgs(gpa: std.mem.Allocator, arguments_json: []const u8) !ShellArgs {
    const parsed = std.json.parseFromSlice(ShellArgsJson, gpa, arguments_json, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidToolArguments;
    defer parsed.deinit();
    const command = parsed.value.command orelse return error.InvalidToolArguments;
    if (command.len == 0) return error.InvalidToolArguments;
    return .{ .command = try gpa.dupe(u8, command), .background = parsed.value.run_in_background orelse false };
}

/// Deep-copy an `Output` so cache entries and hits own independent storage.
/// Each field is cleaned up on its own failure, so any error return leaves
/// nothing behind.
pub fn dupeOutput(gpa: std.mem.Allocator, output: *const common.Output) !common.Output {
    var dup: common.Output = .{
        .stdout = try gpa.dupe(u8, output.stdout),
        .stderr = try gpa.dupe(u8, output.stderr),
        .code = output.code,
    };
    errdefer {
        gpa.free(dup.stdout);
        gpa.free(dup.stderr);
    }
    switch (output.display) {
        .none => {},
        .text => |body| {
            const copy = try gpa.dupe(u8, body);
            errdefer gpa.free(copy);
            dup.display = .{ .text = copy };
        },
        .diff => |body| {
            const copy = try gpa.dupe(u8, body);
            errdefer gpa.free(copy);
            dup.display = .{ .diff = copy };
        },
    }
    if (output.observation) |obs| {
        switch (obs) {
            .complete => |text| {
                const copy = try gpa.dupe(u8, text);
                errdefer gpa.free(copy);
                dup.observation = .{ .complete = copy };
            },
            .truncated_tail => |tail| {
                const text_copy = try gpa.dupe(u8, tail.text);
                errdefer gpa.free(text_copy);
                const path_copy = try gpa.dupe(u8, tail.full_output_path);
                errdefer gpa.free(path_copy);
                dup.observation = .{ .truncated_tail = .{
                    .text = text_copy,
                    .total_lines = tail.total_lines,
                    .shown_lines = tail.shown_lines,
                    .total_bytes = tail.total_bytes,
                    .shown_bytes = tail.shown_bytes,
                    .full_output_path = path_copy,
                } };
            },
        }
    }
    return dup;
}

/// Retained-byte footprint of a cached entry: every owned body, not just
/// stdout/stderr — a truncated-tail observation can carry the bulk.
fn outputFootprint(output: *const common.Output) usize {
    var total = output.stdout.len + output.stderr.len;
    switch (output.display) {
        .none => {},
        .text, .diff => |body| total += body.len,
    }
    if (output.observation) |obs| {
        switch (obs) {
            .complete => |text| total += text.len,
            .truncated_tail => |tail| total += tail.text.len + tail.full_output_path.len,
        }
    }
    return total;
}

const cache_marker = "[cached result of an identical earlier call this session — run a mutating command or change the command to refresh]\n";

/// Prefix the cached marker onto a hit's rendered surfaces so the model
/// knows the output is a replay and may be stale. `formatLlmObservation`
/// prefers `observation` over `stdout`, so whichever surface exists gets the
/// marker (both, when both do). Mutates `output` IN PLACE and only swaps a
/// field after its replacement allocation succeeded, so a caller's
/// deinit-on-error path stays valid on every failure.
fn markCached(gpa: std.mem.Allocator, output: *common.Output) !void {
    {
        const marked = try std.fmt.allocPrint(gpa, "{s}{s}", .{ cache_marker, output.stdout });
        gpa.free(output.stdout);
        output.stdout = marked;
    }

    if (output.observation) |obs| {
        switch (obs) {
            .complete => |text| {
                const marked = try std.fmt.allocPrint(gpa, "{s}{s}", .{ cache_marker, text });
                gpa.free(output.observation.?.complete);
                output.observation = .{ .complete = marked };
            },
            .truncated_tail => |tail| {
                const marked = try std.fmt.allocPrint(gpa, "{s}{s}", .{ cache_marker, tail.text });
                gpa.free(output.observation.?.truncated_tail.text);
                output.observation = .{ .truncated_tail = .{
                    .text = marked,
                    .total_lines = tail.total_lines,
                    .shown_lines = tail.shown_lines + 1,
                    .total_bytes = tail.total_bytes,
                    .shown_bytes = tail.shown_bytes + @as(u32, @intCast(cache_marker.len)),
                    .full_output_path = tail.full_output_path,
                } };
            },
        }
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────

test "isReadOnlyShellCommand accepts single read-only verbs" {
    try std.testing.expect(isReadOnlyShellCommand("git status"));
    try std.testing.expect(isReadOnlyShellCommand("git log --oneline -5"));
    try std.testing.expect(isReadOnlyShellCommand("cat package.json"));
    try std.testing.expect(isReadOnlyShellCommand("/usr/bin/git diff"));
    try std.testing.expect(isReadOnlyShellCommand("Get-ChildItem -Force"));
    try std.testing.expect(isReadOnlyShellCommand("rg TODO src/"));

    try std.testing.expect(!isReadOnlyShellCommand("git commit -m x"));
    try std.testing.expect(!isReadOnlyShellCommand("git branch feature"));
    try std.testing.expect(!isReadOnlyShellCommand("npm install"));
    try std.testing.expect(!isReadOnlyShellCommand("echo hi > file.txt"));
    try std.testing.expect(!isReadOnlyShellCommand("cat a; cat b"));
    try std.testing.expect(!isReadOnlyShellCommand("git status && npm test"));
    try std.testing.expect(!isReadOnlyShellCommand("cat $(which git)"));
    try std.testing.expect(!isReadOnlyShellCommand("ls | grep foo"));

    // Verbs with mutating FORMS are excluded outright (review follow-up):
    // a wrongly cached mutation replays stale state as ground truth.
    try std.testing.expect(!isReadOnlyShellCommand("find . -name '*.log' -delete"));
    try std.testing.expect(!isReadOnlyShellCommand("find . -exec rm -rf {} +"));
    try std.testing.expect(!isReadOnlyShellCommand("sort -o out.txt in.txt"));
    try std.testing.expect(!isReadOnlyShellCommand("hostname newname"));
    try std.testing.expect(!isReadOnlyShellCommand("date -s '2020-01-01'"));
    // Read-only verbs with writer flags are rejected by fragment.
    try std.testing.expect(!isReadOnlyShellCommand("git diff --output=patch.diff"));
    try std.testing.expect(!isReadOnlyShellCommand("git show --output=f.txt HEAD"));
}

test "cache hit, miss, and mutation invalidation" {
    const gpa = std.testing.allocator;
    var cache = ResultCache.init(gpa);
    defer cache.deinit();

    const args = ("{\"command\":\"git status\",\"description\":\"check state\"}");

    // Miss on first lookup, store, hit (marked) on the second.
    try std.testing.expectEqual(ResultCache.ShellLookup.miss, cache.lookupShell(args));
    const output: common.Output = .{
        .stdout = try gpa.dupe(u8, "nothing to commit"),
        .stderr = try gpa.dupe(u8, ""),
        .code = 0,
    };
    var owned = output;
    defer owned.deinit(gpa);
    cache.storeShell(args, &owned);

    switch (cache.lookupShell(args)) {
        .hit => |hit| {
            defer {
                var mut = hit;
                mut.deinit(gpa);
            }
            try std.testing.expect(std.mem.startsWith(u8, hit.stdout, "[cached result"));
            try std.testing.expect(std.mem.indexOf(u8, hit.stdout, "nothing to commit") != null);
        },
        .miss, .bypass => return error.TestUnexpectedResult,
    }

    // A different description with the same command still hits: the key is
    // the command, not the whole arguments JSON.
    const other_description = ("{\"description\":\"recheck\",\"command\":\"git status\"}");
    switch (cache.lookupShell(other_description)) {
        .hit => |hit| {
            var mut = hit;
            mut.deinit(gpa);
        },
        .miss, .bypass => return error.TestUnexpectedResult,
    }

    // A mutating command clears the cache and bypasses.
    try std.testing.expectEqual(ResultCache.ShellLookup.bypass, cache.lookupShell(("{\"command\":\"npm install\",\"description\":\"x\"}")));
    try std.testing.expectEqual(ResultCache.ShellLookup.miss, cache.lookupShell(args));
}

test "failures and background requests are never cached" {
    const gpa = std.testing.allocator;
    var cache = ResultCache.init(gpa);
    defer cache.deinit();

    // Failed outputs are not stored — a retry must actually re-run.
    const failing_args = ("{\"command\":\"cat nope.txt\"}");
    try std.testing.expectEqual(ResultCache.ShellLookup.miss, cache.lookupShell(failing_args));
    const failed: common.Output = .{
        .stdout = try gpa.dupe(u8, ""),
        .stderr = try gpa.dupe(u8, "no such file"),
        .code = 1,
    };
    var owned = failed;
    defer owned.deinit(gpa);
    cache.storeShell(failing_args, &owned);
    try std.testing.expectEqual(ResultCache.ShellLookup.miss, cache.lookupShell(failing_args));

    // Background requests bypass the cache entirely.
    const bg_args = ("{\"command\":\"git status\",\"run_in_background\":true}");
    try std.testing.expectEqual(ResultCache.ShellLookup.bypass, cache.lookupShell(bg_args));
    const bg_output: common.Output = .{
        .stdout = try gpa.dupe(u8, "job 7 started"),
        .stderr = try gpa.dupe(u8, ""),
        .code = 0,
    };
    var bg_owned = bg_output;
    defer bg_owned.deinit(gpa);
    cache.storeShell(bg_args, &bg_owned);
    try std.testing.expectEqual(ResultCache.ShellLookup.miss, cache.lookupShell(("{\"command\":\"git status\"}")));

    // Unparseable arguments bypass without caching anything.
    try std.testing.expectEqual(ResultCache.ShellLookup.bypass, cache.lookupShell("not json"));
}

test "entry cap evicts oldest first" {
    const gpa = std.testing.allocator;
    var cache = ResultCache.init(gpa);
    defer cache.deinit();

    var cmd_buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < max_entries + 5) : (i += 1) {
        const cmd = try std.fmt.bufPrint(&cmd_buf, "cat file{d}.txt", .{i});
        var args_buf: [96]u8 = undefined;
        const args = try std.fmt.bufPrint(&args_buf, "{{\"command\":\"{s}\"}}", .{cmd});
        try std.testing.expectEqual(ResultCache.ShellLookup.miss, cache.lookupShell(args));
        const output: common.Output = .{
            .stdout = try gpa.dupe(u8, "x"),
            .stderr = try gpa.dupe(u8, ""),
            .code = 0,
        };
        var owned = output;
        defer owned.deinit(gpa);
        cache.storeShell(args, &owned);
    }

    // The oldest five were evicted; the newest `max_entries` survive.
    try std.testing.expectEqual(max_entries, cache.entries.items.len);
    var args_buf: [96]u8 = undefined;
    const evicted = try std.fmt.bufPrint(&args_buf, "{{\"command\":\"cat file0.txt\"}}", .{});
    try std.testing.expectEqual(ResultCache.ShellLookup.miss, cache.lookupShell(evicted));
    const survivor = try std.fmt.bufPrint(&args_buf, "{{\"command\":\"cat file{d}.txt\"}}", .{max_entries + 4});
    switch (cache.lookupShell(survivor)) {
        .hit => |hit| {
            var mut = hit;
            mut.deinit(gpa);
        },
        .miss, .bypass => return error.TestUnexpectedResult,
    }
}

test "dupeOutput deep-copies display and observation" {
    const gpa = std.testing.allocator;
    const original: common.Output = .{
        .stdout = try gpa.dupe(u8, "out"),
        .stderr = try gpa.dupe(u8, "err"),
        .code = 0,
        .display = .{ .text = try gpa.dupe(u8, "display") },
        .observation = .{ .complete = try gpa.dupe(u8, "obs") },
    };
    var owned = original;
    defer owned.deinit(gpa);

    var dup = try dupeOutput(gpa, &owned);
    defer dup.deinit(gpa);
    try std.testing.expectEqualStrings("out", dup.stdout);
    try std.testing.expectEqualStrings("display", dup.display.text);
    try std.testing.expectEqualStrings("obs", dup.observation.?.complete);
}
