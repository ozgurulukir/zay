//! The status bar widget: right-aligned telemetry segments (velocity, meter,
//! model status).
//!
//! Composed from vxfw layout widgets (`FlexRow`, `Text`, `SizedBox`) so the
//! bar degrades gracefully on narrow terminals: velocity drops first, meter
//! second, model status always visible (ellipsis-truncated if it alone exceeds
//! width).

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui_style = @import("../style.zig");

const Palette = tui_style.Palette;

/// A single status bar segment descriptor.
pub const Segment = struct {
    text: []const u8,
    style: vaxis.Style,
    width: u16,
};

/// Priority ranking for extensible status bar segments.
/// When terminal width shrinks, lower priority segments drop first.
pub const SegmentPriority = enum(u8) {
    critical = 0, // Must always remain visible (e.g. status/model indicator, truncated if needed)
    high = 1, // High importance (e.g. context meter, lane indicator)
    medium = 2, // Medium importance (e.g. token velocity, git branch, background jobs)
    low = 3, // Low importance (e.g. session title, cwd path, secondary hints)
};

pub const BarSegment = struct {
    id: []const u8 = "",
    text: []const u8,
    style: vaxis.Style = .{},
    priority: SegmentPriority = .medium,
    gap_before: u16 = 1,
};

/// The result of `layoutStatusBar` or `layoutSegments`: which segments survive
/// and their combined width.
pub const Layout = struct {
    segments: []const Segment,
    total_width: u16,
};

/// Generalized priority-based status bar segment layout.
/// Progressively drops lower-priority segments when available columns are constrained.
pub fn layoutSegments(
    arena: std.mem.Allocator,
    available_width: u16,
    candidates: []const BarSegment,
) Layout {
    if (available_width == 0 or candidates.len == 0) {
        return .{ .segments = &.{}, .total_width = 0 };
    }

    var priority_ceiling: u8 = @intFromEnum(SegmentPriority.low);
    while (true) {
        var active_count: usize = 0;
        var needed_width: u16 = 0;

        for (candidates) |cand| {
            if (cand.text.len == 0) continue;
            if (@intFromEnum(cand.priority) > priority_ceiling) continue;
            const w: u16 = @intCast(@min(vaxis.gwidth.gwidth(cand.text, .unicode), std.math.maxInt(u16)));
            if (w == 0) continue;
            const gap: u16 = if (active_count > 0) cand.gap_before else 0;
            needed_width += gap + w;
            active_count += 1;
        }

        if (needed_width <= available_width) {
            if (active_count == 0) return .{ .segments = &.{}, .total_width = 0 };
            const segs = arena.alloc(Segment, active_count) catch return .{ .segments = &.{}, .total_width = 0 };
            var idx: usize = 0;
            for (candidates) |cand| {
                if (cand.text.len == 0) continue;
                if (@intFromEnum(cand.priority) > priority_ceiling) continue;
                const w: u16 = @intCast(@min(vaxis.gwidth.gwidth(cand.text, .unicode), std.math.maxInt(u16)));
                if (w == 0) continue;
                segs[idx] = .{ .text = cand.text, .style = cand.style, .width = w };
                idx += 1;
            }
            return .{ .segments = segs, .total_width = needed_width };
        }

        if (priority_ceiling > 0) {
            priority_ceiling -= 1;
        } else {
            // Even critical segments alone exceed available_width:
            // Truncate the first critical segment to available_width
            for (candidates) |cand| {
                if (cand.text.len == 0) continue;
                if (cand.priority == .critical) {
                    const segs = arena.alloc(Segment, 1) catch return .{ .segments = &.{}, .total_width = 0 };
                    segs[0] = .{ .text = cand.text, .style = cand.style, .width = available_width };
                    return .{ .segments = segs, .total_width = available_width };
                }
            }
            return .{ .segments = &.{}, .total_width = 0 };
        }
    }
}

/// Transparent 1x1 spacer widget: lets the border `─` show through the gap
/// between the left block and the meter.
const spacer_dummy: u8 = 0;
const spacer_widget = vxfw.Widget{
    .userdata = @ptrCast(@constCast(&spacer_dummy)),
    .drawFn = drawSpacer,
};

fn drawSpacer(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    return vxfw.Surface{
        .size = .{ .width = 1, .height = 1 },
        .widget = spacer_widget,
        .buffer = &.{},
        .children = &.{},
    };
}

/// Compute which status bar segments survive within `available_width`.
///
/// Priority: status always (ellipsized if alone and too wide); add meter if it
/// fits; add velocity if it fits after that. The left block (velocity+status or
/// just one of them) is separated from the meter by a 1-cell gap.
///
/// Pure: no I/O.
pub fn layoutStatusBar(
    arena: std.mem.Allocator,
    available_width: u16,
    velocity_text: []const u8,
    meter_text: []const u8,
    meter_style: vaxis.Style,
    status_text: []const u8,
    status_style: vaxis.Style,
) Layout {
    if (available_width == 0) {
        return .{ .segments = &.{}, .total_width = 0 };
    }

    const status_width: u16 = @intCast(@min(vaxis.gwidth.gwidth(status_text, .unicode), std.math.maxInt(u16)));
    const meter_width: u16 = @intCast(@min(vaxis.gwidth.gwidth(meter_text, .unicode), std.math.maxInt(u16)));
    const velocity_width: u16 = @intCast(@min(vaxis.gwidth.gwidth(velocity_text, .unicode), std.math.maxInt(u16)));

    const has_velocity = velocity_text.len > 0 and velocity_width > 0;
    const has_status = status_text.len > 0 and status_width > 0;
    const has_meter = meter_text.len > 0 and meter_width > 0;

    const full_left_width: u16 = if (has_velocity and has_status)
        velocity_width + 2 + status_width
    else if (has_velocity)
        velocity_width
    else
        status_width;

    const gap_width: u16 = if (has_meter and full_left_width > 0) 1 else 0;
    const all_three_width = full_left_width + gap_width + (if (has_meter) meter_width else 0);

    // 1. Check if all three (or whatever is present including velocity) fit.
    if (has_velocity and all_three_width <= available_width) {
        const left_text = if (has_status)
            std.fmt.allocPrint(arena, "{s}  {s}", .{ velocity_text, status_text }) catch status_text
        else
            velocity_text;

        var count: usize = 0;
        if (full_left_width > 0) count += 1;
        if (has_meter) count += 1;

        const segs = arena.alloc(Segment, count) catch return .{ .segments = &.{}, .total_width = 0 };
        var idx: usize = 0;
        if (full_left_width > 0) {
            segs[idx] = .{ .text = left_text, .style = status_style, .width = full_left_width };
            idx += 1;
        }
        if (has_meter) {
            segs[idx] = .{ .text = meter_text, .style = meter_style, .width = meter_width };
            idx += 1;
        }
        return .{
            .segments = segs,
            .total_width = all_three_width,
        };
    }

    // 2. Velocity dropped (or not present). Try status + meter.
    const status_gap_width: u16 = if (has_meter and has_status) 1 else 0;
    const status_meter_width = status_width + status_gap_width + (if (has_meter) meter_width else 0);

    if (has_meter and status_meter_width <= available_width) {
        var count: usize = 0;
        if (has_status) count += 1;
        count += 1; // meter

        const segs = arena.alloc(Segment, count) catch return .{ .segments = &.{}, .total_width = 0 };
        var idx: usize = 0;
        if (has_status) {
            segs[idx] = .{ .text = status_text, .style = status_style, .width = status_width };
            idx += 1;
        }
        segs[idx] = .{ .text = meter_text, .style = meter_style, .width = meter_width };
        return .{
            .segments = segs,
            .total_width = status_meter_width,
        };
    }

    // 3. Meter dropped (or not present). Try status only.
    if (status_width <= available_width) {
        if (!has_status) {
            return .{ .segments = &.{}, .total_width = 0 };
        }
        const segs = arena.alloc(Segment, 1) catch return .{ .segments = &.{}, .total_width = 0 };
        segs[0] = .{ .text = status_text, .style = status_style, .width = status_width };
        return .{
            .segments = segs,
            .total_width = status_width,
        };
    }

    // 4. Status alone exceeds available_width: truncate/ellipsize status.
    const segs = arena.alloc(Segment, 1) catch return .{ .segments = &.{}, .total_width = 0 };
    segs[0] = .{ .text = status_text, .style = status_style, .width = available_width };
    return .{
        .segments = segs,
        .total_width = available_width,
    };
}

/// A status-bar view model. Skill inventory text is rendered as a separate
/// status segment so metadata never changes transcript geometry or selection.
pub const StatusBarWidget = struct {
    status_text: []const u8 = "no model",
    meter_text: []const u8 = "",
    meter_style: ?vaxis.Style = null,
    velocity_text: []const u8 = "",
    /// Active durable skill names, when the TUI config opts into showing them.
    skill_inventory: []const []const u8 = &.{},
    /// Custom candidate segments overriding the default layout when non-empty.
    custom_segments: []const BarSegment = &.{},

    pub fn widget(self: *StatusBarWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = draw,
        };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *StatusBarWidget = @ptrCast(@alignCast(ptr));
        const max_width = ctx.max.width orelse ctx.min.width;
        const p = tui_style.activePalette();

        const available_width = max_width -| 2;
        var status = self.status_text;
        var inventory: std.ArrayList(u8) = .empty;
        defer inventory.deinit(ctx.arena);
        if (self.skill_inventory.len > 0) {
            if (self.status_text.len > 0) {
                try inventory.appendSlice(ctx.arena, self.status_text);
                try inventory.appendSlice(ctx.arena, " · ");
            }
            try inventory.appendSlice(ctx.arena, "skills: ");
            for (self.skill_inventory, 0..) |name, index| {
                if (index > 0) try inventory.appendSlice(ctx.arena, ", ");
                try inventory.appendSlice(ctx.arena, name);
            }
            status = inventory.items;
        }
        const layout = if (self.custom_segments.len > 0)
            layoutSegments(ctx.arena, available_width, self.custom_segments)
        else
            layoutStatusBar(
                ctx.arena,
                available_width,
                self.velocity_text,
                self.meter_text,
                self.meter_style orelse p.model_status,
                status,
                p.model_status,
            );

        if (layout.segments.len == 0 or layout.total_width == 0) {
            return vxfw.Surface{
                .size = .{ .width = max_width, .height = 1 },
                .widget = self.widget(),
                .buffer = &.{},
                .children = &.{},
            };
        }

        const max_flex = layout.segments.len * 2;
        const flex_children = try ctx.arena.alloc(vxfw.FlexItem, max_flex);
        var child_count: usize = 0;

        for (layout.segments, 0..) |seg, i| {
            if (i > 0) {
                flex_children[child_count] = .{ .widget = spacer_widget, .flex = 0 };
                child_count += 1;
            }
            const text_widget = try ctx.arena.create(vxfw.Text);
            text_widget.* = .{
                .text = seg.text,
                .softwrap = false,
                .overflow = .ellipsis,
                .width_basis = .longest_line,
                .style = seg.style,
            };
            const box_widget = try ctx.arena.create(vxfw.SizedBox);
            box_widget.* = .{
                .child = text_widget.widget(),
                .size = .{ .width = seg.width, .height = 1 },
            };
            flex_children[child_count] = .{ .widget = box_widget.widget(), .flex = 0 };
            child_count += 1;
        }

        var flex_row: vxfw.FlexRow = .{ .children = flex_children[0..child_count] };
        const flex_surface = try flex_row.widget().draw(ctx);

        const origin_col = (max_width -| 2) -| layout.total_width;
        const child_buf = try ctx.arena.alloc(vxfw.SubSurface, 1);
        child_buf[0] = .{
            .origin = .{ .row = 0, .col = origin_col },
            .surface = flex_surface,
            .z_index = 0,
        };

        return vxfw.Surface{
            .size = .{ .width = max_width, .height = 1 },
            .widget = self.widget(),
            .buffer = &.{},
            .children = child_buf,
        };
    }
};

// --- Tests ---

test "layoutStatusBar keeps all three when they fit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const meter_style: vaxis.Style = .{ .fg = .{ .index = 2 } };
    const status_style: vaxis.Style = .{ .fg = .{ .index = 7 } };

    const layout = layoutStatusBar(
        arena.allocator(),
        50,
        "⚡ 5.0",
        "[███░░░] 50%",
        meter_style,
        "openai · gpt-4",
        status_style,
    );
    try std.testing.expectEqual(@as(usize, 2), layout.segments.len);
    try std.testing.expectEqualStrings("⚡ 5.0  openai · gpt-4", layout.segments[0].text);
    try std.testing.expectEqual(@as(u16, 22), layout.segments[0].width);
    try std.testing.expectEqualStrings("[███░░░] 50%", layout.segments[1].text);
    try std.testing.expectEqual(@as(u16, 12), layout.segments[1].width);
    try std.testing.expectEqual(@as(u16, 35), layout.total_width);
}

test "layoutStatusBar drops velocity when all three do not fit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const meter_style: vaxis.Style = .{ .fg = .{ .index = 2 } };
    const status_style: vaxis.Style = .{ .fg = .{ .index = 7 } };

    // available_width = 30: 34 (all three) doesn't fit, but 27 (status + gap + meter = 14 + 1 + 12) fits.
    const layout = layoutStatusBar(
        arena.allocator(),
        30,
        "⚡ 5.0",
        "[███░░░] 50%",
        meter_style,
        "openai · gpt-4",
        status_style,
    );
    try std.testing.expectEqual(@as(usize, 2), layout.segments.len);
    try std.testing.expectEqualStrings("openai · gpt-4", layout.segments[0].text);
    try std.testing.expectEqual(@as(u16, 14), layout.segments[0].width);
    try std.testing.expectEqualStrings("[███░░░] 50%", layout.segments[1].text);
    try std.testing.expectEqual(@as(u16, 12), layout.segments[1].width);
    try std.testing.expectEqual(@as(u16, 27), layout.total_width);
}

test "layoutStatusBar drops meter when meter+status do not fit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const meter_style: vaxis.Style = .{ .fg = .{ .index = 2 } };
    const status_style: vaxis.Style = .{ .fg = .{ .index = 7 } };

    // available_width = 20: 27 (status + meter) doesn't fit, but 14 (status) fits.
    const layout = layoutStatusBar(
        arena.allocator(),
        20,
        "⚡ 5.0",
        "[███░░░] 50%",
        meter_style,
        "openai · gpt-4",
        status_style,
    );
    try std.testing.expectEqual(@as(usize, 1), layout.segments.len);
    try std.testing.expectEqualStrings("openai · gpt-4", layout.segments[0].text);
    try std.testing.expectEqual(@as(u16, 14), layout.segments[0].width);
    try std.testing.expectEqual(@as(u16, 14), layout.total_width);
}

test "layoutStatusBar truncates/ellipsizes status when alone and too wide" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const meter_style: vaxis.Style = .{ .fg = .{ .index = 2 } };
    const status_style: vaxis.Style = .{ .fg = .{ .index = 7 } };

    // available_width = 10: 14 (status) doesn't fit -> truncated to 10.
    const layout = layoutStatusBar(
        arena.allocator(),
        10,
        "⚡ 5.0",
        "[███░░░] 50%",
        meter_style,
        "openai · gpt-4",
        status_style,
    );
    try std.testing.expectEqual(@as(usize, 1), layout.segments.len);
    try std.testing.expectEqualStrings("openai · gpt-4", layout.segments[0].text);
    try std.testing.expectEqual(@as(u16, 10), layout.segments[0].width);
    try std.testing.expectEqual(@as(u16, 10), layout.total_width);
}

test "layoutStatusBar skips empty velocity and meter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const meter_style: vaxis.Style = .{ .fg = .{ .index = 2 } };
    const status_style: vaxis.Style = .{ .fg = .{ .index = 7 } };

    const layout = layoutStatusBar(
        arena.allocator(),
        20,
        "",
        "",
        meter_style,
        "openai · gpt-4",
        status_style,
    );
    try std.testing.expectEqual(@as(usize, 1), layout.segments.len);
    try std.testing.expectEqualStrings("openai · gpt-4", layout.segments[0].text);
    try std.testing.expectEqual(@as(u16, 14), layout.segments[0].width);
    try std.testing.expectEqual(@as(u16, 14), layout.total_width);
}

test "status bar rightmost segment lands at max_width - 3" {
    const gpa = std.testing.allocator;

    var widget: StatusBarWidget = .{
        .status_text = "openai · gpt-4o",
        .meter_text = "50k / 128k [39%]",
        .velocity_text = "10.0 tok/s",
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const max_width: u16 = 80;
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = max_width, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try widget.widget().draw(ctx);

    // The FlexRow is the only child, placed at origin.col = (max_width -| 2) -| total_width.
    try std.testing.expectEqual(@as(usize, 1), surface.children.len);
    const flex_origin = surface.children[0].origin.col;
    const available_width = max_width -| 2;
    const expected_origin = available_width -| surface.children[0].surface.size.width;
    try std.testing.expectEqual(expected_origin, flex_origin);

    // Rightmost segment's last cell = origin + width - 1 = max_width - 3.
    const rightmost_cell = flex_origin + surface.children[0].surface.size.width - 1;
    try std.testing.expectEqual(max_width -| 3, rightmost_cell);
}

test "StatusBarWidget keeps skill inventory opt-in at the view-model boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var hidden: StatusBarWidget = .{ .status_text = "model", .skill_inventory = &.{} };
    const hidden_ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const hidden_surface = try hidden.widget().draw(hidden_ctx);
    try std.testing.expect(hidden_surface.children.len > 0);

    var shown: StatusBarWidget = .{ .status_text = "model", .skill_inventory = &.{"how"} };
    const shown_surface = try shown.widget().draw(hidden_ctx);
    try std.testing.expect(shown_surface.children.len > 0);
}

test "StatusBarWidget renders velocity during thinking activity" {
    const gpa = std.testing.allocator;

    var widget: StatusBarWidget = .{
        .status_text = "openai · gpt-4o",
        .velocity_text = "25.0 tok/s",
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const max_width: u16 = 80;
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = max_width, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try widget.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 1), surface.children.len);
    try std.testing.expect(surface.children[0].surface.size.width > 0);
}

test "layoutSegments drops segments according to priority when constrained" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const candidates = [_]BarSegment{
        .{ .id = "lane", .text = "[1/2]", .priority = .high },
        .{ .id = "status", .text = "claude-3-5", .priority = .critical },
        .{ .id = "velocity", .text = "⚡ 45", .priority = .medium },
        .{ .id = "title", .text = "feature-auth", .priority = .low },
    };

    // Width 50: all 4 fit
    const full = layoutSegments(arena.allocator(), 50, &candidates);
    try std.testing.expectEqual(@as(usize, 4), full.segments.len);
    try std.testing.expectEqualStrings("[1/2]", full.segments[0].text);
    try std.testing.expectEqualStrings("feature-auth", full.segments[3].text);

    // Width 28: low priority ("feature-auth", len 12) drops first
    const med = layoutSegments(arena.allocator(), 28, &candidates);
    try std.testing.expectEqual(@as(usize, 3), med.segments.len);
    try std.testing.expectEqualStrings("[1/2]", med.segments[0].text);
    try std.testing.expectEqualStrings("claude-3-5", med.segments[1].text);
    try std.testing.expectEqualStrings("⚡ 45", med.segments[2].text);

    // Width 20: medium priority ("⚡ 45") drops next
    const high = layoutSegments(arena.allocator(), 20, &candidates);
    try std.testing.expectEqual(@as(usize, 2), high.segments.len);
    try std.testing.expectEqualStrings("[1/2]", high.segments[0].text);
    try std.testing.expectEqualStrings("claude-3-5", high.segments[1].text);

    // Width 12: high priority drops, only critical ("claude-3-5", len 10) survives
    const crit = layoutSegments(arena.allocator(), 12, &candidates);
    try std.testing.expectEqual(@as(usize, 1), crit.segments.len);
    try std.testing.expectEqualStrings("claude-3-5", crit.segments[0].text);

    // Width 6: critical segment is truncated to available width
    const trunc = layoutSegments(arena.allocator(), 6, &candidates);
    try std.testing.expectEqual(@as(usize, 1), trunc.segments.len);
    try std.testing.expectEqual(@as(u16, 6), trunc.segments[0].width);
}
