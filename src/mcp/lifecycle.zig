//! MCP client lifecycle spoke, extracted from mcp/client.zig (issue #367
//! slice 11). Owns process/session lifetime: the stdio child spawn and its
//! bounded Windows teardown, the Streamable HTTP session termination, the
//! transport constructors and connect-clone, and the #385 transport-lifetime
//! bracket (`captureStdioTransport`/`releaseStdioTransport` + parked pipes).
//!
//! The `McpClient` TYPE and all of its state stay in client.zig; this file
//! imports client.zig only for the type (plus `zeroedChild`, the test
//! fixture, and `ServerStatus` via the type). Spoke pattern
//! (mcp/wire.zig, agent/queue_ops.zig): free functions over `*McpClient`;
//! mutual import terminates at the type level; client.zig keeps
//! unchanged-signature method delegates for the externally-called surface.
//! Log scope stays `.mcp`, identical to client.zig.
//!
//! Lock discipline (unchanged, see the field docs on `transport_mutex`):
//! `stop`/`markConnecting`/`adoptFailure`/`terminateHttpSession` take
//! `transport_mutex` alone and never `request_mutex`; the capture bracket
//! holds it only across the handle snapshot; the in-flight counter is atomic
//! so a canceled lock can never strand the deferred pipe close.

const std = @import("std");
const config_mod = @import("../config/config.zig");
const os = @import("../os.zig");
const discovery_mod = @import("discovery.zig");
const wire = @import("wire.zig");
const client_mod = @import("client.zig");

const McpClient = client_mod.McpClient;
const ServerStatus = client_mod.ServerStatus;
const assert = std.debug.assert;

/// Same `.mcp` scope as client.zig so log output is unchanged by the move.
const log = std.log.scoped(.mcp);

const windows_child_stop_wait_ms = 1_000;

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
    clone.read_timeout_ms = self.read_timeout_ms;
    clone.generation = self.generation;
    markConnecting(&clone, io);
    assert(clone.discovery.tools.items.len == 0);
    assert(!clone.discovery.pending_refresh.load(.acquire));
    return clone;
}

/// Map the lifecycle union to the public `ServerStatus` enum. The
/// union is the canonical state; this is the legacy API surface
/// for callers (manager, TUI) that read the status field.
pub fn statusOf(self: *const McpClient) ServerStatus {
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
        parkStdioPipes(self, io);
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
    if (self.transport == .sse) terminateHttpSession(self, io);
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
    if (self.in_flight_requests.load(.acquire) == 0) closePendingPipesLocked(self, io);
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
pub const StdioPipes = struct { stdin: std.Io.File, stdout: std.Io.File };

pub fn captureStdioTransport(self: *McpClient, io: std.Io) !StdioPipes {
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
    closePendingPipesLocked(self, io);
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
        wire.runHttpVoidWithTimeout(self, io, .termination, wire.httpTerminationTask, .{ self, io, sid }) catch |err| {
            log.warn("MCP HTTP session termination failed err={s}", .{@errorName(err)});
        };
        return;
    }

    wire.terminateHttpSessionUnbounded(self, io, sid);
}

test "McpClient startStdio + stop lifecycle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Spawn a simple echo server that reads one line and echoes it back.
    var client = try client_mod.initMockClient(gpa, "stdio-test", "hang");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    try std.testing.expect(client.lifecycle == .stdio);
    try std.testing.expectEqual(ServerStatus.connecting, client.status());
}

test "McpClient setError stops a live stdio transport before failing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // hang mode: the child never exits on its own until it is stopped, so
    // the process-death probe below can only pass if setError actually
    // terminated it.
    var client = try client_mod.initMockClient(gpa, "leaky", "hang");
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
