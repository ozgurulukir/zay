//! BackgroundManager — runs long-lived bash commands (`run_in_background`) off
//! the turn loop so the agent is not blocked. Each job streams its merged
//! stdout/stderr to a stable log file (so the model can `tail` it), keeps a
//! bounded in-memory tail for the completion notice, and runs its own reader
//! thread that waits for exit.
//!
//! Threading: the manager is reachable from the UI thread (poll/cancel/shutdown)
//! and owns one reader `std.Thread` per job. The reader only touches its own
//! `Job` (via atomics for the bits the UI reads) and the log file — never the
//! agent or the session — so the only shared state is the job list, guarded by a
//! plain mutex. Delivery back to the agent is pull-based: the UI drains finished
//! jobs each tick (see `takeFinished`) and enqueues the notice itself, keeping
//! all agent/history mutation on the UI/worker threads.
//!
//! Lifecycle: a clean exit calls `shutdownAll` (terminate + join). On Windows the
//! per-job Job Object additionally carries KILL_ON_JOB_CLOSE, so an unexpected
//! Nova exit (panic/kill) still tears down the whole process tree when our last
//! handle closes.

const std = @import("std");

const bash = @import("bash.zig");
const os = @import("os.zig");

const assert = std.debug.assert;

/// Bounded in-memory tail kept per job for the completion notice. The full
/// output always lives in the log file; this is only what the model sees inline.
const tail_bytes_max: usize = 8 * 1024;
const read_reserve: usize = 64 * 1024;

pub const BackgroundManager = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Guards the job list and the per-job display fields. A spinlock (matching
    /// the agent's queue mutex) — every critical section is short and takes no
    /// I/O, and the reader threads never acquire it, so a `join` under the lock
    /// can't deadlock.
    mutex: std.atomic.Mutex = .unlocked,
    next_id: u32 = 1,
    jobs: std.ArrayList(*Job) = .empty,

    pub const StartOptions = struct {
        command: []const u8,
        cwd: []const u8,
        env_map: *const std.process.Environ.Map,
        /// Opaque token (the owning `*Agent`) handed back at completion so the UI
        /// routes the delivery to the right lane. The manager never derefs it.
        owner: *anyopaque,
    };

    /// What the bash tool needs to tell the model after a launch. Owned by the
    /// caller; free with `deinit`.
    pub const StartResult = struct {
        label: []u8,
        pid: i64,
        log_path: []u8,

        pub fn deinit(self: *StartResult, gpa: std.mem.Allocator) void {
            gpa.free(self.label);
            gpa.free(self.log_path);
            self.* = undefined;
        }
    };

    /// A read-only snapshot of one running job for the TUI modal. Owned by the
    /// caller; free the slice with `freeViews`.
    pub const JobView = struct {
        id: u32,
        label: []u8,
        command: []u8,
        elapsed_seconds: u64,
    };

    /// A finished job handed to the UI. `completion_message` is the model-facing
    /// notice (null when the job was killed by the user/shutdown — those are
    /// surfaced in the transcript but not delivered to the model). Owned by the
    /// caller; free with `deinit`.
    pub const Finished = struct {
        id: u32,
        label: []u8,
        command: []u8,
        exit_code: u8,
        killed: bool,
        completion_message: ?[]u8,
        owner: *anyopaque,

        pub fn deinit(self: *Finished, gpa: std.mem.Allocator) void {
            gpa.free(self.label);
            gpa.free(self.command);
            if (self.completion_message) |m| gpa.free(m);
            self.* = undefined;
        }
    };

    const State = enum(u8) { running, finished };

    const Job = struct {
        manager: *BackgroundManager,
        id: u32,
        label: []u8,
        command: []u8,
        cwd: []u8,
        log_path: []u8,
        pid: i64,
        owner: *anyopaque,
        started: std.Io.Timestamp,
        child: std.process.Child,
        log_file: std.Io.File,
        kill_handle: KillHandle,
        tail: std.ArrayList(u8) = .empty,
        thread: ?std.Thread = null,
        state: std.atomic.Value(State) = .init(.running),
        killed: std.atomic.Value(bool) = .init(false),
        exit_code: u8 = 0,
        completion_message: ?[]u8 = null,
        reported: bool = false,
    };

    pub fn init(io: std.Io, gpa: std.mem.Allocator) BackgroundManager {
        return .{ .io = io, .gpa = gpa };
    }

    fn lockMutex(self: *BackgroundManager) void {
        while (!self.mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    /// Spawn `opts.command` under bash with stderr merged into stdout, streaming
    /// to a fresh log file, and start its reader thread. Returns immediately.
    pub fn start(self: *BackgroundManager, opts: StartOptions) !StartResult {
        const gpa = self.gpa;
        const io = self.io;

        self.lockMutex();
        const id = self.next_id;
        self.next_id += 1;
        self.mutex.unlock();

        const label = try std.fmt.allocPrint(gpa, "bg_{d}", .{id});
        errdefer gpa.free(label);
        const log_name = try std.fmt.allocPrint(gpa, "nova-{s}.log", .{label});
        defer gpa.free(log_name);
        const log_path = try bash.namedTempPath(gpa, log_name);
        errdefer gpa.free(log_path);

        var log_file = try std.Io.Dir.createFile(.cwd(), io, log_path, .{});
        errdefer log_file.close(io);

        // Merge stderr into stdout so the log preserves chronological order, like
        // the foreground capture path. The shell is non-login (see bash.zig).
        const merged = try std.fmt.allocPrint(gpa, "exec 2>&1\n{s}", .{opts.command});
        defer gpa.free(merged);

        var child = try std.process.spawn(io, .{
            .argv = &.{ bash.shellPath(io), "-c", merged },
            .cwd = .{ .path = opts.cwd },
            .environ_map = opts.env_map,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        // From here a failure must also tear down the spawned child.
        errdefer child.kill(io);

        const kill_handle = KillHandle.make(child);
        const pid = processId(child);

        const command_owned = try gpa.dupe(u8, opts.command);
        errdefer gpa.free(command_owned);
        const cwd_owned = try gpa.dupe(u8, opts.cwd);
        errdefer gpa.free(cwd_owned);

        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        job.* = .{
            .manager = self,
            .id = id,
            .label = label,
            .command = command_owned,
            .cwd = cwd_owned,
            .log_path = log_path,
            .pid = pid,
            .owner = opts.owner,
            .started = std.Io.Timestamp.now(io, .awake),
            .child = child,
            .log_file = log_file,
            .kill_handle = kill_handle,
        };

        const result: StartResult = .{
            .label = try gpa.dupe(u8, label),
            .pid = pid,
            .log_path = try gpa.dupe(u8, log_path),
        };
        errdefer {
            var r = result;
            r.deinit(gpa);
        }

        self.lockMutex();
        try self.jobs.append(gpa, job);
        self.mutex.unlock();
        errdefer {
            self.lockMutex();
            _ = removeJobPtr(&self.jobs, job);
            self.mutex.unlock();
        }

        // Spawn the reader last: once it owns the child/log it must run to
        // completion, so nothing above may fail after this point. Publish the
        // handle under the mutex so `takeFinished` (which reads `job.thread`
        // under the same lock) never races this write; until it lands the job
        // reads as running, and a job that finishes first is deferred a poll.
        const thread = try std.Thread.spawn(.{}, runReader, .{job});
        self.lockMutex();
        job.thread = thread;
        self.mutex.unlock();
        return result;
    }

    /// Body of a job's reader thread: stream output to the log + tail until EOF,
    /// reap the child, build the completion notice, and flip the job to finished.
    fn runReader(job: *Job) void {
        const io = job.manager.io;
        const gpa = job.manager.gpa;

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(1) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{job.child.stdout.?});
        defer multi_reader.deinit();
        const reader = multi_reader.reader(0);

        while (multi_reader.fill(read_reserve, .none)) |_| {
            const chunk = reader.buffered();
            if (chunk.len == 0) continue;
            job.log_file.writeStreamingAll(io, chunk) catch {};
            appendTail(job, gpa, chunk);
            reader.tossBuffered();
        } else |_| {}

        const term = job.child.wait(io) catch std.process.Child.Term{ .unknown = 0 };
        job.log_file.close(io);
        job.exit_code = termCode(term);

        // A user/shutdown kill is surfaced in the UI only — don't wake the model
        // with output it didn't ask to wait for.
        if (!job.killed.load(.acquire)) {
            job.completion_message = buildCompletionMessage(job, gpa) catch null;
        }
        job.state.store(.finished, .release);
    }

    /// Keep `job.tail` to the last `tail_bytes_max` bytes, trimming on a UTF-8
    /// boundary so the inline notice never splits a codepoint.
    fn appendTail(job: *Job, gpa: std.mem.Allocator, chunk: []const u8) void {
        job.tail.appendSlice(gpa, chunk) catch return;
        if (job.tail.items.len <= tail_bytes_max * 2) return;
        var trim_start = job.tail.items.len - tail_bytes_max;
        while (trim_start < job.tail.items.len and (job.tail.items[trim_start] & 0xC0) == 0x80) trim_start += 1;
        const kept = job.tail.items.len - trim_start;
        std.mem.copyForwards(u8, job.tail.items[0..kept], job.tail.items[trim_start..]);
        job.tail.shrinkRetainingCapacity(kept);
    }

    fn buildCompletionMessage(job: *Job, gpa: std.mem.Allocator) ![]u8 {
        const now = std.Io.Timestamp.now(job.manager.io, .awake);
        const elapsed_ns: i128 = job.started.durationTo(now).nanoseconds;
        const secs: u64 = @intCast(@max(elapsed_ns, 0) / std.time.ns_per_s);
        var elapsed_buf: [32]u8 = undefined;
        const elapsed = formatElapsed(&elapsed_buf, secs);

        const tail = std.mem.trimEnd(u8, job.tail.items, "\n");
        const body = if (tail.len == 0) "(no output)" else tail;
        return std.fmt.allocPrint(
            gpa,
            "Background command {s} (`{s}`) finished after {s} with exit code {d}.\n\n" ++
                "{s}\n\n[Full log: {s}]",
            .{ job.label, job.command, elapsed, job.exit_code, body, job.log_path },
        );
    }

    /// Snapshot the running jobs for the TUI modal (oldest first). Free with
    /// `freeViews`.
    pub fn snapshot(self: *BackgroundManager, gpa: std.mem.Allocator) ![]JobView {
        self.lockMutex();
        defer self.mutex.unlock();
        const now = std.Io.Timestamp.now(self.io, .awake);
        var out: std.ArrayList(JobView) = .empty;
        errdefer freeViewsList(&out, gpa);
        for (self.jobs.items) |job| {
            if (job.state.load(.acquire) != .running) continue;
            const elapsed_ns: i128 = job.started.durationTo(now).nanoseconds;
            try out.append(gpa, .{
                .id = job.id,
                .label = try gpa.dupe(u8, job.label),
                .command = try gpa.dupe(u8, job.command),
                .elapsed_seconds = @intCast(@max(elapsed_ns, 0) / std.time.ns_per_s),
            });
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn freeViews(gpa: std.mem.Allocator, views: []JobView) void {
        for (views) |*view| {
            gpa.free(view.label);
            gpa.free(view.command);
        }
        gpa.free(views);
    }

    fn freeViewsList(list: *std.ArrayList(JobView), gpa: std.mem.Allocator) void {
        for (list.items) |*view| {
            gpa.free(view.label);
            gpa.free(view.command);
        }
        list.deinit(gpa);
    }

    /// How many jobs the manager is tracking (running plus finished-but-not-yet-
    /// reported). The UI keeps its drain tick alive while this is non-zero.
    pub fn activeCount(self: *BackgroundManager) usize {
        self.lockMutex();
        defer self.mutex.unlock();
        return self.jobs.items.len;
    }

    /// How many jobs are still running — the count shown in the footer.
    pub fn runningCount(self: *BackgroundManager) usize {
        self.lockMutex();
        defer self.mutex.unlock();
        var count: usize = 0;
        for (self.jobs.items) |job| {
            if (job.state.load(.acquire) == .running) count += 1;
        }
        return count;
    }

    /// Request termination of job `id`. The process (and on Windows its whole
    /// tree) is killed; the reader then reaps it and marks it finished+killed.
    /// Returns true if a running job matched.
    pub fn cancel(self: *BackgroundManager, id: u32) bool {
        self.lockMutex();
        defer self.mutex.unlock();
        for (self.jobs.items) |job| {
            if (job.id != id) continue;
            if (job.state.load(.acquire) != .running) return false;
            job.killed.store(true, .release);
            job.kill_handle.terminate();
            return true;
        }
        return false;
    }

    /// Take every finished-but-unreported job, transferring ownership to the
    /// caller (the UI), which shows the notice and — for non-killed jobs —
    /// delivers `completion_message` to the owning agent. Free each with `deinit`.
    pub fn takeFinished(self: *BackgroundManager, gpa: std.mem.Allocator) ![]Finished {
        self.lockMutex();
        defer self.mutex.unlock();
        var out: std.ArrayList(Finished) = .empty;
        errdefer {
            for (out.items) |*f| f.deinit(gpa);
            out.deinit(gpa);
        }
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            const job = self.jobs.items[i];
            if (job.reported or job.state.load(.acquire) != .finished) {
                i += 1;
                continue;
            }
            // A very fast command can reach `.finished` before `start` finished
            // assigning `job.thread`. Defer to the next poll rather than free a
            // job whose reader thread is not yet joinable.
            if (job.thread == null) {
                i += 1;
                continue;
            }
            // The reader has stored `.finished`; join so the thread is fully
            // settled before we free the job.
            job.thread.?.join();
            job.thread = null;
            const finished = buildFinished(job, gpa) catch {
                // Leave the job in place; retry on the next poll.
                job.reported = false;
                i += 1;
                continue;
            };
            try out.append(gpa, finished);
            _ = self.jobs.orderedRemove(i);
            destroyJob(self.gpa, self.io, job);
        }
        return out.toOwnedSlice(gpa);
    }

    fn buildFinished(job: *Job, gpa: std.mem.Allocator) !Finished {
        const label = try gpa.dupe(u8, job.label);
        errdefer gpa.free(label);
        const command = try gpa.dupe(u8, job.command);
        errdefer gpa.free(command);
        const message: ?[]u8 = if (job.completion_message) |m| try gpa.dupe(u8, m) else null;
        return .{
            .id = job.id,
            .label = label,
            .command = command,
            .exit_code = job.exit_code,
            .killed = job.killed.load(.acquire),
            .completion_message = message,
            .owner = job.owner,
        };
    }

    /// Terminate and reap every job, then free everything. Called at clean exit.
    pub fn shutdownAll(self: *BackgroundManager) void {
        self.lockMutex();
        var list = self.jobs;
        self.jobs = .empty;
        self.mutex.unlock();

        for (list.items) |job| {
            if (job.state.load(.acquire) == .running) {
                job.killed.store(true, .release);
                job.kill_handle.terminate();
            }
            if (job.thread) |thread| {
                thread.join();
                job.thread = null;
            }
            destroyJob(self.gpa, self.io, job);
        }
        list.deinit(self.gpa);
    }

    pub fn deinit(self: *BackgroundManager) void {
        self.shutdownAll();
        self.* = undefined;
    }

    fn destroyJob(gpa: std.mem.Allocator, io: std.Io, job: *Job) void {
        _ = io;
        job.kill_handle.deinit();
        gpa.free(job.label);
        gpa.free(job.command);
        gpa.free(job.cwd);
        gpa.free(job.log_path);
        job.tail.deinit(gpa);
        if (job.completion_message) |m| gpa.free(m);
        gpa.destroy(job);
    }

    fn removeJobPtr(jobs: *std.ArrayList(*Job), job: *Job) bool {
        for (jobs.items, 0..) |candidate, index| {
            if (candidate == job) {
                _ = jobs.orderedRemove(index);
                return true;
            }
        }
        return false;
    }
};

/// Render an elapsed duration compactly: `45s`, `12m 03s`, `2h 05m`.
fn formatElapsed(buf: []u8, total_seconds: u64) []const u8 {
    if (total_seconds < 60) return std.fmt.bufPrint(buf, "{d}s", .{total_seconds}) catch "?";
    const minutes = total_seconds / 60;
    const seconds = total_seconds % 60;
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ minutes, seconds }) catch "?";
    const hours = minutes / 60;
    const rem_minutes = minutes % 60;
    return std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ hours, rem_minutes }) catch "?";
}

fn termCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |value| value,
        .signal, .stopped, .unknown => 255,
    };
}

fn processId(child: std.process.Child) i64 {
    if (os.is_windows) return @intCast(windows.GetProcessId(child.id.?));
    return @intCast(child.id.?);
}

/// Platform handle used to terminate a job's whole process tree.
const KillHandle = if (os.is_windows) WindowsKill else PosixKill;

const PosixKill = struct {
    pid: std.posix.pid_t,

    fn make(child: std.process.Child) PosixKill {
        return .{ .pid = child.id.? };
    }

    /// Best-effort: signals the direct shell child. Grandchildren in the same
    /// group are not reliably reached without a process-group setup the spawn
    /// API does not expose — see the module header.
    fn terminate(self: *PosixKill) void {
        std.posix.kill(self.pid, std.posix.SIG.KILL) catch {};
    }

    fn deinit(self: *PosixKill) void {
        self.* = undefined;
    }
};

const WindowsKill = struct {
    /// Job Object owning the process tree; null if creation/assignment failed,
    /// in which case `proc` is used for a single-process terminate.
    job: ?windows.HANDLE,
    /// Independent duplicate of the process handle, valid until `deinit` — so
    /// terminating never races the reader thread closing the child's own handle.
    proc: ?windows.HANDLE,

    fn make(child: std.process.Child) WindowsKill {
        const hproc = child.id.?;
        var dup: windows.HANDLE = undefined;
        const proc: ?windows.HANDLE = if (windows.DuplicateHandle(
            windows.GetCurrentProcess(),
            hproc,
            windows.GetCurrentProcess(),
            &dup,
            0,
            0,
            windows.DUPLICATE_SAME_ACCESS,
        ) != 0) dup else null;

        var job: ?windows.HANDLE = windows.CreateJobObjectW(null, null);
        if (job) |handle| {
            var info: windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
            info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            _ = windows.SetInformationJobObject(
                handle,
                windows.JobObjectExtendedLimitInformation,
                &info,
                @sizeOf(windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
            );
            if (windows.AssignProcessToJobObject(handle, hproc) == 0) {
                std.os.windows.CloseHandle(handle);
                job = null;
            }
        }
        return .{ .job = job, .proc = proc };
    }

    fn terminate(self: *WindowsKill) void {
        if (self.job) |handle| {
            _ = windows.TerminateJobObject(handle, 1);
        } else if (self.proc) |handle| {
            _ = windows.TerminateProcess(handle, 1);
        }
    }

    fn deinit(self: *WindowsKill) void {
        // Closing the job's last handle also kills any survivors
        // (KILL_ON_JOB_CLOSE), the backstop for an unexpected Nova exit.
        if (self.job) |handle| std.os.windows.CloseHandle(handle);
        if (self.proc) |handle| std.os.windows.CloseHandle(handle);
        self.* = undefined;
    }
};

/// Win32 surface for process-tree termination, kept local so the rest of the
/// codebase stays platform-agnostic.
const windows = struct {
    const HANDLE = std.os.windows.HANDLE;
    // Plain C int rather than std's `Bool(c_int)` enum so the `!= 0` / `== 0`
    // ABI checks below read naturally; the Win32 BOOL is a 32-bit int.
    const BOOL = c_int;
    const DWORD = std.os.windows.DWORD;

    const DUPLICATE_SAME_ACCESS: DWORD = 0x00000002;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x00002000;
    const JobObjectExtendedLimitInformation: c_int = 9;

    const IO_COUNTERS = extern struct {
        ReadOperationCount: u64,
        WriteOperationCount: u64,
        OtherOperationCount: u64,
        ReadTransferCount: u64,
        WriteTransferCount: u64,
        OtherTransferCount: u64,
    };

    const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
        PerProcessUserTimeLimit: i64,
        PerJobUserTimeLimit: i64,
        LimitFlags: DWORD,
        MinimumWorkingSetSize: usize,
        MaximumWorkingSetSize: usize,
        ActiveProcessLimit: DWORD,
        Affinity: usize,
        PriorityClass: DWORD,
        SchedulingClass: DWORD,
    };

    const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
        BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
        IoInfo: IO_COUNTERS,
        ProcessMemoryLimit: usize,
        JobMemoryLimit: usize,
        PeakProcessMemoryUsed: usize,
        PeakJobMemoryUsed: usize,
    };

    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    extern "kernel32" fn GetProcessId(Process: HANDLE) callconv(.winapi) DWORD;
    extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: c_uint) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*anyopaque, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(hJob: HANDLE, hProcess: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn TerminateJobObject(hJob: HANDLE, uExitCode: c_uint) callconv(.winapi) BOOL;
    extern "kernel32" fn SetInformationJobObject(
        hJob: HANDLE,
        JobObjectInformationClass: c_int,
        lpJobObjectInformation: *anyopaque,
        cbJobObjectInformationLength: DWORD,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn DuplicateHandle(
        hSourceProcessHandle: HANDLE,
        hSourceHandle: HANDLE,
        hTargetProcessHandle: HANDLE,
        lpTargetHandle: *HANDLE,
        dwDesiredAccess: DWORD,
        bInheritHandle: BOOL,
        dwOptions: DWORD,
    ) callconv(.winapi) BOOL;
};

test "manager runs a command, streams a log, and reports completion" {
    const gpa = std.testing.allocator;
    var manager = BackgroundManager.init(std.testing.io, gpa);
    defer manager.deinit();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var owner: u8 = 0;

    var started = try manager.start(.{
        .command = "printf 'hello-bg\\n'",
        .cwd = ".",
        .env_map = &env,
        .owner = &owner,
    });
    defer started.deinit(gpa);
    try std.testing.expectEqualStrings("bg_1", started.label);

    // The reader thread runs asynchronously; poll until the job reports finished.
    var finished: []BackgroundManager.Finished = &.{};
    var tries: usize = 0;
    while (tries < 500) : (tries += 1) {
        finished = try manager.takeFinished(gpa);
        if (finished.len > 0) break;
        gpa.free(finished);
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    defer {
        for (finished) |*job| job.deinit(gpa);
        gpa.free(finished);
    }

    try std.testing.expectEqual(@as(usize, 1), finished.len);
    try std.testing.expect(!finished[0].killed);
    try std.testing.expectEqual(@as(u8, 0), finished[0].exit_code);
    try std.testing.expect(finished[0].completion_message != null);
    try std.testing.expect(std.mem.indexOf(u8, finished[0].completion_message.?, "hello-bg") != null);
    try std.testing.expect(@as(*anyopaque, &owner) == finished[0].owner);
    // Reported job is removed from the manager.
    try std.testing.expectEqual(@as(usize, 0), manager.activeCount());
}

test "formatElapsed renders compact durations" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("45s", formatElapsed(&buf, 45));
    try std.testing.expectEqualStrings("12m 03s", formatElapsed(&buf, 12 * 60 + 3));
    try std.testing.expectEqualStrings("2h 05m", formatElapsed(&buf, 2 * 3600 + 5 * 60 + 9));
}
