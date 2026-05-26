const std = @import("std");
const nova = @import("nova");

// TODO: This should only be disabled for production since it messes up
// the TUI buffer
pub const std_options: std.Options = .{
    .unexpected_error_tracing = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    try nova.run(init, gpa);
}
