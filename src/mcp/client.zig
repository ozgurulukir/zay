//! Model Context Protocol (MCP) Client.
//! Implements protocol state machine, tool discovery, execution, and health monitoring.

const std = @import("std");
const log = std.log.scoped(.mcp);
const config_mod = @import("../config/config.zig");
const os = @import("../os.zig");
const tools_common = @import("../tools/common.zig");
const discovery_mod = @import("discovery.zig");
const wire = @import("wire.zig");
const session_ops = @import("session_ops.zig");
const lifecycle = @import("lifecycle.zig");

/// Re-export: callers construct `std.process.Child` placeholders via
/// `client_mod.zeroedChild` (agent, executor, manager, session_switcher).
pub const zeroedChild = lifecycle.zeroedChild;

pub const ServerStatus = enum {
    connecting,
    connected,
    failed,
    disabled,

    pub fn label(self: ServerStatus) []const u8 {
        return switch (self) {
            .connecting => "CONNECTING",
            .connected => "CONNECTED",
            .failed => "FAILED",
            .disabled => "DISABLED",
        };
    }
};

pub const McpTool = discovery_mod.McpTool;

/// Server identity reported in the `initialize` response. Owned; freed in
/// `McpClient.deinit`. Used for diagnostics and TUI display.
pub const ServerInfo = struct {
    name: []u8,
    version: []u8,

    pub fn deinit(self: *ServerInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.version);
        self.* = undefined;
    }
};

pub const McpClient = struct {
    gpa: std.mem.Allocator,
    name: []u8,
    /// The static transport configuration. Variants make illegal
    /// combinations unrepresentable: a stdio client always has
    /// command+args, an sse client always has a url.
    transport: union(enum) {
        stdio: struct {
            command: []u8,
            args: [][]u8,
        },
        sse: struct {
            url: []u8,
            /// Extra HTTP headers sent with every request (already `{env:VAR}`-
            /// expanded by the manager). Owned; freed in `stop`.
            headers: []config_mod.McpHeader = &.{},
        },
    },
    /// Runtime lifecycle. Variants make illegal combinations
    /// unrepresentable: only stdio can have a `process`, only failed
    /// has a reason, only disabled/connecting/ready are valid for the
    /// inner status.
    lifecycle: union(enum) {
        disabled,
        stdio: struct {
            process: std.process.Child,
            status: enum { connecting, ready },
            win32_job_obj: if (os.is_windows) ?wire.windows.HANDLE else void = if (os.is_windows) null else {},
        },
        sse: struct {
            status: enum { connecting, ready },
        },
        failed: struct {
            reason: []u8,
        },
    },
    latency_ms: u32 = 0,
    /// The discovery cache: discovered tool records, the
    /// `notifications/tools/list_changed` pending flag, and the
    /// `capabilities.tools.listChanged` capability bit. Owned by the
    /// `discovery.zig` spoke (no back-reference); the client orchestrates —
    /// it fills the cache via `listTools`, routes notifications into it, and
    /// drops it through `clearTools` on every transition off a live
    /// transport (#384 invariants live in the spoke).
    discovery: discovery_mod.Discovery,
    next_request_id: i64 = 1,
    /// Serializes JSON-RPC requests — stdin/stdout pipes can't handle
    /// concurrent requests. Defensive for future parallel tool execution.
    request_mutex: std.Io.Mutex = .init,
    /// Transport LIFETIME guard (#385) — not request serialization. Guards the
    /// `lifecycle` union variant, the stdio pipe handles, and `session_id`
    /// against `stop`/`setError` racing an in-flight request's captured
    /// handles. Short critical sections only, NEVER held across request I/O.
    /// Lock order is strictly `request_mutex → transport_mutex`;
    /// `stop`/`setError`/`terminateHttpSession` take this mutex alone and never
    /// `request_mutex`, so the UI thread can never block on an in-flight
    /// request.
    transport_mutex: std.Io.Mutex = .init,
    /// Requests currently inside a stdio capture bracket (I/O on the live
    /// pipes). `stop` parks the pipes instead of closing while this is > 0;
    /// the LAST exiting request performs the deferred close on its own thread.
    /// Atomic so a worker's release never needs `transport_mutex` — a canceled
    /// lock there must not strand the counter (it would strand the deferred
    /// close with it). Writes to the parked-pipes decision itself remain
    /// mutex-guarded.
    in_flight_requests: std.atomic.Value(u32) = .init(0),
    /// Pipes parked by `stop` while requests were in flight (#385). Non-null
    /// means someone must close them; the release bracket consumes it. Windows:
    /// a closed HANDLE value may be reused by another object, POSIX: fd reuse —
    /// closing under an in-flight read is a crossfire, not an error.
    /// Guarded by `transport_mutex`.
    pending_close: ?struct { stdin: ?std.Io.File = null, stdout: ?std.Io.File = null } = null,
    /// Timeout for one stdio poll or complete HTTP request, in milliseconds.
    read_timeout_ms: u32 = 30_000,
    /// Monotonic slot generation assigned by `McpManager` so async connect
    /// jobs never install into a removed-and-readded client of the same name.
    generation: u64 = 0,
    /// Server-assigned `Mcp-Session-Id` for the Streamable HTTP transport.
    /// null until the initialize response provides one. Owned; freed in deinit.
    session_id: ?[]u8 = null,
    /// Server identity from the `initialize` response. Owned; freed in deinit.
    /// null until the handshake completes (or if the server omitted serverInfo).
    server_info: ?ServerInfo = null,
    /// Protocol version the server echoed back in `initialize`. May differ
    /// from what we sent — the server may downgrade. Owned; freed in deinit.
    negotiated_protocol: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, name: []const u8, command: ?[]const u8, args: []const []const u8, url: ?[]const u8) !McpClient {
        // Legacy init: if url is set, build an sse client; otherwise stdio.
        // The caller picks the transport via the (command, url) pair.
        if (url) |u| {
            if (command != null) return error.AmbiguousTransport;
            return initSse(gpa, name, u);
        }
        const cmd = command orelse return error.NoTransport;
        return initStdio(gpa, name, cmd, args);
    }

    /// Unchanged-signature delegate: the body moved to `lifecycle.zig`
    /// (`initStdio`) in issue #367 slice 11.
    pub fn initStdio(gpa: std.mem.Allocator, name: []const u8, command: []const u8, args: []const []const u8) !McpClient {
        return lifecycle.initStdio(gpa, name, command, args);
    }

    /// Unchanged-signature delegate: the body moved to `lifecycle.zig`
    /// (`initSse`) in issue #367 slice 11.
    pub fn initSse(gpa: std.mem.Allocator, name: []const u8, url: []const u8) !McpClient {
        return lifecycle.initSse(gpa, name, url);
    }

    /// Unchanged-signature delegate: the body moved to `lifecycle.zig`
    /// (`cloneForConnect`) in issue #367 slice 11.
    pub fn cloneForConnect(self: *const McpClient, io: std.Io) !McpClient {
        return lifecycle.cloneForConnect(self, io);
    }

    /// Unchanged-signature delegate: the body moved to `lifecycle.zig`
    /// (`statusOf`) in issue #367 slice 11.
    pub fn status(self: *const McpClient) ServerStatus {
        return lifecycle.statusOf(self);
    }

    /// Thread-safe status read under `transport_mutex` for worker threads.
    pub fn statusSync(self: *McpClient, io: std.Io) ServerStatus {
        self.transport_mutex.lockUncancelable(io);
        defer self.transport_mutex.unlock(io);
        return lifecycle.statusOf(self);
    }

    /// Unchanged-signature delegate: the body moved to `lifecycle.zig`
    /// (`markConnecting`) in issue #367 slice 11.
    pub fn markConnecting(self: *McpClient, io: std.Io) void {
        lifecycle.markConnecting(self, io);
    }

    /// Unchanged-signature delegate: the body moved to `lifecycle.zig`
    /// (`adoptFailure`) in issue #367 slice 11.
    pub fn adoptFailure(self: *McpClient, io: std.Io, reason: []u8) void {
        lifecycle.adoptFailure(self, io, reason);
    }
    pub fn deinit(self: *McpClient, io: std.Io) void {
        self.stop(io);
        self.gpa.free(self.name);
        switch (self.transport) {
            .stdio => |t| {
                self.gpa.free(t.command);
                for (t.args) |arg| self.gpa.free(arg);
                if (t.args.len > 0) self.gpa.free(t.args);
            },
            .sse => |t| {
                self.gpa.free(t.url);
                config_mod.freeHeaders(self.gpa, t.headers);
            },
        }
        switch (self.lifecycle) {
            .failed => |f| self.gpa.free(f.reason),
            else => {},
        }
        self.discovery.deinit();
        if (self.session_id) |sid| self.gpa.free(sid);
        if (self.server_info) |*si| si.deinit(self.gpa);
        if (self.negotiated_protocol) |pv| self.gpa.free(pv);
        self.* = undefined;
    }

    /// Set the lifecycle to failed (or replace the existing reason). A live
    /// transport variant owns real resources — a stdio child process plus
    /// Windows Job Object handle, or an HTTP session — so it is stopped
    /// BEFORE the union overwrite; dropping the variant raw would orphan the
    /// child and leak the handle, and a later stop/deinit could never reach
    /// them through the `.failed` arm (#384 bug 3). Stopping a transport also
    /// invalidates its discovery cache, so the tools are cleared with it: a
    /// non-connected lifecycle never carries tools, which is what keeps the
    /// manager's reconcile re-launching connects for a failed server instead
    /// of wedging it in CONNECTING with stale tools. On OOM the client ends
    /// up cleanly `.disabled` (stopped, cache empty) rather than half-failed.
    pub fn setError(self: *McpClient, io: std.Io, comptime fmt: []const u8, args: anytype) void {
        switch (self.lifecycle) {
            .stdio, .sse => self.stop(io),
            else => {},
        }
        self.clearTools();
        // Allocate the replacement before freeing the old reason: on OOM the
        // client keeps a coherent (already-stopped) state instead of carrying
        // a freed `.failed` reason.
        const reason = std.fmt.allocPrint(self.gpa, fmt, args) catch {
            log.warn("MCP '{s}': OOM formatting failure reason; left disabled instead of failed", .{self.name});
            return;
        };
        // Serialize the lifecycle overwrite with any worker's capture bracket
        // (#385) — a capture that took the `.stdio` tag branch must never
        // dereference a union mid-overwrite.
        const locked = if (self.transport_mutex.lock(io)) true else |_| false;
        defer if (locked) self.transport_mutex.unlock(io);
        if (self.lifecycle == .failed) self.gpa.free(self.lifecycle.failed.reason);
        self.lifecycle = .{ .failed = .{ .reason = reason } };
    }

    /// Free every discovered tool record and empty the list, clearing the
    /// pending-refresh flag with it. Unchanged-signature delegate to the
    /// discovery spoke, which owns the invariant: the cache belongs to a
    /// live transport, so stopping the transport without dropping the cache
    /// would leave stale tools that wedge the next reconcile in CONNECTING
    /// (#384). Every transition off a live transport calls this.
    pub fn clearTools(self: *McpClient) void {
        self.discovery.clear();
    }

    /// Route a server-initiated notification captured during a request read.
    /// Only `notifications/tools/list_changed` is consumed (marks the
    /// discovery cache stale — the bookkeeping lives on the
    /// `discovery.zig` spoke); other notifications (progress, logging,
    /// resources/list_changed, prompts/list_changed) are accepted but ignored
    /// — Zay doesn't expose those primitives yet. `payload` is unused for
    /// the list_changed path (the spec carries no params), but kept on the
    /// signature for future notifications that do carry params.
    pub fn handleNotification(self: *McpClient, method: []const u8, payload: []const u8) void {
        _ = payload;
        self.discovery.onNotification(method);
    }

    /// True when a `notifications/tools/list_changed` arrived since the last
    /// check. The App calls this on each tick and, when true, calls
    /// `refreshMcpTools` (which re-runs `tools/list` and reinjects schemas).
    /// Unchanged-signature delegate to the discovery spoke's atomic
    /// read-and-clear swap.
    pub fn pollToolsRefresh(self: *McpClient) bool {
        return self.discovery.takeRefreshPending();
    }

    /// Spawn the MCP server subprocess (stdio transport). Unchanged-signature
    /// delegate: the body moved to `lifecycle.zig` (`startStdio`) in issue
    /// #367 slice 11.
    pub fn startStdio(self: *McpClient, io: std.Io) !void {
        return lifecycle.startStdio(self, io);
    }

    /// Stop the subprocess and close its pipes. Unchanged-signature delegate:
    /// the body moved to `lifecycle.zig` (`stop`) in issue #367 slice 11.
    pub fn stop(self: *McpClient, io: std.Io) void {
        lifecycle.stop(self, io);
    }

    /// Register as an in-flight stdio request and snapshot the live pipe
    /// handles (#385). Unchanged-signature delegate: the body moved to
    /// `lifecycle.zig` (`captureStdioTransport`) in issue #367 slice 11.
    /// wire.zig calls this method form — keep the signature frozen.
    pub fn captureStdioTransport(self: *McpClient, io: std.Io) !lifecycle.StdioPipes {
        return lifecycle.captureStdioTransport(self, io);
    }

    /// Exit a `captureStdioTransport` bracket. Unchanged-signature delegate:
    /// the body moved to `lifecycle.zig` (`releaseStdioTransport`) in issue
    /// #367 slice 11. wire.zig calls this method form — keep frozen.
    pub fn releaseStdioTransport(self: *McpClient, io: std.Io) void {
        lifecycle.releaseStdioTransport(self, io);
    }
    /// Send a JSON-RPC request and read the response. Dispatches on the
    /// transport — both arms are delegates to the wire spoke: stdio reads a
    /// newline-delimited response line; Streamable HTTP POSTs and reads a
    /// JSON body or an SSE stream. Returns the raw JSON-RPC response (owned,
    /// caller must free). Serialized via request_mutex — concurrent calls
    /// queue, not interleave.
    pub fn sendRequest(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) ![]u8 {
        return switch (self.transport) {
            .stdio => wire.sendRequestStdio(self, io, method, params_json),
            .sse => wire.sendRequestHttp(self, io, method, params_json),
        };
    }

    /// Send a JSON-RPC notification (no response expected). Dispatches on the
    /// transport.
    pub fn sendNotification(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) !void {
        return switch (self.transport) {
            .stdio => wire.sendNotificationStdio(self, io, method, params_json),
            .sse => wire.sendNotificationHttp(self, io, method, params_json),
        };
    }

    /// Unchanged-signature delegate: the body moved to `session_ops.zig`
    /// (`initialize`) in issue #367 slice 12.
    pub fn initialize(self: *McpClient, io: std.Io) !void {
        return session_ops.initialize(self, io);
    }

    /// Unchanged-signature delegate: the body moved to `session_ops.zig`
    /// (`listTools`) in issue #367 slice 12.
    pub fn listTools(self: *McpClient, io: std.Io) !void {
        return session_ops.listTools(self, io);
    }

    /// Unchanged-signature delegate: the body moved to `session_ops.zig`
    /// (`listToolsFresh`) in issue #367 slice 12. manager.zig calls this
    /// method form — keep the signature frozen.
    pub fn listToolsFresh(self: *McpClient, io: std.Io) !std.ArrayList(discovery_mod.McpTool) {
        return session_ops.listToolsFresh(self, io);
    }

    /// Unchanged-signature delegate: the body moved to `session_ops.zig`
    /// (`callTool`) in issue #367 slice 12.
    pub fn callTool(self: *McpClient, io: std.Io, tool_name: []const u8, arguments_json: []const u8) ![]u8 {
        return session_ops.callTool(self, io, tool_name, arguments_json);
    }

    /// Register a mock or discovered tool for testing / dynamic loading.
    /// Unchanged-signature delegate to the discovery spoke's `addTool`, which
    /// owns the record construction and its failure contract (the record
    /// takes ownership of `schema` on success; on error `schema` stays
    /// caller-owned). `raw_input_schema` is the server's original
    /// `inputSchema` JSON (borrowed; duped into the record) — pass null for
    /// mock tools that have no source schema.
    pub fn addTool(
        self: *McpClient,
        tool_name: []const u8,
        description: []const u8,
        schema: tools_common.Schema,
        raw_input_schema: ?[]const u8,
    ) !void {
        try self.discovery.addTool(self.name, tool_name, description, schema, raw_input_schema);
    }
};

/// Test-only fixture: spawn a mock MCP server in the given mode. Shared with
/// the wire spoke's stdio tests (mcp/wire.zig); not part of the public API.
pub fn initMockClient(gpa: std.mem.Allocator, name: []const u8, mode: []const u8) !McpClient {
    return McpClient.init(gpa, name, @import("mcp_mock_server").path, &.{mode}, null);
}

test "McpClient initializes and formats namespaced tool names" {
    const gpa = std.testing.allocator;
    var client = try McpClient.init(gpa, "memory", "npx", &.{}, null);
    defer client.deinit(std.testing.io);

    client.lifecycle = .{
        .stdio = .{
            .process = zeroedChild(),
            .status = .ready,
        },
    };
    try client.addTool("create_entities", "Create entities in graph", .{ .properties = &.{} }, null);

    try std.testing.expectEqualStrings("memory", client.name);
    try std.testing.expectEqual(ServerStatus.connected, client.status());
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    try std.testing.expectEqualStrings("mcp__memory__create_entities", client.discovery.tools.items[0].full_name);
}

test "McpClient sendRequest round-trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Bash one-liner: read one line from stdin, echo a fixed JSON-RPC response.
    var client = try initMockClient(gpa, "echo-test", "default");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    const response = try client.sendRequest(io, "initialize", "{\"protocolVersion\":\"2024-11-05\"}");
    defer gpa.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"protocolVersion\"") != null);
}

test "McpClient init and addTool leak no partial copies on a mid-call OOM" {
    // Regression for the hoisted errdefer chains: a `try` dupe failing inside
    // a struct literal (initStdio's name/command, addTool's server/name/
    // description) used to strand every already-copied slice. Iterate every
    // allocation index so each failure point — including the tools append —
    // is exercised; leak-freedom is asserted by the testing allocator at
    // process end, not by the error code.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var succeeded = false;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        if (McpClient.init(failing.allocator(), "bare", "echo", &.{}, null)) |client_val| {
            var client = client_val;
            defer client.deinit(io);

            if (client.addTool("search", "Search the index", .{ .properties = &.{} }, "{\"type\":\"object\"}")) {
                try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
                try std.testing.expectEqualStrings("{\"type\":\"object\"}", client.discovery.tools.items[0].raw_input_schema.?);
                succeeded = true;
                break;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
    try std.testing.expect(succeeded);
}
