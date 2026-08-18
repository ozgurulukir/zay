//! Fixed-capacity list with ArrayList-compatible ergonomics.
//!
//! Designed for small architectural caps (e.g. max 4 lanes). Storage is inline
//! in the struct itself — no heap allocation — but the API mirrors std.ArrayList
//! enough that call sites change only `.items` -> `.slice()`, `.len` -> `.len()`,
//! and `.append(gpa, value)` -> `.append(value)`.
//!
//! Capacity is a comptime constant; attempts to append past capacity return
//! error.OutOfMemory so callers can keep their existing error-handling shape.

const std = @import("std");

pub fn BoundedList(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        storage: [capacity]T = undefined,
        count: usize = 0,

        /// O(1). Returns the live slice.
        pub fn slice(self: *const Self) []const T {
            return self.storage[0..self.count];
        }

        /// O(1). Mutable live slice.
        pub fn sliceMut(self: *Self) []T {
            return self.storage[0..self.count];
        }

        /// O(1).
        pub fn len(self: *const Self) usize {
            return self.count;
        }

        /// Maximum number of elements this list can hold.
        pub const max_capacity = capacity;

        /// O(1). Returns whether the list is full.
        pub fn isFull(self: *const Self) bool {
            return self.count == capacity;
        }

        /// O(n) worst case. Adds one element.
        /// Returns error.OutOfMemory at capacity so callers can preserve existing
        /// error-handling shape.
        pub fn append(self: *Self, item: T) error{OutOfMemory}!void {
            if (self.count >= capacity) return error.OutOfMemory;
            self.storage[self.count] = item;
            self.count += 1;
        }

        /// O(n). Removes and returns the element at `index`, shifting later
        /// elements down. Asserts index < len.
        pub fn orderedRemove(self: *Self, index: usize) T {
            std.debug.assert(index < self.count);
            const old = self.storage[index];
            for (index..self.count - 1) |i| {
                self.storage[i] = self.storage[i + 1];
            }
            self.count -= 1;
            return old;
        }

        /// O(n). Removes and returns the last element. Asserts non-empty.
        pub fn pop(self: *Self) T {
            std.debug.assert(self.count > 0);
            self.count -= 1;
            return self.storage[self.count];
        }

        /// O(1). Returns the element at `index`. Asserts bounds.
        pub fn at(self: *const Self, index: usize) T {
            std.debug.assert(index < self.count);
            return self.storage[index];
        }

        /// O(1). Mutable pointer to the element at `index`. Asserts bounds.
        pub fn ptrAt(self: *Self, index: usize) *T {
            std.debug.assert(index < self.count);
            return &self.storage[index];
        }

        /// O(n). Clears the list without freeing inline storage.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.count = 0;
        }

        /// No-op for API parity with ArrayList; inline storage owns nothing.
        pub fn deinit(self: *Self) void {
            self.count = 0;
        }

        /// O(1) default init.
        pub fn init() Self {
            return .{};
        }
    };
}

test "BoundedList basic operations" {
    var list = BoundedList(u32, 4){};
    try std.testing.expectEqual(@as(usize, 0), list.len());
    try std.testing.expectEqual(@as(usize, 4), BoundedList(u32, 4).max_capacity);

    try list.append(10);
    try list.append(20);
    try list.append(30);
    try std.testing.expectEqual(@as(usize, 3), list.len());
    try std.testing.expectEqual(@as(u32, 10), list.at(0));
    try std.testing.expectEqual(@as(u32, 20), list.at(1));
    try std.testing.expectEqual(@as(u32, 30), list.at(2));

    _ = list.orderedRemove(1);
    try std.testing.expectEqual(@as(usize, 2), list.len());
    try std.testing.expectEqual(@as(u32, 10), list.at(0));
    try std.testing.expectEqual(@as(u32, 30), list.at(1));

    try list.append(40);
    try list.append(50);
    try std.testing.expect(list.isFull());
    try std.testing.expectError(error.OutOfMemory, list.append(60));

    const last = list.pop();
    try std.testing.expectEqual(@as(u32, 50), last);
    try std.testing.expectEqual(@as(usize, 3), list.len());
}

test "BoundedList zero capacity boundary" {
    var list = BoundedList(u32, 0){};
    try std.testing.expectEqual(@as(usize, 0), list.len());
    try std.testing.expect(list.isFull());
    try std.testing.expectError(error.OutOfMemory, list.append(10));
}

test "BoundedList single capacity fill and pop" {
    var list = BoundedList(u32, 1){};
    try std.testing.expect(!list.isFull());
    try list.append(42);
    try std.testing.expect(list.isFull());
    try std.testing.expectError(error.OutOfMemory, list.append(99));
    try std.testing.expectEqual(@as(u32, 42), list.pop());
    try std.testing.expectEqual(@as(usize, 0), list.len());
    try std.testing.expect(!list.isFull());
}

test "BoundedList orderedRemove shift ordering across boundaries" {
    var list = BoundedList(u32, 5){};
    try list.append(10);
    try list.append(20);
    try list.append(30);
    try list.append(40);

    // Remove head (index 0)
    const head = list.orderedRemove(0);
    try std.testing.expectEqual(@as(u32, 10), head);
    try std.testing.expectEqualSlices(u32, &.{ 20, 30, 40 }, list.slice());

    // Remove tail (index 2)
    const tail = list.orderedRemove(2);
    try std.testing.expectEqual(@as(u32, 40), tail);
    try std.testing.expectEqualSlices(u32, &.{ 20, 30 }, list.slice());
}

test "BoundedList clearRetainingCapacity resets count for reuse" {
    var list = BoundedList(u32, 3){};
    try list.append(1);
    try list.append(2);
    try list.append(3);
    try std.testing.expect(list.isFull());

    list.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), list.len());
    try std.testing.expect(!list.isFull());

    try list.append(100);
    try list.append(200);
    try std.testing.expectEqualSlices(u32, &.{ 100, 200 }, list.slice());
}

test "BoundedList sliceMut and ptrAt in-place modification" {
    var list = BoundedList(u32, 3){};
    try list.append(1);
    try list.append(2);
    try list.append(3);

    list.ptrAt(1).* = 99;
    try std.testing.expectEqual(@as(u32, 99), list.at(1));

    const mut_slice = list.sliceMut();
    mut_slice[0] = 77;
    try std.testing.expectEqualSlices(u32, &.{ 77, 99, 3 }, list.slice());
}
