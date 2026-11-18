//! Deterministic stdio MCP server used by the client and manager tests.

const std = @import("std");

const protocol_version = "2024-11-05";
const greet_tools_array = "[{\"name\":\"greet\",\"description\":\"Say hello\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Name to greet\"}},\"required\":[\"name\"]}}]";
const tool_list = "{\"tools\":" ++ greet_tools_array ++ "}";

/// Second page of the `paginated_tools` discovery fixture (#450): one more
/// tool, no further cursor — a client that follows `nextCursor` must
/// concatenate BOTH pages.
const paginated_tool_list_2 = "{\"tools\":[{\"name\":\"farewell\",\"description\":\"Say goodbye\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"required\":[]}}]}";

/// The cursor page 1 of the paginated fixture advertises; page 2 is served
/// only to a client that echoes it back in `params.cursor`.
const paginated_cursor = "page-2";

/// The id the `server_request` fixture uses for its server-initiated
/// requests, and the JSON-RPC 2.0 reserved "method not found" code the
/// client must answer with (spec-mandated value; kept local so this fixture
/// stays dependency-free).
const server_request_id: i64 = 900;
const server_request_method_not_found: i64 = -32601;

/// Milliseconds between the chunks of a `drip` response: short enough that
/// the test stays fast, long enough that a client's poll loop sees the gap.
const drip_chunk_gap_ms: i64 = 15;

/// Comptime-collapse a multiline JSON literal into the single line the stdio
/// transport requires — JSON-RPC responses are newline-delimited. Raw
/// newlines can only be insignificant whitespace in valid JSON (control
/// characters inside JSON strings are illegal), so dropping them is safe for
/// this file's fixtures, which never split a token across lines.
fn singleLineJson(comptime json: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(2 * json.len + 1000);
        var line: []const u8 = &.{};
        for (json) |byte| {
            if (byte == '\n') continue;
            line = line ++ [_]u8{byte};
        }
        return line;
    }
}

/// A discovery response whose `inputSchema` exercises every JSON Schema
/// construct the local projection cannot model: `$defs`/`$ref`, nested
/// object `properties`/`required`, array `items`/`prefixItems`,
/// `allOf`/`anyOf`/`oneOf`/`not`, `pattern`/`format`, numeric and length
/// bounds, `const`, and a mixed-type `enum`. Served by the `rich_schema`
/// mode so the raw-preservation pipeline can be tested end-to-end.
const rich_tool_list = singleLineJson(
    \\{"tools":[{"name":"query","description":"Query with a rich schema","inputSchema":{
    \\  "type":"object",
    \\  "$defs":{"Filter":{"type":"object","properties":{"field":{"type":"string"},"op":{"type":"string","enum":["eq","ne","gt"]}},"required":["field","op"]}},
    \\  "properties":{
    \\    "filter":{"$ref":"#/$defs/Filter","description":"Reusable filter"},
    \\    "nested":{"type":"object","properties":{"inner":{"type":"object","properties":{"depth":{"type":"integer","minimum":0,"maximum":9}},"required":["depth"]}},"required":["inner"]},
    \\    "tags":{"type":"array","items":{"type":"string","minLength":1},"maxItems":10},
    \\    "tuple":{"type":"array","prefixItems":[{"type":"string"},{"type":"integer"}]},
    \\    "composite":{"allOf":[{"type":"object","properties":{"a":{"type":"string"}}},{"type":"object","properties":{"b":{"type":"number"}}}]},
    \\    "variant":{"oneOf":[{"type":"string","pattern":"^[a-z]+$"},{"type":"object","properties":{"kind":{"const":"custom"}},"required":["kind"]}]},
    \\    "loose":{"anyOf":[{"type":"string","format":"date-time"},{"type":"integer"}],"description":"Loose variant"},
    \\    "negated":{"not":{"type":"null"}},
    \\    "mode":{"enum":["fast","slow",3,null]},
    \\    "email":{"type":"string","format":"email","pattern":"^.+@.+$","minLength":3},
    \\    "ratio":{"type":"number","minimum":0,"maximum":1,"exclusiveMaximum":true}
    \\  },
    \\  "required":["filter","tags"],
    \\  "additionalProperties":false
    \\}}]}
);

const Mode = enum {
    default,
    list_changed,
    interleaved,
    malformed_tools,
    fail,
    slow,
    hang,
    partial,
    rich_schema,
    drip,
    server_request,
    late_response,
    paginated_tools,
    paginated_tools_broken,
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
        if (mode == .server_request) {
            // Emulate a server-initiated request (method + id) ahead of the
            // response (#450): a conforming client replies with a JSON-RPC
            // "method not found" error and keeps waiting for the real
            // response. A client that misclassifies the request as a
            // response never answers, so the mock fails and the handshake
            // with it.
            try writeLine(writer, "{\"jsonrpc\":\"2.0\",\"id\":900,\"method\":\"sampling/createMessage\",\"params\":{}}");
            const reply = (try readLine(gpa, reader)) orelse return error.MissingErrorReply;
            defer gpa.free(reply);
            const reply_parsed = std.json.parseFromSlice(std.json.Value, gpa, reply, .{}) catch return error.InvalidErrorReply;
            defer reply_parsed.deinit();
            if (reply_parsed.value != .object) return error.InvalidErrorReply;
            const reply_obj = reply_parsed.value.object;
            const reply_id = reply_obj.get("id") orelse return error.InvalidErrorReply;
            if (reply_id != .integer or reply_id.integer != server_request_id) return error.InvalidErrorReply;
            const reply_error = reply_obj.get("error") orelse return error.InvalidErrorReply;
            if (reply_error != .object) return error.InvalidErrorReply;
            const reply_code = reply_error.object.get("code") orelse return error.InvalidErrorReply;
            if (reply_code != .integer or reply_code.integer != server_request_method_not_found) return error.InvalidErrorReply;
        }
        if (mode == .late_response) {
            // A decoy response for the PREVIOUS request id first (#450): a
            // client matching by order misattributes it; matching by id
            // skips it and waits for the real response.
            const decoy = try std.fmt.allocPrint(
                gpa,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{}}}}",
                .{id_value.integer - 1},
            );
            defer gpa.free(decoy);
            try writeLine(writer, decoy);
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
            try writeResponseLine(io, mode, writer, response);
        } else if (std.mem.eql(u8, method, "tools/list")) {
            if (mode == .interleaved and !saw_tools_list) {
                try writeLine(writer, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}");
            }
            const first_tools_list = !saw_tools_list;
            saw_tools_list = true;
            if (mode == .malformed_tools) {
                try writeLine(writer, "this is not json");
            } else if (mode == .paginated_tools or mode == .paginated_tools_broken) {
                try writePaginatedToolsPage(gpa, mode, &object, first_tools_list, id_value.integer, writer);
            } else {
                const list = if (mode == .rich_schema) rich_tool_list else tool_list;
                const response = try std.fmt.allocPrint(
                    gpa,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
                    .{ id_value.integer, list },
                );
                defer gpa.free(response);
                try writeResponseLine(io, mode, writer, response);
            }
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const response = try std.fmt.allocPrint(
                gpa,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"Hello, World!\"}}]}}}}",
                .{id_value.integer},
            );
            defer gpa.free(response);
            try writeResponseLine(io, mode, writer, response);
        } else {
            const response = try std.fmt.allocPrint(
                gpa,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{}}}}",
                .{id_value.integer},
            );
            defer gpa.free(response);
            try writeResponseLine(io, mode, writer, response);
        }
    }
}

/// Serve one `tools/list` page for the paginated fixtures (#450): page 1 is
/// the greet list plus `nextCursor: page-2`; page 2 is served only to a
/// client that echoes that cursor back in `params.cursor`, and is garbage
/// in the `_broken` variant so the fetch fails mid-pagination.
fn writePaginatedToolsPage(
    gpa: std.mem.Allocator,
    mode: Mode,
    object: *const std.json.ObjectMap,
    first_page: bool,
    request_id: i64,
    writer: anytype,
) !void {
    if (first_page) {
        // `nextCursor` lives INSIDE the result object per the MCP tools/list
        // pagination contract.
        const response = try std.fmt.allocPrint(
            gpa,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":{s},\"nextCursor\":\"{s}\"}}}}",
            .{ request_id, greet_tools_array, paginated_cursor },
        );
        defer gpa.free(response);
        return writeLine(writer, response);
    }
    // Continuation page: require the client to send back the cursor page 1
    // advertised — a null-params re-request can never reach this branch.
    const cursor_ok = blk: {
        const params = object.get("params") orelse break :blk false;
        if (params != .object) break :blk false;
        const cursor = params.object.get("cursor") orelse break :blk false;
        break :blk cursor == .string and std.mem.eql(u8, cursor.string, paginated_cursor);
    };
    if (!cursor_ok) return error.InvalidCursor;
    if (mode == .paginated_tools_broken) {
        return writeLine(writer, "this is not json");
    }
    const response = try std.fmt.allocPrint(
        gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
        .{ request_id, paginated_tool_list_2 },
    );
    defer gpa.free(response);
    return writeLine(writer, response);
}

/// Write one newline-delimited response line. In `drip` mode the line is
/// split into two chunks with sleeps between (#450): a client must keep
/// making progress on a flowing partial line without tripping its deadline,
/// which is exactly the per-chunk budget re-check the bounded line reader
/// performs.
fn writeResponseLine(io: std.Io, mode: Mode, writer: anytype, line: []const u8) !void {
    if (mode != .drip) return writeLine(writer, line);
    const half = line.len / 2;
    try writeRaw(writer, line[0..half]);
    io.sleep(.fromMilliseconds(drip_chunk_gap_ms), .awake) catch {};
    try writeRaw(writer, line[half..]);
    io.sleep(.fromMilliseconds(drip_chunk_gap_ms), .awake) catch {};
    try writeRaw(writer, "\n");
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
    try std.testing.expectEqual(Mode.rich_schema, try parseMode("rich_schema"));
    try std.testing.expectEqual(Mode.drip, try parseMode("drip"));
    try std.testing.expectEqual(Mode.server_request, try parseMode("server_request"));
    try std.testing.expectEqual(Mode.late_response, try parseMode("late_response"));
    try std.testing.expectEqual(Mode.paginated_tools, try parseMode("paginated_tools"));
    try std.testing.expectEqual(Mode.paginated_tools_broken, try parseMode("paginated_tools_broken"));
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
    try std.testing.expectEqual(Mode.rich_schema, std.meta.stringToEnum(Mode, "rich_schema"));
    try std.testing.expectEqual(Mode.drip, std.meta.stringToEnum(Mode, "drip"));
    try std.testing.expectEqual(Mode.server_request, std.meta.stringToEnum(Mode, "server_request"));
    try std.testing.expectEqual(Mode.late_response, std.meta.stringToEnum(Mode, "late_response"));
    try std.testing.expectEqual(Mode.paginated_tools, std.meta.stringToEnum(Mode, "paginated_tools"));
    try std.testing.expectEqual(Mode.paginated_tools_broken, std.meta.stringToEnum(Mode, "paginated_tools_broken"));

    try std.testing.expectEqual(@as(?Mode, null), std.meta.stringToEnum(Mode, "nonexistent"));
    try std.testing.expectEqual(@as(?Mode, null), std.meta.stringToEnum(Mode, "DEFAULT"));
}

test "richToolList_isValidJsonWithEveryUnsupportedConstruct" {
    // Arrange & Act
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, rich_tool_list, .{});
    defer parsed.deinit();

    // Assert — the fixture must stay parseable and keep the constructs the
    // raw-preservation tests assert on.
    const tools_val = parsed.value.object.get("tools").?;
    const input_schema = tools_val.array.items[0].object.get("inputSchema").?;
    const schema_obj = input_schema.object;
    try std.testing.expect(schema_obj.get("$defs") != null);
    const properties = schema_obj.get("properties").?.object;
    try std.testing.expect(properties.get("filter").?.object.get("$ref") != null);
    try std.testing.expect(properties.get("tuple").?.object.get("prefixItems") != null);
    try std.testing.expect(properties.get("composite").?.object.get("allOf") != null);
    try std.testing.expect(properties.get("variant").?.object.get("oneOf") != null);
    try std.testing.expect(properties.get("loose").?.object.get("anyOf") != null);
    try std.testing.expect(properties.get("negated").?.object.get("not") != null);
    // The format keyword lives inside the loose union's first branch.
    const loose_branches = properties.get("loose").?.object.get("anyOf").?.array.items;
    try std.testing.expectEqualStrings("date-time", loose_branches[0].object.get("format").?.string);
    try std.testing.expectEqual(false, schema_obj.get("additionalProperties").?.bool);
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
    var reader = std.Io.Reader.fixed("first line\nsecond line\n");

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
    try std.testing.expectEqualStrings("hello json-rpc\n", written);
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

test "paginatedToolList2_isValidJsonWithFarewellTool" {
    // Arrange & Act — the second page of the paginated discovery fixture.
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, paginated_tool_list_2, .{});
    defer parsed.deinit();

    // Assert
    try std.testing.expect(parsed.value == .object);
    const tools_val = parsed.value.object.get("tools").?;
    try std.testing.expectEqual(@as(usize, 1), tools_val.array.items.len);
    const farewell_tool = tools_val.array.items[0].object;
    try std.testing.expectEqualStrings("farewell", farewell_tool.get("name").?.string);
    try std.testing.expectEqualStrings("Say goodbye", farewell_tool.get("description").?.string);
}
