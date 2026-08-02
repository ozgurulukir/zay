//! Async branch naming for parallel lanes. A lane starts on a `nova/<hex>`
//! branch; on its first submit a job asks the session's own model (via the
//! runtime's dedicated naming client, never the connection driving the live
//! turn) for a descriptive name, and the branch is renamed in place when it
//! lands. Runs off the UI thread via `io.concurrent`, mirroring the
//! diff-refresh job pattern: the job owns its inputs and frees itself,
//! flipping `done` last so the tick handler can poll without blocking. Every
//! failure resolves to "no name" — the hex branch simply stays.

const std = @import("std");

const ai = @import("../ai.zig");

/// Per-message excerpt cap when building the prompt — naming only needs the
/// gist, not whole pasted files.
const message_excerpt_max: usize = 500;
pub const branch_slug_max: usize = 40;

pub const BranchJob = struct {
    gpa: std.mem.Allocator,
    /// The lane runtime's dedicated naming client (`.none` resolves to no
    /// name). Borrowed — the App cancels this job before the client's runtime
    /// is torn down or reconnected.
    client: ai.LanguageModel,
    /// Recent parent-lane messages (oldest first). Owned.
    context: [][]u8,
    /// The lane's first prompt. Owned.
    first_message: []u8,
    done: *std.atomic.Value(bool),

    pub fn deinit(self: *BranchJob) void {
        for (self.context) |message| self.gpa.free(message);
        if (self.context.len > 0) self.gpa.free(self.context);
        self.gpa.free(self.first_message);
        self.* = undefined;
    }
};

pub const BranchOutcome = struct {
    /// Sanitized branch slug (without the `nova/` prefix), or null when the
    /// model produced nothing usable. Owned.
    slug: ?[]u8,

    pub fn deinit(self: *BranchOutcome, gpa: std.mem.Allocator) void {
        if (self.slug) |slug| gpa.free(slug);
        self.* = undefined;
    }
};

pub fn runBranchJob(job: *BranchJob) BranchOutcome {
    const gpa = job.gpa;
    const done = job.done;
    defer {
        job.deinit();
        gpa.destroy(job);
        done.store(true, .release);
    }
    if (job.client == .none) return .{ .slug = null };
    return .{ .slug = requestSlug(gpa, job) catch null };
}

fn requestSlug(gpa: std.mem.Allocator, job: *BranchJob) !?[]u8 {
    var prompt: std.Io.Writer.Allocating = .init(gpa);
    defer prompt.deinit();
    try prompt.writer.writeAll(
        "Based on these messages, write a git branch name (lowercase words " ++
            "separated by dashes). Respond with only the name of the branch.\n",
    );
    for (job.context) |message| {
        try prompt.writer.writeAll("\n");
        try prompt.writer.writeAll(excerpt(message));
    }
    try prompt.writer.writeAll("\n");
    try prompt.writer.writeAll(excerpt(job.first_message));

    // Mirrors `compaction.summarize`: one user message, collect the text
    // blocks of the reply.
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, prompt.written()) } };
    var message: ai.ChatMessage = .{ .user = .{ .content = blocks } };
    defer message.deinit(gpa);

    var turn = try job.client.prompt(&.{.{ .borrowed = &message }}, ai.streamNoop());
    defer turn.deinit(gpa);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (turn.assistant.assistant.content) |block| {
        if (block == .text) try out.appendSlice(gpa, block.text.text);
    }
    return try sanitizeBranchSlug(gpa, out.items);
}

fn excerpt(message: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    if (trimmed.len <= message_excerpt_max) return trimmed;
    var cut = message_excerpt_max;
    while (cut > 0 and (trimmed[cut] & 0xC0) == 0x80) cut -= 1;
    return trimmed[0..cut];
}

/// The model's raw output shaped into a valid, readable git branch slug:
/// first line only, an echoed label ("branch name: …") / quotes / `nova/`
/// prefix stripped, lowercased, non-alphanumerics collapsed into single
/// dashes, capped at `branch_slug_max`. Null when nothing survives.
pub fn sanitizeBranchSlug(gpa: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var line = firstLine(raw);
    // Models sometimes echo a label ("branch name: auth-race"); a legitimate
    // slug never contains ':', so keep what follows the last one.
    if (std.mem.lastIndexOfScalar(u8, line, ':')) |colon| {
        const rest = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (rest.len > 0) line = rest;
    }
    line = std.mem.trim(u8, line, " \t\"'`");
    if (std.mem.startsWith(u8, line, "nova/")) line = line["nova/".len..];

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (line) |raw_char| {
        const char = std.ascii.toLower(raw_char);
        if (std.ascii.isAlphanumeric(char)) {
            try out.append(gpa, char);
        } else if (out.items.len > 0 and out.items[out.items.len - 1] != '-') {
            try out.append(gpa, '-');
        }
        if (out.items.len >= branch_slug_max) break;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) return null;
    // Generic or collision-prone names; keeping the hex id beats a lane that
    // reads like the repo's actual main branch.
    const rejected = [_][]const u8{ "main", "master", "branch", "branch-name", "name", "git", "nova" };
    for (rejected) |bad| {
        if (std.mem.eql(u8, out.items, bad)) return null;
    }
    return try out.toOwnedSlice(gpa);
}

fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return std.mem.trimEnd(u8, trimmed[0..end], " \t\r");
}

test "sanitizeBranchSlug shapes model output into a git slug" {
    const gpa = std.testing.allocator;

    const plain = (try sanitizeBranchSlug(gpa, "fix-login-race")).?;
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("fix-login-race", plain);

    const messy = (try sanitizeBranchSlug(gpa, "  `nova/Fix_Login  Race!`\nExtra explanation line")).?;
    defer gpa.free(messy);
    try std.testing.expectEqualStrings("fix-login-race", messy);

    const long = (try sanitizeBranchSlug(gpa, "a-very-long-branch-name-that-keeps-going-and-going-forever")).?;
    defer gpa.free(long);
    try std.testing.expect(long.len <= branch_slug_max);
    try std.testing.expect(long[long.len - 1] != '-');

    try std.testing.expectEqual(@as(?[]u8, null), try sanitizeBranchSlug(gpa, "!!! ???"));
    try std.testing.expectEqual(@as(?[]u8, null), try sanitizeBranchSlug(gpa, ""));

    // Echoed labels are stripped; only the name survives.
    const labeled = (try sanitizeBranchSlug(gpa, "git branch name: auth-session-race")).?;
    defer gpa.free(labeled);
    try std.testing.expectEqualStrings("auth-session-race", labeled);

    // Generic/collision-prone names keep the hex id (null).
    try std.testing.expectEqual(@as(?[]u8, null), try sanitizeBranchSlug(gpa, "main"));
    try std.testing.expectEqual(@as(?[]u8, null), try sanitizeBranchSlug(gpa, "Branch name: master"));
}
