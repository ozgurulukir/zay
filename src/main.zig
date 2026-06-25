const std = @import("std");
const nova = @import("nova");
const logger = @import("logger");

pub const std_options: std.Options = .{
    .unexpected_error_tracing = false,
    .logFn = novaLog,
};

fn novaLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ comptime level.asText() ++ "] (" ++ @tagName(scope) ++ ") ";
    logger.log(prefix ++ format, args);
}

pub const panic = std.debug.FullPanic(novaPanic);

fn novaPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    std.debug.print("\x1b[?1049l\x1b[?1003l\x1b[?1000l\x1b[?25h\x1b[0m\r\n", .{});
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    try nova.run(init, gpa);
}
