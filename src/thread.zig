const std = @import("std");

const assert = std.debug.assert;

/// How a tool's display body should be drawn in the TUI.
///   - `.plain`: single muted-gray body (bash output, file reads, etc.).
///   - `.diff`: per-line — `+` green, `-` red, others gray (edit_file only).
/// Failure overrides everything to red at draw time. See CONTEXT.md's
/// **Color rule** and **Render** definitions.
pub const Render = enum { plain, diff };

pub const MessageKind = enum {
    user,
    agent,
    logo,
    thinking,
    tool,
    status,

    fn selectable(self: MessageKind) bool {
        return self != .logo and self != .status;
    }
};

pub const Message = struct {
    kind: MessageKind,
    title: []u8,
    body: []u8,
    expanded: bool = true,
    failed: bool = false,
    /// Only meaningful when `kind == .tool`. Drives per-line styling of the
    /// body in the TUI; see `Render`.
    tool_render: Render = .plain,
    /// Only meaningful when `kind == .tool`. The tool's stderr text, owned,
    /// rendered in red below the gray body. Null when the tool produced no
    /// stderr output.
    stderr_body: ?[]u8 = null,

    pub fn deinit(self: *Message, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        gpa.free(self.body);
        if (self.stderr_body) |stderr| gpa.free(stderr);
        self.* = undefined;
    }
};

pub const Thread = struct {
    messages: std.ArrayList(Message) = .empty,
    selected: ?u32 = null,

    pub fn deinit(self: *Thread, gpa: std.mem.Allocator) void {
        for (self.messages.items) |*message| {
            message.deinit(gpa);
        }
        self.messages.deinit(gpa);
        self.* = undefined;
    }

    pub fn append(
        self: *Thread,
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
    /// selectable message in the thread (so streaming a new selectable message
    /// should follow). Users who have scrolled up to an earlier message stop
    /// "following the tail" and won't get yanked forward on the next append.
    ///
    /// `selected` is always a selectable index by invariant, and the only
    /// non-selectable message that ever sits at the tail is the lone status
    /// spinner — so it suffices to check the final one or two slots. O(1).
    pub fn isFollowingTail(self: *const Thread) bool {
        const selected = self.selected orelse return true;
        const count: u32 = @intCast(self.messages.items.len);
        if (selected + 1 == count) return true;
        if (selected + 2 == count and !self.messages.items[count - 1].kind.selectable()) return true;
        return false;
    }

    pub fn appendAgentDelta(
        self: *Thread,
        gpa: std.mem.Allocator,
        index: u32,
        delta: []const u8,
    ) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.kind == .agent);
        try appendOwned(gpa, &message.body, delta);
    }

    pub fn appendThinkingDelta(
        self: *Thread,
        gpa: std.mem.Allocator,
        index: u32,
        delta: []const u8,
    ) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.kind == .thinking);
        try appendOwned(gpa, &message.body, delta);
    }

    pub fn insert(
        self: *Thread,
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

    pub fn select(self: *Thread, index: u32) void {
        assert(index < self.messages.items.len);
        assert(self.messages.items[index].kind.selectable());
        self.selected = index;
    }

    pub fn selectLast(self: *Thread) void {
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

    pub fn remove(self: *Thread, gpa: std.mem.Allocator, index: u32) void {
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

    pub fn startTool(self: *Thread, gpa: std.mem.Allocator, command: []const u8) !u32 {
        const title = try toolTitle(gpa, command);
        defer gpa.free(title);
        const index = try self.append(gpa, .tool, title, "");
        self.messages.items[index].expanded = false;
        return index;
    }

    pub fn updateTool(self: *Thread, gpa: std.mem.Allocator, index: u32, command: []const u8) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.kind == .tool);

        const title = try toolTitle(gpa, command);
        gpa.free(message.title);
        message.title = title;
    }

    pub fn finishThinking(self: *Thread, gpa: std.mem.Allocator, index: u32) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.kind == .thinking);
        if (std.mem.eql(u8, message.title, "Thoughts")) return;

        const title = try gpa.dupe(u8, "Thoughts");
        gpa.free(message.title);
        message.title = title;
    }

    pub fn finishTool(
        self: *Thread,
        gpa: std.mem.Allocator,
        index: u32,
        body: []const u8,
        stderr_body: ?[]const u8,
        failed: bool,
    ) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.kind == .tool);
        try appendOwned(gpa, &message.body, body);
        if (stderr_body) |stderr| {
            assert(stderr.len > 0);
            const owned = try gpa.dupe(u8, stderr);
            if (message.stderr_body) |existing| gpa.free(existing);
            message.stderr_body = owned;
        }
        message.failed = failed;
    }

    pub fn moveSelection(self: *Thread, direction: enum { previous, next }) void {
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

    pub fn toggleSelected(self: *Thread) void {
        const selected = self.selected orelse return;
        assert(selected < self.messages.items.len);
        const message = &self.messages.items[selected];
        switch (message.kind) {
            .thinking, .tool => message.expanded = !message.expanded,
            .user, .agent, .logo, .status => {},
        }
    }

    fn nearestSelectable(self: *const Thread, index: u32) ?u32 {
        assert(self.messages.items.len > 0);
        assert(index < self.messages.items.len);
        if (self.messages.items[index].kind.selectable()) return index;
        if (self.nextSelectable(index)) |next| return next;
        return self.previousSelectable(index);
    }

    fn previousSelectable(self: *const Thread, index: u32) ?u32 {
        assert(index < self.messages.items.len);
        var current = index;
        while (current > 0) {
            current -= 1;
            if (self.messages.items[current].kind.selectable()) return current;
        }
        return null;
    }

    fn nextSelectable(self: *const Thread, index: u32) ?u32 {
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
    const old = target.*;
    const joined = try gpa.alloc(u8, old.len + suffix.len);
    @memcpy(joined[0..old.len], old);
    @memcpy(joined[old.len..], suffix);
    gpa.free(old);
    target.* = joined;
}

fn toolTitle(gpa: std.mem.Allocator, command: []const u8) ![]u8 {
    return try std.fmt.allocPrint(gpa, "$ {s}", .{command});
}

test "thinking and tool messages are compact until toggled" {
    const gpa = std.testing.allocator;
    var thread: Thread = .{};
    defer thread.deinit(gpa);

    _ = try thread.append(gpa, .thinking, "thinking", "one two three four");
    try std.testing.expect(!thread.messages.items[0].expanded);
    thread.toggleSelected();
    try std.testing.expect(thread.messages.items[0].expanded);
}

test "selectLast selects last selectable before status tail" {
    const gpa = std.testing.allocator;
    var thread: Thread = .{};
    defer thread.deinit(gpa);

    _ = try thread.append(gpa, .agent, "agent", "one");
    _ = try thread.append(gpa, .status, "status", "loading");
    thread.selected = null;

    thread.selectLast();

    try std.testing.expectEqual(@as(?u32, 0), thread.selected);
}

test "consecutive tools remain separate messages" {
    const gpa = std.testing.allocator;
    var thread: Thread = .{};
    defer thread.deinit(gpa);

    const first = try thread.startTool(gpa, "ls");
    try thread.finishTool(gpa, first, "ls\n", null, false);
    const second = try thread.startTool(gpa, "pwd");
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(usize, 2), thread.messages.items.len);
    try std.testing.expectEqualStrings("$ ls", thread.messages.items[0].title);
    try std.testing.expectEqualStrings("$ pwd", thread.messages.items[1].title);
    try std.testing.expect(!thread.messages.items[0].expanded);
    try std.testing.expect(!thread.messages.items[1].expanded);
}

test "remove keeps selection in range" {
    const gpa = std.testing.allocator;
    var thread: Thread = .{};
    defer thread.deinit(gpa);

    _ = try thread.append(gpa, .user, "you", "one");
    _ = try thread.append(gpa, .agent, "agent", "two");
    thread.remove(gpa, 1);

    try std.testing.expectEqual(@as(usize, 1), thread.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), thread.selected.?);
}
