const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");

const tui_style = @import("../style.zig");
const StylePalette = tui_style.Palette;

pub const Entry = struct {
    name: []const u8,
    description: []const u8 = "",
    category: []const u8 = "",
};

pub const Content = struct {
    entries: []const Entry,
    filter: []const u8,
    selection: u32,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        try self.drawEntries(&surface, ctx);
        return surface;
    }

    fn drawEntries(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        var row: u16 = 0;
        var index: u32 = 0;
        for (self.entries) |entry| {
            if (!matchesCommandFilter(entry.name, entry.description, self.filter)) continue;
            const selected = index == self.selection;
            const text = try std.fmt.allocPrint(ctx.arena, "  /{s}", .{entry.name});
            try panel.commandLine(surface, row, text, ctx, selected);
            if (entry.description.len > 0 and surface.size.width > 24) {
                const desc_style = if (selected) StylePalette.selected_item else StylePalette.thinking_body;
                _ = panel.writeBorderTextEndingAt(surface, ctx, row, surface.size.width -| 2, entry.description, desc_style);
            }
            row += 1;
            index += 1;
            if (row >= surface.size.height) return;
        }
    }
};

pub fn matchesCommandFilter(name: []const u8, description: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (startsWithIgnoreCase(name, filter)) return true;
    if (containsIgnoreCase(name, filter)) return true;
    if (containsIgnoreCase(description, filter)) return true;
    return false;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (prefix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "command panel filters entries case-insensitively and fuzzy/substring" {
    const entries = [_]Entry{ .{ .name = "Connect", .description = "Configure AI provider" }, .{ .name = "Resume", .description = "Past session" } };
    try std.testing.expect(matchesCommandFilter(entries[0].name, entries[0].description, "co"));
    try std.testing.expect(matchesCommandFilter(entries[0].name, entries[0].description, "nect"));
    try std.testing.expect(matchesCommandFilter(entries[0].name, entries[0].description, "provider"));
    try std.testing.expect(!matchesCommandFilter(entries[1].name, entries[1].description, "co"));
}
