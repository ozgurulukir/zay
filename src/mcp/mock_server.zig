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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const mode_name = args.next() orelse "default";
    const mode = std.meta.stringToEnum(Mode, mode_name) orelse return error.InvalidMode;
    if (mode == .fail) std.process.exit(1);

    var input_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &input_buf);
    var output_buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buf);

    var saw_tools_list = false;
    while (try readLine(gpa, &reader.interface)) |line| {
        defer gpa.free(line);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const object = parsed.value.object;
        const method_value = object.get("method") orelse continue;
        if (method_value != .string) continue;
        const method = method_value.string;
        const id_value = object.get("id") orelse continue;
        if (id_value != .integer) return error.UnsupportedRequestId;

        if (mode == .hang) {
            while (true) init.io.sleep(.fromSeconds(1), .awake) catch {};
        }
        if (mode == .slow) init.io.sleep(.fromMilliseconds(500), .awake) catch {};
        if (mode == .partial) {
            // Exercise clients that can observe bytes on stdout without a
            // complete newline-delimited JSON-RPC response.
            try writer.interface.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
            try writer.interface.flush();
            while (true) init.io.sleep(.fromSeconds(1), .awake) catch {};
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
            try writeLine(&writer, response);
        } else if (std.mem.eql(u8, method, "tools/list")) {
            if (mode == .interleaved and !saw_tools_list) {
                try writeLine(&writer, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}");
            }
            saw_tools_list = true;
            if (mode == .malformed_tools) {
                try writeLine(&writer, "this is not json");
            } else {
                const response = try std.fmt.allocPrint(
                    gpa,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
                    .{ id_value.integer, tool_list },
                );
                defer gpa.free(response);
                try writeLine(&writer, response);
            }
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const response = try std.fmt.allocPrint(
                gpa,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"Hello, World!\"}}]}}}}",
                .{id_value.integer},
            );
            defer gpa.free(response);
            try writeLine(&writer, response);
        } else {
            const response = try std.fmt.allocPrint(
                gpa,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{}}}}",
                .{id_value.integer},
            );
            defer gpa.free(response);
            try writeLine(&writer, response);
        }
    }
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

fn writeLine(writer: anytype, line: []const u8) !void {
    try writer.interface.writeAll(line);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}


test "modeEnum_parsesValidModesAndRejectsInvalid" {
    // Arrange & Act & Assert
    try std.testing.expectEqual(Mode.default, std.meta.stringToEnum(Mode, "default"));
    try std.testing.expectEqual(Mode.list_changed, std.meta.stringToEnum(Mode, "list_changed"));
    try std.testing.expectEqual(Mode.interleaved, std.meta.stringToEnum(Mode, "interleaved"));
    try std.testing.expectEqual(Mode.malformed_tools, std.meta.stringToEnum(Mode, "malformed_tools"));
    try std.testing.expectEqual(Mode.fail, std.meta.stringToEnum(Mode, "fail"));
    try std.testing.expectEqual(Mode.slow, std.meta.stringToEnum(Mode, "slow"));
    try std.testing.expectEqual(Mode.hang, std.meta.stringToEnum(Mode, "hang"));
    try std.testing.expectEqual(Mode.partial, std.meta.stringToEnum(Mode, "partial"));

    try std.testing.expectEqual(@as(?Mode, null), std.meta.stringToEnum(Mode, "nonexistent"));
    try std.testing.expectEqual(@as(?Mode, null), std.meta.stringToEnum(Mode, "DEFAULT"));
}

test "readLine_returnsNull_whenStreamIsEmpty" {
    // Arrange
    const gpa = std.testing.allocator;
    var reader = std.Io.Reader.fixed("");

    // Act
    const result = try readLine(gpa, &reader);

    // Assert
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "readLine_readsSingleLine_withoutTrailingNewline" {
    // Arrange
    const gpa = std.testing.allocator;
    var reader = std.Io.Reader.fixed("first line
second line
");

    // Act
    const line1 = try readLine(gpa, &reader);
    defer if (line1) |l| gpa.free(l);

    const line2 = try readLine(gpa, &reader);
    defer if (line2) |l| gpa.free(l);

    const line3 = try readLine(gpa, &reader);

    // Assert
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("first line", line1.?);

    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("second line", line2.?);

    try std.testing.expectEqual(@as(?[]u8, null), line3);
}

test "writeLine_appendsNewlineAndFlushes_whenCalled" {
    // Arrange
    const gpa = std.testing.allocator;
    var allocating_writer: std.Io.Writer.Allocating = .init(gpa);
    defer allocating_writer.deinit();

    // Act
    try writeLine(&allocating_writer, "hello json-rpc");
    const written = try allocating_writer.toOwnedSlice();
    defer gpa.free(written);

    // Assert
    try std.testing.expectEqualStrings("hello json-rpc
", written);
}

test "toolList_containsValidJsonAndGreetTool" {
    // Arrange
    const gpa = std.testing.allocator;

    // Act
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, tool_list, .{});
    defer parsed.deinit();

    // Assert
    try std.testing.expectEqualStrings("2024-11-05", protocol_version);
    try std.testing.expect(parsed.value == .object);
    const tools_val = parsed.value.object.get("tools");
    try std.testing.expect(tools_val != null);
    try std.testing.expect(tools_val.? == .array);
    try std.testing.expectEqual(@as(usize, 1), tools_val.?.array.items.len);

    const greet_tool = tools_val.?.array.items[0].object;
    try std.testing.expectEqualStrings("greet", greet_tool.get("name").?.string);
    try std.testing.expectEqualStrings("Say hello", greet_tool.get("description").?.string);
}
