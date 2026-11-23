//! Pure overlay chrome and widget composition (INV-WIDGET-1).
//!
//! `SearchableOverlayChrome` renders a bordered popup with an optional `>`
//! search `TextField` + `─` separator and an arbitrary child `vxfw.Widget`.
//! `OverlayWidget` composes `SearchableOverlayChrome` with the pure per-mode
//! leaf widget view models built at the frame boundary by `overlay_builder.zig`.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const app_state = @import("../app_state.zig");
const tui_style = @import("../style.zig");
const command_panel = @import("command_panel.zig");
const help_picker = @import("help_picker.zig");
const lanes_picker = @import("lanes_picker.zig");
const links_picker = @import("links_picker.zig");
const mcp_status = @import("mcp_status.zig");
const model_picker = @import("model_picker.zig");
const panel = @import("panel.zig");
const plugins_status = @import("plugins_status.zig");
const provider_picker = @import("provider_picker.zig");
const resume_picker = @import("resume_picker.zig");
const search_widget = @import("search.zig");
const settings_widget = @import("settings.zig");
const theme_picker = @import("theme_picker.zig");
const tree_selector = @import("tree_selector.zig");

const Mode = app_state.Mode;

pub const OverlaySize = struct { width: u16, height: u16 };

pub fn preferredOverlaySize(mode: Mode) OverlaySize {
    return switch (mode) {
        .normal => .{ .width = 0, .height = 0 },
        .command => .{ .width = 64, .height = 16 },
        .provider_picker => .{ .width = 72, .height = 16 },
        .session_picker => .{ .width = 80, .height = 16 },
        .model_picker => .{ .width = 90, .height = 16 },
        .tree_picker => .{ .width = 90, .height = 20 },
        .save_message => .{ .width = 60, .height = 3 },
        .lanes => .{ .width = 80, .height = 16 },
        .help => .{ .width = 90, .height = help_picker.help_overlay_height },
        .settings => .{ .width = 90, .height = 25 },
        .mcp => .{ .width = 90, .height = 20 },
        .plugins => .{ .width = 80, .height = 16 },
        .search => .{ .width = 90, .height = 20 },
        .theme_picker => .{ .width = 64, .height = 16 },
        .link_picker => .{ .width = 90, .height = 16 },
        .diff_viewer => .{ .width = 0, .height = 0 },
    };
}

pub fn isListPicker(mode: Mode) bool {
    return switch (mode) {
        .command, .session_picker, .model_picker, .tree_picker, .lanes, .help, .mcp, .plugins, .search, .theme_picker, .link_picker => true,
        else => false,
    };
}

pub fn overlaySize(mode: Mode, max_cols: u16, max_rows: u16) OverlaySize {
    if (mode == .normal or mode == .diff_viewer) return .{ .width = 0, .height = 0 };

    if (mode == .save_message) {
        const min_w = @min(@as(u16, 40), max_cols);
        const max_w_target = (max_cols * 9) / 10;
        const upper_w = @min(max_cols, @max(min_w, max_w_target));
        const w = @max(min_w, @min(@as(u16, 60), upper_w));
        const h = @min(@as(u16, 3), max_rows);
        return .{ .width = w, .height = h };
    }

    const pref = preferredOverlaySize(mode);

    // Width: clamp(preferred, 40, ~90% of columns)
    const min_w = @min(@as(u16, 40), max_cols);
    const max_w_target = (max_cols * 9) / 10;
    const upper_w = @min(max_cols, @max(min_w, max_w_target));
    const width = if (pref.width <= min_w)
        min_w
    else if (pref.width >= upper_w)
        upper_w
    else
        pref.width;

    // Height: clamp(preferred, 8, ~70% of rows), growing list pickers on tall terminals (rows >= 35)
    const min_h = @min(@as(u16, 8), max_rows);
    const max_h_target = (max_rows * 7) / 10;
    const upper_h = @min(max_rows, @max(min_h, max_h_target));
    const height = if (max_rows >= 35 and isListPicker(mode) and upper_h > pref.height)
        upper_h
    else if (pref.height < min_h)
        min_h
    else
        @min(pref.height, upper_h);

    return .{ .width = width, .height = height };
}

/// Pure searchable overlay chrome: border + label + optional `>` search
/// `TextField` + `─` separator + child `vxfw.Widget`. Zero App-pointer dependency.
pub const SearchableOverlayChrome = struct {
    label: []const u8,
    width: u16,
    height: u16,
    full_panel: bool = false,
    palette_input: ?*vxfw.TextField = null,
    fill_background: bool = true,
    content: vxfw.Widget,

    pub fn widget(self: *SearchableOverlayChrome) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *SearchableOverlayChrome = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        const max_w: u16 = ctx.max.width orelse 80;
        const max_h: u16 = ctx.max.height orelse 24;
        const total_w: u16 = @min(self.width, max_w);
        const total_h: u16 = @min(self.height, max_h);

        var inner: ChromeInner = .{
            .full_panel = self.full_panel or self.palette_input == null,
            .palette_input = self.palette_input,
            .fill_background = self.fill_background,
            .content = self.content,
        };
        const border_labels: []const vxfw.Border.BorderLabel = if (self.label.len > 0)
            &.{.{ .text = self.label, .alignment = .top_left }}
        else
            &.{};
        var border: vxfw.Border = .{
            .child = inner.widget(),
            .labels = border_labels,
            .style = p.border,
        };
        return border.widget().draw(ctx.withConstraints(
            .{ .width = total_w, .height = total_h },
            .{ .width = total_w, .height = total_h },
        ));
    }
};

const ChromeInner = struct {
    full_panel: bool,
    palette_input: ?*vxfw.TextField,
    fill_background: bool,
    content: vxfw.Widget,

    fn widget(self: *ChromeInner) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawInner };
    }

    fn drawInner(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *ChromeInner = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        const iw: u16 = ctx.max.width orelse 0;
        const ih: u16 = ctx.max.height orelse 0;

        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = iw, .height = ih });
        if (self.fill_background) panel.fillBackground(&surface);

        if (self.full_panel or self.palette_input == null) {
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{
                .origin = .{ .row = 0, .col = 0 },
                .z_index = 0,
                .surface = try self.content.draw(ctx.withConstraints(
                    .{ .width = iw, .height = ih },
                    .{ .width = iw, .height = ih },
                )),
            };
            surface.children = children;
            return surface;
        }

        // Horizontal separator under the search row.
        var sep_col: u16 = 0;
        while (sep_col < iw) : (sep_col += 1) {
            surface.writeCell(sep_col, 1, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = p.border,
            });
        }

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);

        // Row 0: prompt + shared overlay search input.
        var prompt_text: vxfw.Text = .{ .text = ">", .softwrap = false, .width_basis = .parent };
        var prompt_box: vxfw.SizedBox = .{ .child = prompt_text.widget(), .size = .{ .width = 2, .height = 1 } };
        var input_box: vxfw.SizedBox = .{ .child = self.palette_input.?.widget(), .size = .{ .width = iw -| 2, .height = 1 } };
        var search_row: vxfw.FlexRow = .{ .children = &.{
            .{ .widget = prompt_box.widget(), .flex = 0 },
            .{ .widget = input_box.widget(), .flex = 1 },
        } };
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .z_index = 0,
            .surface = try search_row.widget().draw(ctx.withConstraints(
                .{ .width = iw, .height = 1 },
                .{ .width = iw, .height = 1 },
            )),
        };

        // Rows 2..: mode-specific content area.
        const content_h: u16 = ih -| 2;
        const content_ctx = ctx.withConstraints(
            .{ .width = iw, .height = content_h },
            .{ .width = iw, .height = content_h },
        );
        children[1] = .{
            .origin = .{ .row = 2, .col = 0 },
            .z_index = 0,
            .surface = try self.content.draw(content_ctx),
        };

        surface.children = children;
        return surface;
    }
};

pub const OverlayContent = union(enum) {
    command: command_panel.Content,
    session: resume_picker.Content,
    provider: provider_picker.Content,
    model: model_picker.Content,
    tree: tree_selector.Content,
    save_message: vxfw.Text,
    lanes: lanes_picker.Content,
    help: help_picker.Content,
    settings: settings_widget.Content,
    mcp: mcp_status.Content,
    plugins: plugins_status.Content,
    search: search_widget.Content,
    theme: theme_picker.Content,
    links: links_picker.Content,

    pub fn widget(self: *OverlayContent) vxfw.Widget {
        return switch (self.*) {
            inline else => |*c| c.widget(),
        };
    }
};

pub const OverlayWidget = struct {
    label: []const u8,
    width: u16,
    height: u16,
    full_panel: bool,
    palette_input: ?*vxfw.TextField,
    content: OverlayContent,

    pub fn widget(self: *OverlayWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawOverlay };
    }

    fn drawOverlay(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *OverlayWidget = @ptrCast(@alignCast(ptr));
        var chrome: SearchableOverlayChrome = .{
            .label = self.label,
            .width = self.width,
            .height = self.height,
            .full_panel = self.full_panel,
            .palette_input = self.palette_input,
            .fill_background = true,
            .content = self.content.widget(),
        };
        return chrome.widget().draw(ctx);
    }
};

test "overlaySize gives every mode a panel and zeroes the chromeless ones" {
    // Exhaustive over the Mode enum: a mode added without an overlay size
    // must fail here, not show up as a zero-sized popup at runtime.
    inline for (std.meta.fields(Mode)) |field| {
        const mode: Mode = @enumFromInt(field.value);
        const size = overlaySize(mode, 100, 30);
        switch (mode) {
            // Rendered inline, no overlay panel.
            .normal, .diff_viewer => {
                try std.testing.expectEqual(@as(u16, 0), size.width);
                try std.testing.expectEqual(@as(u16, 0), size.height);
            },
            // Every other mode gets a visible panel.
            else => {
                try std.testing.expect(size.width > 0);
                try std.testing.expect(size.height > 0);
            },
        }
    }
}

test "overlaySize pins known panel dimensions on standard terminal" {
    try std.testing.expectEqual(@as(u16, 64), overlaySize(.command, 100, 30).width);
    try std.testing.expectEqual(@as(u16, 90), overlaySize(.settings, 100, 40).width);
    try std.testing.expectEqual(@as(u16, 25), overlaySize(.settings, 100, 40).height);
    try std.testing.expectEqual(@as(u16, 20), overlaySize(.tree_picker, 100, 30).height);
    try std.testing.expectEqual(@as(u16, 3), overlaySize(.save_message, 100, 30).height);
}

test "overlaySize table-driven across heights 5..80 and widths 20..200" {
    const heights = [_]u16{ 5, 8, 12, 24, 40, 60, 80 };
    const widths = [_]u16{ 20, 35, 50, 80, 100, 160, 200 };
    const modes = [_]Mode{ .command, .session_picker, .tree_picker, .help, .settings, .save_message };

    for (heights) |h| {
        for (widths) |w| {
            for (modes) |m| {
                const s = overlaySize(m, w, h);
                try std.testing.expect(s.width <= w);
                try std.testing.expect(s.height <= h);

                if (m == .save_message) {
                    try std.testing.expect(s.height <= 3);
                } else {
                    if (h >= 40) {
                        try std.testing.expect(s.height >= 20);
                    }
                    try std.testing.expect(s.width > 0);
                    try std.testing.expect(s.height > 0);
                }
            }
        }
    }
}
