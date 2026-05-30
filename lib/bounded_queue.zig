const std = @import("std");

const assert = std.debug.assert;

pub fn BoundedQueue(comptime T: type) type {
    return struct {
        head: u32 = 0,
        count: u32 = 0,

        const Self = @This();

        pub fn len(self: *const Self) u32 {
            return self.count;
        }

        pub fn empty(self: *const Self) bool {
            return self.count == 0;
        }

        pub fn full(self: *const Self, buffer: []const T) bool {
            assert(buffer.len > 0);
            assert(buffer.len <= std.math.maxInt(u32));
            assert(self.count <= buffer.len);
            return self.count == buffer.len;
        }

        pub fn push(self: *Self, buffer: []T, item: T) bool {
            assert(buffer.len > 0);
            assert(buffer.len <= std.math.maxInt(u32));
            assert(self.count <= buffer.len);
            if (self.count == buffer.len) return false;
            const capacity: u32 = @intCast(buffer.len);
            const tail = (self.head + self.count) % capacity;
            buffer[tail] = item;
            self.count += 1;
            assert(self.count <= buffer.len);
            return true;
        }

        pub fn pop(self: *Self, buffer: []T) ?T {
            assert(buffer.len > 0);
            assert(buffer.len <= std.math.maxInt(u32));
            assert(self.count <= buffer.len);
            if (self.count == 0) return null;
            const capacity: u32 = @intCast(buffer.len);
            const item = buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            if (self.count == 0) self.head = 0;
            assert(self.count <= buffer.len);
            return item;
        }

        pub fn peek(self: *const Self, buffer: []const T) ?*const T {
            assert(buffer.len > 0);
            assert(buffer.len <= std.math.maxInt(u32));
            assert(self.count <= buffer.len);
            if (self.count == 0) return null;
            return &buffer[self.head];
        }
    };
}

test "bounded queue preserves order across wrap" {
    var buffer: [3]u8 = undefined;
    var queue: BoundedQueue(u8) = .{};

    try std.testing.expect(queue.push(&buffer, 1));
    try std.testing.expect(queue.push(&buffer, 2));
    try std.testing.expectEqual(@as(?u8, 1), queue.pop(&buffer));
    try std.testing.expect(queue.push(&buffer, 3));
    try std.testing.expect(queue.push(&buffer, 4));
    try std.testing.expect(!queue.push(&buffer, 5));

    try std.testing.expectEqual(@as(?u8, 2), queue.pop(&buffer));
    try std.testing.expectEqual(@as(?u8, 3), queue.pop(&buffer));
    try std.testing.expectEqual(@as(?u8, 4), queue.pop(&buffer));
    try std.testing.expectEqual(@as(?u8, null), queue.pop(&buffer));
}
