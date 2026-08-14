//! LaneBridge — a request/response sync primitive between a `lane` tool call
//! running on a lane's worker thread and the UI (`App`) on the main thread.
//!
//! The `lane` tool (like every tool) executes inside `Agent.run` on the
//! worker thread, so it cannot touch App-owned state (threads, split, parked
//! lanes) directly. The bridge mirrors the `ApprovalGate` pattern in
//! `tui/agent_worker.zig`: the worker posts a `Request` and blocks on a
//! condition; the UI services it every tick and resolves it with a
//! `Response`. Layer-agnostic — the App is a consumer, not a dependency.
//!
//! Requests are tracked as an intrusive linked list: the driver's `spawn`
//! can be in flight while a spawned worker's `list`/`read` is serviced in
//! the same tick, so a single-slot primitive would clobber the earlier
//! request and leave its lane blocked forever.

const std = @import("std");

pub const Op = enum {
    list,
    create,
    enter,
    leave,
    merge,
    spawn,
    read,
    cancel,
    await,
    steer,
    delete,
};

/// A lane operation posted by a worker. String fields are owned by the
/// requesting worker (allocated with the tool's gpa) and freed via `deinit`
/// after the request resolves. `requester` is the opaque `*Agent` that
/// posted — the UI resolves it back to a lane for the role guard and the
/// completion routing.
pub const Request = struct {
    op: Op,
    purpose: ?[]const u8 = null,
    task: ?[]const u8 = null,
    lane: ?[]const u8 = null,
    steer: ?[]const u8 = null,
    requester: *anyopaque,
    /// Written by the UI's `service` when the handler resolves this request;
    /// the waiting worker wakes once it is non-null. Not part of the public
    /// request payload — the bridge uses it to hand back the response.
    response: ?Response = null,
    /// Intrusive in-flight-list link (the bridge tracks multiple concurrent
    /// requests — the driver plus its spawned workers share one bridge).
    next: ?*Request = null,

    pub fn deinit(self: *Request, gpa: std.mem.Allocator) void {
        if (self.purpose) |s| gpa.free(s);
        if (self.task) |s| gpa.free(s);
        if (self.lane) |s| gpa.free(s);
        if (self.steer) |s| gpa.free(s);
        self.* = undefined;
    }
};

/// The UI's answer to a lane operation.
///
/// Ownership: `text` is allocated by the UI (app.gpa) and freed by the tool
/// after it formats the model observation. `lane_id` and `path` are
/// **borrowed** slices into an open lane's worktree `path` string (owned by
/// that lane's `Thread`) — the tool never frees them, and for `enter` it
/// adopts `path` as the agent's workspace borrow.
pub const Response = struct {
    text: []u8,
    code: u8 = 0,
    lane_id: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

pub const LaneBridge = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    /// Head of the in-flight request list. More than one lane can be blocked
    /// at once (the driver spawning while a spawned worker calls `list`/`read`
    /// concurrently), so a single-slot primitive would clobber the earlier
    /// request and leave it blocked forever.
    pending: ?*Request = null,
    last: ?*Request = null,

    /// Worker-side: post a request and block until the UI resolves it.
    /// Returns `error.Canceled` when the owning future is cancelled (turn
    /// interrupt / app teardown) — the condition wait errors because the
    /// cancel aborts the blocking read. The caller frees the request.
    pub fn request(self: *LaneBridge, io: std.Io, req: *Request) error{Canceled}!Response {
        self.mutex.lock(io) catch return error.Canceled;
        defer self.mutex.unlock(io);
        // Append to the in-flight list; each request waits on its OWN
        // response field, so concurrent requesters never clobber each other.
        req.next = null;
        if (self.last) |tail| tail.next = req else self.pending = req;
        self.last = req;
        while (req.response == null) {
            self.condition.wait(io, &self.mutex) catch {
                _ = self.remove(req);
                return error.Canceled;
            };
        }
        const resp = req.response.?;
        _ = self.remove(req);
        return resp;
    }

    /// Unlink `req` from the in-flight list. Returns whether it was present
    /// (a cancelled wait can race a service that already resolved it).
    fn remove(self: *LaneBridge, req: *Request) bool {
        var prev: ?*Request = null;
        var cur = self.pending;
        while (cur) |c| {
            if (c == req) {
                if (prev) |p| p.next = c.next else self.pending = c.next;
                if (self.last == req) self.last = prev;
                c.next = null;
                return true;
            }
            prev = c;
            cur = c.next;
        }
        return false;
    }

    /// UI-side: resolve every request whose handler answers; leave the rest
    /// in flight (e.g. `await` polling a running lane) for the next tick.
    /// `handler` runs with the bridge lock held. Wakes all waiters after any
    /// resolution so a worker whose request was answered resumes immediately.
    pub fn service(
        self: *LaneBridge,
        io: std.Io,
        ctx: *anyopaque,
        handler: *const fn (*anyopaque, *const Request) ?Response,
    ) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        var resolved = false;
        var cur = self.pending;
        while (cur) |req| {
            const next = req.next; // snapshot before a possible unlink
            if (handler(ctx, req)) |resp| {
                req.response = resp;
                _ = self.remove(req);
                resolved = true;
            }
            cur = next;
        }
        if (resolved) self.condition.broadcast(io);
    }
};

/// Thread-local slot the executor sets around tool dispatch so the `lane`
/// tool can reach the live bridge and the `*Agent` that posted. Null bridge
/// = headless/tests — the tool reports "lanes unavailable".
pub const Slot = struct {
    bridge: ?*LaneBridge = null,
    requester: ?*anyopaque = null,
};
pub var lane_bridge_slot: Slot = .{};

/// Build a response with an owned text allocated from `gpa`. `lane_id` and
/// `path` are borrowed (see `Response`).
pub fn response(
    gpa: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
    lane_id: ?[]const u8,
    path: ?[]const u8,
) std.mem.Allocator.Error!Response {
    return .{
        .text = try std.fmt.allocPrint(gpa, fmt, args),
        .lane_id = lane_id,
        .path = path,
    };
}

/// Build a failure response with a non-zero code.
pub fn fail(
    gpa: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) std.mem.Allocator.Error!Response {
    return .{
        .text = try std.fmt.allocPrint(gpa, fmt, args),
        .code = 1,
    };
}

test "full request → service → response round-trip across threads" {
    const gpa = std.testing.allocator;
    var bridge: LaneBridge = .{};
    var result: Response = undefined;
    var req = Request{ .op = .list, .requester = undefined };
    defer req.deinit(gpa);

    const Handler = struct {
        fn handle(ctx: *anyopaque, req_in: *const Request) ?Response {
            _ = ctx;
            std.debug.assert(req_in.op == .list);
            return response(std.testing.allocator, "two lanes", .{}, null, null) catch unreachable;
        }
    };

    const Worker = struct {
        fn run(b: *LaneBridge, r: *Request, out: *Response) void {
            // The request must resolve here (the service below runs before the
            // join); a failure traps the test.
            out.* = b.request(std.testing.io, r) catch unreachable;
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &bridge, &req, &result });

    // Wait until the worker has posted and is blocked.
    var spins: u32 = 0;
    while (spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
        bridge.mutex.lock(std.testing.io) catch continue;
        const posted = bridge.pending != null;
        bridge.mutex.unlock(std.testing.io);
        if (posted) break;
    }
    try std.testing.expect(bridge.pending != null);

    bridge.service(std.testing.io, undefined, &Handler.handle);
    thread.join();
    try std.testing.expectEqualStrings("two lanes", result.text);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(bridge.pending == null);
    gpa.free(result.text);
}

test "service with a still-pending handler leaves the request in flight" {
    const gpa = std.testing.allocator;
    var bridge: LaneBridge = .{};

    const PendingHandler = struct {
        fn handle(_: *anyopaque, _: *const Request) ?Response {
            // `await` polls a running lane: null keeps the request pending.
            return null;
        }
    };

    // Pre-seed the request the way the worker would (service runs on the UI
    // thread; here we drive both sides on this thread for the state check).
    var req = Request{ .op = .await, .requester = undefined };
    defer req.deinit(gpa);
    bridge.mutex.lock(std.testing.io) catch unreachable;
    bridge.pending = &req;
    bridge.mutex.unlock(std.testing.io);

    bridge.service(std.testing.io, undefined, &PendingHandler.handle);
    try std.testing.expect(bridge.pending == &req);
    try std.testing.expect(req.response == null);
}

test "two concurrent requesters both resolve (multi-request collision regression)" {
    // The single-slot bridge originally asserted `pending == null`, but the
    // orchestration model puts the driver AND its spawned workers on the same
    // bridge — a worker's `lane list` racing the driver's next `lane spawn`
    // must not clobber the in-flight request. Both must resolve.
    const gpa = std.testing.allocator;
    var bridge: LaneBridge = .{};
    var result_a: Response = undefined;
    var result_b: Response = undefined;
    var req_a = Request{ .op = .list, .requester = undefined };
    var req_b = Request{ .op = .list, .requester = undefined };

    const Worker = struct {
        fn run(b: *LaneBridge, r: *Request, out: *Response, delay_ms: i64) void {
            if (delay_ms > 0) std.testing.io.sleep(.fromMilliseconds(delay_ms), .awake) catch {};
            out.* = b.request(std.testing.io, r) catch unreachable;
        }
    };
    const Ctx = struct { a: *Request, b: *Request };
    const Handler = struct {
        fn handle(ctx: *anyopaque, req: *const Request) ?Response {
            const c: *Ctx = @ptrCast(@alignCast(ctx));
            const tag = if (@intFromPtr(req) == @intFromPtr(c.a))
                "A"
            else if (@intFromPtr(req) == @intFromPtr(c.b))
                "B"
            else
                return null;
            return response(std.testing.allocator, "resp {s}", .{tag}, null, null) catch unreachable;
        }
    };
    var handler_ctx = Ctx{ .a = &req_a, .b = &req_b };

    const thread_a = try std.Thread.spawn(.{}, Worker.run, .{ &bridge, &req_a, &result_a, 0 });
    // Let A post first so both are in flight before the first service pass.
    var spins: u32 = 0;
    while (spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
        bridge.mutex.lock(std.testing.io) catch continue;
        const posted = bridge.pending != null;
        bridge.mutex.unlock(std.testing.io);
        if (posted) break;
    }
    try std.testing.expect(bridge.pending != null);
    const thread_b = try std.Thread.spawn(.{}, Worker.run, .{ &bridge, &req_b, &result_b, 10 });

    // Service until both requests carry a response.
    var spins2: u32 = 0;
    while (spins2 < 100_000) : (spins2 += 1) {
        bridge.service(std.testing.io, &handler_ctx, &Handler.handle);
        bridge.mutex.lock(std.testing.io) catch continue;
        const done = req_a.response != null and req_b.response != null;
        bridge.mutex.unlock(std.testing.io);
        if (done) break;
        std.testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
    }
    thread_a.join();
    thread_b.join();
    defer gpa.free(result_a.text);
    defer gpa.free(result_b.text);
    try std.testing.expectEqualStrings("resp A", result_a.text);
    try std.testing.expectEqualStrings("resp B", result_b.text);
}

test "request with an owned lane field frees cleanly" {
    const gpa = std.testing.allocator;
    var req = Request{
        .op = .enter,
        .lane = try gpa.dupe(u8, "abc123"),
        .requester = undefined,
    };
    try std.testing.expectEqualStrings("abc123", req.lane.?);
    req.deinit(gpa);
}

test "request yields Canceled when the waiting task is cancelled" {
    const gpa = std.testing.allocator;
    var bridge: LaneBridge = .{};
    var req = Request{ .op = .list, .requester = undefined };
    defer req.deinit(gpa);

    const Worker = struct {
        fn run(b: *LaneBridge, r: *Request, got_cancel: *std.atomic.Value(bool)) void {
            _ = b.request(std.testing.io, r) catch |err| {
                if (err == error.Canceled) got_cancel.store(true, .release);
                return;
            };
            // A response here would mean the cancel did not reach the wait.
            std.debug.panic("request resolved instead of cancelling", .{});
        }
    };
    var got_cancel: std.atomic.Value(bool) = .init(false);
    var future = try std.testing.io.concurrent(Worker.run, .{ &bridge, &req, &got_cancel });

    // Wait until the worker has posted and is blocked on the condition.
    var spins: u32 = 0;
    while (spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
        bridge.mutex.lock(std.testing.io) catch continue;
        const posted = bridge.pending != null;
        bridge.mutex.unlock(std.testing.io);
        if (posted) break;
    }
    try std.testing.expect(bridge.pending != null);

    // Cancel aborts the condition wait — same contract as the turn-interrupt
    // and app-teardown paths.
    _ = future.cancel(std.testing.io);
    try std.testing.expect(got_cancel.load(.acquire));
    try std.testing.expect(bridge.pending == null); // the wait dropped it
}
