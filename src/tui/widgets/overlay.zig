//! Mode overlay popup: the centered bordered box shown in command, session,
//! provider, model, tree, save-message, and lanes modes.
//!
//! Pulled out of `tui.zig` (R7.1 of `_pm/Projects/tui-split`) — the overlay
//! widget delegates the inner content to the per-mode picker widgets via
//! `OverlayInner.drawInner`, which is a mode switch over `App.mode` that
//! instantiates the right picker. The border label is set by `overlayLabel`,
//! and the popup size by `overlaySize`.
//!
//! Instantiated by `drawRoot` in `tui/root_layout.zig` and published as
//! `pub const OverlayWidget` via `tui.zig` re-export.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../../tui.zig");
const tui_style = @import("../style.zig");
const panel = @import("panel.zig");
const command_panel = @import("command_panel.zig");
const lanes_picker = @import("lanes_picker.zig");
const model_picker = @import("model_picker.zig");
const provider_picker = @import("provider_picker.zig");
const resume_picker = @import("resume_picker.zig");
const tree_selector = @import("tree_selector.zig");
const tui_status = @import("../status.zig");
const codex = @import("../../codex.zig");

const App = tui.App;
const StylePalette = tui_style.Palette;

const OverlaySize = struct { width: u16, height: u16 };

fn overlaySize(mode: App.Mode) OverlaySize {
    return switch (mode) {
        .normal => .{ .width = 0, .height = 0 },
        .command => .{ .width = 64, .height = 16 },
        .provider_picker => .{ .width = 72, .height = 16 },
        .session_picker => .{ .width = 80, .height = 16 },
        .model_picker => .{ .width = 90, .height = 16 },
        .tree_picker => .{ .width = 90, .height = 20 },
        .save_message => .{ .width = 60, .height = 3 },
        .lanes => .{ .width = 80, .height = 16 },
        .help => .{ .width = 80, .height = 18 },
        .diff_viewer => .{ .width = 0, .height = 0 },
    };
}

fn overlayLabel(app: *const App) []const u8 {
    return switch (app.mode) {
        .normal => "",
        .command => "Command",
        .session_picker => "Search for Sessions",
        .provider_picker => "Connect to Provider",
        .model_picker => "Select Model",
        .tree_picker => "Session Timeline",
        .save_message => "Commit Message",
        .help => "Help & Keyboard Shortcuts",
        .lanes => switch (app.nav.lanes_purpose) {
            .manage => "Parallel Lanes",
            .merge_dest => "Merge Into",
        },
        .diff_viewer => "",
    };
}

fn writeBorderLabel(surface: *vxfw.Surface, ctx: vxfw.DrawContext, text: []const u8) void {
    writeBorderLabelLeft(surface, ctx, 0, text, StylePalette.border_label);
}

fn writeBorderLabelLeft(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, text: []const u8, style: vaxis.Style) void {
    if (text.len == 0 or row >= surface.size.height) return;
    var col: u16 = 1;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const width: u16 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        if (col + width >= surface.size.width) break;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = bytes, .width = @intCast(width) },
            .style = style,
        });
        col += width;
    }
}

pub const OverlayWidget = struct {
    app: *App,

    pub fn widget(self: *OverlayWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawOverlay };
    }

    fn drawOverlay(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *OverlayWidget = @ptrCast(@alignCast(ptr));
        const size = if (self.app.mode == .provider_picker and self.app.pickers.provider.stage == .form)
            OverlaySize{ .width = 72, .height = 12 }
        else
            overlaySize(self.app.mode);
        const max_w: u16 = ctx.max.width orelse size.width;
        const max_h: u16 = ctx.max.height orelse size.height;
        const total_w: u16 = @min(size.width, max_w);
        const total_h: u16 = @min(size.height, max_h);
        var inner: OverlayInner = .{ .app = self.app };
        var border: vxfw.Border = .{
            .child = inner.widget(),
            .style = StylePalette.thinking_body,
        };
        var surface = try border.widget().draw(ctx.withConstraints(
            .{ .width = total_w, .height = total_h },
            .{ .width = total_w, .height = total_h },
        ));
        writeBorderLabel(&surface, ctx, overlayLabel(self.app));
        return surface;
    }
};

const OverlayInner = struct {
    app: *App,

    fn widget(self: *OverlayInner) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawInner };
    }

    fn drawInner(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *OverlayInner = @ptrCast(@alignCast(ptr));
        const iw: u16 = ctx.max.width orelse 0;
        const ih: u16 = ctx.max.height orelse 0;

        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = iw, .height = ih });

        // The provider setup form hosts its own inline editor, so it skips the
        // shared search row entirely and fills the panel from the top.
        if (self.app.mode == .provider_picker and self.app.pickers.provider.stage == .form) {
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{
                .origin = .{ .row = 0, .col = 0 },
                .z_index = 0,
                .surface = try drawContent(self.app, ctx.withConstraints(
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
                .style = StylePalette.thinking_body,
            });
        }

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);

        // Row 0: prompt + shared overlay search input.
        var prompt_text: vxfw.Text = .{ .text = ">", .softwrap = false, .width_basis = .parent };
        var prompt_box: vxfw.SizedBox = .{ .child = prompt_text.widget(), .size = .{ .width = 2, .height = 1 } };
        var input_box: vxfw.SizedBox = .{ .child = self.app.inputs.palette.widget(), .size = .{ .width = iw -| 2, .height = 1 } };
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
            .surface = try drawContent(self.app, content_ctx),
        };

        surface.children = children;
        return surface;
    }

    const help_picker = @import("help_picker.zig");

    fn drawContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        return switch (app.mode) {
            .command => drawCommandContent(app, ctx),
            .session_picker => drawSessionContent(app, ctx),
            .provider_picker => drawProviderContent(app, ctx),
            .model_picker => drawModelContent(app, ctx),
            .tree_picker => drawTreeContent(app, ctx),
            .save_message => drawSaveMessageContent(app, ctx),
            .lanes => drawLanesContent(app, ctx),
            .help => drawHelpContent(app, ctx),
            // The diff viewer is full-screen — `drawRoot` returns before the
            // overlay path, so this is never reached.
            .normal, .diff_viewer => unreachable,
        };
    }

    fn drawHelpContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        _ = app;
        var content: help_picker.Content = .{};
        return content.widget().draw(ctx);
    }

    fn drawSaveMessageContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        _ = app;
        // No body — the border label ("Commit Message") and the input row say it all.
        var text: vxfw.Text = .{ .text = "" };
        return text.widget().draw(ctx);
    }

    fn drawTreeContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var content: tree_selector.Content = .{
            .state = &app.pickers.tree,
            .list = &app.tree_list,
        };
        return content.widget().draw(ctx);
    }

    fn drawLanesContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const entries = try app.buildLaneEntries(ctx.arena);
        var content: lanes_picker.Content = .{
            .list = &app.lanes_list,
            .entries = entries,
            .selection = app.nav.lanes_selection,
            .empty_message = switch (app.nav.lanes_purpose) {
                .manage => "  No parked lanes.",
                .merge_dest => "  No lanes to merge into.",
            },
        };
        return content.widget().draw(ctx);
    }

    fn drawCommandContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const filter = try app.peekPaletteInput();
        defer app.gpa.free(filter);
        // Build the visible entry list (lane commands appear only with >1 lane);
        // resolveCommand applies the same visibility + filter, so indices align.
        var buf: [tui.commands.len]command_panel.Entry = undefined;
        var n: usize = 0;
        for (tui.commands) |entry| {
            if (!tui.commandVisible(app, entry)) continue;
            buf[n] = .{ .name = entry.name, .description = entry.description };
            n += 1;
        }
        var content: command_panel.Content = .{
            .entries = buf[0..n],
            .filter = filter,
            .selection = app.nav.command_selection,
        };
        return content.widget().draw(ctx);
    }

    fn drawSessionContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const filter = try app.peekPaletteInput();
        defer app.gpa.free(filter);
        var content: resume_picker.Content = .{
            .io = app.io,
            .list = &app.resume_list,
            .summaries = app.resume_summaries.items,
            .selection = app.nav.resume_selection,
            .folded_projects = app.resume_folded_projects.items,
            .filter = filter,
            .tree_mode = app.nav.resume_global,
        };
        return content.widget().draw(ctx);
    }

    fn drawProviderContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var content: provider_picker.Content = .{
            .state = app.pickers.provider,
            .codex_signed_in = app.isCodexSignedIn(),
            // `conn_status` is indexed by `catalogueProviders()` order, exactly
            // how the picker iterates its rows.
            .statuses = &app.conn_status,
            .key_input = app.provider_key_input.items,
            .api_keys = &app.provider_api_keys,
        };
        return content.widget().draw(ctx);
    }

    fn drawModelContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const filter = try app.peekPaletteInput();
        defer app.gpa.free(filter);
        const status = tui_status.modelStatus(app.liveRuntime(), app.cached_config);
        // Project the consolidated entries into the parallel slices the picker
        // widget consumes. Arena-allocated, rebuilt each draw — cheap, and it
        // keeps the picker decoupled from the catalogue's internal layout.
        const entries = app.pickers.models.entries.items;
        const picker_models = try ctx.arena.alloc(codex.Model, entries.len);
        const picker_reasoning = try ctx.arena.alloc(u32, entries.len);
        for (entries, 0..) |entry, i| {
            picker_models[i] = entry.model;
            picker_reasoning[i] = entry.reasoning_index;
        }
        var content: model_picker.Content = .{
            .models = picker_models,
            .list = &app.model_list,
            .selection = app.pickers.models.model_selection,
            .column = app.pickers.models.model_column,
            .active_model = if (status) |value| value.model else null,
            .reasoning_options = tui.reasoningOptions(),
            .reasoning_indexes = picker_reasoning,
            .scope = tui.modelPickerScope(app.pickers.models.model_scope),
            .filter = filter,
            .loading = app.pickers.models.model_load_future != null,
            .error_message = app.pickers.models.model_load_error,
        };
        return content.widget().draw(ctx);
    }
};
