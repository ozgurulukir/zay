//! Scripted local HTTP server shared by transport and agent tests.

const std = @import("std");

pub const Response = struct {
    status: std.http.Status,
    extra_headers: []const std.http.Header = &.{},
    body: []const u8 = "",
    body_delay_ms: u32 = 0,
    /// Close after consuming the request without sending a response head.
    drop_after_request: bool = false,
};

pub const MockHttpServer = struct {
    /// Caps optional request-body capture without unbounded server storage.
    const captured_request_max: usize = 8;

    io: std.Io,
    gpa: ?std.mem.Allocator = null,
    server: std.Io.net.Server,
    responses: []const Response,
    connection_count: std.atomic.Value(u32) = .init(0),
    captured: [captured_request_max]?[]u8 = .{null} ** captured_request_max,

    pub fn init(io: std.Io, responses: []const Response) !MockHttpServer {
        return initWithAllocator(null, io, responses);
    }

    pub fn initCapturing(gpa: std.mem.Allocator, io: std.Io, responses: []const Response) !MockHttpServer {
        return initWithAllocator(gpa, io, responses);
    }

    fn initWithAllocator(gpa: ?std.mem.Allocator, io: std.Io, responses: []const Response) !MockHttpServer {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = try addr.listen(io, .{ .reuse_address = true });
        return .{ .gpa = gpa, .io = io, .server = server, .responses = responses };
    }

    pub fn deinit(self: *MockHttpServer) void {
        if (self.gpa) |gpa| {
            for (self.captured) |maybe_body| {
                if (maybe_body) |body| gpa.free(body);
            }
        }
        self.server.deinit(self.io);
    }

    pub fn port(self: *const MockHttpServer) u16 {
        return self.server.socket.address.ip4.port;
    }

    pub fn serve(self: *MockHttpServer) void {
        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var response_buf: [8192]u8 = undefined;
        for (self.responses) |response| {
            var stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            const connection_index = self.connection_count.fetchAdd(1, .monotonic);
            var reader = stream.reader(self.io, &read_buf);
            var writer = stream.writer(self.io, &write_buf);
            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = http_server.receiveHead() catch return;
            self.captureRequestBody(connection_index, &request);
            if (response.drop_after_request) continue;
            if (response.body_delay_ms > 0) {
                var body_writer = request.respondStreaming(&response_buf, .{
                    .content_length = response.body.len,
                    .respond_options = .{
                        .status = response.status,
                        .keep_alive = false,
                        .extra_headers = response.extra_headers,
                    },
                }) catch return;
                body_writer.flush() catch return;
                self.io.sleep(.fromMilliseconds(response.body_delay_ms), .awake) catch return;
                body_writer.writer.writeAll(response.body) catch return;
                body_writer.end() catch return;
                continue;
            }
            request.respond(response.body, .{
                .status = response.status,
                .keep_alive = false,
                .extra_headers = response.extra_headers,
            }) catch return;
        }
    }

    fn captureRequestBody(self: *MockHttpServer, connection_index: u32, request: *std.http.Server.Request) void {
        var body_buf: [16384]u8 = undefined;
        var body_reader = request.readerExpectNone(&body_buf);
        if (self.gpa) |gpa| {
            if (connection_index < self.captured.len) {
                if (body_reader.allocRemaining(gpa, .limited(1024 * 1024))) |body| {
                    self.captured[connection_index] = body;
                } else |_| {}
                return;
            }
        }

        // A close with unread request bytes becomes a reset on Windows and can
        // discard the response head before the client observes it.
        _ = body_reader.discardRemaining() catch {};
    }
};

/// Builds the standard local OpenAI-compatible client used by retry tests.
pub fn retryTestClient(comptime Client: type, gpa: std.mem.Allocator, io: std.Io, port: u16) !Client {
    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1", .{port});
    errdefer gpa.free(base_url);

    var client: Client = undefined;
    try client.init(gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        // Keep retry tests fast without sleeping between attempts.
        .retry_base_delay_ms = 0,
    });
    // Client.init deep-copies its config, so it does not retain this temporary URL.
    gpa.free(base_url);
    return client;
}
