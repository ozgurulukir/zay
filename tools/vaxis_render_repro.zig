//! libvaxis clear/render and terminal-width reproduction.

const std = @import("std");
const vaxis = @import("vaxis");

const Demo = struct {
    frame: u8 = 0,

    fn widget(self: *Demo) vaxis.vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = handleEvent,
            .drawFn = draw,
        };
    }

    fn handleEvent(userdata: *anyopaque, ctx: *vaxis.vxfw.EventContext, event: vaxis.vxfw.Event) anyerror!void {
        const self: *Demo = @ptrCast(@alignCast(userdata));
        switch (event) {
            .init => {
                ctx.redraw = true;
                try ctx.tick(1500, self.widget());
            },
            .tick => {
                if (self.frame == 0) {
                    self.frame = 1;
                    ctx.consumeAndRedraw();
                }
            },
            .key_press => |key| {
                if (shouldQuit(key.codepoint)) ctx.quit = true;
            },
            else => {},
        }
    }

    fn shouldQuit(codepoint: u21) bool {
        if (codepoint == vaxis.Key.escape) return true;
        if (codepoint == 'q') return true;
        if (codepoint == 'Q') return true;
        return false;
    }

    fn draw(userdata: *anyopaque, ctx: vaxis.vxfw.DrawContext) std.mem.Allocator.Error!vaxis.vxfw.Surface {
        const self: *Demo = @ptrCast(@alignCast(userdata));
        const size = ctx.max.size();
        var surface: vaxis.vxfw.Surface = .{
            .size = size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = &.{},
        };

        const long_frame = [_][]const u8{
            "{",
            "  \"nodes\": 50422,",
            "  \"edges\": 162412,",
            "  \"sourceAvailable\": true,",
            "  \"hint\": \"⚠️ Index is 22 commits behind HEAD.\",",
            "  \"wide\": \"東京 🛠 e\\u{301}\",",
            "  \"previousPayload\": \"THIS QUOTE SHOULD DISAPPEAR\",",
            "}",
        };
        const short_frame = [_][]const u8{
            "{",
            "  \"nodes\": 42,",
            "  \"sourceAvailable\": true",
            "}",
        };
        const lines: []const []const u8 = if (self.frame == 0) &long_frame else &short_frame;
        const status = if (self.frame == 0)
            "FRAME A: long content is visible"
        else
            "FRAME B: old cells should now be blank";

        const child_height: u16 = if (self.frame == 0) 12 else 7;
        var child = try vaxis.vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = size.width,
            .height = child_height,
        });
        writeText(&child, ctx, 0, 0, "libvaxis width smoke test: frame A -> frame B");
        writeText(&child, ctx, 1, 0, status);
        for (lines, 2..) |line, row| {
            writeText(&child, ctx, @intCast(row), 0, line);
        }
        writeText(&child, ctx, child_height -| 1, 0, "Press q or Escape to exit.");

        var children = try ctx.arena.alloc(vaxis.vxfw.SubSurface, 1);
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = child,
            .z_index = 0,
        };
        surface.children = children;
        return surface;
    }

    fn writeText(
        surface: *vaxis.vxfw.Surface,
        ctx: vaxis.vxfw.DrawContext,
        row: u16,
        column: u16,
        text: []const u8,
    ) void {
        std.debug.assert(row < surface.size.height);
        var current_column = column;
        var iter = ctx.graphemeIterator(text);
        while (iter.next()) |grapheme| {
            if (current_column >= surface.size.width) break;
            const bytes = grapheme.bytes(text);
            const width: u8 = @intCast(ctx.stringWidth(bytes));
            if (width == 0) continue;
            if (current_column + width > surface.size.width) break;
            surface.writeCell(current_column, row, .{
                .char = .{ .grapheme = bytes, .width = width },
            });
            current_column += width;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var tty_buffer: [8192]u8 = undefined;
    var app = try vaxis.vxfw.App.init(init.io, init.gpa, init.environ_map, &tty_buffer);
    defer app.deinit();

    var demo: Demo = .{};
    try app.run(demo.widget(), .{ .framerate = 30 });
}
