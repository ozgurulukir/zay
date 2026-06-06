const std = @import("std");

/// Hard cap on indentation levels so a pathologically deep branch can't push
/// text off-screen. Each level is 3 columns.
pub const max_levels: u16 = 16;

/// Build the tree-art prefix for a row. The root and linear chains (indent 0)
/// render flush unless `is_branch_point` is set. Every other node draws
/// ancestor gutters (`│  `/blank) followed by its own connector. The middle
/// slot carries either a horizontal segment or a branch tee, kept to the same
/// 3-column width as a gutter so columns line up.
pub fn buildPrefix(
    arena: std.mem.Allocator,
    indent: u16,
    is_last: bool,
    last_at_indent: []const bool,
    is_folded: bool,
    is_foldable: bool,
    is_branch_point: bool,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (indent > 0) {
        const levels = @min(indent, max_levels);
        var cell: u16 = 0;
        while (cell + 1 < levels) : (cell += 1) {
            const ancestor_indent = cell + 1;
            const draw_bar = ancestor_indent < last_at_indent.len and !last_at_indent[ancestor_indent];
            try out.appendSlice(arena, if (draw_bar) "│  " else "   ");
        }
        try out.appendSlice(arena, if (is_last) "╰" else "├");
        _ = is_folded;
        _ = is_foldable;
        try out.appendSlice(arena, "─");
        try out.append(arena, ' ');
    } else if (is_branch_point) {
        try out.appendSlice(arena, "┬ ");
    }
    return out.toOwnedSlice(arena);
}

test "root branch and children share connector column" {
    const root = try buildPrefix(std.testing.allocator, 0, false, &.{}, false, false, true);
    defer std.testing.allocator.free(root);
    var last = [_]bool{false} ** (max_levels + 2);
    const child = try buildPrefix(std.testing.allocator, 1, false, last[0..], false, false, false);
    defer std.testing.allocator.free(child);

    try std.testing.expectEqualStrings("┬ ", root);
    try std.testing.expectEqualStrings("├─ ", child);
}

test "nested branch points keep the normal connector" {
    var last = [_]bool{false} ** (max_levels + 2);
    const nested = try buildPrefix(std.testing.allocator, 1, false, last[0..], false, false, true);
    defer std.testing.allocator.free(nested);

    try std.testing.expectEqualStrings("├─ ", nested);
}
