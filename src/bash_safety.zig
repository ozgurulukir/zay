//! Local bash command safety classifier client.

const std = @import("std");

const assert = std.debug.assert;

const response_bytes_max: u32 = 4096;
const redirect_buffer_bytes: u32 = 8192;

pub const Verdict = enum {
    safe,
    unsafe,
    unavailable,
};

pub fn commandFromArguments(gpa: std.mem.Allocator, arguments: []const u8) ![]u8 {
    const JsonArgs = struct {
        command: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch return error.InvalidToolArguments;
    defer parsed.deinit();
    const command = parsed.value.command orelse return error.InvalidToolArguments;
    if (command.len == 0) return error.InvalidToolArguments;
    return try gpa.dupe(u8, command);
}

pub fn classify(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    cwd: []const u8,
    command: []const u8,
) Verdict {
    assert(url.len > 0);
    assert(cwd.len > 0);
    assert(command.len > 0);

    return classifyFallible(gpa, io, url, cwd, command) catch .unavailable;
}

fn classifyFallible(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    cwd: []const u8,
    command: []const u8,
) !Verdict {
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequest(&payload.writer, cwd, command);

    var response_body: std.Io.Writer.Allocating = .init(gpa);
    defer response_body.deinit();
    var redirect_buffer: [redirect_buffer_bytes]u8 = undefined;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const status = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = url },
        .payload = payload.written(),
        .response_writer = &response_body.writer,
        .redirect_buffer = &redirect_buffer,
        .keep_alive = true,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    });
    if (response_body.written().len > response_bytes_max) return error.ResponseTooLarge;
    const status_code: u16 = @intFromEnum(status.status);
    if (status_code < 200) return error.HttpUnexpectedStatus;
    if (status_code >= 300) return error.HttpUnexpectedStatus;
    return parseResponse(gpa, response_body.written());
}

fn writeRequest(writer: *std.Io.Writer, cwd: []const u8, command: []const u8) !void {
    try writer.writeAll("{\"cwd\":");
    try std.json.Stringify.value(cwd, .{}, writer);
    try writer.writeAll(",\"command\":");
    try std.json.Stringify.value(command, .{}, writer);
    try writer.writeAll("}");
}

const ClassifierResponse = struct {
    label: []const u8,
};

fn parseResponse(gpa: std.mem.Allocator, bytes: []const u8) !Verdict {
    if (bytes.len == 0) return error.InvalidClassifierResponse;
    const parsed = std.json.parseFromSlice(ClassifierResponse, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidClassifierResponse;
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.label, "safe")) return .safe;
    if (std.mem.eql(u8, parsed.value.label, "unsafe")) return .unsafe;
    return error.InvalidClassifierResponse;
}

test "bash safety extracts command from tool arguments" {
    const gpa = std.testing.allocator;
    const command = try commandFromArguments(gpa, "{\"command\":\"rm -rf /tmp/x\",\"reason\":\"clean\"}");
    defer gpa.free(command);
    try std.testing.expectEqualStrings("rm -rf /tmp/x", command);
}

test "bash safety parses classifier responses" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(Verdict.safe, try parseResponse(gpa, "{\"label\":\"safe\"}"));
    try std.testing.expectEqual(Verdict.unsafe, try parseResponse(gpa, "{\"label\":\"unsafe\",\"score\":0.99}"));
    try std.testing.expectError(error.InvalidClassifierResponse, parseResponse(gpa, "{\"label\":\"maybe\"}"));
}
