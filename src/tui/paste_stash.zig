//! Paste-collapse stash for large prompt pastes (issue #509).
//!
//! Pastes exceeding `line_threshold` lines or `byte_threshold` bytes insert a
//! compact `[Pasted N lines]` placeholder into the prompt `TextField` while
//! stashing the full normalized text here. On submit (`beginSubmit` or
//! `enqueueSubmit`), `expandAndClear` swaps every placeholder back to its full
//! text so prompt history, session persistence, and the LLM receive the full
//! content.

const std = @import("std");

pub const line_threshold: usize = 10;
pub const byte_threshold: usize = 512;

pub const Entry = struct {
    placeholder: []u8,
    full_text: []u8,
};

pub fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |b| {
        if (b == '\n') count += 1;
    }
    return count;
}

pub fn shouldCollapse(text: []const u8) bool {
    return lineCount(text) > line_threshold or text.len > byte_threshold;
}

pub const PasteStash = struct {
    entries: std.ArrayList(Entry) = .empty,
    next_id: usize = 1,

    pub fn deinit(self: *PasteStash, gpa: std.mem.Allocator) void {
        self.clear(gpa);
        self.entries.deinit(gpa);
        self.* = undefined;
    }

    pub fn clear(self: *PasteStash, gpa: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            gpa.free(entry.placeholder);
            gpa.free(entry.full_text);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Stash `full_text` and return its borrowed placeholder slice (valid
    /// until `clear`/`deinit`).
    pub fn stash(self: *PasteStash, gpa: std.mem.Allocator, full_text: []const u8) ![]const u8 {
        const lines = lineCount(full_text);
        const base = try std.fmt.allocPrint(gpa, "[Pasted {d} lines]", .{lines});
        const placeholder = if (self.hasPlaceholder(base)) blk: {
            gpa.free(base);
            const id = self.next_id;
            self.next_id += 1;
            break :blk try std.fmt.allocPrint(gpa, "[Pasted {d} lines #{d}]", .{ lines, id });
        } else base;
        errdefer gpa.free(placeholder);

        const owned_full = try gpa.dupe(u8, full_text);
        errdefer gpa.free(owned_full);

        try self.entries.append(gpa, .{
            .placeholder = placeholder,
            .full_text = owned_full,
        });
        return placeholder;
    }

    fn hasPlaceholder(self: *const PasteStash, needle: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.placeholder, needle)) return true;
        }
        return false;
    }

    /// Replace all stashed placeholders in `raw` with their full text, clear
    /// the stash, and return an owned expanded slice.
    pub fn expandAndClear(self: *PasteStash, gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
        defer self.clear(gpa);
        if (self.entries.items.len == 0) return gpa.dupe(u8, raw);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        var pos: usize = 0;
        while (pos < raw.len) {
            var matched: ?Entry = null;
            for (self.entries.items) |entry| {
                if (std.mem.startsWith(u8, raw[pos..], entry.placeholder)) {
                    matched = entry;
                    break;
                }
            }
            if (matched) |entry| {
                try out.appendSlice(gpa, entry.full_text);
                pos += entry.placeholder.len;
            } else {
                try out.append(gpa, raw[pos]);
                pos += 1;
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// If `cursor` lies inside or immediately at the right edge of a stashed
    /// placeholder in `text`, return its `[start, end)` byte span so Backspace
    /// can delete the placeholder atomically.
    pub fn placeholderSpanAtBackspace(
        self: *const PasteStash,
        text: []const u8,
        cursor: usize,
    ) ?struct { start: usize, end: usize } {
        if (cursor == 0 or cursor > text.len) return null;
        for (self.entries.items) |entry| {
            var search_from: usize = 0;
            while (std.mem.indexOfPos(u8, text, search_from, entry.placeholder)) |start| {
                const end = start + entry.placeholder.len;
                if (cursor > start and cursor <= end) {
                    return .{ .start = start, .end = end };
                }
                search_from = end;
            }
        }
        return null;
    }
};

test "shouldCollapse respects line and byte thresholds" {
    try std.testing.expect(!shouldCollapse("hello\nworld"));
    try std.testing.expect(!shouldCollapse("1\n2\n3\n4\n5\n6\n7\n8\n9\n10"));
    try std.testing.expect(shouldCollapse("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11"));

    const small = "a" ** 512;
    const large = "a" ** 513;
    try std.testing.expect(!shouldCollapse(small));
    try std.testing.expect(shouldCollapse(large));
}

test "PasteStash stash, expandAndClear, and placeholderSpanAtBackspace" {
    const gpa = std.testing.allocator;
    var stash: PasteStash = .{};
    defer stash.deinit(gpa);

    const p1 = try stash.stash(gpa, "line1\nline2\nline3");
    try std.testing.expectEqualStrings("[Pasted 3 lines]", p1);
    const p2 = try stash.stash(gpa, "a\nb\nc");
    try std.testing.expectEqualStrings("[Pasted 3 lines #1]", p2);

    const raw = "prefix [Pasted 3 lines] mid [Pasted 3 lines #1] suffix";
    const span = stash.placeholderSpanAtBackspace(raw, "prefix [Pasted 3 lines]".len).?;
    try std.testing.expectEqual(@as(usize, 7), span.start);
    try std.testing.expectEqual("prefix [Pasted 3 lines]".len, span.end);

    const expanded = try stash.expandAndClear(gpa, raw);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings("prefix line1\nline2\nline3 mid a\nb\nc suffix", expanded);
    try std.testing.expectEqual(@as(usize, 0), stash.entries.items.len);
}
