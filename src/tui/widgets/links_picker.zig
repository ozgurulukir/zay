//! "Links in this message" picker (#504): lists every markdown and bare-URL
//! link in the selected transcript message, showing the full destination URL
//! and allowing keyboard-only users to copy or open any link.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const terminal_markdown = @import("terminal_markdown");
const panel = @import("panel.zig");
const tui_style = @import("../style.zig");
const text_fit = @import("../text_fit.zig");

pub const LinkItem = struct {
    label: []u8,
    url: []u8,
};

pub const State = struct {
    items: std.ArrayList(LinkItem) = .empty,
    selection: u32 = 0,

    pub fn reset(self: *State, gpa: std.mem.Allocator) void {
        for (self.items.items) |*item| {
            gpa.free(item.label);
            gpa.free(item.url);
        }
        self.items.clearRetainingCapacity();
        self.selection = 0;
    }

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.reset(gpa);
        self.items.deinit(gpa);
        self.* = undefined;
    }

    pub fn loadFromBody(self: *State, gpa: std.mem.Allocator, body: []const u8) !void {
        self.reset(gpa);
        var rendered = try terminal_markdown.render(gpa, body, 1000);
        defer rendered.deinit(gpa);

        for (rendered.rows) |row| {
            for (row.spans) |span| {
                if (span.link_url.len == 0) continue;
                const trimmed_text = std.mem.trim(u8, span.text, " \t");
                if (trimmed_text.len == 0) continue;
                var existing_idx: ?usize = null;
                for (self.items.items, 0..) |item, i| {
                    if (std.mem.eql(u8, item.url, span.link_url)) {
                        existing_idx = i;
                        break;
                    }
                }
                if (existing_idx) |idx| {
                    const cur = self.items.items[idx].label;
                    if (!std.mem.eql(u8, cur, trimmed_text) and !std.mem.eql(u8, trimmed_text, span.link_url)) {
                        if (std.mem.eql(u8, cur, span.link_url)) {
                            const replaced = try gpa.dupe(u8, trimmed_text);
                            gpa.free(cur);
                            self.items.items[idx].label = replaced;
                        } else {
                            const joined = try std.fmt.allocPrint(gpa, "{s} {s}", .{ cur, trimmed_text });
                            gpa.free(cur);
                            self.items.items[idx].label = joined;
                        }
                    }
                    continue;
                }
                const label = try gpa.dupe(u8, trimmed_text);
                errdefer gpa.free(label);
                const url = try gpa.dupe(u8, span.link_url);
                errdefer gpa.free(url);
                try self.items.append(gpa, .{ .label = label, .url = url });
            }
        }
    }

    pub fn selectedUrl(self: *const State) ?[]const u8 {
        if (self.selection >= self.items.items.len) return null;
        return self.items.items[self.selection].url;
    }
};

pub fn isAllowedOpenScheme(url: []const u8) bool {
    const prefixes = [_][]const u8{ "https://", "http://", "mailto:", "file://" };
    for (prefixes) |prefix| {
        if (url.len >= prefix.len and std.ascii.eqlIgnoreCase(url[0..prefix.len], prefix)) {
            return true;
        }
    }
    return false;
}

/// Open `url` in the platform's default handler as a bounded child process.
/// Never invokes a shell or plugin bridge.
pub fn openUrlInPlatform(io: std.Io, url: []const u8) !void {
    if (!isAllowedOpenScheme(url)) return error.DisallowedUrlScheme;
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", "", url },
        else => &.{ "xdg-open", url },
    };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = child.wait(io) catch {};
}

pub const Content = struct {
    state: *State,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        panel.fillBackground(&surface);
        if (width == 0 or height == 0) return surface;

        const items = self.state.items.items;
        if (items.len == 0) {
            panel.lineStyledAt(&surface, 0, "  No links in this message · Esc closes", ctx, 1, p.muted) catch {};
            return surface;
        }

        const list_height = if (height > 1) height - 1 else height;
        const viewport = panel.ViewportWindow.compute(self.state.selection, @intCast(items.len), list_height);
        var idx = viewport.start_index;
        while (idx < viewport.end_index) : (idx += 1) {
            const item = items[idx];
            const selected = idx == self.state.selection;
            const screen_row = viewport.screenRow(idx);
            const row_text = if (std.mem.eql(u8, item.label, item.url))
                item.url
            else
                try std.fmt.allocPrint(ctx.arena, "{s}  →  {s}", .{ item.label, item.url });
            try panel.commandLine(&surface, screen_row, row_text, ctx, selected);
        }
        panel.drawViewportScrollbar(&surface, viewport, @intCast(items.len));
        if (height > 1) {
            if (self.state.selectedUrl()) |url| {
                if (text_fit.measure(url) > width -| 4) {
                    panel.drawDetailFooter(&surface, ctx, height - 1, url);
                } else {
                    panel.lineStyledAt(&surface, height - 1, "  Enter/y: copy · o: open · Esc: close", ctx, 1, p.muted) catch {};
                }
            }
        }
        return surface;
    }
};

test "State.loadFromBody extracts markdown and bare URLs without duplicates" {
    const gpa = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(gpa);

    const body = "Read [docs](https://zay.org/docs) and https://example.com/a plus https://zay.org/docs";
    try state.loadFromBody(gpa, body);

    try std.testing.expectEqual(@as(usize, 2), state.items.items.len);
    try std.testing.expectEqualStrings("docs", state.items.items[0].label);
    try std.testing.expectEqualStrings("https://zay.org/docs", state.items.items[0].url);
    try std.testing.expectEqualStrings("https://example.com/a", state.items.items[1].url);
}

test "isAllowedOpenScheme rejects javascript and data URIs" {
    try std.testing.expect(isAllowedOpenScheme("https://example.com"));
    try std.testing.expect(isAllowedOpenScheme("HTTP://example.com"));
    try std.testing.expect(isAllowedOpenScheme("mailto:a@b.c"));
    try std.testing.expect(!isAllowedOpenScheme("javascript:alert(1)"));
    try std.testing.expect(!isAllowedOpenScheme("data:text/plain,hi"));
}
