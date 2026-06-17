const std = @import("std");

/// Hard cap on indentation levels so a pathologically deep branch can't push
/// text off-screen. Each level is 3 columns.
pub const max_levels: u16 = 16;

pub const folded_marker = "⊞";
pub const expanded_marker = "⊟";

/// Build the shared tree-art prefix for session trees.
///
/// This matches Pi's tree view: each indentation level is three columns, with
/// ancestor gutters in the first column, connectors in the first column of the
/// current level, and the fold marker in the middle column.
pub fn buildPrefix(
    arena: std.mem.Allocator,
    indent: u16,
    is_last: bool,
    last_at_indent: []const bool,
    is_folded: bool,
    is_foldable: bool,
    is_branch_point: bool,
) ![]const u8 {
    _ = is_branch_point;
    var out: std.ArrayList(u8) = .empty;
    if (indent == 0) {
        if (is_foldable) try out.appendSlice(arena, if (is_folded) folded_marker ++ " " else expanded_marker ++ " ");
        return out.toOwnedSlice(arena);
    }

    const levels = @min(indent, max_levels);
    var cell: u16 = 0;
    while (cell < levels) : (cell += 1) {
        const connector_cell = cell + 1 == levels;
        if (connector_cell) {
            try out.appendSlice(arena, if (is_last) "╰" else "├");
            if (is_foldable) {
                try out.appendSlice(arena, if (is_folded) folded_marker else expanded_marker);
            } else {
                try out.appendSlice(arena, "─");
            }
            try out.append(arena, ' ');
        } else {
            const ancestor_indent = cell + 1;
            const draw_bar = ancestor_indent < last_at_indent.len and !last_at_indent[ancestor_indent];
            try out.appendSlice(arena, if (draw_bar) "│  " else "   ");
        }
    }
    return out.toOwnedSlice(arena);
}

test "root fold markers match pi tree art" {
    const folded = try buildPrefix(std.testing.allocator, 0, false, &.{}, true, true, true);
    defer std.testing.allocator.free(folded);
    const expanded = try buildPrefix(std.testing.allocator, 0, false, &.{}, false, true, true);
    defer std.testing.allocator.free(expanded);

    try std.testing.expectEqualStrings("⊞ ", folded);
    try std.testing.expectEqualStrings("⊟ ", expanded);
}

test "children use pi connectors and fold markers" {
    var last = [_]bool{false} ** (max_levels + 2);
    const child = try buildPrefix(std.testing.allocator, 1, false, last[0..], false, false, false);
    defer std.testing.allocator.free(child);
    const folded = try buildPrefix(std.testing.allocator, 1, true, last[0..], true, true, false);
    defer std.testing.allocator.free(folded);

    try std.testing.expectEqualStrings("├─ ", child);
    try std.testing.expectEqualStrings("╰⊞ ", folded);
}

test "nested gutters use pi connector columns" {
    var last = [_]bool{false} ** (max_levels + 2);
    const nested = try buildPrefix(std.testing.allocator, 2, false, last[0..], false, false, false);
    defer std.testing.allocator.free(nested);

    try std.testing.expectEqualStrings("│  ├─ ", nested);
}
