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
    start: usize = 0,
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
        return self.stashAt(gpa, full_text, "", 0);
    }

    /// Stash `full_text` at `insert_pos` in `current_text`, ensuring the
    /// generated placeholder does not collide with any existing stash entry or
    /// literal text already present in `current_text`.
    pub fn stashAt(
        self: *PasteStash,
        gpa: std.mem.Allocator,
        full_text: []const u8,
        current_text: []const u8,
        insert_pos: usize,
    ) ![]const u8 {
        const lines = lineCount(full_text);
        const base = try std.fmt.allocPrint(gpa, "[Pasted {d} lines]", .{lines});
        const placeholder = if (self.hasCollision(base, current_text)) blk: {
            gpa.free(base);
            while (true) {
                const id = self.next_id;
                self.next_id += 1;
                const candidate = try std.fmt.allocPrint(gpa, "[Pasted {d} lines #{d}]", .{ lines, id });
                if (!self.hasCollision(candidate, current_text)) break :blk candidate;
                gpa.free(candidate);
            }
        } else base;
        errdefer gpa.free(placeholder);

        const owned_full = try gpa.dupe(u8, full_text);
        errdefer gpa.free(owned_full);

        for (self.entries.items) |*entry| {
            if (entry.start >= insert_pos) entry.start += placeholder.len;
        }

        try self.entries.append(gpa, .{
            .placeholder = placeholder,
            .full_text = owned_full,
            .start = insert_pos,
        });
        return placeholder;
    }

    fn hasCollision(self: *const PasteStash, needle: []const u8, current_text: []const u8) bool {
        if (self.hasPlaceholder(needle)) return true;
        return std.mem.indexOf(u8, current_text, needle) != null;
    }

    fn hasPlaceholder(self: *const PasteStash, needle: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.placeholder, needle)) return true;
        }
        return false;
    }

    /// Reconcile stashed entries against the current prompt `text`: evict any
    /// entry whose placeholder is no longer present in `text`, and update
    /// tracked positions for surviving entries.
    pub fn syncWithText(self: *PasteStash, gpa: std.mem.Allocator, text: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            if (findClosestOccurrence(text, entry.placeholder, entry.start)) |pos| {
                entry.start = pos;
                i += 1;
            } else {
                const removed = self.entries.orderedRemove(i);
                gpa.free(removed.placeholder);
                gpa.free(removed.full_text);
            }
        }
    }

    fn findClosestOccurrence(text: []const u8, needle: []const u8, hint_pos: usize) ?usize {
        if (needle.len == 0 or needle.len > text.len) return null;
        var best: ?usize = null;
        var best_dist: usize = std.math.maxInt(usize);
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, text, search_from, needle)) |pos| {
            const dist = if (pos >= hint_pos) pos - hint_pos else hint_pos - pos;
            if (dist < best_dist) {
                best_dist = dist;
                best = pos;
            }
            search_from = pos + needle.len;
        }
        return best;
    }

    /// Replace each stashed entry's bound placeholder in `raw` with its full
    /// text, clear the stash, and return an owned expanded slice. Each entry
    /// expands at most once so literal placeholder text typed elsewhere is not
    /// substituted.
    pub fn expandAndClear(self: *PasteStash, gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
        defer self.clear(gpa);
        if (self.entries.items.len == 0) return gpa.dupe(u8, raw);

        const Span = struct {
            start: usize,
            end: usize,
            full_text: []const u8,
        };
        var spans: std.ArrayList(Span) = .empty;
        defer spans.deinit(gpa);

        for (self.entries.items) |entry| {
            const p = entry.placeholder;
            if (p.len == 0 or p.len > raw.len) continue;
            // Prefer the exact tracked position if it matches and doesn't overlap.
            var chosen: ?usize = null;
            if (entry.start + p.len <= raw.len and std.mem.eql(u8, raw[entry.start .. entry.start + p.len], p)) {
                var overlaps = false;
                for (spans.items) |s| {
                    if (entry.start < s.end and entry.start + p.len > s.start) {
                        overlaps = true;
                        break;
                    }
                }
                if (!overlaps) chosen = entry.start;
            }
            if (chosen == null) {
                var best_dist: usize = std.math.maxInt(usize);
                var search_from: usize = 0;
                while (std.mem.indexOfPos(u8, raw, search_from, p)) |pos| {
                    var overlaps = false;
                    for (spans.items) |s| {
                        if (pos < s.end and pos + p.len > s.start) {
                            overlaps = true;
                            break;
                        }
                    }
                    if (!overlaps) {
                        const dist = if (pos >= entry.start) pos - entry.start else entry.start - pos;
                        if (dist < best_dist) {
                            best_dist = dist;
                            chosen = pos;
                        }
                    }
                    search_from = pos + p.len;
                }
            }
            if (chosen) |start| {
                try spans.append(gpa, .{
                    .start = start,
                    .end = start + p.len,
                    .full_text = entry.full_text,
                });
            }
        }

        if (spans.items.len == 0) return gpa.dupe(u8, raw);

        std.mem.sort(Span, spans.items, {}, struct {
            fn lessThan(_: void, a: Span, b: Span) bool {
                return a.start < b.start;
            }
        }.lessThan);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var pos: usize = 0;
        for (spans.items) |span| {
            if (span.start < pos) continue;
            try out.appendSlice(gpa, raw[pos..span.start]);
            try out.appendSlice(gpa, span.full_text);
            pos = span.end;
        }
        try out.appendSlice(gpa, raw[pos..]);
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
        var best: ?struct { start: usize, end: usize, dist: usize } = null;
        for (self.entries.items) |entry| {
            var search_from: usize = 0;
            while (std.mem.indexOfPos(u8, text, search_from, entry.placeholder)) |start| {
                const end = start + entry.placeholder.len;
                if (cursor > start and cursor <= end) {
                    const dist = if (start >= entry.start) start - entry.start else entry.start - start;
                    if (best == null or dist < best.?.dist) {
                        best = .{ .start = start, .end = end, .dist = dist };
                    }
                }
                search_from = end;
            }
        }
        if (best) |b| return .{ .start = b.start, .end = b.end };
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

test "PasteStash avoids colliding with literal placeholder text and evicts deleted entries" {
    const gpa = std.testing.allocator;
    var stash: PasteStash = .{};
    defer stash.deinit(gpa);

    // User typed literal "[Pasted 3 lines]" before pasting a 3-line block.
    const existing = "[Pasted 3 lines] ";
    const p1 = try stash.stashAt(gpa, "real\nsecond\nthird", existing, existing.len);
    try std.testing.expectEqualStrings("[Pasted 3 lines #1]", p1);

    const combined = "[Pasted 3 lines] [Pasted 3 lines #1]";
    // Backspacing inside the earlier literal text must NOT trigger atomic delete.
    try std.testing.expect(stash.placeholderSpanAtBackspace(combined, "[Pasted 3 lines]".len) == null);
    // Backspacing inside the real placeholder selects only the second span.
    const span = stash.placeholderSpanAtBackspace(combined, combined.len).?;
    try std.testing.expectEqual(@as(usize, existing.len), span.start);
    try std.testing.expectEqual(combined.len, span.end);

    // Expanding leaves the literal prefix untouched and expands only the stashed entry.
    const expanded = try stash.expandAndClear(gpa, combined);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings("[Pasted 3 lines] real\nsecond\nthird", expanded);

    // Simulate Ctrl+U deleting a placeholder, then typing literal text again.
    _ = try stash.stashAt(gpa, "secret\npaste\nbody", "", 0);
    stash.syncWithText(gpa, "");
    try std.testing.expectEqual(@as(usize, 0), stash.entries.items.len);
    const literal_after_clear = try stash.expandAndClear(gpa, "[Pasted 3 lines]");
    defer gpa.free(literal_after_clear);
    try std.testing.expectEqualStrings("[Pasted 3 lines]", literal_after_clear);
}
