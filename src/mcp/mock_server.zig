//! Deterministic stdio MCP server used by the client and manager tests.

const std = @import("std");

const protocol_version = "2024-11-05";
const tool_list = "{\"tools\":[{\"name\":\"greet\",\"description\":\"Say hello\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Name to greet\"}},\"required\":[\"name\"]}}]}";

const Mode = enum {
    default,
    list_changed,
    interleaved,
    malformed_tools,
    fail,
    slow,
    hang,
    partial,
};

pub fn parseMode(mode_name: ?[]const u8) !Mode {
    const name = mode_name orelse "default";
    return std.meta.stringToEnum(Mode, name) orelse error.InvalidMode;
}

pub fn processRequests(
    gpa: std.mem.Allocator,
    io: std.Io,
    mode: Mode,
    reader: *std.Io.Reader,
    writer: anytype,
) !void {
    var saw_tools_list = false;
    while (try readLine(gpa, reader)) |line| {
        defer gpa.free(line);
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const object = parsed.value.object;
        const method_value = object.get("method") orelse continue;
        if (method_value != .string) continue;
        const method = method_value.string;
        const id_value = object.get("id") orelse continue;
        if (id_value != .integer) return error.UnsupportedRequestId;

        if (mode == .hang) {
            while (true) io.sleep(.fromSeconds(1), .awake) catch {};
        }
        if (mode == .slow) io.sleep(.fromMilliseconds(500), .awake) catch {};
        if (mode == .partial) {
            // Exercise clients that can observe bytes on stdout without a
            // complete newline-delimited JSON-RPC response.
            try writeRaw(writer, "{\"jsonrpc\":\"2.0\",\"id\":");
            while (true) io.sleep(.fromSeconds(1), .awake) catch {};
        }

        if (std.mem.eql(u8, method, "initialize")) {
            const list_changed = mode == .list_changed or mode == .interleaved;
            const server_name = if (mode == .list_changed) "changeful" else "mock";
            const server_version = if (mode == .list_changed) "2.0" else "1.0";
            var response_writer: std.Io.Writer.Allocating = .init(gpa);
            defer response_writer.deinit();
            try response_writer.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
            try std.json.Stringify.value(id_value.integer, .{}, &response_writer.writer);
            try response_writer.writer.writeAll(" ,\"result\":{\"protocolVersion\":");
            try std.json.Stringify.value(protocol_version, .{}, &response_writer.writer);
            try response_writer.writer.writeAll(" ,\"serverInfo\":{\"name\":");
            try std.json.Stringify.value(server_name, .{}, &response_writer.writer);
            try response_writer.writer.writeAll(" ,\"version\":");
            try std.json.Stringify.value(server_version, .{}, &response_writer.writer);
            try response_writer.writer.writeAll("},\"capabilities\":{\"tools\":{");
            if (list_changed) try response_writer.writer.writeAll("\"listChanged\":true");
            try response_writer.writer.writeAll("}}}}");
            const response = try response_writer.toOwnedSlice();
            defer gpa.free(response);
            try writeLine(writer, response);
        } else if (std.mem.eql(u8, method, "tools/list")) {
            if (mode == .interleaved and !saw_tools_list) {
                try writeLine(writer, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}");
            }
            saw_tools_list = true;
            if (mode == .malformed_tools) {
                try writeLine(writer, "this is not json");
            } else {
                const response = try std.fmt.allocPrint(
                    gpa,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
                    .{ id_value.integer, tool_list },
                );
                defer gpa.free(response);
                try writeLine(writer, response);
            }
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const response = try std.fmt.allocPrint(
                gpa,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"Hello, World!\"}}]}}}}",
                .{id_value.integer},
            );
            defer gpa.free(response);
            try writeLine(writer, response);
        } else {
            const response = try std.fmt.allocPrint(
                gpa,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{}}}}",
                .{id_value.integer},
            );
            defer gpa.free(response);
            try writeLine(writer, response);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const mode = try parseMode(args.next());
    if (mode == .fail) std.process.exit(1);

    var input_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &input_buf);
    var output_buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buf);

    try processRequests(gpa, init.io, mode, &reader.interface, &writer);
}

fn readLine(gpa: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var line: std.Io.Writer.Allocating = .init(gpa);
    errdefer line.deinit();
    _ = reader.streamDelimiterEnding(&line.writer, '\n') catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => return error.OutOfMemory,
    };
    if (line.written().len == 0) return null;
    _ = reader.take(1) catch {};
    return try line.toOwnedSlice();
}

fn writeRaw(writer: anytype, bytes: []const u8) !void {
    const P = @TypeOf(writer);
    const T = if (@typeInfo(P) == .pointer) @typeInfo(P).pointer.child else P;
    if (@hasField(T, "interface")) {
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    } else if (@hasField(T, "writer")) {
        try writer.writer.writeAll(bytes);
    } else {
        try writer.writeAll(bytes);
    }
}

fn writeLine(writer: anytype, line: []const u8) !void {
    try writeRaw(writer, line);
    try writeRaw(writer, "\n");
}

test "parseMode_returnsExpectedMode_whenGivenValidString" {
    // Arrange & Act & Assert
    try std.testing.expectEqual(Mode.default, try parseMode(null));
    try std.testing.expectEqual(Mode.default, try parseMode("default"));
    try std.testing.expectEqual(Mode.list_changed, try parseMode("list_changed"));
    try std.testing.expectEqual(Mode.interleaved, try parseMode("interleaved"));
    try std.testing.expectEqual(Mode.malformed_tools, try parseMode("malformed_tools"));
    try std.testing.expectEqual(Mode.fail, try parseMode("fail"));
    try std.testing.expectEqual(Mode.slow, try parseMode("slow"));
    try std.testing.expectEqual(Mode.hang, try parseMode("hang"));
    try std.testing.expectEqual(Mode.partial, try parseMode("partial"));
}

test "parseMode_returnsInvalidMode_whenGivenUnknownString" {
    // Arrange & Act & Assert
    try std.testing.expectError(error.InvalidMode, parseMode("invalid_mode_name"));
}

test "processRequests_handlesInitializeAndTools_whenInDefaultMode" {
    // Arrange
    const gpa = std.testing.allocator;
    const input =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"greet\"}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ping\"}\n";
    var reader: std.Io.Reader = .fixed(input);
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();

    // Act
    try processRequests(gpa, std.testing.io, .default, &reader, &writer);

    // Assert
    const output = writer.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "{\"jsonrpc\":\"2.0\",\"id\":1 ,\"result\":{\"protocolVersion\":\"2024-11-05\" ,\"serverInfo\":{\"name\":\"mock\" ,\"version\":\"1.0\"},\"capabilities\":{\"tools\":{}}}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"greet\",\"description\":\"Say hello\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Name to greet\"}},\"required\":[\"name\"]}}]}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Hello, World!\"}]}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{}}") != null);
}

test "processRequests_includesListChangedCapability_whenInListChangedMode" {
    // Arrange
    const gpa = std.testing.allocator;
    const input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n";
    var reader: std.Io.Reader = .fixed(input);
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();

    // Act
    try processRequests(gpa, std.testing.io, .list_changed, &reader, &writer);

    // Assert
    const output = writer.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"serverInfo\":{\"name\":\"changeful\" ,\"version\":\"2.0\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"capabilities\":{\"tools\":{\"listChanged\":true}}") != null);
}

test "processRequests_emitsNotificationBeforeToolsList_whenInInterleavedMode" {
    // Arrange
    const gpa = std.testing.allocator;
    const input = "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/list\"}\n";
    var reader: std.Io.Reader = .fixed(input);
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();

    // Act
    try processRequests(gpa, std.testing.io, .interleaved, &reader, &writer);

    // Assert
    const output = writer.written();
    const notification_pos = std.mem.indexOf(u8, output, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}");
    const response_pos = std.mem.indexOf(u8, output, "{\"jsonrpc\":\"2.0\",\"id\":10,\"result\":{");
    try std.testing.expect(notification_pos != null);
    try std.testing.expect(response_pos != null);
    try std.testing.expect(notification_pos.? < response_pos.?);
}

test "processRequests_emitsMalformedJson_whenInMalformedToolsMode" {
    // Arrange
    const gpa = std.testing.allocator;
    const input = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/list\"}\n";
    var reader: std.Io.Reader = .fixed(input);
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();

    // Act
    try processRequests(gpa, std.testing.io, .malformed_tools, &reader, &writer);

    // Assert
    try std.testing.expectEqualStrings("this is not json\n", writer.written());
}

test "processRequests_returnsError_whenRequestIdIsNotInteger" {
    // Arrange
    const gpa = std.testing.allocator;
    const input = "{\"jsonrpc\":\"2.0\",\"id\":\"not_an_int\",\"method\":\"initialize\"}\n";
    var reader: std.Io.Reader = .fixed(input);
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();

    // Act & Assert
    try std.testing.expectError(error.UnsupportedRequestId, processRequests(gpa, std.testing.io, .default, &reader, &writer));
}

test "processRequests_skipsInvalidJsonLines_andContinuesProcessing" {
    // Arrange
    const gpa = std.testing.allocator;
    const input =
        "invalid json line\n" ++
        "{\"jsonrpc\":\"2.0\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"ping\"}\n";
    var reader: std.Io.Reader = .fixed(input);
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();

    // Act
    try processRequests(gpa, std.testing.io, .default, &reader, &writer);

    // Assert
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}\n", writer.written());
}
