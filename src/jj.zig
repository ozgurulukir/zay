//! Typed seam over jujutsu (jj). Nova drives jj in *colocated* mode (`.jj/`
//! beside `.git/`) so every jj commit is a real git object and git tooling keeps
//! working. This module is the boundary where jj's stringly-typed CLI output
//! becomes branded, validated values — nothing downstream should ever hand-roll
//! a change-id or bookmark from a raw `[]const u8`.
//!
//! The anchor for the conversation↔code binding is the **change-id**, not the
//! git commit SHA: change-ids are stable across history rewrites (rebase on
//! merge, squash of per-turn checkpoints), so a `checkpoint` session entry that
//! stores one still resolves after the lane is merged. SHAs would dangle.

const std = @import("std");

const assert = std.debug.assert;

pub const Error = error{
    BadChangeId,
    BadBookmarkName,
    BadWorkspaceName,
};

/// A jj change-id. jj renders a full change-id as 32 letters drawn from the
/// `k`–`z` "reverse-hex" alphabet (visually distinct from a hex commit SHA);
/// `max_len` is bounded generously above that so a longer id from a future jj
/// can't silently truncate. Stored inline (no allocation) like `session.EntryId`.
///
/// `parse` is the only constructor — that is the boundary discipline: a value of
/// this type is, by construction, a syntactically valid change-id.
pub const ChangeId = struct {
    bytes: [max_len]u8,
    len: u8,

    pub const max_len: u8 = 64;

    /// Parse one change-id out of raw jj output (e.g. `jj log --no-graph -T
    /// change_id`). Surrounding whitespace/newline is trimmed; the remainder
    /// must be non-empty, within `max_len`, and entirely in the `k`–`z`
    /// alphabet. Rejects everything else rather than storing a lie.
    pub fn parse(raw: []const u8) Error!ChangeId {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > max_len) return error.BadChangeId;
        for (trimmed) |byte| {
            if (byte < 'k' or byte > 'z') return error.BadChangeId;
        }
        var id: ChangeId = .{ .bytes = undefined, .len = @intCast(trimmed.len) };
        @memcpy(id.bytes[0..trimmed.len], trimmed);
        return id;
    }

    pub fn slice(self: *const ChangeId) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: ChangeId, other: ChangeId) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

/// A jj bookmark name (jj's term for a named pointer; exports to a git branch in
/// colocated mode). Nova generates these as `nova/<session-id>`, so validation
/// is a guard against accidental garbage, not untrusted input: non-empty, no
/// whitespace, and none of the characters git refuses in a ref name.
pub const BookmarkName = struct {
    bytes: [max_len]u8,
    len: u8,

    pub const max_len: u8 = 128;

    pub fn parse(raw: []const u8) Error!BookmarkName {
        if (raw.len == 0 or raw.len > max_len) return error.BadBookmarkName;
        for (raw) |byte| {
            if (byte <= ' ' or byte == 0x7f) return error.BadBookmarkName;
            if (std.mem.indexOfScalar(u8, "~^:?*[\\", byte) != null) return error.BadBookmarkName;
        }
        var name: BookmarkName = .{ .bytes = undefined, .len = @intCast(raw.len) };
        @memcpy(name.bytes[0..raw.len], raw);
        return name;
    }

    pub fn slice(self: *const BookmarkName) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A jj workspace name (jj's term for a worktree-equivalent: a separate working
/// copy sharing the one `.jj/store`). Stricter than a bookmark because it also
/// names a directory: letters, digits, `-`, `_` only.
pub const WorkspaceName = struct {
    bytes: [max_len]u8,
    len: u8,

    pub const max_len: u8 = 128;

    pub fn parse(raw: []const u8) Error!WorkspaceName {
        if (raw.len == 0 or raw.len > max_len) return error.BadWorkspaceName;
        for (raw) |byte| {
            const ok = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_';
            if (!ok) return error.BadWorkspaceName;
        }
        var name: WorkspaceName = .{ .bytes = undefined, .len = @intCast(raw.len) };
        @memcpy(name.bytes[0..raw.len], raw);
        return name;
    }

    pub fn slice(self: *const WorkspaceName) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A *live* lane's relationship to the working tree, as a sum type so the
/// impossible combinations never compile. The bag-of-optionals shape this
/// replaces — `{ path: ?[]u8, bookmark: ?Bookmark, ... }` — admits "working with
/// no path"; here that can't be written down. "Merged" is deliberately NOT a
/// variant: a lane that has been squashed and popped is no longer a workspace,
/// so its outcome lives in `MergeRecord`, reachable only once the lane stops
/// being live (see `Thread.State` in the tui layer).
///
///   - `.primary`  the root thread, living in the repo's main working copy. It
///                 has no dedicated workspace and is never popped.
///   - `.working`  a derived lane with its own jj workspace + bookmark, branched
///                 from `base`. Always has a live, owned `path`.
pub const Lane = union(enum) {
    primary,
    working: Working,

    /// A derived lane with a live workspace. `path` is owned (absolute path to
    /// the workspace directory); everything else is inline-branded.
    pub const Working = struct {
        workspace: WorkspaceName,
        bookmark: BookmarkName,
        base: ChangeId,
        path: []u8,
    };

    /// Free the only owned field. `.primary` owns nothing.
    pub fn deinit(self: *Lane, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .working => |w| gpa.free(w.path),
            .primary => {},
        }
        self.* = undefined;
    }

    /// The directory an agent worker for this lane should run tools in, or null
    /// for `.primary` (the caller uses the repo root).
    pub fn workingPath(self: *const Lane) ?[]const u8 {
        return switch (self.*) {
            .working => |w| w.path,
            .primary => null,
        };
    }
};

/// The outcome of merging a `.working` lane: it was squashed into
/// `target_bookmark` at change `into`, and its workspace was popped. No owned
/// fields — the workspace directory is gone, so a dangling `path` is
/// structurally impossible rather than a value we must remember to clear.
pub const MergeRecord = struct {
    bookmark: BookmarkName,
    target_bookmark: BookmarkName,
    into: ChangeId,
};

// ===========================================================================
// jj CLI boundary
//
// Everything below shells out to the `jj` binary and funnels its stdout through
// the parsers above. The layer is stateless — callers pass the repo/workspace
// directory on each call. Commands invoke `jj` directly via argv (no shell), so
// there is no quoting to get wrong, and a missing binary surfaces as the typed
// `JjNotFound` rather than a generic spawn error.
// ===========================================================================

pub const CmdError = error{
    JjNotFound,
    JjSpawnFailed,
    JjCommandFailed,
    JjBadOutput,
    OutOfMemory,
} || Error;

const cmd_stdout_limit: usize = 256 * 1024;
const cmd_stderr_limit: usize = 64 * 1024;
const cmd_timeout_seconds: u32 = 30;

fn cmdTimeout() std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(cmd_timeout_seconds), .clock = .awake } };
}

const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    fn deinit(self: *Captured, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }
};

fn termCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |value| value,
        .signal, .stopped, .unknown => 255,
    };
}

/// Run one jj subcommand in `cwd`, capturing stdout/stderr. `args` must NOT
/// include the binary — it is prepended here so a caller can't reach for the
/// wrong jj. A missing binary maps to `JjNotFound` so features can degrade.
fn run(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const []const u8) CmdError!Captured {
    assert(cwd.len > 0);
    assert(args.len > 0);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "jj");
    try argv.appendSlice(gpa, args);

    const result = std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(cmd_stdout_limit),
        .stderr_limit = .limited(cmd_stderr_limit),
        .timeout = cmdTimeout(),
    }) catch |err| return switch (err) {
        error.FileNotFound => error.JjNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.JjSpawnFailed,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .code = termCode(result.term) };
}

/// True when the `jj` binary can be invoked at all. Cheap probe used to gate
/// worktree features and to skip integration tests where jj isn't installed.
pub fn isAvailable(gpa: std.mem.Allocator, io: std.Io) bool {
    var out = run(gpa, io, ".", &.{"--version"}) catch return false;
    defer out.deinit(gpa);
    return out.code == 0;
}

/// Whether `repo_dir` (an absolute path) is already a jj repo. Lets
/// `ensureColocated` stay idempotent without parsing `jj git init`'s error.
pub fn isColocated(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8) bool {
    const path = std.fs.path.join(gpa, &.{ repo_dir, ".jj" }) catch return false;
    defer gpa.free(path);
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

/// Ensure `repo_dir` is a colocated jj repo (`.jj` beside `.git`), creating one
/// if absent. Idempotent.
pub fn ensureColocated(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8) CmdError!void {
    if (isColocated(gpa, io, repo_dir)) return;
    var out = try run(gpa, io, repo_dir, &.{ "git", "init", "--colocate" });
    defer out.deinit(gpa);
    if (out.code != 0) return error.JjCommandFailed;
}

/// The change-id of the working-copy commit (`@`) in `dir`. Reading triggers
/// jj's snapshot, so the result reflects the current on-disk state.
pub fn workingCopyChangeId(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) CmdError!ChangeId {
    var out = try run(gpa, io, dir, &.{ "log", "--no-graph", "-r", "@", "-T", "change_id" });
    defer out.deinit(gpa);
    if (out.code != 0) return error.JjCommandFailed;
    return ChangeId.parse(out.stdout);
}

/// Whether the working-copy commit has no changes against its parent.
pub fn workingCopyEmpty(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) CmdError!bool {
    var out = try run(gpa, io, dir, &.{ "log", "--no-graph", "-r", "@", "-T", "empty" });
    defer out.deinit(gpa);
    if (out.code != 0) return error.JjCommandFailed;
    return parseBool(out.stdout);
}

fn parseBool(raw: []const u8) CmdError!bool {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "true")) return true;
    if (std.mem.eql(u8, trimmed, "false")) return false;
    return error.JjBadOutput;
}

/// Seal the current turn's changes into a checkpoint commit in `dir`, returning
/// the change-id to record — or null when the working copy had no changes (the
/// caller maps null to "this conversation node reuses the previous checkpoint").
/// The sealed change keeps the pre-commit `@` change-id; `jj commit` then opens
/// a fresh empty `@` on top, which is why we read the id *before* committing.
pub fn sealTurn(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, message: []const u8) CmdError!?ChangeId {
    assert(message.len > 0);
    if (try workingCopyEmpty(gpa, io, dir)) return null;
    const sealed = try workingCopyChangeId(gpa, io, dir);
    var out = try run(gpa, io, dir, &.{ "commit", "-m", message });
    defer out.deinit(gpa);
    if (out.code != 0) return error.JjCommandFailed;
    return sealed;
}

/// Create a new workspace named `name` rooted at `dest_dir`, its working copy
/// based on `revision` (the checkpoint a lane branches from). This is the jj
/// equivalent of `git worktree add`.
pub fn workspaceAdd(
    gpa: std.mem.Allocator,
    io: std.Io,
    repo_dir: []const u8,
    name: WorkspaceName,
    dest_dir: []const u8,
    revision: ChangeId,
) CmdError!void {
    var out = try run(gpa, io, repo_dir, &.{ "workspace", "add", "--name", name.slice(), "--revision", revision.slice(), dest_dir });
    defer out.deinit(gpa);
    if (out.code != 0) return error.JjCommandFailed;
}

/// Drop the workspace named `name` from the repo's records (its directory should
/// already be removed). Does not delete the directory itself.
pub fn workspaceForget(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8, name: WorkspaceName) CmdError!void {
    var out = try run(gpa, io, repo_dir, &.{ "workspace", "forget", name.slice() });
    defer out.deinit(gpa);
    if (out.code != 0) return error.JjCommandFailed;
}

// === Merge ops ============================================================
//
// These land a lane's work back onto main. jj records conflicts as data in the
// rebased commits (it never aborts), so `rebaseChainOnto` always "succeeds"
// mechanically and `rangeHasConflicts` is the gate. The revsets below are
// best-effort for jj 0.42 and MUST be confirmed with a live `/merge` on a
// throwaway repo before being relied on — `undoLast` is the reversibility net.

/// Rebase the lane's checkpoint chain — the commits in `base..head` — onto
/// `dest` (the current main tip), in the shared repo. Change-ids are stable
/// across the rebase, so `head` still resolves afterward (now atop `dest`).
pub fn rebaseChainOnto(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8, base: ChangeId, head: ChangeId, dest: ChangeId) CmdError!void {
    const source = try std.fmt.allocPrint(gpa, "roots({s}..{s})", .{ base.slice(), head.slice() });
    defer gpa.free(source);
    var out = try run(gpa, io, repo_dir, &.{ "rebase", "-s", source, "-d", dest.slice() });
    defer out.deinit(gpa);
    if (out.code != 0) return error.JjCommandFailed;
}

/// Whether any commit in `base..head` carries a conflict (after a rebase). Uses
/// the `conflict` commit-template keyword; emits "x" per conflicted commit.
pub fn rangeHasConflicts(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8, base: ChangeId, head: ChangeId) CmdError!bool {
    const revset = try std.fmt.allocPrint(gpa, "{s}..{s}", .{ base.slice(), head.slice() });
    defer gpa.free(revset);
    var out = try run(gpa, io, repo_dir, &.{ "log", "--no-graph", "-r", revset, "-T", "if(conflict, \"x\", \"\")" });
    defer out.deinit(gpa);
    if (out.code != 0) return error.JjCommandFailed;
    return std.mem.indexOfScalar(u8, out.stdout, 'x') != null;
}

/// Put a fresh working-copy commit on top of `rev` in `dir` — advances the
/// primary lane onto freshly-landed work so its tree reflects the merge.
pub fn newOnTop(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, rev: ChangeId) CmdError!void {
    var out = try run(gpa, io, dir, &.{ "new", rev.slice() });
    defer out.deinit(gpa);
    if (out.code != 0) return error.JjCommandFailed;
}

/// Undo the last jj operation — reverts a rebase that produced conflicts so a
/// merge attempt leaves main untouched.
pub fn undoLast(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8) CmdError!void {
    var out = try run(gpa, io, repo_dir, &.{"undo"});
    defer out.deinit(gpa);
    if (out.code != 0) return error.JjCommandFailed;
}

test "ChangeId.parse accepts k-z, trims, rejects hex" {
    const full = "kxryzmorlvtnpqswvkxryzmorlvtnpqs"; // 32 letters, all in k-z
    const ok = try ChangeId.parse("  " ++ full ++ "\n");
    try std.testing.expectEqual(@as(u8, 32), ok.len);
    try std.testing.expectEqualStrings(full, ok.slice());

    try std.testing.expectError(error.BadChangeId, ChangeId.parse(""));
    try std.testing.expectError(error.BadChangeId, ChangeId.parse("   \n"));
    // 'a'..'f' is a commit SHA, not a change-id.
    try std.testing.expectError(error.BadChangeId, ChangeId.parse("deadbeef"));
    try std.testing.expectError(error.BadChangeId, ChangeId.parse("k" ** (ChangeId.max_len + 1)));
}

test "ChangeId.eql compares the live slice, not the buffer tail" {
    const a = try ChangeId.parse("kkk");
    const b = try ChangeId.parse("kkk");
    const c = try ChangeId.parse("kkl");
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "BookmarkName rejects ref-illegal characters" {
    _ = try BookmarkName.parse("nova/0123456789abcdef");
    try std.testing.expectError(error.BadBookmarkName, BookmarkName.parse("has space"));
    try std.testing.expectError(error.BadBookmarkName, BookmarkName.parse("bad:colon"));
    try std.testing.expectError(error.BadBookmarkName, BookmarkName.parse(""));
}

test "WorkspaceName allows only directory-safe characters" {
    _ = try WorkspaceName.parse("nova-feature_1");
    try std.testing.expectError(error.BadWorkspaceName, WorkspaceName.parse("nova/slash"));
    try std.testing.expectError(error.BadWorkspaceName, WorkspaceName.parse("dot.dir"));
}

test "Lane sum type frees only the working path" {
    const gpa = std.testing.allocator;
    var lane: Lane = .{ .working = .{
        .workspace = try WorkspaceName.parse("nova-x"),
        .bookmark = try BookmarkName.parse("nova/x"),
        .base = try ChangeId.parse("kkk"),
        .path = try gpa.dupe(u8, "/repo/.nova/workspaces/x"),
    } };
    try std.testing.expectEqualStrings("/repo/.nova/workspaces/x", lane.workingPath().?);
    lane.deinit(gpa);

    var primary: Lane = .primary;
    try std.testing.expectEqual(@as(?[]const u8, null), primary.workingPath());
    primary.deinit(gpa);
}

test "parseBool maps jj empty-template output, rejects the rest" {
    try std.testing.expect(try parseBool("true\n"));
    try std.testing.expect(!try parseBool("  false  "));
    try std.testing.expectError(error.JjBadOutput, parseBool("maybe"));
}

test "jj: colocate, read @, empty flag, seal a checkpoint" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!isAvailable(gpa, io)) return error.SkipZigTest;

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);

    var rand: [8]u8 = undefined;
    io.random(&rand);
    const hex = std.fmt.bytesToHex(rand, .lower);
    const name = try std.fmt.allocPrint(gpa, "nova-jjtest-{s}", .{hex[0..]});
    defer gpa.free(name);

    try std.Io.Dir.cwd().createDirPath(io, name);
    defer std.Io.Dir.cwd().deleteTree(io, name) catch {};

    const repo = try std.fs.path.join(gpa, &.{ cwd, name });
    defer gpa.free(repo);

    try ensureColocated(gpa, io, repo);
    try std.testing.expect(isColocated(gpa, io, repo));

    // A fresh working copy is empty; `@` still has a valid 32-char change-id.
    try std.testing.expect(try workingCopyEmpty(gpa, io, repo));
    const id0 = try workingCopyChangeId(gpa, io, repo);
    try std.testing.expectEqual(@as(u8, 32), id0.len);

    // Writing a file makes `@` non-empty (jj snapshots on the next command).
    const file_rel = try std.fs.path.join(gpa, &.{ name, "f.txt" });
    defer gpa.free(file_rel);
    var f = try std.Io.Dir.createFile(.cwd(), io, file_rel, .{});
    try f.writeStreamingAll(io, "hello\n");
    f.close(io);
    try std.testing.expect(!(try workingCopyEmpty(gpa, io, repo)));

    // Sealing returns the change-id that held the changes (the pre-commit `@`)
    // and leaves a fresh empty `@` behind.
    const sealed = (try sealTurn(gpa, io, repo, "nova: checkpoint")) orelse return error.TestFailed;
    try std.testing.expect(sealed.eql(id0));
    try std.testing.expect(try workingCopyEmpty(gpa, io, repo));

    // Sealing again with nothing changed is a no-op.
    try std.testing.expect((try sealTurn(gpa, io, repo, "nova: checkpoint")) == null);
}
