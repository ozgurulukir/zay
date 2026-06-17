const std = @import("std");

const terminal_markdown = @import("terminal_markdown");

const assert = std.debug.assert;

/// How a tool's display body should be drawn in the TUI.
///   - `.plain`: single muted-gray body.
///   - `.diff`: per-line diff styling with `+` green, `-` red, others gray.
/// Failure overrides everything to red at draw time.
pub const Render = enum { plain, diff };

pub const MessageKind = enum {
    user,
    agent,
    skill,
    logo,
    thinking,
    tool,
    status,
    notice,

    fn selectable(self: MessageKind) bool {
        return self != .logo and self != .status;
    }

    pub fn dimmable(self: MessageKind) bool {
        return switch (self) {
            .user, .agent, .skill, .thinking, .tool, .notice => true,
            .logo, .status => false,
        };
    }
};

/// Memoized row count for a message at a given width. Computing it scans the
/// whole (possibly multi-KB, streaming) body, and the draw loop asks for it
/// several times per frame, so we cache the last result. Width is part of the
/// key (resize changes wrapping); content changes invalidate via
/// `Message.invalidateRowCache`, called by every `Transcript` mutator. Because the
/// only layout-affecting writes go through those mutators, width is the only
/// thing the lookup itself has to re-check.
pub const RowCache = struct {
    valid: bool = false,
    width: u16 = 0,
    rows: u16 = 0,
};

/// Memoized rendered markdown for an `.agent` body at a given width. Where
/// `RowCache` stores only a row *count*, this keeps the fully rendered
/// `Row`/`Span` list so a visible message isn't re-parsed on every animation
/// frame (the dominant per-frame cost in the draw loop). The spans borrow
/// slices of `Message.body`, so the cache is valid only while the body is
/// unchanged: every mutator that touches the body invalidates it via
/// `invalidateRowCache`, and `deinit` frees the owned row/span arrays. The draw
/// layer leaves very large bodies uncached (see `message.zig`) so a giant
/// message never materializes its whole row list — preserving the draw-time
/// out-of-memory guard.
pub const RenderCache = struct {
    valid: bool = false,
    width: u16 = 0,
    rendered: ?terminal_markdown.Rendered = null,
};

pub const Message = struct {
    kind: MessageKind,
    title: []u8,
    body: []u8,
    expanded: bool = true,
    failed: bool = false,
    /// Only meaningful when `kind == .tool`. True while the executor owns the
    /// call and the TUI should animate the title prefix.
    tool_running: bool = false,
    /// Only meaningful when `kind == .tool`. Drives per-line styling of the
    /// body in the TUI; see `Render`.
    tool_render: Render = .plain,
    /// Only meaningful when `kind == .tool`. The tool's stderr text, owned,
    /// rendered in red below the gray body. Null when the tool produced no
    /// stderr output.
    stderr_body: ?[]u8 = null,
    /// Only meaningful when `kind == .tool`. Title shown when the row is
    /// expanded; used for bash to reveal the exact command behind a summary.
    tool_expanded_title: ?[]u8 = null,
    /// Cached row count; see `RowCache`. Not owned, needs no cleanup.
    row_cache: RowCache = .{},
    /// Cached rendered markdown; see `RenderCache`. Owned — freed in `deinit`.
    render_cache: RenderCache = .{},

    pub fn deinit(self: *Message, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        gpa.free(self.body);
        if (self.stderr_body) |stderr| gpa.free(stderr);
        if (self.tool_expanded_title) |title| gpa.free(title);
        if (self.render_cache.rendered) |*rendered| rendered.deinit(gpa);
        self.* = undefined;
    }

    /// Drop the memoized row count and rendered markdown after a layout-affecting
    /// change. The rendered markdown's spans borrow `body`, which the caller is
    /// about to mutate (and may move via `realloc`), so the stale render must
    /// never be drawn again. The owned allocation is freed lazily — on the next
    /// render or in `deinit` — because this runs on hot mutators with no
    /// allocator at hand; freeing only releases the gpa-owned row/span arrays and
    /// never dereferences the borrowed (now-dangling) span text.
    pub fn invalidateRowCache(self: *Message) void {
        self.row_cache.valid = false;
        self.render_cache.valid = false;
    }
};

pub const Transcript = struct {
    messages: std.ArrayList(Message) = .empty,
    selected: ?u32 = null,

    pub fn deinit(self: *Transcript, gpa: std.mem.Allocator) void {
        for (self.messages.items) |*message| {
            message.deinit(gpa);
        }
        self.messages.deinit(gpa);
        self.* = undefined;
    }

    pub fn append(
        self: *Transcript,
        gpa: std.mem.Allocator,
        kind: MessageKind,
        title: []const u8,
        body: []const u8,
    ) !u32 {
        assert(title.len > 0);
        const owned_title = try gpa.dupe(u8, title);
        errdefer gpa.free(owned_title);
        const owned_body = try gpa.dupe(u8, body);
        errdefer gpa.free(owned_body);

        const index: u32 = @intCast(self.messages.items.len);
        const following_tail = self.isFollowingTail();
        try self.messages.append(gpa, .{
            .kind = kind,
            .title = owned_title,
            .body = owned_body,
            .expanded = kind == .user or kind == .agent or kind == .logo,
        });
        if (kind.selectable() and following_tail) self.selected = index;
        return index;
    }

    /// True when no message is selected, or when the selection is at the last
    /// selectable message in the transcript (so streaming a new selectable message
    /// should follow). Users who have scrolled up to an earlier message stop
    /// "following the tail" and won't get yanked forward on the next append.
    ///
    /// `selected` is always a selectable index by invariant, and the only
    /// non-selectable message that ever sits at the tail is the lone status
    /// spinner — so it suffices to check the final one or two slots. O(1).
    pub fn isFollowingTail(self: *const Transcript) bool {
        const selected = self.selected orelse return true;
        const count: u32 = @intCast(self.messages.items.len);
        if (selected + 1 == count) return true;
        if (selected + 2 == count and !self.messages.items[count - 1].kind.selectable()) return true;
        return false;
    }

    pub fn appendAgentDelta(
        self: *Transcript,
        gpa: std.mem.Allocator,
        index: u32,
        delta: []const u8,
    ) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.kind == .agent);
        try appendOwned(gpa, &message.body, delta);
        message.invalidateRowCache();
    }

    pub fn appendThinkingDelta(
        self: *Transcript,
        gpa: std.mem.Allocator,
        index: u32,
        delta: []const u8,
    ) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.kind == .thinking);
        try appendOwned(gpa, &message.body, delta);
        message.invalidateRowCache();
    }

    pub fn insert(
        self: *Transcript,
        gpa: std.mem.Allocator,
        index: u32,
        kind: MessageKind,
        title: []const u8,
        body: []const u8,
    ) !u32 {
        assert(index <= self.messages.items.len);
        assert(title.len > 0);
        const owned_title = try gpa.dupe(u8, title);
        errdefer gpa.free(owned_title);
        const owned_body = try gpa.dupe(u8, body);
        errdefer gpa.free(owned_body);

        try self.messages.insert(gpa, index, .{
            .kind = kind,
            .title = owned_title,
            .body = owned_body,
            .expanded = kind == .user or kind == .agent or kind == .logo,
        });
        if (self.selected) |selected| {
            if (selected >= index) self.selected = selected + 1;
        }
        return index;
    }

    pub fn select(self: *Transcript, index: u32) void {
        assert(index < self.messages.items.len);
        assert(self.messages.items[index].kind.selectable());
        self.selected = index;
    }

    pub fn selectLast(self: *Transcript) void {
        if (self.messages.items.len == 0) {
            self.selected = null;
            return;
        }
        var index: u32 = @intCast(self.messages.items.len);
        while (index > 0) {
            index -= 1;
            if (self.messages.items[index].kind.selectable()) {
                self.selected = index;
                return;
            }
        }
        self.selected = null;
    }

    pub fn remove(self: *Transcript, gpa: std.mem.Allocator, index: u32) void {
        assert(index < self.messages.items.len);
        self.messages.items[index].deinit(gpa);
        _ = self.messages.orderedRemove(index);

        if (self.messages.items.len == 0) {
            self.selected = null;
            return;
        }

        if (self.selected) |selected| {
            self.selected = if (selected == index)
                self.nearestSelectable(@min(index, @as(u32, @intCast(self.messages.items.len - 1))))
            else if (selected > index)
                selected - 1
            else
                selected;
        }
    }

    pub fn startTool(self: *Transcript, gpa: std.mem.Allocator, command: []const u8) !u32 {
        const title = try toolTitle(gpa, command);
        defer gpa.free(title);
        const index = try self.append(gpa, .tool, title, "");
        self.messages.items[index].expanded = false;
        self.messages.items[index].tool_running = true;
        return index;
    }

    pub fn updateTool(self: *Transcript, gpa: std.mem.Allocator, index: u32, command: []const u8) !void {
        try self.updateToolExpanded(gpa, index, command, null);
    }

    pub fn updateToolExpanded(
        self: *Transcript,
        gpa: std.mem.Allocator,
        index: u32,
        command: []const u8,
        expanded_command: ?[]const u8,
    ) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.kind == .tool);

        const title = try toolTitle(gpa, command);
        errdefer gpa.free(title);
        const expanded_title = if (expanded_command) |value| try toolTitle(gpa, value) else null;
        errdefer if (expanded_title) |value| gpa.free(value);
        gpa.free(message.title);
        if (message.tool_expanded_title) |value| gpa.free(value);
        message.title = title;
        message.tool_expanded_title = expanded_title;
        message.invalidateRowCache();
    }

    pub fn finishThinking(self: *Transcript, gpa: std.mem.Allocator, index: u32) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.kind == .thinking);
        if (std.mem.eql(u8, message.title, "Thoughts")) return;

        const title = try gpa.dupe(u8, "Thoughts");
        gpa.free(message.title);
        message.title = title;
    }

    pub fn finishTool(
        self: *Transcript,
        gpa: std.mem.Allocator,
        index: u32,
        body: []const u8,
        stderr_body: ?[]const u8,
        failed: bool,
    ) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.kind == .tool);
        message.tool_running = false;
        try appendOwned(gpa, &message.body, body);
        if (stderr_body) |stderr| {
            assert(stderr.len > 0);
            const owned = try gpa.dupe(u8, stderr);
            if (message.stderr_body) |existing| gpa.free(existing);
            message.stderr_body = owned;
        }
        message.failed = failed;
        message.invalidateRowCache();
    }

    pub fn finishSkill(
        self: *Transcript,
        gpa: std.mem.Allocator,
        index: u32,
        body: []const u8,
        failed: bool,
    ) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.kind == .skill);
        try appendOwned(gpa, &message.body, body);
        message.failed = failed;
        message.invalidateRowCache();
    }

    /// Set a message's expanded state, invalidating its cached row count. The
    /// The turn view mutates `expanded` when a tool finishes; route it
    /// through here so the cache stays correct.
    pub fn setExpanded(self: *Transcript, index: u32, value: bool) void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        message.expanded = value;
        message.invalidateRowCache();
    }

    pub fn moveSelection(self: *Transcript, direction: enum { previous, next }) void {
        if (self.messages.items.len == 0) {
            self.selected = null;
            return;
        }

        const selected = self.selected orelse self.nearestSelectable(0) orelse return;
        self.selected = switch (direction) {
            .previous => self.previousSelectable(selected) orelse selected,
            .next => self.nextSelectable(selected) orelse selected,
        };
    }

    pub fn hasRunningTool(self: *const Transcript) bool {
        for (self.messages.items) |message| {
            if (message.kind != .tool) continue;
            if (message.tool_running) return true;
        }
        return false;
    }

    pub fn stopRunningTools(self: *Transcript) bool {
        var stopped = false;
        for (self.messages.items) |*message| {
            if (message.kind != .tool) continue;
            if (!message.tool_running) continue;
            message.tool_running = false;
            stopped = true;
        }
        return stopped;
    }

    pub fn toggleSelected(self: *Transcript) void {
        const selected = self.selected orelse return;
        assert(selected < self.messages.items.len);
        const message = &self.messages.items[selected];
        switch (message.kind) {
            .thinking, .tool => {
                message.expanded = !message.expanded;
                message.invalidateRowCache();
            },
            .skill => if (message.body.len > 0) {
                message.expanded = !message.expanded;
                message.invalidateRowCache();
            },
            .user, .agent, .logo, .status, .notice => {},
        }
    }

    fn nearestSelectable(self: *const Transcript, index: u32) ?u32 {
        assert(self.messages.items.len > 0);
        assert(index < self.messages.items.len);
        if (self.messages.items[index].kind.selectable()) return index;
        if (self.nextSelectable(index)) |next| return next;
        return self.previousSelectable(index);
    }

    fn previousSelectable(self: *const Transcript, index: u32) ?u32 {
        assert(index < self.messages.items.len);
        var current = index;
        while (current > 0) {
            current -= 1;
            if (self.messages.items[current].kind.selectable()) return current;
        }
        return null;
    }

    fn nextSelectable(self: *const Transcript, index: u32) ?u32 {
        assert(index < self.messages.items.len);
        var current = index + 1;
        while (current < self.messages.items.len) : (current += 1) {
            if (self.messages.items[current].kind.selectable()) return @intCast(current);
        }
        return null;
    }
};

fn appendOwned(gpa: std.mem.Allocator, target: *[]u8, suffix: []const u8) !void {
    if (suffix.len == 0) return;
    // `realloc` grows the buffer in place when the allocator's size class has
    // room, so streaming deltas don't recopy the whole (ever-growing) body on
    // every append. A fresh alloc + memcpy here is O(N) per delta — O(N²) over
    // a long response, the main driver of mid-stream slowdown.
    const old_len = target.len;
    const joined = try gpa.realloc(target.*, old_len + suffix.len);
    @memcpy(joined[old_len..], suffix);
    target.* = joined;
}

pub fn toolTitle(gpa: std.mem.Allocator, command: []const u8) ![]u8 {
    return try std.fmt.allocPrint(gpa, "🛠  {s}", .{command});
}

test "thinking and tool messages are compact until toggled" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .thinking, "thinking", "one two three four");
    try std.testing.expect(!transcript.messages.items[0].expanded);
    transcript.toggleSelected();
    try std.testing.expect(transcript.messages.items[0].expanded);
}

test "selectLast selects last selectable before status tail" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .agent, "agent", "one");
    _ = try transcript.append(gpa, .status, "status", "loading");
    transcript.selected = null;

    transcript.selectLast();

    try std.testing.expectEqual(@as(?u32, 0), transcript.selected);
}

test "consecutive tools remain separate messages" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    const first = try transcript.startTool(gpa, "ls");
    try transcript.finishTool(gpa, first, "ls\n", null, false);
    const second = try transcript.startTool(gpa, "pwd");
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(usize, 2), transcript.messages.items.len);
    try std.testing.expectEqualStrings("🛠  ls", transcript.messages.items[0].title);
    try std.testing.expectEqualStrings("🛠  pwd", transcript.messages.items[1].title);
    try std.testing.expect(!transcript.messages.items[0].expanded);
    try std.testing.expect(!transcript.messages.items[1].expanded);
}

test "remove keeps selection in range" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .user, "you", "one");
    _ = try transcript.append(gpa, .agent, "agent", "two");
    transcript.remove(gpa, 1);

    try std.testing.expectEqual(@as(usize, 1), transcript.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), transcript.selected.?);
}
