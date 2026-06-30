//! Standalone allocation benchmark for the markdown renderer.
//! Reports heap-allocation counts for a cold render and for a streaming
//! re-render pattern.
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

    std.debug.print("--- markdown render bench (width 80) ---\n", .{});

    {
        var cold: CountingAllocator = .{ .child = gpa };
        var out = try terminal_markdown.render(cold.allocator(), body, 80);
        const rows = out.rows.len;
        out.deinit(cold.allocator());
        std.debug.print("cold render:          rows={d:>4}  allocs={d:>6}  bytes={d:>9}\n", .{ rows, cold.count, cold.bytes });
    }

    {
        var stream: CountingAllocator = .{ .child = gpa };
        const a = stream.allocator();
        const deltas = 100;
        var k: usize = 1;
        while (k <= deltas) : (k += 1) {
            const prefix_len = (body.len * k) / deltas;
            var r = try terminal_markdown.render(a, body[0..prefix_len], 80);
            r.deinit(a);
        }
        std.debug.print("streaming {d} deltas:  allocs={d:>6}  bytes={d:>9}\n", .{ deltas, stream.count, stream.bytes });
    }
}
