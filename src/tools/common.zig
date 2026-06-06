const std = @import("std");

const assert = std.debug.assert;

pub const Output = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    display: ?[]u8 = null,
    observation: ?Observation = null,

    pub fn deinit(self: *Output, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        if (self.display) |display| gpa.free(display);
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

/// A typed record describing one tool. The Tool registry in `tools.zig`
/// is a slice of these; it is the single source of truth for what tools
/// exist. Display policy (Expand-by-default, render mode) is NOT carried
/// here — that lives TUI-side.
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
    ) Error!Output,
    /// Produce the **Display label** shown in the TUI's `$ <label>` line.
    /// Parses the tool's argument JSON to pick a meaningful summary; falls
    /// back to the bare tool name on partial / invalid JSON.
    displayLabel: *const fn (
        gpa: std.mem.Allocator,
        args: []const u8,
    ) std.mem.Allocator.Error![]u8,
};

pub const Schema = struct {
    properties: []const Property,

    pub const Property = struct {
        name: []const u8,
        kind: Kind,
        description: []const u8,
        required: bool,
    };

    pub const Kind = enum { string, integer, object };
};

pub fn ok(gpa: std.mem.Allocator, stdout: []u8) Error!Output {
    const stderr = try gpa.alloc(u8, 0);
    return .{ .stdout = stdout, .stderr = stderr, .code = 0, .display = null };
}

pub fn okWithDisplay(gpa: std.mem.Allocator, stdout: []u8, display: []u8) Error!Output {
    assert(stdout.len > 0);
    assert(display.len > 0);
    const stderr = try gpa.alloc(u8, 0);
    return .{ .stdout = stdout, .stderr = stderr, .code = 0, .display = display };
}

pub fn fail(gpa: std.mem.Allocator, message: []const u8, code: u8) Error!Output {
    assert(code != 0);
    assert(message.len > 0);
    const stdout = try gpa.alloc(u8, 0);
    errdefer gpa.free(stdout);
    const stderr = try gpa.dupe(u8, message);
    return .{ .stdout = stdout, .stderr = stderr, .code = code, .display = null };
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
    return .{ .stdout = stdout, .stderr = stderr, .code = code, .display = null };
}

/// Helper for Display label implementations. Parses the argument JSON and
/// extracts a single string field; returns the bare `fallback` (owned) when
/// the JSON is partial / invalid / missing the field. This is the function
/// every tool's `displayLabel` ends up calling for the common case.
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
