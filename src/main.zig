const std = @import("std");
const nova = @import("nova");

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    try nova.run(init, gpa);
}
