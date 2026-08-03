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
//! One request is in flight at a time. Contention is bounded by the 4-lane
//! cap and by the requester guard (only the primary lane spawns/enters/
//! merges; other lanes only `list`/`read`), so a second lane's call simply
//! waits for the first to resolve.

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
    pending: ?*Request = null,
    response: ?Response = null,

    /// Worker-side: post a request and block until the UI resolves it.
    /// Returns `error.Canceled` when the owning future is cancelled (turn
    /// interrupt / app teardown) — the condition wait errors because the
    /// cancel aborts the blocking read. The caller frees the request.
    pub fn request(self: *LaneBridge, io: std.Io, req: *Request) error{Canceled}!Response {
        self.mutex.lock(io) catch return error.Canceled;
        defer self.mutex.unlock(io);
        std.debug.assert(self.pending == null);
        self.pending = req;
        while (self.response == null) {
            self.condition.wait(io, &self.mutex) catch {
                self.pending = null;
                return error.Canceled;
            };
        }
        const resp = self.response.?;
        self.response = null;
        self.pending = null;
        return resp;
    }

    /// UI-side: if a request is in flight, build a response and wake the
    /// worker. `handler` runs with the bridge lock held and returns null
    /// while the request is still pending (e.g. `await` polling a running
    /// lane) — in that case the request stays in flight for the next tick.
    pub fn service(
        self: *LaneBridge,
        io: std.Io,
        ctx: *anyopaque,
        handler: *const fn (*anyopaque, *const Request) ?Response,
    ) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        const req = self.pending orelse return;
        const resp = handler(ctx, req) orelse return;
        self.response = resp;
        self.pending = null;
        self.condition.signal(io);
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
    try std.testing.expect(bridge.response == null);
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
