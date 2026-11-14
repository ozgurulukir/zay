//! Model Context Protocol (MCP) Client.
//! Implements protocol state machine, tool discovery, execution, and health monitoring.

const std = @import("std");
const log = std.log.scoped(.mcp);
const config_mod = @import("../config/config.zig");
const os = @import("../os.zig");
const http = @import("../http.zig");
const tools_common = @import("../tools/common.zig");
const transport = @import("transport.zig");
const schema_mod = @import("schema.zig");
const discovery_mod = @import("discovery.zig");
const wire = @import("wire.zig");

const assert = std.debug.assert;

// Streamable HTTP transport buffer/bound sizes.
const http_body_buffer_bytes = 8 * 1024;
const http_redirect_buffer_bytes = 16 * 1024;
const http_transfer_buffer_bytes = 64 * 1024;
const http_response_bytes_max = 64 * 1024 * 1024;
const windows_child_stop_wait_ms = 1_000;

const HttpRequestOutcome = union(enum) {
    response: []u8,
    failure: anyerror,
};

const HttpVoidOutcome = union(enum) {
    success,
    failure: anyerror,
};

const HttpSelectEvent = union(enum) {
    request: HttpRequestOutcome,
    notification: HttpVoidOutcome,
    termination: HttpVoidOutcome,
    timeout: void,
};

// MCP protocol version strings (spec-mandated — the server echoes one back
// during `initialize` negotiation, so these values can never change).
const protocol_version_stdio = "2024-11-05";
const protocol_version_streamable_http = "2025-03-26";

/// The Streamable HTTP `Accept` value: either a single JSON body or an SSE
/// stream (MCP spec contract).
const accept_streamable_http = http.content_type_json ++ ", " ++ http.media_type_event_stream;

/// A zeroed `std.process.Child` placeholder. On Windows the `thread_handle`
/// field is a non-nullable HANDLE, so `std.mem.zeroes` cannot be used; a
/// non-null sentinel pointer is substituted instead. The placeholder is only
/// ever overwritten by a real `spawn` before use.
pub fn zeroedChild() std.process.Child {
    if (os.is_windows) {
        return .{
            .id = null,
            .thread_handle = @ptrFromInt(1),
            .stdin = null,
            .stdout = null,
            .stderr = null,
            .request_resource_usage_statistics = false,
        };
    }
    return std.mem.zeroes(std.process.Child);
}

/// Zig's Windows Child.kill waits forever for the process handle to signal.
/// MCP servers are external programs and must not be able to wedge TUI
/// teardown, so terminate the process but bound the reap wait. Closing the job
/// object immediately afterwards remains the descendant-process backstop.
fn stopChildWindowsBounded(child: *std.process.Child) void {
    if (!os.is_windows) unreachable;
    const process_handle = child.id orelse return;

    _ = std.os.windows.ntdll.RtlReportSilentProcessExit(process_handle, @enumFromInt(1));
    _ = std.os.windows.ntdll.NtTerminateProcess(process_handle, @enumFromInt(1));

    const timeout_100ns: std.os.windows.LARGE_INTEGER =
        -(@as(std.os.windows.LARGE_INTEGER, windows_child_stop_wait_ms) * std.time.ns_per_ms / 100);
    switch (std.os.windows.ntdll.NtWaitForSingleObject(process_handle, .FALSE, &timeout_100ns)) {
        .WAIT_0 => {},
        .TIMEOUT => log.warn("MCP child did not stop within {d}ms; releasing process handles", .{windows_child_stop_wait_ms}),
        else => log.warn("MCP child wait failed during shutdown; releasing process handles", .{}),
    }

    _ = os.closeWin32Handle(process_handle);
    child.id = null;
    _ = os.closeWin32Handle(child.thread_handle);
    child.thread_handle = undefined;
    assert(child.stdin == null);
    assert(child.stdout == null);
    assert(child.stderr == null);
}

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

    /// Internal: build a McpClient from explicit stdio parameters. The
    /// manager now constructs Transport unions directly via this path.
    pub fn initStdio(gpa: std.mem.Allocator, name: []const u8, command: []const u8, args: []const []const u8) !McpClient {
        var owned_args = try gpa.alloc([]u8, args.len);
        var args_done: usize = 0;
        errdefer {
            // Free only the initialized prefix: when a dupe below fails, the
            // tail of `owned_args` is still undefined and freeing it reads a
            // garbage pointer (negative-space sweep test in mcp/manager.zig).
            for (owned_args[0..args_done]) |a| gpa.free(a);
            gpa.free(owned_args);
        }
        for (args, 0..) |arg, i| {
            owned_args[i] = try gpa.dupe(u8, arg);
            args_done += 1;
        }
        // Hoisted dupes: a failing `try` inside the struct literal would leave
        // the earlier copies stranded when the return never materializes.
        const name_owned = try gpa.dupe(u8, name);
        errdefer gpa.free(name_owned);
        const command_owned = try gpa.dupe(u8, command);
        errdefer gpa.free(command_owned);
        return .{
            .gpa = gpa,
            .name = name_owned,
            .transport = .{
                .stdio = .{
                    .command = command_owned,
                    .args = owned_args,
                },
            },
            .lifecycle = .disabled,
            .discovery = discovery_mod.Discovery.init(gpa),
        };
    }

    pub fn initSse(gpa: std.mem.Allocator, name: []const u8, url: []const u8) !McpClient {
        const name_owned = try gpa.dupe(u8, name);
        errdefer gpa.free(name_owned);
        const url_owned = try gpa.dupe(u8, url);
        errdefer gpa.free(url_owned);
        return .{
            .gpa = gpa,
            .name = name_owned,
            .transport = .{ .sse = .{ .url = url_owned } },
            .lifecycle = .disabled,
            .discovery = discovery_mod.Discovery.init(gpa),
        };
    }

    /// Build a fresh client with the same transport configuration (name, stdio
    /// command/args, sse url/headers) in `.connecting` lifecycle, for an async
    /// connect worker. The worker spawns and handshakes on the clone; the
    /// manager moves the completed client into the live list slot on the main
    /// thread, so the live client is never mutated off-thread.
    ///
    /// The clone starts from the `initStdio`/`initSse` defaults, so it never
    /// inherits the live client's discovery cache: `discovery` is a fresh
    /// `Discovery` — empty tools, pending flag reset. A fresh connect has
    /// nothing to refresh yet — its own handshake runs `listTools` — and
    /// inheriting a stale pending flag would trigger a redundant re-discovery
    /// on the first tick after the clone is installed.
    pub fn cloneForConnect(self: *const McpClient, io: std.Io) !McpClient {
        var clone: McpClient = switch (self.transport) {
            .stdio => |t| try initStdio(self.gpa, self.name, t.command, t.args),
            .sse => |t| try initSse(self.gpa, self.name, t.url),
        };
        errdefer clone.deinit(io);
        if (self.transport == .sse) {
            clone.transport.sse.headers = try config_mod.cloneHeaders(self.gpa, self.transport.sse.headers);
        }
        clone.markConnecting(io);
        assert(clone.discovery.tools.items.len == 0);
        assert(!clone.discovery.pending_refresh.load(.acquire));
        return clone;
    }

    /// Map the lifecycle union to the public `ServerStatus` enum. The
    /// union is the canonical state; this is the legacy API surface
    /// for callers (manager, TUI) that read the status field.
    pub fn status(self: *const McpClient) ServerStatus {
        return switch (self.lifecycle) {
            .disabled => .disabled,
            .stdio => |s| switch (s.status) {
                .connecting => .connecting,
                .ready => .connected,
            },
            .sse => |s| switch (s.status) {
                .connecting => .connecting,
                .ready => .connected,
            },
            .failed => .failed,
        };
    }

    /// Move the lifecycle to connecting (preserves any existing
    /// stdio process handle or sse url). Used by the manager after
    /// syncFromConfig to mark a previously-disabled client as
    /// about-to-connect.
    ///
    /// The `.disabled`/`.failed` overwrites run under `transport_mutex`
    /// (#385): a background refresh worker can still be inside this client
    /// (its capture bracket reads the union tag under the same mutex), so the
    /// write must not race that read even though it is UI-thread-only.
    pub fn markConnecting(self: *McpClient, io: std.Io) void {
        const locked = if (self.transport_mutex.lock(io)) true else |_| false;
        defer if (locked) self.transport_mutex.unlock(io);
        switch (self.lifecycle) {
            .stdio => |*s| s.status = .connecting,
            .sse => |*s| s.status = .connecting,
            .disabled => {
                self.lifecycle = switch (self.transport) {
                    .stdio => .{ .stdio = .{
                        .process = zeroedChild(),
                        .status = .connecting,
                    } },
                    .sse => .{ .sse = .{ .status = .connecting } },
                };
            },
            .failed => {
                self.gpa.free(self.lifecycle.failed.reason);
                self.lifecycle = switch (self.transport) {
                    .stdio => .{ .stdio = .{
                        .process = zeroedChild(),
                        .status = .connecting,
                    } },
                    .sse => .{ .sse = .{ .status = .connecting } },
                };
            },
        }
    }

    /// Install a pre-built `.failed` reason under the `transport_mutex`
    /// discipline (#385) — the manager's connect-failure arm has already
    /// stopped the transport and cleared tools; this only swaps the variant,
    /// serialized against any worker's capture bracket like `setError`'s
    /// write. Takes ownership of `reason`; frees any prior one (possible only
    /// if the caller skipped `stop`, which always frees it).
    pub fn adoptFailure(self: *McpClient, io: std.Io, reason: []u8) void {
        const locked = if (self.transport_mutex.lock(io)) true else |_| false;
        defer if (locked) self.transport_mutex.unlock(io);
        if (self.lifecycle == .failed) self.gpa.free(self.lifecycle.failed.reason);
        self.lifecycle = .{ .failed = .{ .reason = reason } };
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

    /// Spawn the MCP server subprocess (stdio transport).
    /// Sets up stdin/stdout pipes for JSON-RPC communication.
    pub fn startStdio(self: *McpClient, io: std.Io) !void {
        const t = switch (self.transport) {
            .stdio => |t| t,
            .sse => return error.NoStdioTransport,
        };
        // Build argv: command + args
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.append(self.gpa, t.command);
        for (t.args) |arg| try argv.append(self.gpa, arg);

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            // MCP servers are pipe-only helpers. Keep terminal control keys
            // (Ctrl+C/Ctrl+D) in the TUI instead of broadcasting them to a
            // console child while its handshake is being canceled.
            .create_no_window = os.is_windows,
        });
        errdefer child.kill(io);

        var win32_job_obj: if (os.is_windows) ?wire.windows.HANDLE else void = if (os.is_windows) null else {};
        if (os.is_windows) {
            if (child.id) |proc_handle| {
                win32_job_obj = os.createKillOnCloseJobForProcess(proc_handle);
            }
        }
        errdefer {
            if (os.is_windows) {
                if (win32_job_obj) |h| {
                    _ = os.terminateWin32JobObject(h, 1);
                    _ = os.closeWin32Handle(h);
                }
            }
        }

        self.lifecycle = .{
            .stdio = .{
                .process = child,
                .status = .connecting,
                .win32_job_obj = win32_job_obj,
            },
        };
    }

    /// Stop the subprocess and close its pipes. POSIX gets SIGTERM followed by
    /// kill/reap; Windows terminates the Job Object and uses a bounded process
    /// wait so an external MCP server cannot wedge TUI teardown. For the
    /// Streamable HTTP transport, terminates the remote session (best-effort)
    /// and drops the session id.
    ///
    /// Pipe close is deferred while requests are in flight (#385): a worker
    /// holding captured handles must never observe them closed (HANDLE/fd
    /// reuse crossfire), so `parkStdioPipes` moves them to `pending_close` and
    /// the last exiting request closes them on its own thread. Process
    /// kill/reap stays immediate — it never touches the pipe handles — so an
    /// in-flight read fails loudly via the existing crash/EOF paths. The
    /// lifecycle flips to `.disabled` synchronously; status() never waits on
    /// the deferred close.
    pub fn stop(self: *McpClient, io: std.Io) void {
        log.info("shutdown.mcp.client.begin name={s}", .{self.name});
        defer log.info("shutdown.mcp.client.done name={s}", .{self.name});
        if (self.lifecycle == .stdio) {
            var child = self.lifecycle.stdio.process;
            const job_obj = if (os.is_windows) self.lifecycle.stdio.win32_job_obj else null;
            // Close stdin so the child sees EOF and can exit gracefully —
            // parked instead of closed while a request is in flight.
            self.parkStdioPipes(io);
            child.stdin = null;
            child.stdout = null;
            // SIGTERM first — gives well-behaved servers a chance to clean up.
            // kill() below sends SIGKILL and reaps the zombie regardless.
            if (child.id) |pid| {
                if (!os.is_windows) {
                    std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch {};
                }
            }
            if (os.is_windows) {
                if (job_obj) |h| {
                    _ = os.terminateWin32JobObject(h, 1);
                }
                stopChildWindowsBounded(&child);
                if (job_obj) |h| _ = os.closeWin32Handle(h);
            } else {
                child.kill(io);
            }
        }
        if (self.transport == .sse) self.terminateHttpSession(io);
        // A failed client may carry an owned reason (set via `setError`, e.g.
        // by the async connect worker before tearing the clone down). Free it
        // before the lifecycle is clobbered, or deinit's failed-arm can never
        // see it and the reason leaks.
        if (self.lifecycle == .failed) self.gpa.free(self.lifecycle.failed.reason);
        // Serialize the lifecycle overwrite with any worker's capture bracket
        // (#385). Parked pipes are closed here ONLY when no request is in
        // flight — an in-flight request owns its captured handles and closes
        // them in its release bracket; closing under it would be exactly the
        // HANDLE/fd-reuse crossfire #385 fixes. A worker wedged past its join
        // point (no path reaches this; manager deinit joins jobs first)
        // leaks the parked handles to process exit instead of racing it.
        // If the lock is canceled we proceed unsynchronized, matching
        // pre-#385 teardown semantics, rather than blocking shutdown.
        const locked = if (self.transport_mutex.lock(io)) true else |_| false;
        defer if (locked) self.transport_mutex.unlock(io);
        if (self.in_flight_requests.load(.acquire) == 0) self.closePendingPipesLocked(io);
        self.lifecycle = .disabled;
    }

    /// Move the stdio pipe handles out of the child under `transport_mutex`:
    /// closed immediately when no request is in flight (previous behavior),
    /// parked in `pending_close` for the last exiting request to close
    /// otherwise (#385). On lock failure (canceled teardown) the pipes are
    /// left open — stop clobbers the lifecycle union either way; the handles
    /// are closed by the release bracket, stop's tail, or process exit,
    /// rather than blocking on a canceled mutex.
    fn parkStdioPipes(self: *McpClient, io: std.Io) void {
        self.transport_mutex.lock(io) catch return;
        defer self.transport_mutex.unlock(io);
        if (self.lifecycle != .stdio) return;
        const child = &self.lifecycle.stdio.process;
        if (self.in_flight_requests.load(.acquire) > 0) {
            self.pending_close = .{ .stdin = child.stdin, .stdout = child.stdout };
        } else {
            if (child.stdin) |*f| f.close(io);
            if (child.stdout) |*f| f.close(io);
        }
        child.stdin = null;
        child.stdout = null;
    }

    /// Register as an in-flight stdio request and snapshot the live pipe
    /// handles under `transport_mutex` (#385). The lifecycle variant IS the
    /// generation check: anything but `.stdio` with both pipes present fails
    /// loudly here instead of I/O on closed handles. Every caller must run the
    /// paired `releaseStdioTransport` (use `defer`) — it owns the deferred
    /// close when `stop` parked the pipes mid-flight.
    pub fn captureStdioTransport(self: *McpClient, io: std.Io) !struct { stdin: std.Io.File, stdout: std.Io.File } {
        try self.transport_mutex.lock(io);
        defer self.transport_mutex.unlock(io);
        if (self.lifecycle != .stdio) return error.NotConnected;
        const child = &self.lifecycle.stdio.process;
        const stdin_file = child.stdin orelse return error.NotConnected;
        const stdout_file = child.stdout orelse return error.NotConnected;
        _ = self.in_flight_requests.fetchAdd(1, .monotonic);
        return .{ .stdin = stdin_file, .stdout = stdout_file };
    }

    /// Exit a `captureStdioTransport` bracket. The counter is atomic, so the
    /// decrement NEVER needs `transport_mutex` — a canceled lock (request
    /// canceled during manager deinit) cannot strand the bracket open. The
    /// last exiting request performs the deferred close; if its lock attempt
    /// is also canceled, stop's tail (which re-checks the counter) or process
    /// exit closes the parked pipes instead.
    pub fn releaseStdioTransport(self: *McpClient, io: std.Io) void {
        if (self.in_flight_requests.fetchSub(1, .acq_rel) != 1) return;
        self.transport_mutex.lock(io) catch return;
        defer self.transport_mutex.unlock(io);
        self.closePendingPipesLocked(io);
    }

    /// Close pipes parked by `parkStdioPipes`, if any, for a caller already
    /// holding `transport_mutex` (the release bracket and stop's locked tail).
    fn closePendingPipesLocked(self: *McpClient, io: std.Io) void {
        if (self.pending_close) |parked| {
            if (parked.stdin) |*f| f.close(io);
            if (parked.stdout) |*f| f.close(io);
            self.pending_close = null;
        }
    }

    /// Terminate the remote session via HTTP DELETE (best-effort) and free the
    /// stored session id. Servers may refuse DELETE; failures are ignored since
    /// the connection is being torn down regardless. Idempotent.
    ///
    /// Guarded by `transport_mutex` (#385): the DELETE's header bytes borrow
    /// Terminate the remote session via HTTP DELETE (best-effort) and free the
    /// stored session id. Servers may refuse DELETE; failures are ignored since
    /// the connection is being torn down regardless. Idempotent.
    ///
    /// The session id is DETACHED under `transport_mutex` — a short section —
    /// and the DELETE runs outside the mutex (#385 review): the request is
    /// network I/O (unbounded connect on POSIX), and holding the mutex across
    /// it would stall a worker's `snapshotSessionId` for the whole span while
    /// the worker holds `request_mutex`. The detached ownership closes the
    /// free-while-borrowed race: concurrent request paths read the field under
    /// the mutex (or hold their own snapshot) and never touch the detached id.
    fn terminateHttpSession(self: *McpClient, io: std.Io) void {
        self.transport_mutex.lock(io) catch return;
        const session_id = self.session_id;
        self.session_id = null;
        self.transport_mutex.unlock(io);
        defer if (session_id) |sid| self.gpa.free(sid);

        const sid = session_id orelse return;
        if (os.is_windows) {
            self.runHttpVoidWithTimeout(io, .termination, httpTerminationTask, .{ self, io, sid }) catch |err| {
                log.warn("MCP HTTP session termination failed err={s}", .{@errorName(err)});
            };
            return;
        }

        self.terminateHttpSessionUnbounded(io, sid);
    }

    fn terminateHttpSessionUnbounded(self: *McpClient, io: std.Io, session_id: []const u8) void {
        const url = switch (self.transport) {
            .sse => |t| t.url,
            .stdio => return,
        };
        var client: std.http.Client = .{ .allocator = self.gpa, .io = io };
        defer client.deinit();
        const extra_headers = buildExtraHeadersWith(self.gpa, self.customHttpHeaders(), session_id) catch return;
        defer self.gpa.free(extra_headers);
        var req = client.request(.DELETE, std.Uri.parse(url) catch return, .{
            .extra_headers = extra_headers,
        }) catch return;
        defer req.deinit();
        // Best-effort: bound the send so teardown can't hang on a dead server,
        // then send the termination without waiting for the response.
        if (req.connection) |conn| self.applyHttpTimeout(conn);
        req.sendBodiless() catch return;
    }

    /// Send a JSON-RPC request and read the response. Dispatches on the
    /// transport: stdio reads a newline-delimited response line (the wire
    /// spoke); Streamable HTTP POSTs and reads a JSON body or an SSE
    /// stream. Returns the raw JSON-RPC response (owned, caller must
    /// free). Serialized via request_mutex — concurrent calls queue, not
    /// interleave.
    pub fn sendRequest(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) ![]u8 {
        return switch (self.transport) {
            .stdio => wire.sendRequestStdio(self, io, method, params_json),
            .sse => self.sendRequestHttp(io, method, params_json),
        };
    }

    /// Send a JSON-RPC notification (no response expected). Dispatches on the
    /// transport.
    pub fn sendNotification(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) !void {
        return switch (self.transport) {
            .stdio => wire.sendNotificationStdio(self, io, method, params_json),
            .sse => self.sendNotificationHttp(io, method, params_json),
        };
    }

    // ── Streamable HTTP transport ──

    /// Split a request timeout in milliseconds into the `(sec, usec)` components
    /// of a POSIX `timeval` as used by `applyHttpTimeout`. Kept as a pure helper
    /// so the rounding math is unit-testable cross-platform (`std.posix.timeval`
    /// is not available on Windows, where the socket-timeout path is skipped).
    fn httpTimeoutParts(read_timeout_ms: u32) struct { sec: i64, usec: i64 } {
        return .{
            .sec = @intCast(read_timeout_ms / 1000),
            .usec = @intCast((read_timeout_ms % 1000) * 1000),
        };
    }

    /// Apply a socket-level send/recv timeout so a server that accepts the
    /// connection but then stalls — no response head, or a mid-body stop —
    /// fails the handshake instead of blocking the worker forever.
    ///
    /// `std.http.Client` exposes no connect-phase timeout in Zig 0.16, so the
    /// connect itself is bounded only by kernel TCP/DNS timeouts. Connects now
    /// run on a worker thread (`McpManager.launchConnect`), so a connect hang
    /// can never freeze the UI; this bounds everything after connect.
    fn applyHttpTimeout(self: *McpClient, conn: *std.http.Client.Connection) void {
        if (!os.is_windows) {
            const parts = httpTimeoutParts(self.read_timeout_ms);
            const tv: std.posix.timeval = .{
                .sec = parts.sec,
                // macOS suseconds_t is 32-bit c_int; usec is bounded to
                // [0, 999_000] by the modulo in httpTimeoutParts.
                .usec = @intCast(parts.usec),
            };
            std.posix.setsockopt(
                conn.stream_reader.stream.socket.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.RCVTIMEO,
                std.mem.asBytes(&tv),
            ) catch {};
            std.posix.setsockopt(
                conn.stream_reader.stream.socket.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.SNDTIMEO,
                std.mem.asBytes(&tv),
            ) catch {};
        }
    }

    /// Windows' std.Io socket backend does not expose a socket-level timeout
    /// through `std.posix`, and the HTTP client has no request deadline of its
    /// own. Race the whole HTTP operation — including DNS/connect, response
    /// head, and an SSE body — against a timer so cancellation covers every
    /// phase of the request.
    fn runHttpRequestWithTimeout(
        self: *McpClient,
        io: std.Io,
        method: []const u8,
        params_json: ?[]const u8,
    ) ![]u8 {
        var events: [2]HttpSelectEvent = undefined;
        var select = std.Io.Select(HttpSelectEvent).init(io, &events);
        defer select.cancelDiscard();

        try select.concurrent(.request, httpRequestTask, .{ self, io, method, params_json });
        try select.concurrent(.timeout, httpTimeoutTask, .{ io, self.read_timeout_ms });

        const event = select.await() catch |err| {
            self.cancelHttpSelect(&select);
            return err;
        };
        return switch (event) {
            .request => |outcome| switch (outcome) {
                .response => |response| response,
                .failure => |err| err,
            },
            .timeout => {
                self.cancelHttpSelect(&select);
                return error.Timeout;
            },
            else => unreachable,
        };
    }

    /// Run a void HTTP operation with the same deadline used for requests.
    /// `field` is restricted by the call sites to `.notification` and
    /// `.termination`; the union keeps the two operation families distinct so
    /// a response allocation can never be mistaken for a void result.
    fn runHttpVoidWithTimeout(
        self: *McpClient,
        io: std.Io,
        comptime field: std.Io.Select(HttpSelectEvent).Field,
        function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) !void {
        var events: [2]HttpSelectEvent = undefined;
        var select = std.Io.Select(HttpSelectEvent).init(io, &events);
        defer select.cancelDiscard();

        try select.concurrent(field, function, args);
        try select.concurrent(.timeout, httpTimeoutTask, .{ io, self.read_timeout_ms });

        const event = try select.await();
        switch (event) {
            .timeout => return error.Timeout,
            .notification => |outcome| switch (outcome) {
                .success => {},
                .failure => |err| return err,
            },
            .termination => |outcome| switch (outcome) {
                .success => {},
                .failure => |err| return err,
            },
            .request => unreachable,
        }
    }

    fn cancelHttpSelect(self: *McpClient, select: *std.Io.Select(HttpSelectEvent)) void {
        while (select.cancel()) |event| {
            switch (event) {
                .request => |outcome| switch (outcome) {
                    .response => |response| self.gpa.free(response),
                    .failure => {},
                },
                .notification, .termination, .timeout => {},
            }
        }
    }

    /// POST a JSON-RPC request to the remote endpoint and return the matching
    /// JSON-RPC response (owned). The response is either a single
    /// `application/json` body or a `text/event-stream` searched for the
    /// request `id`. Captures the server-assigned `Mcp-Session-Id`.
    fn sendRequestHttp(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) ![]u8 {
        if (os.is_windows) {
            return self.runHttpRequestWithTimeout(io, method, params_json);
        }
        return self.sendRequestHttpUnbounded(io, method, params_json);
    }

    fn sendRequestHttpUnbounded(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) ![]u8 {
        const url = switch (self.transport) {
            .sse => |t| t.url,
            .stdio => return error.NoHttpTransport,
        };

        try self.request_mutex.lock(io);
        defer self.request_mutex.unlock(io);

        const id = self.next_request_id;
        self.next_request_id += 1;

        const body = try transport.formatRequest(self.gpa, id, method, params_json);
        defer self.gpa.free(body);

        var client: std.http.Client = .{ .allocator = self.gpa, .io = io };
        defer client.deinit();

        // Owned session-id snapshot (#385): immune to a concurrent
        // stop→terminateHttpSession freeing the stored id while this request's
        // header bytes still borrow it.
        const session_snapshot = self.snapshotSessionId(io, self.gpa);
        defer if (session_snapshot) |sid| self.gpa.free(sid);
        const extra_headers = try buildExtraHeadersWith(self.gpa, self.customHttpHeaders(), session_snapshot);
        defer self.gpa.free(extra_headers);
        var req = try client.request(.POST, try std.Uri.parse(url), .{
            .headers = .{ .content_type = .{ .override = http.content_type_json } },
            .extra_headers = extra_headers,
        });
        defer req.deinit();
        // Bound send + head + body reads so a stalled server fails fast.
        if (req.connection) |conn| self.applyHttpTimeout(conn);
        try writeBody(&req, body);

        var redirect_buffer: [http_redirect_buffer_bytes]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);
        const status_code: u16 = @intFromEnum(response.head.status);
        if (status_code == 404) return error.McpSessionExpired;
        if (status_code == 401 or status_code == 403) return error.McpUnauthorized;
        if (!http.isSuccess(status_code)) return error.McpHttpRequestFailed;

        // Capture session id + content type BEFORE the body reader invalidates
        // the head's borrowed pointers.
        try self.captureSessionId(io, response.head);
        const is_sse = isEventStream(response.head);

        if (is_sse) {
            var transfer_buffer: [http_transfer_buffer_bytes]u8 = undefined;
            const reader = response.reader(&transfer_buffer);
            var notifications: std.ArrayList(transport.Notification) = .empty;
            defer {
                for (notifications.items) |*n| n.deinit(self.gpa);
                notifications.deinit(self.gpa);
            }
            const response_body = try transport.readSseResponse(self.gpa, reader, id, &notifications);
            // Route accumulated server notifications — they may mark the
            // discovery cache stale, which the App polls on the next tick.
            for (notifications.items) |n| self.handleNotification(n.method, n.payload);
            return response_body;
        }
        return try readJsonBody(self.gpa, &response);
    }

    /// POST a JSON-RPC notification to the remote endpoint. Expects
    /// 202 Accepted (or 200); the response body is not consumed.
    fn sendNotificationHttp(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) !void {
        if (os.is_windows) {
            return self.runHttpVoidWithTimeout(io, .notification, httpNotificationTask, .{ self, io, method, params_json });
        }
        return self.sendNotificationHttpUnbounded(io, method, params_json);
    }

    fn sendNotificationHttpUnbounded(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) !void {
        const url = switch (self.transport) {
            .sse => |t| t.url,
            .stdio => return error.NoHttpTransport,
        };

        try self.request_mutex.lock(io);
        defer self.request_mutex.unlock(io);

        const body = try transport.formatNotification(self.gpa, method, params_json);
        defer self.gpa.free(body);

        var client: std.http.Client = .{ .allocator = self.gpa, .io = io };
        defer client.deinit();

        // Owned session-id snapshot (#385) — same rationale as
        // sendRequestHttpUnbounded.
        const session_snapshot = self.snapshotSessionId(io, self.gpa);
        defer if (session_snapshot) |sid| self.gpa.free(sid);
        const extra_headers = try buildExtraHeadersWith(self.gpa, self.customHttpHeaders(), session_snapshot);
        defer self.gpa.free(extra_headers);
        var req = try client.request(.POST, try std.Uri.parse(url), .{
            .headers = .{ .content_type = .{ .override = http.content_type_json } },
            .extra_headers = extra_headers,
        });
        defer req.deinit();
        // Bound send + head reads so a stalled server fails fast.
        if (req.connection) |conn| self.applyHttpTimeout(conn);
        try writeBody(&req, body);

        var redirect_buffer: [http_redirect_buffer_bytes]u8 = undefined;
        const response = try req.receiveHead(&redirect_buffer);
        try self.captureSessionId(io, response.head);
        const status_code: u16 = @intFromEnum(response.head.status);
        if (status_code == 404) return error.McpSessionExpired;
        if (status_code >= 400) return error.McpHttpRequestFailed;
    }

    /// Build the extra request headers: the Streamable HTTP `Accept` header,
    /// `Mcp-Session-Id` once a session is established, and any custom headers
    /// configured for the server (e.g. API keys). Returned slice is owned; free
    /// with `gpa.free`.
    ///
    /// Reads `session_id`, so callers must hold `transport_mutex` — or use the
    /// `snapshotSessionId` + `buildExtraHeadersWith` pair (#385), which hands
    /// the request an owned dupe immune to a concurrent `terminateHttpSession`
    /// freeing the stored id.
    fn customHttpHeaders(self: *const McpClient) []const config_mod.McpHeader {
        return switch (self.transport) {
            .sse => |t| t.headers,
            .stdio => &.{},
        };
    }

    fn buildExtraHeaders(self: *const McpClient, gpa: std.mem.Allocator) ![]std.http.Header {
        return buildExtraHeadersWith(gpa, self.customHttpHeaders(), self.session_id);
    }

    /// Pure header builder behind `buildExtraHeaders`; `session_id` is passed
    /// in so a request can build headers from an owned snapshot instead of
    /// borrowing the live field (#385).
    fn buildExtraHeadersWith(gpa: std.mem.Allocator, custom: []const config_mod.McpHeader, session_id: ?[]const u8) ![]std.http.Header {
        const count = 1 + custom.len + (if (session_id != null) @as(usize, 1) else 0);
        const headers = try gpa.alloc(std.http.Header, count);
        var i: usize = 0;
        headers[i] = .{ .name = "Accept", .value = accept_streamable_http };
        i += 1;
        if (session_id) |sid| {
            headers[i] = .{ .name = "Mcp-Session-Id", .value = sid };
            i += 1;
        }
        for (custom) |h| {
            headers[i] = .{ .name = h.name, .value = h.value };
            i += 1;
        }
        return headers;
    }

    /// Owned copy of the live `session_id` under `transport_mutex` (#385), for
    /// request paths that hold `request_mutex` and must not borrow the field a
    /// concurrent `stop`→`terminateHttpSession` may free. null when there is
    /// no session or the lock is canceled (the request then fails loudly
    /// server-side rather than racing the free). Caller frees the result.
    fn snapshotSessionId(self: *McpClient, io: std.Io, gpa: std.mem.Allocator) ?[]u8 {
        self.transport_mutex.lock(io) catch return null;
        defer self.transport_mutex.unlock(io);
        const sid = self.session_id orelse return null;
        return gpa.dupe(u8, sid) catch {
            log.warn("MCP '{s}': OOM snapshotting session id; request goes out session-less", .{self.name});
            return null;
        };
    }

    /// Update `session_id` from the response's `Mcp-Session-Id` header (if
    /// present). Header values borrow the response head, so the value is duped.
    /// The free/dupe swap is guarded by `transport_mutex` (#385) — callers hold
    /// `request_mutex`, so the lock order stays `request_mutex →
    /// transport_mutex`.
    fn captureSessionId(self: *McpClient, io: std.Io, head: std.http.Client.Response.Head) !void {
        var it = head.iterateHeaders();
        while (it.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) continue;
            try self.transport_mutex.lock(io);
            defer self.transport_mutex.unlock(io);
            // Dupe BEFORE freeing the old value: on OOM the field keeps the
            // coherent old id instead of dangling at freed memory.
            const fresh = try self.gpa.dupe(u8, header.value);
            if (self.session_id) |old| self.gpa.free(old);
            self.session_id = fresh;
            return;
        }
    }

    /// Perform the MCP initialize handshake.
    /// On success, sets status to .connected, records latency, and captures
    /// the server's reported protocol version, serverInfo, and the
    /// `tools.listChanged` capability flag (for `notifications/tools/list_changed`
    /// subscription). Zay is a client only — it advertises no client
    /// capabilities (no sampling, no roots, no elicitation server-side).
    pub fn initialize(self: *McpClient, io: std.Io) !void {
        const start = std.Io.Timestamp.now(io, .awake);

        // Streamable HTTP requires protocol 2025-03-26+; stdio keeps the
        // original version so existing local servers are unaffected.
        const protocol_version: []const u8 = switch (self.transport) {
            .stdio => protocol_version_stdio,
            .sse => protocol_version_streamable_http,
        };
        const params = try std.fmt.allocPrint(self.gpa,
            \\{{"protocolVersion":"{s}","capabilities":{{}},"clientInfo":{{"name":"zay","version":"1.0"}}}}
        , .{protocol_version});
        defer self.gpa.free(params);

        const response = try self.sendRequest(io, "initialize", params);
        defer self.gpa.free(response);

        const parsed = try schema_mod.parseResponse(self.gpa, response) orelse {
            self.setError(io, "handshake returned no result", .{});
            return error.McpHandshakeFailed;
        };
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse {
            self.setError(io, "handshake result missing", .{});
            return error.McpHandshakeFailed;
        };
        if (result != .object) {
            self.setError(io, "handshake result not an object", .{});
            return error.McpHandshakeFailed;
        }
        const result_obj = result.object;

        // Negotiate protocol version — the server may echo or downgrade.
        // We accept whatever the server returns; no version pinning yet.
        if (result_obj.get("protocolVersion")) |pv| {
            if (pv == .string) {
                if (self.negotiated_protocol) |old| self.gpa.free(old);
                self.negotiated_protocol = self.gpa.dupe(u8, pv.string) catch null;
            }
        }

        // Capture server identity for diagnostics and TUI display.
        if (result_obj.get("serverInfo")) |si| {
            if (si == .object) {
                const sname = if (si.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                const sver = if (si.object.get("version")) |v| (if (v == .string) v.string else "") else "";
                if (self.server_info) |*old| old.deinit(self.gpa);
                self.server_info = .{
                    .name = self.gpa.dupe(u8, sname) catch "",
                    .version = self.gpa.dupe(u8, sver) catch "",
                };
            }
        }

        // Parse server capabilities — record `tools.listChanged` on the
        // discovery spoke so the App can subscribe to
        // `notifications/tools/list_changed` and re-discover.
        self.discovery.server_supports_tools_list_changed = false;
        if (result_obj.get("capabilities")) |caps| {
            if (caps == .object) {
                if (caps.object.get("tools")) |tools_cap| {
                    if (tools_cap == .object) {
                        if (tools_cap.object.get("listChanged")) |lc| {
                            if (lc == .bool) self.discovery.server_supports_tools_list_changed = lc.bool;
                        }
                    }
                }
            }
        }

        // Send initialized notification
        try self.sendNotification(io, "notifications/initialized", null);

        const end = std.Io.Timestamp.now(io, .awake);
        const elapsed_ns = start.durationTo(end).nanoseconds;
        self.latency_ms = @intCast(@max(elapsed_ns, 0) / std.time.ns_per_ms);
        // Mark the active transport as ready.
        switch (self.lifecycle) {
            .stdio => |*s| s.status = .ready,
            .sse => |*s| s.status = .ready,
            else => {},
        }
    }

    /// Query tools/list and REPLACE the client's tool list. On success the
    /// cache equals exactly the server's response — tools removed server-side
    /// disappear and re-discovery never duplicates records (the old append
    /// path inflated every count on `tools/list_changed`, #384 bug 2). On
    /// failure (request error, parse error, OOM) the previous list stays
    /// fully intact: the replacement is built first and swapped in only once
    /// every record is owned.
    pub fn listTools(self: *McpClient, io: std.Io) !void {
        const fresh = try self.listToolsFresh(io);
        self.discovery.replaceAll(fresh);
    }

    /// tools/list WITHOUT touching the discovery cache: returns freshly-built
    /// owned records for the caller to install via `Discovery.replaceAll` (the
    /// background re-discovery path, #385). A malformed response (no result
    /// object, `tools` not an array) errors instead of returning an empty list
    /// — installing empty would wipe the cache, so failure-keeps-old holds by
    /// construction. Thread-safety: runs on refresh worker threads,
    /// concurrent with in-flight tool calls (`request_mutex`) and with `stop`
    /// (`transport_mutex` capture bracket); never mutates shared state except
    /// the request-serialized fields and the atomic refresh flag.
    pub fn listToolsFresh(self: *McpClient, io: std.Io) !std.ArrayList(discovery_mod.McpTool) {
        const response = try self.sendRequest(io, "tools/list", null);
        defer self.gpa.free(response);

        const parsed = try schema_mod.parseResponse(self.gpa, response) orelse return error.McpInvalidToolsResponse;
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return error.McpInvalidToolsResponse;
        if (result != .object) return error.McpInvalidToolsResponse;

        const tools_val = result.object.get("tools") orelse return error.McpInvalidToolsResponse;
        if (tools_val != .array) return error.McpInvalidToolsResponse;

        var fresh: std.ArrayList(McpTool) = .empty;
        errdefer {
            for (fresh.items) |*tool| tool.deinit(self.gpa);
            fresh.deinit(self.gpa);
        }
        for (tools_val.array.items) |tool_val| {
            var record = try discovery_mod.toolRecordFromListEntry(self.gpa, self.name, tool_val) orelse continue;
            fresh.append(self.gpa, record) catch |err| {
                record.deinit(self.gpa);
                return err;
            };
        }
        return fresh;
    }

    /// Call a tool via `tools/call` JSON-RPC.
    /// Returns the text content from the tool response (owned, caller must free).
    /// JSON-RPC errors and `isError: true` both return the server's message
    /// as text (not a Zig error) so the model can read what went wrong.
    pub fn callTool(self: *McpClient, io: std.Io, tool_name: []const u8, arguments_json: []const u8) ![]u8 {
        // Build params JSON with proper escaping for tool_name
        var pw: std.Io.Writer.Allocating = .init(self.gpa);
        defer pw.deinit();
        try pw.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(tool_name, .{}, &pw.writer);
        try pw.writer.writeAll(",\"arguments\":");
        try pw.writer.writeAll(arguments_json);
        try pw.writer.writeAll("}");
        const params = try pw.toOwnedSlice();
        defer self.gpa.free(params);

        const response = try self.sendRequest(io, "tools/call", params);
        defer self.gpa.free(response);

        // Parse response inline to handle JSON-RPC errors with full context
        const trimmed = std.mem.trim(u8, response, " \t\r\n");
        if (trimmed.len == 0) return error.McpToolCallFailed;

        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, trimmed, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.McpToolCallFailed;
        const obj = parsed.value.object;

        // JSON-RPC error — return the server's error message as text
        if (obj.get("error")) |err_val| {
            if (err_val == .object) {
                const msg = if (err_val.object.get("message")) |m|
                    (if (m == .string) m.string else "unknown error")
                else
                    "unknown error";
                const code = if (err_val.object.get("code")) |c|
                    (if (c == .integer) c.integer else 0)
                else
                    0;
                log.warn("MCP tool '{s}' JSON-RPC error (code {d}): {s}", .{ tool_name, code, msg });
                return self.gpa.dupe(u8, msg);
            }
            return error.McpToolCallFailed;
        }

        const result = obj.get("result") orelse return error.McpToolCallFailed;
        if (result != .object) return error.McpToolCallFailed;

        // Log server-side errors but still return the text content so the
        // model can read the server's error description (per MCP spec).
        if (result.object.get("isError")) |is_err| {
            if (is_err == .bool and is_err.bool) {
                log.warn("MCP tool '{s}' returned isError: true", .{tool_name});
            }
        }

        return schema_mod.extractContentText(self.gpa, result);
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

fn httpTimeoutTask(io: std.Io, timeout_ms: u32) void {
    io.sleep(std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)), .awake) catch {};
}

fn httpRequestTask(
    self: *McpClient,
    io: std.Io,
    method: []const u8,
    params_json: ?[]const u8,
) HttpRequestOutcome {
    const response = self.sendRequestHttpUnbounded(io, method, params_json) catch |err| {
        return .{ .failure = err };
    };
    return .{ .response = response };
}

fn httpNotificationTask(
    self: *McpClient,
    io: std.Io,
    method: []const u8,
    params_json: ?[]const u8,
) HttpVoidOutcome {
    self.sendNotificationHttpUnbounded(io, method, params_json) catch |err| {
        return .{ .failure = err };
    };
    return .success;
}

fn httpTerminationTask(self: *McpClient, io: std.Io, session_id: []const u8) HttpVoidOutcome {
    self.terminateHttpSessionUnbounded(io, session_id);
    return .success;
}

fn stalledHttpOperation(io: std.Io) HttpVoidOutcome {
    io.sleep(std.Io.Duration.fromSeconds(30), .awake) catch |err| {
        return .{ .failure = err };
    };
    return .success;
}

/// Write the request `body` with an explicit content-length and flush it, so
/// the server receives a complete request before we read the response head.
fn writeBody(req: *std.http.Client.Request, body: []const u8) !void {
    req.transfer_encoding = .{ .content_length = body.len };
    var body_buffer: [http_body_buffer_bytes]u8 = undefined;
    var body_writer = try req.sendBodyUnflushed(&body_buffer);
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();
}

/// True when the response `Content-Type` is `text/event-stream` (an SSE
/// stream) rather than a single `application/json` body.
fn isEventStream(head: std.http.Client.Response.Head) bool {
    const content_type = head.content_type orelse return false;
    return std.mem.indexOf(u8, content_type, http.media_type_event_stream) != null;
}

/// Read a single `application/json` response body, honouring content-encoding
/// (mirrors `modelsdev.fetchApiJson`: Cloudflare-style hosts may gzip it).
/// Returns the owned body; caller frees.
fn readJsonBody(gpa: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
    var empty_decompress_buffer: [0]u8 = .{};
    var decompress_buffer: []u8 = &empty_decompress_buffer;
    var decompress_buffer_owned = false;
    switch (response.head.content_encoding) {
        .identity => {},
        .zstd => {
            decompress_buffer = try gpa.alloc(u8, std.compress.zstd.default_window_len);
            decompress_buffer_owned = true;
        },
        .deflate, .gzip => {
            decompress_buffer = try gpa.alloc(u8, std.compress.flate.max_window_len);
            decompress_buffer_owned = true;
        },
        .compress => return error.UnsupportedCompressionMethod,
    }
    defer if (decompress_buffer_owned) gpa.free(decompress_buffer);

    var transfer_buffer: [http_transfer_buffer_bytes]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    return reader.allocRemaining(gpa, .limited(http_response_bytes_max)) catch |err| switch (err) {
        error.StreamTooLong => error.McpResponseTooLarge,
        else => |e| e,
    };
}

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

test "McpClient startStdio + stop lifecycle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Spawn a simple echo server that reads one line and echoes it back.
    var client = try initMockClient(gpa, "stdio-test", "hang");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    try std.testing.expect(client.lifecycle == .stdio);
    try std.testing.expectEqual(ServerStatus.connecting, client.status());
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

test "McpClient full handshake + tools/list" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try initMockClient(gpa, "mock-server", "default");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    // Handshake
    try client.initialize(io);
    try std.testing.expectEqual(ServerStatus.connected, client.status());

    // Capability negotiation — server reported serverInfo + protocolVersion
    // and `capabilities.tools` without the listChanged flag.
    try std.testing.expect(client.server_info != null);
    try std.testing.expectEqualStrings("mock", client.server_info.?.name);
    try std.testing.expectEqualStrings("1.0", client.server_info.?.version);
    try std.testing.expect(client.negotiated_protocol != null);
    try std.testing.expectEqualStrings("2024-11-05", client.negotiated_protocol.?);
    try std.testing.expectEqual(false, client.discovery.server_supports_tools_list_changed);

    // Tool discovery
    try client.listTools(io);
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    try std.testing.expectEqualStrings("mcp__mock-server__greet", client.discovery.tools.items[0].full_name);
    try std.testing.expectEqualStrings("greet", client.discovery.tools.items[0].name);
    try std.testing.expectEqualStrings("Say hello", client.discovery.tools.items[0].description);
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items[0].schema.properties.len);
    try std.testing.expectEqualStrings("name", client.discovery.tools.items[0].schema.properties[0].name);
    try std.testing.expectEqual(tools_common.Schema.Kind.string, client.discovery.tools.items[0].schema.properties[0].kind);
    try std.testing.expect(client.discovery.tools.items[0].schema.properties[0].required);
}

test "McpClient listTools preserves the raw inputSchema of a rich schema" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try initMockClient(gpa, "rich-server", "rich_schema");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    try client.initialize(io);
    try client.listTools(io);

    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    const tool = client.discovery.tools.items[0];
    const raw = tool.raw_input_schema orelse return error.RawSchemaMissing;

    // Every construct the projection drops survives the raw capture.
    for ([_][]const u8{ "$defs", "$ref", "prefixItems", "allOf", "oneOf", "anyOf", "\"not\"", "pattern", "minimum", "maxItems", "\"const\"", "exclusiveMaximum" }) |construct| {
        try std.testing.expect(std.mem.indexOf(u8, raw, construct) != null);
    }

    // The raw capture is valid JSON — provider pass-through writes it verbatim.
    const round_tripped = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer round_tripped.deinit();
    try std.testing.expect(round_tripped.value == .object);

    // The projection is still built alongside it and stays lossy-by-design:
    // a $ref property projects to an unconstrained string, never a claim
    // about the referenced shape.
    const filter_property = tool.schema.properties[0];
    try std.testing.expectEqualStrings("filter", filter_property.name);
    try std.testing.expectEqual(tools_common.Schema.Kind.string, filter_property.kind);
    try std.testing.expect(filter_property.kind_unconstrained);
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

test "McpClient initialize captures tools.listChanged capability" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try initMockClient(gpa, "changeful", "list_changed");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    try client.initialize(io);
    try std.testing.expectEqual(ServerStatus.connected, client.status());
    try std.testing.expect(client.discovery.server_supports_tools_list_changed);
    try std.testing.expectEqualStrings("changeful", client.server_info.?.name);
    try std.testing.expectEqualStrings("2.0", client.server_info.?.version);
}

test "McpClient callTool round-trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try initMockClient(gpa, "mock-server", "default");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    // Handshake + discovery
    try client.initialize(io);
    try client.listTools(io);
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);

    // Call the tool
    const result = try client.callTool(io, "greet", "{\"name\":\"World\"}");
    defer gpa.free(result);

    try std.testing.expectEqualStrings("Hello, World!", result);
}

// ---------------------------------------------------------------------------
// Streamable HTTP transport tests
// ---------------------------------------------------------------------------

test "buildExtraHeaders sends Accept, session id, and custom headers" {
    const gpa = std.testing.allocator;
    var client = try McpClient.initSse(gpa, "x", "http://x/mcp");
    defer client.deinit(std.testing.io);

    // No session, no custom headers → only Accept.
    {
        const headers = try client.buildExtraHeaders(gpa);
        defer gpa.free(headers);
        try std.testing.expectEqual(@as(usize, 1), headers.len);
        try std.testing.expectEqualStrings("Accept", headers[0].name);
        try std.testing.expectEqualStrings("application/json, text/event-stream", headers[0].value);
    }

    // With a session → Accept + Mcp-Session-Id.
    client.session_id = try gpa.dupe(u8, "sess-1");
    {
        const headers = try client.buildExtraHeaders(gpa);
        defer gpa.free(headers);
        try std.testing.expectEqual(@as(usize, 2), headers.len);
        try std.testing.expectEqualStrings("Mcp-Session-Id", headers[1].name);
        try std.testing.expectEqualStrings("sess-1", headers[1].value);
    }

    // With a custom header → Accept + Mcp-Session-Id + custom (e.g. an API key).
    client.transport.sse.headers = try config_mod.cloneHeaders(gpa, &[_]config_mod.McpHeader{
        .{ .name = @constCast("CONTEXT7_API_KEY"), .value = @constCast("secret") },
    });
    {
        const headers = try client.buildExtraHeaders(gpa);
        defer gpa.free(headers);
        try std.testing.expectEqual(@as(usize, 3), headers.len);
        try std.testing.expectEqualStrings("CONTEXT7_API_KEY", headers[2].name);
        try std.testing.expectEqualStrings("secret", headers[2].value);
    }
}

test "captureSessionId + isEventStream read the response head" {
    const gpa = std.testing.allocator;
    var client = try McpClient.initSse(gpa, "x", "http://x/mcp");
    defer client.deinit(std.testing.io);

    const json_head = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nMcp-Session-Id: sess-42\r\n\r\n",
    );
    try client.captureSessionId(std.testing.io, json_head);
    try std.testing.expectEqualStrings("sess-42", client.session_id.?);
    try std.testing.expect(!isEventStream(json_head));

    const sse_head = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n",
    );
    try std.testing.expect(isEventStream(sse_head));
}

test "httpTimeoutParts derives timeval sec/usec from read_timeout_ms" {
    // The per-server `requestTimeoutMs` knob flows into `read_timeout_ms` and
    // feeds `applyHttpTimeout`'s socket timeval. Exact multiples land on zero
    // usec; non-multiples carry the sub-second remainder.
    const whole = McpClient.httpTimeoutParts(5000);
    try std.testing.expectEqual(@as(i64, 5), whole.sec);
    try std.testing.expectEqual(@as(i64, 0), whole.usec);

    const partial = McpClient.httpTimeoutParts(1500);
    try std.testing.expectEqual(@as(i64, 1), partial.sec);
    try std.testing.expectEqual(@as(i64, 500_000), partial.usec);

    // Sub-second values produce zero sec and the sub-second remainder in usec.
    const sub_second = McpClient.httpTimeoutParts(250);
    try std.testing.expectEqual(@as(i64, 0), sub_second.sec);
    try std.testing.expectEqual(@as(i64, 250_000), sub_second.usec);
}

test "Windows HTTP timeout cancels a stalled operation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try McpClient.initSse(gpa, "timeout-test", "http://127.0.0.1/mcp");
    defer client.deinit(io);
    client.read_timeout_ms = 10;

    try std.testing.expectError(
        error.Timeout,
        client.runHttpVoidWithTimeout(io, .notification, stalledHttpOperation, .{io}),
    );
}

// ---------------------------------------------------------------------------
// Discovery-cache and failure-path invariants (#384)
// ---------------------------------------------------------------------------

test "McpClient listTools replaces the cache instead of appending" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try initMockClient(gpa, "rediscover", "default");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    try client.initialize(io);

    // Prime the cache with a record a previous discovery left behind and the
    // server has since removed. Re-discovery REPLACES the cache: the result
    // must be exactly the server's catalog, never the union of both lists
    // (the old append path grew the list on every `tools/list_changed`).
    try client.addTool("stale", "Removed server-side", .{ .properties = &.{} }, null);
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);

    try client.listTools(io);
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    try std.testing.expectEqualStrings("greet", client.discovery.tools.items[0].name);
    try std.testing.expectEqualStrings("mcp__rediscover__greet", client.discovery.tools.items[0].full_name);

    // The list_changed path re-runs listTools on the same client — a second
    // discovery must keep the count at the server's catalog size, with
    // unique names (no duplicates).
    try client.listTools(io);
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    try std.testing.expectEqualStrings("greet", client.discovery.tools.items[0].name);
}

test "McpClient keeps the previous tool list when re-discovery fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // malformed_tools: the discovery response is not JSON, so listTools
    // fails (or finds no result) after the request itself round-trips.
    var client = try initMockClient(gpa, "broken-list", "malformed_tools");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    try client.initialize(io);

    // Prime via the registration seam, as an earlier successful discovery
    // would have: exactly one record, which the failed refresh must leave
    // fully intact — a failed re-discovery never empties the cache.
    try client.addTool("kept", "Survives the failed refresh", .{ .properties = &.{} }, null);

    if (client.listTools(io)) |_| {
        // parseResponse may also reject the line as a null result — a void
        // success. Both outcomes must leave the cache untouched.
    } else |_| {}

    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    try std.testing.expectEqualStrings("kept", client.discovery.tools.items[0].name);
    try std.testing.expectEqualStrings("mcp__broken-list__kept", client.discovery.tools.items[0].full_name);
    try std.testing.expectEqual(ServerStatus.connected, client.status());
}

test "McpClient setError stops a live stdio transport before failing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // hang mode: the child never exits on its own until it is stopped, so
    // the process-death probe below can only pass if setError actually
    // terminated it.
    var client = try initMockClient(gpa, "leaky", "hang");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    // Prime the cache, as a completed discovery would have.
    try client.addTool("cached", "Discovered before the failure", .{ .properties = &.{} }, null);

    // Watch the child while the client still owns it — the watch survives
    // the client closing its own process handle.
    var watch: ?os.ChildExitWatch = os.ChildExitWatch.init(&client.lifecycle.stdio.process);
    defer if (watch) |*w| w.deinit();
    if (os.ChildExitWatch.supported) try std.testing.expect(watch != null);

    const started = std.Io.Timestamp.now(io, .awake);
    client.setError(io, "handshake exploded", .{});
    const elapsed_ns = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;

    // The stop-first teardown (pipe close, terminate, bounded reap) must
    // stay bounded — an unbounded wait would wedge TUI teardown.
    try std.testing.expect(elapsed_ns < 5 * std.time.ns_per_s);

    try std.testing.expectEqual(ServerStatus.failed, client.status());
    switch (client.lifecycle) {
        .failed => |f| try std.testing.expectEqualStrings("handshake exploded", f.reason),
        else => return error.UnexpectedLifecycle,
    }
    // The transport's discovery cache went down with it — a failed lifecycle
    // never carries tools.
    try std.testing.expectEqual(@as(usize, 0), client.discovery.tools.items.len);

    // The orphan half of the bug: the process must actually be gone, not
    // merely dropped from the lifecycle union.
    if (watch) |*w| try std.testing.expect(w.awaitExit(io, 2_000));
}

// ---------------------------------------------------------------------------
// Transport-lifetime races + background re-discovery (#385)
// ---------------------------------------------------------------------------

test "McpClient listToolsFresh returns owned records and never touches the cache" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // default mode: the discovery response round-trips normally.
    var client = try initMockClient(gpa, "fresh", "default");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);
    try client.initialize(io);

    // Prime the cache as a completed discovery would have; listToolsFresh
    // must leave it untouched — the caller owns installation.
    try client.addTool("cached", "Primed before the fetch", .{ .properties = &.{} }, null);

    var fresh = try client.listToolsFresh(io);
    defer {
        for (fresh.items) |*tool| tool.deinit(gpa);
        fresh.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), fresh.items.len);
    try std.testing.expectEqualStrings("greet", fresh.items[0].name);
    // The cache still holds exactly the primed record.
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    try std.testing.expectEqualStrings("cached", client.discovery.tools.items[0].name);
}

test "McpClient listToolsFresh errors on a malformed response and keeps the cache" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try initMockClient(gpa, "broken-fresh", "malformed_tools");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);
    try client.initialize(io);
    try client.addTool("kept", "Survives the failed fetch", .{ .properties = &.{} }, null);

    // A malformed tools/list response must error — never return an empty
    // list, which the installer would swap in and wipe the cache. The error
    // identity depends on where parsing rejects the line (SyntaxError from
    // the JSON scanner, McpInvalidToolsResponse from the shape checks) —
    // either keeps the cache intact.
    if (client.listToolsFresh(io)) |_| return error.ExpectedError else |_| {}
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    try std.testing.expectEqualStrings("kept", client.discovery.tools.items[0].name);
}

test "snapshotSessionId dupes under transport_mutex and buildExtraHeadersWith keeps the header set" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var client = try McpClient.initSse(gpa, "x", "http://x/mcp");
    defer client.deinit(io);

    // No session yet.
    try std.testing.expect(client.snapshotSessionId(io, gpa) == null);

    client.session_id = try gpa.dupe(u8, "sess-42");
    const snapshot = client.snapshotSessionId(io, gpa) orelse return error.SnapshotFailed;
    defer gpa.free(snapshot);
    try std.testing.expectEqualStrings("sess-42", snapshot);
    // The snapshot is owned — freeing the original leaves it readable.
    gpa.free(client.session_id.?);
    client.session_id = null;
    try std.testing.expectEqualStrings("sess-42", snapshot);

    // The pure builder produces the identical header set for the same input.
    const headers = try McpClient.buildExtraHeadersWith(gpa, &.{}, snapshot);
    defer gpa.free(headers);
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("Accept", headers[0].name);
    try std.testing.expectEqualStrings("Mcp-Session-Id", headers[1].name);
    try std.testing.expectEqualStrings("sess-42", headers[1].value);
}
