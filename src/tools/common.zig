const std = @import("std");

const assert = std.debug.assert;

pub const DisplayKind = enum(u8) { text, diff };

/// Optional display body a tool can attach to its `Output`. The
/// variant tells the renderer how to draw the body (plain text vs
/// per-line diff). `none` means the renderer falls back to stdout.
/// Variants make illegal combinations unrepresentable: a `.diff` body
/// must be non-empty, and a `none` body has no kind.
pub const Display = union(enum) {
    none,
    text: []u8,
    diff: []u8,
};

pub const Output = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    display: Display = .none,
    observation: ?Observation = null,

    pub fn deinit(self: *Output, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        switch (self.display) {
            inline .text, .diff => |body| gpa.free(body),
            .none => {},
        }
        if (self.observation) |*observation| observation.deinit(gpa);
        self.* = undefined;
    }
};

pub const Observation = union(enum) {
    complete: []u8,
    truncated_tail: TruncatedTail,

    pub const TruncatedTail = struct {
        text: []u8,
        total_lines: u32,
        shown_lines: u32,
        total_bytes: u64,
        shown_bytes: u32,
        full_output_path: []u8,
    };

    pub fn deinit(self: *Observation, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .complete => |text| gpa.free(text),
            .truncated_tail => |tail| {
                gpa.free(tail.text);
                gpa.free(tail.full_output_path);
            },
        }
        self.* = undefined;
    }

    pub fn render(self: Observation, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return switch (self) {
            .complete => |text| gpa.dupe(u8, text),
            .truncated_tail => |tail| std.fmt.allocPrint(
                gpa,
                "{s}\n\n[Showing last {d} of {d} lines ({d} of {d} bytes). Full output: {s}]",
                .{ tail.text, tail.shown_lines, tail.total_lines, tail.shown_bytes, tail.total_bytes, tail.full_output_path },
            ),
        };
    }
};

pub const Error = error{
    OutOfMemory,
} || std.Io.Cancelable || std.Io.UnexpectedError;

/// The single shared implementation of tool-result truncation: a head+tail
/// sandwich. Keeps the start of the output (head — file-read preamble,
/// command banner) and the conclusion (tail — errors, results, status) with
/// an elision marker, so neither compaction nor historical pruning discards
/// the load-bearing part of a command result. Head-only truncation dropped
/// the tail, forcing the model to re-run commands to rediscover their
/// conclusions. The bash spill `Full output:` footer sits at the very end
/// and survives naturally inside the tail. Caller owns the result; always
/// allocates a fresh buffer (never returns an input slice).
pub fn pruneToolText(gpa: std.mem.Allocator, text: []const u8, cap_bytes: u32) ![]u8 {
    if (text.len <= cap_bytes) return gpa.dupe(u8, text);
    const half = cap_bytes / 2;
    // Head = first half of the budget; tail = last half. They are disjoint,
    // leaving a middle gap the elision marker reports. head_kept guards tiny
    // caps (cap < 2) so head and tail never overlap.
    const head_kept = @min(half, text.len);
    const tail_start = text.len - (cap_bytes - half);
    return elideMiddle(gpa, text[0..head_kept], text[tail_start..], text.len);
}

/// Join a head and tail slice with an elision marker reporting the skipped
/// middle. The single source of truth for the elision format, shared by
/// in-memory tool-result truncation (`pruneToolText`) and file mention
/// ingestion (`at_mention`), so both keep the load-bearing conclusion (tail)
/// alongside the start (head). Caller owns the result.
pub fn elideMiddle(gpa: std.mem.Allocator, head: []const u8, tail: []const u8, total_size: usize) ![]u8 {
    const elided = total_size - head.len - tail.len;
    return std.fmt.allocPrint(
        gpa,
        "{s}\n\n[... {d} of {d} bytes elided to save context ...]\n\n{s}",
        .{ head, elided, total_size, tail },
    );
}

/// Strip ANSI/VT escape sequences from captured tool output (SSOT for the
/// bash and pwsh shells). PowerShell and git-bash both colorize their error
/// and table formatting with CSI sequences (`\x1b[31;1m` etc.); the model
/// reads those as noise, so every observation is cleaned before it is shaped.
/// Only CSI sequences (ESC `[` … final byte) are handled, which covers every
/// code seen in practice. A lone ESC is dropped; an unterminated CSI (no final
/// byte before the end) drops the rest of the input rather than panic. The
/// caller owns the result; always returns a fresh buffer (never an input slice),
/// mirroring the `pruneToolText` contract.
pub fn stripAnsi(gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            if (i + 1 < text.len and text[i + 1] == '[') {
                // CSI: consume params (0x30..0x3f) + intermediates (0x20..0x2f)
                // until a final byte (0x40..0x7e). Unterminated → drop the rest.
                var j = i + 2;
                while (j < text.len and !(text[j] >= 0x40 and text[j] <= 0x7e)) j += 1;
                i = if (j < text.len) j + 1 else text.len;
            } else {
                i += 1; // lone ESC: drop.
            }
            continue;
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

test "pruneToolText returns a fresh dupe when text fits the cap" {
    const gpa = std.testing.allocator;
    const text = "hello world";
    const pruned = try pruneToolText(gpa, text, 100);
    defer gpa.free(pruned);
    try std.testing.expectEqualStrings(text, pruned);
    // Must be a fresh allocation, not the input slice.
    try std.testing.expect(pruned.ptr != text.ptr);
}

test "pruneToolText sandwiches head and tail when text exceeds cap" {
    const gpa = std.testing.allocator;
    const text = "HEAD_BODY" ++ ("x" ** 200) ++ "TAIL_BODY";
    const pruned = try pruneToolText(gpa, text, 20);
    defer gpa.free(pruned);
    try std.testing.expect(std.mem.indexOf(u8, pruned, "HEAD_BODY") != null);
    try std.testing.expect(std.mem.indexOf(u8, pruned, "TAIL_BODY") != null);
    try std.testing.expect(std.mem.indexOf(u8, pruned, "elided to save context") != null);
}

test "pruneToolText handles empty text" {
    const gpa = std.testing.allocator;
    const pruned = try pruneToolText(gpa, "", 10);
    defer gpa.free(pruned);
    try std.testing.expectEqualStrings("", pruned);
}

test "pruneToolText with cap of 1 keeps only the last byte" {
    const gpa = std.testing.allocator;
    // 'X'/'Y'/'Z' don't appear in the elision marker, so we can assert
    // head bytes vanish and the tail byte survives.
    const pruned = try pruneToolText(gpa, "XYZ", 1);
    defer gpa.free(pruned);
    // half = 0 → empty head, 1-byte tail (the last char 'Z').
    try std.testing.expect(std.mem.indexOf(u8, pruned, "Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, pruned, "elided to save context") != null);
    try std.testing.expect(std.mem.indexOf(u8, pruned, "X") == null);
    try std.testing.expect(std.mem.indexOf(u8, pruned, "Y") == null);
}

test "elideMiddle reports the elided byte count" {
    const gpa = std.testing.allocator;
    const joined = try elideMiddle(gpa, "AAAA", "ZZZZ", 100);
    defer gpa.free(joined);
    // 100 - 4 - 4 = 92 bytes elided.
    try std.testing.expect(std.mem.indexOf(u8, joined, "92 of 100 bytes elided") != null);
    try std.testing.expect(std.mem.startsWith(u8, joined, "AAAA"));
    try std.testing.expect(std.mem.endsWith(u8, joined, "ZZZZ"));
}

test "stripAnsi removes the exact bug-report blob" {
    const gpa = std.testing.allocator;
    // `\x1b[31;1mGet-ChildItem: \x1b[0m` followed by `\x1b[36;1mLine |\x1b[0m`.
    const input = "\x1b[31;1mGet-ChildItem: \x1b[0m" ++ "\x1b[36;1mLine |\x1b[0m";
    const stripped = try stripAnsi(gpa, input);
    defer gpa.free(stripped);
    try std.testing.expectEqualStrings("Get-ChildItem: " ++ "Line |", stripped);
}

test "stripAnsi passes through plain text unchanged as a fresh alloc" {
    const gpa = std.testing.allocator;
    const text = "plain output\nsecond line\n";
    const pruned = try stripAnsi(gpa, text);
    defer gpa.free(pruned);
    // No `\x1b`, so the text is byte-identical; must be a fresh allocation,
    // not the input slice (mirrors the `pruneToolText` contract).
    try std.testing.expectEqualStrings(text, pruned);
    try std.testing.expect(pruned.ptr != text.ptr);
}

test "stripAnsi handles multi-param CSI and resets" {
    const gpa = std.testing.allocator;
    // `\x1b[31;1m` (multi-param SGR), `\x1b[0m` (reset), `\x1b[36;1m`.
    const input = "\x1b[31;1mred\x1b[0m and \x1b[36;1mcyan\x1b[0m";
    const stripped = try stripAnsi(gpa, input);
    defer gpa.free(stripped);
    try std.testing.expectEqualStrings("red and cyan", stripped);
}

test "stripAnsi tolerates an unterminated CSI without panic" {
    const gpa = std.testing.allocator;
    // Trailing `\x1b[31` has no final byte → drop the rest, no OOB/index panic.
    const input = "ok\x1b[31";
    const stripped = try stripAnsi(gpa, input);
    defer gpa.free(stripped);
    try std.testing.expectEqualStrings("ok", stripped);
}

test "stripAnsi empty input returns empty output without a slice panic" {
    const gpa = std.testing.allocator;
    const stripped = try stripAnsi(gpa, "");
    defer gpa.free(stripped);
    try std.testing.expectEqualStrings("", stripped);
}

pub const ToolDisplay = struct {
    /// Human-facing summary shown while the tool is collapsed.
    label: []u8,
    /// Machine-facing detail shown in place of `label` when expanded.
    expanded_label: ?[]u8 = null,

    pub fn deinit(self: *ToolDisplay, gpa: std.mem.Allocator) void {
        gpa.free(self.label);
        if (self.expanded_label) |label| gpa.free(label);
        self.* = undefined;
    }
};

/// A typed record describing one tool. The Tool registry in `tools.zig`
/// is a slice of these; it is the single source of truth for what tools
/// exist. Display policy (Expand-by-default, render mode) is NOT carried
/// here — that lives TUI-side.
///
/// `userdata` is passed as the last argument to every callback so the
/// same shared `*const fn` signature can route through per-tool state
/// without resorting to a global mutable slot. Builtin tools pass
/// `undefined` (it is never read); plugin tools pass a `*PluginToolKey`.
pub const Tool = struct {
    name: []const u8,
    /// Raw description template. May contain `{{hsep}}` placeholders that
    /// each LanguageModel adapter substitutes with `~` before sending.
    description: []const u8,
    schema: Schema,
    run: *const fn (
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        args: []const u8,
        userdata: *anyopaque,
    ) Error!Output,
    /// Produce the human display metadata shown in the TUI's tool row.
    /// `label` is the collapsed summary; `expanded_label`, when present,
    /// replaces it while the row is expanded.
    display: *const fn (
        gpa: std.mem.Allocator,
        args: []const u8,
        userdata: *anyopaque,
    ) std.mem.Allocator.Error!ToolDisplay,
    /// Optional per-tool context. Plugin tools use this to carry their
    /// `(plugin_name, tool_name, manager)` key; builtin tools leave it
    /// `undefined`. Borrowed; freed via `userdata_free` on registry teardown.
    userdata: *anyopaque = undefined,
    /// Frees the heap allocation behind `userdata`. Null when the tool
    /// has no per-tool state (e.g. all builtins). The allocator matches
    /// the one that originally allocated `userdata`; the registry passes
    /// it through so the lifetime is unambiguous.
    userdata_free: ?*const fn (gpa: std.mem.Allocator, ud: *anyopaque) void = null,
};

pub const Schema = struct {
    properties: []const Property,

    pub const Property = struct {
        name: []const u8,
        kind: Kind,
        description: []const u8,
        required: bool,
        nullable: bool = false,
        /// Enum constraint values. When present, the property is restricted
        /// to one of these values. Serialized as `"enum": [...]` in the
        /// tool definition JSON so the model knows the valid options.
        enum_values: ?[]const []const u8 = null,
        /// Default value stored as a raw JSON string fragment (e.g. `"42"`,
        /// `"true"`, `"\"auto\""`). When present, serialized as
        /// `"default": <value>` in the tool definition JSON.
        default_value: ?[]const u8 = null,
    };

    pub const Kind = enum { string, integer, number, object, array, boolean };

    /// Free all owned slices in the schema's properties.
    pub fn deinit(self: *Schema, gpa: std.mem.Allocator) void {
        for (self.properties) |*prop| {
            gpa.free(prop.name);
            gpa.free(prop.description);
            if (prop.enum_values) |ev| {
                for (ev) |v| gpa.free(v);
                gpa.free(ev);
            }
            if (prop.default_value) |dv| gpa.free(dv);
        }
        if (self.properties.len > 0) gpa.free(self.properties);
        self.* = undefined;
    }
};

pub fn ok(gpa: std.mem.Allocator, stdout: []u8) Error!Output {
    const stderr = try gpa.alloc(u8, 0);
    return .{ .stdout = stdout, .stderr = stderr, .code = 0 };
}

pub fn okWithDisplay(gpa: std.mem.Allocator, stdout: []u8, display: []u8) Error!Output {
    assert(stdout.len > 0);
    assert(display.len > 0);
    const stderr = try gpa.alloc(u8, 0);
    return .{ .stdout = stdout, .stderr = stderr, .code = 0, .display = .{ .text = display } };
}

pub fn fail(gpa: std.mem.Allocator, message: []const u8, code: u8) Error!Output {
    assert(code != 0);
    assert(message.len > 0);
    const stdout = try gpa.alloc(u8, 0);
    errdefer gpa.free(stdout);
    const stderr = try gpa.dupe(u8, message);
    return .{ .stdout = stdout, .stderr = stderr, .code = code };
}

pub fn failFmt(
    gpa: std.mem.Allocator,
    code: u8,
    comptime fmt: []const u8,
    args: anytype,
) Error!Output {
    assert(code != 0);
    const stdout = try gpa.alloc(u8, 0);
    errdefer gpa.free(stdout);
    const stderr = try std.fmt.allocPrint(gpa, fmt, args);
    return .{ .stdout = stdout, .stderr = stderr, .code = code };
}

/// Helper for display implementations. Parses the argument JSON and extracts
/// a single string field; returns the bare `fallback` (owned) when the JSON is
/// partial / invalid / missing the field.
pub fn readFileBytes(gpa: std.mem.Allocator, io: std.Io, absolute: []const u8, bytes_max: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, absolute, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(bytes_max)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

pub fn joinPath(gpa: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);
    return std.fs.path.join(gpa, &.{ cwd, path });
}

pub fn mapAllocError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.Unexpected,
    };
}

pub fn extractStringField(
    gpa: std.mem.Allocator,
    args: []const u8,
    field: []const u8,
    fallback: []const u8,
) std.mem.Allocator.Error![]u8 {
    if (args.len == 0) return gpa.dupe(u8, fallback);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, args, .{}) catch {
        return gpa.dupe(u8, fallback);
    };
    defer parsed.deinit();
    if (parsed.value != .object) return gpa.dupe(u8, fallback);
    const value = parsed.value.object.get(field) orelse return gpa.dupe(u8, fallback);
    if (value != .string) return gpa.dupe(u8, fallback);
    return gpa.dupe(u8, value.string);
}
