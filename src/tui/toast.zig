//! Generic toast notification system.
//!
//! Two decoupled pieces so the system is reusable by any subsystem, not just
//! the logger:
//!   - `ToastBus` — a thread-safe, allocation-free ring buffer of toast items.
//!     Any thread (logger, MCP, lane, background jobs, future subsystems) can
//!     `push` to it; the UI thread drains it each tick.
//!   - `Widget` — renders the bus's current toasts as a top-right overlay.
//!     Passive: no focus, no key capture.
//!
//! The bus is a global singleton (`global`) because the logger (itself a
//! global, cross-thread) must push to it and the widget must read it. Tests can
//! instantiate their own `ToastBus` value; the app uses the global instance.
//!
//! Thread-safety: `push` is guarded by `std.Io.Mutex` (NOT `std.atomic.Mutex`,
//! which is a spinlock — see AGENTS.md §Gotchas). The push path allocates
//! nothing: `Item.msg` is a fixed inline buffer, so worker threads never touch
//! the heap here.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui_style = @import("style.zig");
const text_fit = @import("text_fit.zig");
const panel = @import("widgets/panel.zig");

/// Severity of a toast; drives its accent color.
pub const Level = enum { info, success, warn, err };

pub fn levelIcon(level: Level) []const u8 {
    return switch (level) {
        .info => "ℹ",
        .success => "✓",
        .warn => "⚠",
        .err => "✗",
    };
}

/// A single toast. Fixed inline message buffer — no heap allocation on the
/// push path (worker threads).
pub const Item = struct {
    level: Level = .info,
    msg: [msg_capacity]u8 = undefined,
    len: u16 = 0,
    /// Monotonic deadline (ms) after which the toast auto-dismisses.
    deadline_ms: i64 = 0,

    pub fn message(self: *const Item) []const u8 {
        return self.msg[0..self.len];
    }
};

/// Max message bytes. Large enough that a toast can carry a real sentence and
/// wrap across a couple of rows; the widget soft-wraps at the box width.
pub const msg_capacity = 1024;
pub const max_items: u8 = 8;
pub const default_duration_ms: u32 = 4000;
pub const default_max_visible: u8 = 3;
/// A toast's message wraps across at most this many content rows before the
/// tail is truncated (with the `…` marker) so a huge message can't fill the
/// screen.
pub const max_wrap_rows: u16 = 4;

/// Thread-safe ring buffer of toasts. UI thread drains; any thread pushes.
pub const ToastBus = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io = undefined,
    /// True once `init` has run. Guards the mutex/io against use before init
    /// (e.g. tests that call `handleTick` without initializing the global bus).
    initialized: bool = false,
    items: [max_items]Item = undefined,
    head: u8 = 0,
    count: u8 = 0,
    duration_ms: u32 = default_duration_ms,
    max_visible: u8 = default_max_visible,
    enabled: bool = true,

    pub fn init(self: *ToastBus, io: std.Io) void {
        self.io = io;
        self.initialized = true;
    }

    /// Push a toast. Truncates `msg` to `msg_capacity` bytes. When the ring is
    /// full, the oldest toast is overwritten (drop-oldest — matches "show the
    /// latest"). Safe to call from any thread.
    pub fn push(self: *ToastBus, level: Level, msg: []const u8) void {
        if (!self.enabled or !self.initialized) return;
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        const now_ms = std.Io.Clock.now(.awake, self.io).toMilliseconds();
        const tail = (self.head + self.count) % max_items;
        var item = &self.items[tail];
        item.* = .{};
        item.level = level;
        const n = @min(msg.len, msg_capacity);
        @memcpy(item.msg[0..n], msg[0..n]);
        item.len = @intCast(n);
        item.deadline_ms = now_ms + self.duration_ms;
        if (self.count < max_items) {
            self.count += 1;
        } else {
            // Ring full: advance head so the oldest is dropped.
            self.head = (self.head + 1) % max_items;
        }
    }

    /// UI thread (tick): drop expired items from the ring buffer. Returns true
    /// if any item was expired or any active toast remains visible.
    pub fn expire(self: *ToastBus) bool {
        if (!self.initialized) return false;
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);

        const now_ms = std.Io.Clock.now(.awake, self.io).toMilliseconds();
        var write: u8 = 0;
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + i) % max_items;
            if (self.items[idx].deadline_ms <= now_ms) continue; // expired
            if (write != i) self.items[(self.head + write) % max_items] = self.items[idx];
            write += 1;
        }
        const dropped = self.count - write;
        self.count = write;
        return dropped > 0 or self.count > 0;
    }

    /// UI thread (draw): read-only snapshot of the newest `max_visible` toasts
    /// into `out` (oldest-to-newest) without mutating the ring buffer.
    pub fn snapshot(self: *ToastBus, out: []Item) usize {
        if (!self.initialized) return 0;
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);

        const cap = @min(self.max_visible, @as(u8, @intCast(out.len)));
        const start = if (self.count > cap) self.count - cap else 0;
        var n: usize = 0;
        var i: u8 = start;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + i) % max_items;
            out[n] = self.items[idx];
            n += 1;
        }
        return n;
    }

    /// UI thread: collect the newest `max_visible` non-expired toasts into
    /// `out` (oldest-to-newest among the visible set), dropping expired ones.
    /// Returns the number written. `out` must have room for `max_visible`.
    pub fn drain(self: *ToastBus, out: []Item) usize {
        _ = self.expire();
        return self.snapshot(out);
    }

    /// Clear the current toasts (e.g. Esc-to-dismiss).
    pub fn dismiss(self: *ToastBus) void {
        if (!self.initialized) return;
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        self.count = 0;
    }

    /// True when there is at least one toast to show. Lock-free read is fine
    /// for a visibility hint (a stale value only delays/advances a frame).
    pub fn hasToasts(self: *const ToastBus) bool {
        return self.enabled and self.initialized and self.count > 0;
    }
};

/// Global instance for the app. init'd from `tui.run` (has io).
pub var global: ToastBus = .{};

/// Renders the bus's current toasts as a top-right overlay. Passive: no focus,
/// no key capture. Each toast is a bordered box colored by level.
pub const Widget = struct {
    bus: *ToastBus,
    palette: *const tui_style.Palette = &tui_style.default_palette,

    pub fn widget(self: *Widget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Widget = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;

        var items: [max_items]Item = undefined;
        const n = self.bus.snapshot(&items);
        if (n == 0) return vxfw.Surface.empty(self.widget());

        // Each toast is a bordered box: 2 rows (border top/bottom) + up to
        // `max_wrap_rows` content rows. The message soft-wraps at the box width
        // so a long toast reads across several rows instead of truncating to a
        // single line. Stack them top-right, newest at the top.
        const box_width: u16 = @min(width, 60);
        const content_width: u16 = box_width -| 2;
        const visible = @min(n, self.bus.max_visible);

        // Compute each toast's wrapped row count so the total surface height
        // matches what we draw (no clipping, no wasted rows).
        var heights: [max_items]u16 = undefined;
        var total_height: u16 = 0;
        for (items[0..visible], 0..) |*item, i| {
            const rows = wrappedRows(item.message(), content_width, ctx);
            heights[i] = rows;
            total_height +|= 2 + rows;
        }

        if (box_width < 2 or total_height == 0) return vxfw.Surface.empty(self.widget());

        var surface = try vxfw.Surface.initWithChildren(
            ctx.arena,
            self.widget(),
            .{ .width = box_width, .height = total_height },
            &.{},
        );

        // Pre-fill surface with opaque themed background so underlying transcript cells don't bleed through.
        panel.fillBackground(&surface, self.palette);

        var row: u16 = 0;
        const p = self.palette;
        for (items[0..visible], 0..) |*item, i| {
            const style = switch (item.level) {
                .info => p.info,
                .success => p.success,
                .warn => p.warning,
                .err => p.error_style,
            };
            const rows = heights[i];
            const top_row = row;
            const bottom_row = row + 1 + rows;

            // Border top.
            surface.writeCell(0, top_row, .{ .char = .{ .grapheme = "╭", .width = 1 }, .style = style });
            surface.writeCell(box_width - 1, top_row, .{ .char = .{ .grapheme = "╮", .width = 1 }, .style = style });
            var c: u16 = 1;
            while (c < box_width - 1) : (c += 1) {
                surface.writeCell(c, top_row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
            }
            if (box_width >= 7) {
                const icon = levelIcon(item.level);
                surface.writeCell(2, top_row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
                surface.writeCell(3, top_row, .{ .char = .{ .grapheme = icon, .width = 1 }, .style = style });
                surface.writeCell(4, top_row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
            }

            // Side borders.
            var r: u16 = top_row + 1;
            while (r < bottom_row) : (r += 1) {
                surface.writeCell(0, r, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = style });
                surface.writeCell(box_width - 1, r, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = style });
            }

            // Content rows: soft-wrap the message, truncating past `max_wrap_rows`.
            drawWrapped(&surface, item.message(), style, ctx, top_row + 1, content_width);

            // Border bottom.
            surface.writeCell(0, bottom_row, .{ .char = .{ .grapheme = "╰", .width = 1 }, .style = style });
            surface.writeCell(box_width - 1, bottom_row, .{ .char = .{ .grapheme = "╯", .width = 1 }, .style = style });
            c = 1;
            while (c < box_width - 1) : (c += 1) {
                surface.writeCell(c, bottom_row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
            }
            // Show subtle Esc dismiss hint on the newest (bottom-most) toast.
            if (i + 1 == visible and box_width >= 9) {
                const dismiss_hint = " Esc ";
                const hint_col: u16 = box_width - 2 - @as(u16, @intCast(dismiss_hint.len));
                const hint_style: vaxis.Style = .{ .fg = style.fg, .bg = p.background.bg, .dim = true };
                for (dismiss_hint, 0..) |_, hi| {
                    surface.writeCell(hint_col + @as(u16, @intCast(hi)), bottom_row, .{
                        .char = .{ .grapheme = dismiss_hint[hi .. hi + 1], .width = 1 },
                        .style = hint_style,
                    });
                }
            }

            row += 2 + rows;
        }
        return surface;
    }
};

/// Number of content rows `text` occupies when soft-wrapped at `width`, capped
/// at `max_wrap_rows`. Mirrors `drawWrapped` so the surface height matches the
/// drawn rows.
fn wrappedRows(text: []const u8, width: u16, ctx: vxfw.DrawContext) u16 {
    _ = ctx;
    if (text.len == 0 or width == 0) return 1;
    return @min(text_fit.textRows(text, width), max_wrap_rows);
}

/// Draw `text` soft-wrapped at `width` starting at `row`, truncating past
/// `max_wrap_rows` with a trailing `…` on the last drawn row.
fn drawWrapped(surface: *vxfw.Surface, text: []const u8, style: vaxis.Style, ctx: vxfw.DrawContext, row: u16, width: u16) void {
    if (text.len == 0 or width == 0) return;
    var r: u16 = row;
    var line_start: usize = 0;
    var truncated = false;
    var last_row_col: u16 = 1;
    while (line_start <= text.len) {
        const line_end = std.mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        if (line.len == 0) {
            if (r + 1 >= row + max_wrap_rows and line_end < text.len) {
                truncated = true;
                break;
            }
            if (line_end < text.len) {
                r += 1;
                if (r >= row + max_wrap_rows) {
                    truncated = true;
                    break;
                }
            }
        } else {
            var start: usize = 0;
            while (start < line.len) {
                const end = text_fit.wrappedLineEnd(line, start, width);
                const next_start = text_fit.skipLinearWhitespace(line, end);
                const has_more_in_line = next_start < line.len;
                const has_more_lines = line_end < text.len;
                const is_last_allowed_row = (r + 1 >= row + max_wrap_rows);
                var col: u16 = 1;
                var iter = ctx.graphemeIterator(line[start..end]);
                while (iter.next()) |grapheme| {
                    const bytes = grapheme.bytes(line[start..end]);
                    const w: u16 = @intCast(ctx.stringWidth(bytes));
                    if (w == 0) continue;
                    if (col + w > surface.size.width -| 1) break;
                    surface.writeCell(col, r, .{
                        .char = .{ .grapheme = bytes, .width = @intCast(w) },
                        .style = style,
                    });
                    col += w;
                    last_row_col = col;
                }
                if (is_last_allowed_row and (has_more_in_line or has_more_lines)) {
                    truncated = true;
                    break;
                }
                start = next_start;
                if (start < line.len) r += 1;
            }
            if (truncated) break;
            if (line_end < text.len) {
                if (r + 1 >= row + max_wrap_rows) {
                    truncated = true;
                    break;
                }
                r += 1;
            }
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
    // If the message was truncated by the row cap, mark the tail on the last valid row with `…`.
    if (truncated and r < surface.size.height) {
        const ellipsis_col = if (last_row_col < surface.size.width -| 1) last_row_col else surface.size.width -| 2;
        if (ellipsis_col >= 1 and ellipsis_col < surface.size.width -| 1) {
            surface.writeCell(ellipsis_col, r, .{
                .char = .{ .grapheme = "…", .width = 1 },
                .style = style,
            });
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "push and drain round-trip" {
    var bus: ToastBus = .{};
    bus.init(std.testing.io);
    bus.push(.info, "hello");
    bus.push(.warn, "world");

    var out: [max_items]Item = undefined;
    const n = bus.drain(&out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("hello", out[0].message());
    try std.testing.expectEqualStrings("world", out[1].message());
}

test "push truncates oversized message" {
    var bus: ToastBus = .{};
    bus.init(std.testing.io);
    const long = "x" ** 2000;
    bus.push(.err, long);

    var out: [max_items]Item = undefined;
    const n = bus.drain(&out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u16, msg_capacity), out[0].len);
}

test "ring overwrites oldest when full" {
    var bus: ToastBus = .{};
    bus.init(std.testing.io);
    bus.max_visible = max_items;
    for (0..max_items) |i| {
        var buf: [8]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "m{d}", .{i});
        bus.push(.info, s);
    }
    // Push one more — oldest ("m0") is dropped.
    bus.push(.info, "m8");

    var out: [max_items]Item = undefined;
    const n = bus.drain(&out);
    try std.testing.expectEqual(@as(usize, max_items), n);
    try std.testing.expectEqualStrings("m1", out[0].message());
    try std.testing.expectEqualStrings("m8", out[7].message());
}

test "drain respects max_visible" {
    var bus: ToastBus = .{};
    bus.init(std.testing.io);
    bus.max_visible = 2;
    for (0..4) |i| {
        var buf: [8]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "m{d}", .{i});
        bus.push(.info, s);
    }

    var out: [max_items]Item = undefined;
    const n = bus.drain(&out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("m2", out[0].message());
    try std.testing.expectEqualStrings("m3", out[1].message());
}

test "drain drops expired items" {
    var bus: ToastBus = .{};
    bus.init(std.testing.io);
    bus.push(.info, "fresh");
    // Force the first item to be expired by setting a past deadline.
    bus.mutex.lock(bus.io) catch unreachable;
    bus.items[0].deadline_ms = 0;
    bus.mutex.unlock(bus.io);

    var out: [max_items]Item = undefined;
    const n = bus.drain(&out);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "dismiss clears toasts" {
    var bus: ToastBus = .{};
    bus.init(std.testing.io);
    bus.push(.info, "hello");
    bus.dismiss();

    var out: [max_items]Item = undefined;
    const n = bus.drain(&out);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "disabled bus drops pushes" {
    var bus: ToastBus = .{};
    bus.init(std.testing.io);
    bus.enabled = false;
    bus.push(.info, "hello");

    var out: [max_items]Item = undefined;
    const n = bus.drain(&out);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "wrappedRows counts soft-wrapped rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 10, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    // "hello world" at width 10 wraps to two rows.
    try std.testing.expectEqual(@as(u16, 2), wrappedRows("hello world", 10, ctx));
    // A single short word stays on one row.
    try std.testing.expectEqual(@as(u16, 1), wrappedRows("hi", 10, ctx));
    // Explicit newline forces a row break.
    try std.testing.expectEqual(@as(u16, 2), wrappedRows("a\nb", 10, ctx));
    // Empty text still occupies one content row.
    try std.testing.expectEqual(@as(u16, 1), wrappedRows("", 10, ctx));
}

test "wrappedRows caps at max_wrap_rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 5, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    // A long run of words at width 5 would exceed the cap; it clamps.
    try std.testing.expectEqual(max_wrap_rows, wrappedRows("one two three four five six", 5, ctx));
}

test "Widget.draw renders initialized bordered surface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bus: ToastBus = .{};
    bus.init(std.testing.io);
    bus.push(.info, "test message");

    var widget_instance: Widget = .{ .bus = &bus };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 30, .height = 10 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try widget_instance.widget().draw(ctx);
    try std.testing.expect(surface.size.width == 30);
    try std.testing.expect(surface.size.height == 3); // 1 top border + 1 content row + 1 bottom border
    try std.testing.expect(surface.buffer.len == 30 * 3);

    // Verify top border corners and semantic icon
    try std.testing.expectEqualStrings("╭", surface.buffer[0].char.grapheme);
    try std.testing.expectEqualStrings("╮", surface.buffer[29].char.grapheme);
    try std.testing.expectEqualStrings("─", surface.buffer[1].char.grapheme);
    try std.testing.expectEqualStrings("ℹ", surface.buffer[3].char.grapheme);

    // Verify content row side borders and opaque themed background
    try std.testing.expectEqualStrings("│", surface.buffer[30].char.grapheme);
    try std.testing.expectEqualStrings("│", surface.buffer[59].char.grapheme);
    try std.testing.expectEqual(tui_style.default_palette.background.bg, surface.buffer[58].style.bg);

    // Verify bottom border corners and Esc dismiss hint
    try std.testing.expectEqualStrings("╰", surface.buffer[60].char.grapheme);
    try std.testing.expectEqualStrings("╯", surface.buffer[89].char.grapheme);
    try std.testing.expectEqualStrings("─", surface.buffer[61].char.grapheme);
    try std.testing.expectEqualStrings("E", surface.buffer[60 + 24].char.grapheme);
    try std.testing.expectEqualStrings("s", surface.buffer[60 + 25].char.grapheme);
    try std.testing.expectEqualStrings("c", surface.buffer[60 + 26].char.grapheme);
}

test "Widget.draw truncates long toast with ellipsis and preserves borders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bus: ToastBus = .{};
    bus.init(std.testing.io);
    bus.push(.info, "word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11 word12");

    var widget_instance: Widget = .{ .bus = &bus };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 15, .height = 10 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try widget_instance.widget().draw(ctx);
    // 1 top + max_wrap_rows (4) + 1 bottom = 6 rows
    try std.testing.expectEqual(2 + max_wrap_rows, surface.size.height);
    try std.testing.expectEqual(@as(u16, 15), surface.size.width);

    // Verify bottom border corners on row 5
    const bottom_start = 15 * (2 + max_wrap_rows - 1);
    try std.testing.expectEqualStrings("╰", surface.buffer[bottom_start].char.grapheme);
    try std.testing.expectEqualStrings("╯", surface.buffer[bottom_start + 14].char.grapheme);
}
