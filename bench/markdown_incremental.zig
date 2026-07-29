//! Standalone allocation benchmark for the incremental markdown renderer.
//! Compares the cost of `Incremental.rows` (stable-prefix cache + volatile
//! tail) against a full `render` re-render at every streaming delta — the same
//! comparison the `metrics.zig` correctness test makes, but here for allocation
//! counts under ReleaseFast. The incremental path should reuse stabilized
//! blocks across deltas, so its allocations stay roughly O(rows) instead of
//! O(deltas x rows).
const std = @import("std");
const terminal_markdown = @import("terminal_markdown");
const CountingAllocator = @import("counting_allocator").CountingAllocator;

fn benchBody(gpa: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try buf.appendSlice(gpa, "## Section heading number with some words\n");
        try buf.appendSlice(gpa, "A paragraph of **bold** and `code` and normal text that is long enough to wrap across an eighty column terminal at least twice over.\n");
        try buf.appendSlice(gpa, "- a list item with `inline code` and more trailing words to force wrapping\n");
        try buf.appendSlice(gpa, "> a block quote line that also wraps around because it carries a fair amount of text\n\n");
    }
    return buf.toOwnedSlice(gpa);
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    const body = try benchBody(gpa);
    defer gpa.free(body);

    std.debug.print("--- markdown incremental bench (width 80) ---\n", .{});
    const deltas: usize = 100;

    // Baseline: full re-render at every delta. Each step throws away the prior
    // result, so allocations grow with both delta count and body length.
    {
        var full: CountingAllocator = .{ .child = gpa };
        const a = full.allocator();
        var k: usize = 1;
        while (k <= deltas) : (k += 1) {
            const prefix_len = (body.len * k) / deltas;
            var r = try terminal_markdown.render(a, body[0..prefix_len], 80);
            r.deinit(a);
        }
        std.debug.print("full re-render {d} deltas: allocs={d:>6}  bytes={d:>9}\n", .{ deltas, full.count, full.bytes });
    }

    // Incremental: the stable cache survives across deltas, so only the
    // volatile tail plus any newly-stabilized block is re-rendered. Allocations
    // should be far lower than the baseline above.
    {
        var inc: CountingAllocator = .{ .child = gpa };
        const ig = inc.allocator();

        // The frame arena is reset between deltas; measure its cost too, since a
        // real caller (the draw loop) recycles it the same way.
        var arena_state: CountingAllocator = .{ .child = gpa };
        const arena_gpa = arena_state.allocator();

        var renderer: terminal_markdown.Incremental = .{};
        defer renderer.deinit(ig);
        var arena = std.heap.ArenaAllocator.init(arena_gpa);
        defer arena.deinit();

        var k: usize = 1;
        while (k <= deltas) : (k += 1) {
            const prefix_len = (body.len * k) / deltas;
            _ = arena.reset(.retain_capacity);
            _ = try renderer.rows(ig, arena.allocator(), body[0..prefix_len], 80);
        }
        std.debug.print("incremental  {d} deltas: allocs={d:>6}  bytes={d:>9}  (gpa)\n", .{
            deltas, inc.count, inc.bytes,
        });
        std.debug.print("incremental  {d} deltas: allocs={d:>6}  bytes={d:>9}  (arena)\n", .{
            deltas, arena_state.count, arena_state.bytes,
        });
    }
}
