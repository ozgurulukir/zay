const std = @import("std");
const vaxis = @import("vaxis");

const assert = std.debug.assert;

pub const Style = enum {
    normal,
    heading,
    quote,
    list_marker,
    table_border,
    code,
    strong,
    emphasis,
};

pub const Span = struct {
    text: []const u8,
    style: Style,
};

pub const Row = struct {
    indent: u16 = 0,
    spans: []Span,
};

pub const Rendered = struct {
    rows: []Row,

    pub fn deinit(self: *Rendered, gpa: std.mem.Allocator) void {
        for (self.rows) |row| gpa.free(row.spans);
        gpa.free(self.rows);
        self.* = undefined;
    }
};

pub fn render(gpa: std.mem.Allocator, text: []const u8, width: u16) !Rendered {
    return renderLimited(gpa, text, width, std.math.maxInt(usize));
}

pub fn renderLimited(gpa: std.mem.Allocator, text: []const u8, width: u16, max_rows: usize) !Rendered {
    assert(width > 0);
    var rows: std.ArrayList(Row) = .empty;
    errdefer freeRows(gpa, rows.items);

    var state: BlockState = .{};
    var line_start: usize = 0;
    while (line_start <= text.len and rows.items.len < max_rows) {
        const line = lineAt(text, line_start);
        if (!state.in_code) {
            if (try renderTable(gpa, &rows, text, line_start, width)) |next_start| {
                if (next_start >= text.len) break;
                line_start = next_start;
                continue;
            }
        }
        try renderLine(gpa, &rows, line.bytes, width, &state);
        if (line.next_start == null) break;
        line_start = line.next_start.?;
    }

    if (text.len == 0) try appendEmptyRow(gpa, &rows);
    return .{ .rows = try rows.toOwnedSlice(gpa) };
}

pub fn countRows(text: []const u8, width: u16) u16 {
    assert(width > 0);
    if (text.len == 0) return 1;
    var rows: u16 = 0;
    var state: BlockState = .{};
    var line_start: usize = 0;
    while (line_start <= text.len) {
        const line = lineAt(text, line_start);
        if (!state.in_code) {
            if (countTableRows(text, line_start, width)) |table| {
                rows += table.rows;
                if (table.next_start >= text.len) break;
                line_start = table.next_start;
                continue;
            }
        }
        rows += countLineRows(line.bytes, width, &state);
        if (line.next_start == null) break;
        line_start = line.next_start.?;
    }
    return rows;
}

const Line = struct { bytes: []const u8, next_start: ?usize };

fn lineAt(text: []const u8, start: usize) Line {
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return .{
        .bytes = text[start..end],
        .next_start = if (end == text.len) null else end + 1,
    };
}

const BlockState = struct { in_code: bool = false };

fn renderLine(gpa: std.mem.Allocator, rows: *std.ArrayList(Row), line: []const u8, width: u16, state: *BlockState) !void {
    if (isFence(line)) {
        state.in_code = !state.in_code;
        return;
    }
    if (line.len == 0) return appendEmptyRow(gpa, rows);
    if (state.in_code) return renderPlainLine(gpa, rows, line, width, .code, 0, &.{});
    if (headingBody(line)) |body| {
        const spans = try inlineSpans(gpa, body.text, .heading);
        defer gpa.free(spans);
        return appendWrapped(gpa, rows, &.{}, 0, spans, width);
    }
    if (quoteBody(line)) |body| {
        const prefix = [_]Span{.{ .text = "┃ ", .style = .quote }};
        const spans = try inlineSpans(gpa, body, .quote);
        defer gpa.free(spans);
        return appendWrapped(gpa, rows, &prefix, 2, spans, width);
    }
    if (listBody(line)) |body| {
        const prefix = [_]Span{.{ .text = "• ", .style = .list_marker }};
        const spans = try inlineSpans(gpa, body, .normal);
        defer gpa.free(spans);
        return appendWrapped(gpa, rows, &prefix, 2, spans, width);
    }
    const spans = try inlineSpans(gpa, line, .normal);
    defer gpa.free(spans);
    return appendWrapped(gpa, rows, &.{}, 0, spans, width);
}

fn renderPlainLine(
    gpa: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    line: []const u8,
    width: u16,
    style: Style,
    continuation_indent: u16,
    prefix: []const Span,
) !void {
    const spans = [_]Span{.{ .text = line, .style = style }};
    return appendWrapped(gpa, rows, prefix, continuation_indent, &spans, width);
}

fn countLineRows(line: []const u8, width: u16, state: *BlockState) u16 {
    if (isFence(line)) {
        state.in_code = !state.in_code;
        return 0;
    }
    if (line.len == 0) return 1;
    var body = line;
    var prefix_width: u16 = 0;
    if (state.in_code) {
        return countWrappedRows(body, width, 0);
    }
    if (headingBody(line)) |heading| {
        body = heading.text;
    } else if (quoteBody(line)) |quote| {
        body = quote;
        prefix_width = 2;
    } else if (listBody(line)) |list| {
        body = list;
        prefix_width = 2;
    }
    return countWrappedRows(body, width, prefix_width);
}

const CountTable = struct { rows: u16, next_start: usize };

fn renderTable(
    gpa: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    text: []const u8,
    table_start: usize,
    width: u16,
) !?usize {
    const header = lineAt(text, table_start);
    const separator_start = header.next_start orelse return null;
    const separator = lineAt(text, separator_start);
    if (!isTableRow(header.bytes)) return null;
    if (!isTableSeparator(separator.bytes)) return null;

    var table_rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (table_rows.items) |cells| gpa.free(cells);
        table_rows.deinit(gpa);
    }

    const header_cells = try tableCells(gpa, header.bytes);
    try table_rows.append(gpa, header_cells);
    var row_start = separator.next_start orelse {
        try renderTableRows(gpa, rows, table_rows.items, width);
        return text.len;
    };
    while (row_start <= text.len) {
        const line = lineAt(text, row_start);
        if (!isTableRow(line.bytes)) {
            try renderTableRows(gpa, rows, table_rows.items, width);
            return row_start;
        }
        try table_rows.append(gpa, try tableCells(gpa, line.bytes));
        row_start = line.next_start orelse {
            try renderTableRows(gpa, rows, table_rows.items, width);
            return text.len;
        };
    }
    try renderTableRows(gpa, rows, table_rows.items, width);
    return text.len;
}

fn countTableRows(text: []const u8, table_start: usize, width: u16) ?CountTable {
    const header = lineAt(text, table_start);
    const separator_start = header.next_start orelse return null;
    const separator = lineAt(text, separator_start);
    if (!isTableRow(header.bytes)) return null;
    if (!isTableSeparator(separator.bytes)) return null;

    const ncol = tableColumnCount(header.bytes);
    if (ncol == 0) return null;
    const col_width = tableColumnWidth(ncol, width);
    var table_lines = countTableVisualRows(header.bytes, col_width);
    var table_rows: u16 = 1;
    var row_start = separator.next_start orelse return .{ .rows = table_lines + table_rows + 1, .next_start = text.len };
    while (row_start <= text.len) {
        const line = lineAt(text, row_start);
        if (!isTableRow(line.bytes)) return .{ .rows = table_lines + table_rows + 1, .next_start = row_start };
        table_lines += countTableVisualRows(line.bytes, col_width);
        table_rows += 1;
        row_start = line.next_start orelse return .{ .rows = table_lines + table_rows + 1, .next_start = text.len };
    }
    return .{ .rows = table_lines + table_rows + 1, .next_start = text.len };
}

fn renderTableRows(gpa: std.mem.Allocator, rows: *std.ArrayList(Row), table_rows: []const []const []const u8, width: u16) !void {
    if (table_rows.len == 0) return;
    const ncol = table_rows[0].len;
    if (ncol == 0) return;
    const col_widths = try tableColumnWidths(gpa, ncol, width);
    defer gpa.free(col_widths);

    try appendTableBorder(gpa, rows, col_widths, .top);
    var row_index: usize = 0;
    while (row_index < table_rows.len) : (row_index += 1) {
        try appendTableDataRow(gpa, rows, table_rows[row_index], col_widths, row_index == 0);
        if (row_index + 1 == table_rows.len) {
            try appendTableBorder(gpa, rows, col_widths, .bottom);
        } else {
            try appendTableBorder(gpa, rows, col_widths, .middle);
        }
    }
}

fn tableCells(gpa: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var cells: std.ArrayList([]const u8) = .empty;
    errdefer cells.deinit(gpa);
    var iter = TableCellIterator.init(line);
    while (iter.next()) |cell| try cells.append(gpa, cell);
    return cells.toOwnedSlice(gpa);
}

fn tableColumnWidths(gpa: std.mem.Allocator, ncol: usize, width: u16) ![]u16 {
    const widths = try gpa.alloc(u16, ncol);
    const content_total = tableContentWidth(ncol, width);
    const base = tableColumnWidth(ncol, width);
    var assigned: u16 = 0;
    for (widths[0 .. ncol - 1]) |*col| {
        col.* = base;
        assigned += base;
    }
    widths[ncol - 1] = content_total - assigned;
    return widths;
}

fn tableContentWidth(ncol: usize, width: u16) u16 {
    const border_count: u16 = @intCast(ncol + 1);
    const padding_count: u16 = @intCast(ncol * 2);
    return @max(width -| border_count -| padding_count, @as(u16, @intCast(ncol)));
}

fn tableColumnWidth(ncol: usize, width: u16) u16 {
    return @max(tableContentWidth(ncol, width) / @as(u16, @intCast(ncol)), 1);
}

const BorderKind = enum { top, middle, bottom };

fn appendTableBorder(gpa: std.mem.Allocator, rows: *std.ArrayList(Row), widths: []const u16, kind: BorderKind) !void {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(gpa);
    try spans.append(gpa, .{ .text = switch (kind) {
        .top => "┌",
        .middle => "├",
        .bottom => "└",
    }, .style = .table_border });
    for (widths, 0..) |col_width, index| {
        try appendRepeatedSpan(gpa, &spans, "─", col_width + 2, .table_border);
        if (index + 1 < widths.len) {
            try spans.append(gpa, .{ .text = switch (kind) {
                .top => "┬",
                .middle => "┼",
                .bottom => "┴",
            }, .style = .table_border });
        }
    }
    try spans.append(gpa, .{ .text = switch (kind) {
        .top => "┐",
        .middle => "┤",
        .bottom => "┘",
    }, .style = .table_border });
    try rows.append(gpa, .{ .spans = try spans.toOwnedSlice(gpa) });
}

fn appendTableDataRow(gpa: std.mem.Allocator, rows: *std.ArrayList(Row), cells: []const []const u8, widths: []const u16, header: bool) !void {
    var cell_rows = try gpa.alloc([]Row, widths.len);
    defer gpa.free(cell_rows);
    for (cell_rows) |*entry| entry.* = &.{};
    defer {
        for (cell_rows) |entry| {
            freeRows(gpa, entry);
            if (entry.len > 0) gpa.free(entry);
        }
    }

    var max_rows: usize = 1;
    for (widths, 0..) |col_width, index| {
        const cell = if (index < cells.len) cells[index] else "";
        const style: Style = if (header) .strong else .normal;
        const cell_spans = try inlineSpans(gpa, cell, style);
        defer gpa.free(cell_spans);
        var wrapped: std.ArrayList(Row) = .empty;
        errdefer freeRows(gpa, wrapped.items);
        try appendWrapped(gpa, &wrapped, &.{}, 0, cell_spans, col_width);
        cell_rows[index] = try wrapped.toOwnedSlice(gpa);
        max_rows = @max(max_rows, cell_rows[index].len);
    }

    var visual_row: usize = 0;
    while (visual_row < max_rows) : (visual_row += 1) {
        var spans: std.ArrayList(Span) = .empty;
        errdefer spans.deinit(gpa);
        try spans.append(gpa, .{ .text = "│", .style = .table_border });
        for (widths, 0..) |col_width, index| {
            try spans.append(gpa, .{ .text = " ", .style = .normal });
            const rendered_cell = if (visual_row < cell_rows[index].len) cell_rows[index][visual_row].spans else &.{};
            try spans.appendSlice(gpa, rendered_cell);
            try appendRepeatedSpan(gpa, &spans, " ", col_width -| spansWidth(rendered_cell), .normal);
            try spans.append(gpa, .{ .text = " │", .style = .table_border });
        }
        try rows.append(gpa, .{ .spans = try spans.toOwnedSlice(gpa) });
    }
}

fn appendRepeatedSpan(gpa: std.mem.Allocator, spans: *std.ArrayList(Span), text: []const u8, count: u16, style: Style) !void {
    var index: u16 = 0;
    while (index < count) : (index += 1) try spans.append(gpa, .{ .text = text, .style = style });
}

fn spansWidth(spans: []const Span) u16 {
    var width: u16 = 0;
    for (spans) |span| width += textWidth(span.text);
    return width;
}

fn isTableRow(line: []const u8) bool {
    return tableColumnCount(line) > 0;
}

fn tableColumnCount(line: []const u8) usize {
    var count: usize = 0;
    var iter = TableCellIterator.init(line);
    while (iter.next()) |_| count += 1;
    if (count < 2) return 0;
    return count;
}

fn countTableVisualRows(line: []const u8, col_width: u16) u16 {
    var rows: u16 = 1;
    var iter = TableCellIterator.init(line);
    while (iter.next()) |cell| {
        rows = @max(rows, countWrappedRows(cell, col_width, 0));
    }
    return rows;
}

fn isTableSeparator(line: []const u8) bool {
    var saw_dash = false;
    for (trim(line)) |byte| {
        switch (byte) {
            '|', ' ', '\t', ':' => {},
            '-' => saw_dash = true,
            else => return false,
        }
    }
    return saw_dash;
}

const TableCellIterator = struct {
    line: []const u8,
    index: usize,
    end: usize,

    fn init(line: []const u8) TableCellIterator {
        const start: usize = if (line.len > 0 and line[0] == '|') 1 else 0;
        const end: usize = if (line.len > start and line[line.len - 1] == '|') line.len - 1 else line.len;
        return .{ .line = line, .index = start, .end = end };
    }

    fn next(self: *TableCellIterator) ?[]const u8 {
        if (self.index >= self.end) return null;
        const start = self.index;
        const pipe = std.mem.indexOfScalarPos(u8, self.line, self.index, '|') orelse self.end;
        self.index = @min(pipe + 1, self.end);
        return trim(self.line[start..@min(pipe, self.end)]);
    }
};

const Heading = struct { text: []const u8 };

fn headingBody(line: []const u8) ?Heading {
    var level: u8 = 0;
    while (level < line.len) : (level += 1) {
        if (line[level] != '#') break;
        if (level == 6) return null;
    }
    if (level == 0) return null;
    if (level >= line.len) return null;
    if (line[level] != ' ') return null;
    return .{ .text = trimLeft(line[level + 1 ..]) };
}

fn quoteBody(line: []const u8) ?[]const u8 {
    if (line.len == 0) return null;
    if (line[0] != '>') return null;
    return trimLeft(line[1..]);
}

fn listBody(line: []const u8) ?[]const u8 {
    if (line.len < 2) return null;
    if (!isListMarker(line[0])) return null;
    if (line[1] != ' ') return null;
    return trimLeft(line[2..]);
}

fn isListMarker(byte: u8) bool {
    return byte == '-' or byte == '*' or byte == '+';
}

fn isFence(line: []const u8) bool {
    const trimmed = trimLeft(line);
    return std.mem.startsWith(u8, trimmed, "```");
}

fn inlineSpans(gpa: std.mem.Allocator, line: []const u8, base: Style) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(gpa);

    var index: usize = 0;
    while (index < line.len) {
        if (line[index] == '`') {
            if (std.mem.indexOfScalarPos(u8, line, index + 1, '`')) |end| {
                try appendSpan(&spans, gpa, line[index + 1 .. end], .code);
                index = end + 1;
                continue;
            }
        }
        if (std.mem.startsWith(u8, line[index..], "**")) {
            if (std.mem.indexOfPos(u8, line, index + 2, "**")) |end| {
                const nested_base: Style = if (base == .heading) .heading else .strong;
                const nested = try inlineSpans(gpa, line[index + 2 .. end], nested_base);
                defer gpa.free(nested);
                try spans.appendSlice(gpa, nested);
                index = end + 2;
                continue;
            }
        }
        if (line[index] == '*') {
            if (std.mem.indexOfScalarPos(u8, line, index + 1, '*')) |end| {
                const nested_base: Style = if (base == .heading) .heading else .emphasis;
                const nested = try inlineSpans(gpa, line[index + 1 .. end], nested_base);
                defer gpa.free(nested);
                try spans.appendSlice(gpa, nested);
                index = end + 1;
                continue;
            }
        }

        const next = nextInlineMarker(line, index + 1);
        try appendSpan(&spans, gpa, line[index..next], base);
        index = next;
    }

    if (spans.items.len == 0) try appendSpan(&spans, gpa, "", base);
    return spans.toOwnedSlice(gpa);
}

fn nextInlineMarker(line: []const u8, start: usize) usize {
    var index = start;
    while (index < line.len) : (index += 1) {
        if (line[index] == '`') return index;
        if (line[index] == '*') return index;
    }
    return line.len;
}

fn appendSpan(spans: *std.ArrayList(Span), gpa: std.mem.Allocator, text: []const u8, style: Style) !void {
    if (text.len == 0) return;
    try spans.append(gpa, .{ .text = text, .style = style });
}

fn appendWrapped(
    gpa: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    first_prefix: []const Span,
    continuation_indent: u16,
    body: []const Span,
    width: u16,
) !void {
    var current: std.ArrayList(Span) = .empty;
    defer current.deinit(gpa);
    var current_width = try startRow(gpa, &current, first_prefix, 0);
    var current_indent: u16 = 0;

    for (body) |span| {
        var index: usize = 0;
        while (index < span.text.len) {
            index = skipSpaces(span.text, index);
            if (index >= span.text.len) break;
            const word_end = nextWordEnd(span.text, index);
            const word = span.text[index..word_end];
            const word_width = textWidth(word);
            if (current_width > current_indent) {
                if (current_width + 1 + word_width > width) {
                    try commitRow(gpa, rows, &current, current_indent);
                    current_indent = continuation_indent;
                    current_width = try startRow(gpa, &current, &.{}, current_indent);
                } else {
                    try current.append(gpa, .{ .text = " ", .style = span.style });
                    current_width += 1;
                }
            }
            if (word_width > width -| current_width) {
                try appendHardWrappedWord(gpa, rows, &current, &current_width, current_indent, continuation_indent, word, span.style, width);
            } else {
                try current.append(gpa, .{ .text = word, .style = span.style });
                current_width += word_width;
            }
            index = word_end;
        }
    }

    if (current.items.len == 0) {
        try current.append(gpa, .{ .text = "", .style = .normal });
    }
    try commitRow(gpa, rows, &current, current_indent);
}

fn appendHardWrappedWord(
    gpa: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    current: *std.ArrayList(Span),
    current_width: *u16,
    current_indent: u16,
    continuation_indent: u16,
    word: []const u8,
    style: Style,
    width: u16,
) !void {
    var index: usize = 0;
    while (index < word.len) {
        const capacity = width -| current_width.*;
        if (capacity == 0) {
            try commitRow(gpa, rows, current, current_indent);
            current_width.* = try startRow(gpa, current, &.{}, continuation_indent);
            continue;
        }
        const end = graphemeSliceEnd(word, index, capacity);
        const slice = word[index..end];
        try current.append(gpa, .{ .text = slice, .style = style });
        current_width.* += textWidth(slice);
        index = end;
        if (index < word.len) {
            try commitRow(gpa, rows, current, current_indent);
            current_width.* = try startRow(gpa, current, &.{}, continuation_indent);
        }
    }
}

fn startRow(gpa: std.mem.Allocator, current: *std.ArrayList(Span), prefix: []const Span, indent: u16) !u16 {
    current.clearRetainingCapacity();
    var width = indent;
    for (prefix) |span| {
        try current.append(gpa, span);
        width += textWidth(span.text);
    }
    return width;
}

fn commitRow(gpa: std.mem.Allocator, rows: *std.ArrayList(Row), current: *std.ArrayList(Span), indent: u16) !void {
    try rows.append(gpa, .{ .indent = indent, .spans = try current.toOwnedSlice(gpa) });
    current.clearRetainingCapacity();
}

fn appendEmptyRow(gpa: std.mem.Allocator, rows: *std.ArrayList(Row)) !void {
    const spans = try gpa.alloc(Span, 0);
    try rows.append(gpa, .{ .spans = spans });
}

fn countWrappedRows(body: []const u8, width: u16, first_prefix_width: u16) u16 {
    if (body.len == 0) return 1;
    var rows: u16 = 1;
    var current_width = first_prefix_width;
    var index: usize = 0;
    while (index < body.len) {
        index = skipSpaces(body, index);
        if (index >= body.len) break;
        const end = nextWordEnd(body, index);
        const word_width = textWidth(body[index..end]);
        if (current_width > 0 and current_width + 1 + word_width > width) {
            rows += 1;
            current_width = first_prefix_width;
        } else if (current_width > 0) {
            current_width += 1;
        }
        if (word_width > width -| current_width) {
            const capacity = @max(width -| current_width, 1);
            rows += @intCast((word_width - capacity + width - 1) / width);
            current_width = @intCast((word_width - capacity) % width);
        } else {
            current_width += word_width;
        }
        index = end;
    }
    return rows;
}

fn nextWordEnd(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        if (isSpace(text[index])) return index;
    }
    return text.len;
}

fn skipSpaces(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        if (!isSpace(text[index])) break;
    }
    return index;
}

fn trimLeft(text: []const u8) []const u8 {
    return text[skipSpaces(text, 0)..];
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t");
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn textWidth(text: []const u8) u16 {
    return vaxis.gwidth.gwidth(text, .unicode);
}

fn graphemeSliceEnd(text: []const u8, start: usize, width: u16) usize {
    assert(start < text.len);
    assert(width > 0);
    var iter = vaxis.unicode.graphemeIterator(text[start..]);
    var used: u16 = 0;
    var end = start;
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text[start..]);
        const grapheme_width = textWidth(bytes);
        if (used > 0) {
            if (used + grapheme_width > width) break;
        }
        end += grapheme.len;
        used += grapheme_width;
        if (used >= width) break;
    }
    return end;
}

fn freeRows(gpa: std.mem.Allocator, rows: []Row) void {
    for (rows) |row| gpa.free(row.spans);
}

test "renders headings, lists, quotes, and inline styles" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "# Title\n- hello **world**\n> `quote`", 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), out.rows.len);
    try std.testing.expectEqual(Style.heading, out.rows[0].spans[0].style);
    try std.testing.expectEqualStrings("• ", out.rows[1].spans[0].text);
    try std.testing.expectEqual(Style.code, out.rows[2].spans[1].style);
}

test "inline backticks render as code" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "Use `zig build test` now", 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.rows.len);
    try std.testing.expect(containsStyledText(out.rows[0].spans, .code, "zig"));
    try std.testing.expect(containsStyledText(out.rows[0].spans, .code, "build"));
    try std.testing.expect(!containsText(out.rows[0].spans, "`"));
}

test "inline code inside strong markers renders as code" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "**This is `code` !**", 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.rows.len);
    try std.testing.expect(containsStyledText(out.rows[0].spans, .strong, "This"));
    try std.testing.expect(containsStyledText(out.rows[0].spans, .code, "code"));
    try std.testing.expect(!containsText(out.rows[0].spans, "`"));
    try std.testing.expect(!containsText(out.rows[0].spans, "**"));
}

test "inline code inside strong heading renders as code" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "# **This is `code` !**", 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.rows.len);
    try std.testing.expect(containsStyledText(out.rows[0].spans, .heading, "This"));
    try std.testing.expect(containsStyledText(out.rows[0].spans, .code, "code"));
    try std.testing.expect(!containsText(out.rows[0].spans, "`"));
    try std.testing.expect(!containsText(out.rows[0].spans, "**"));
}

test "heading inline backticks render as code" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "# Run `zig build test`", 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.rows.len);
    try std.testing.expect(containsStyledText(out.rows[0].spans, .code, "zig"));
    try std.testing.expect(containsStyledText(out.rows[0].spans, .code, "build"));
    try std.testing.expect(!containsText(out.rows[0].spans, "`"));
}

test "headings strip inline strong markers" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "# **Title**", 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.rows.len);
    try std.testing.expectEqual(Style.heading, out.rows[0].spans[0].style);
    try std.testing.expectEqualStrings("Title", out.rows[0].spans[0].text);
}

test "tables render cells and strip strong markers from header" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "| **Name** | Value |\n| --- | --- |\n| alpha | beta |", 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 5), out.rows.len);
    try std.testing.expectEqual(Style.table_border, out.rows[0].spans[0].style);
    try std.testing.expectEqualStrings("┌", out.rows[0].spans[0].text);
    try std.testing.expectEqual(Style.strong, out.rows[1].spans[2].style);
    try std.testing.expectEqualStrings("Name", out.rows[1].spans[2].text);
    try std.testing.expect(std.mem.indexOf(u8, out.rows[1].spans[2].text, "**") == null);
    try std.testing.expectEqual(@as(u16, 5), countRows("| **Name** | Value |\n| --- | --- |\n| alpha | beta |", 80));
}

test "table cells wrap within column width" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "| Name | Value |\n| --- | --- |\n| alpha beta gamma | delta |", 24);
    defer out.deinit(gpa);

    try std.testing.expect(out.rows.len > 5);
    try std.testing.expectEqual(@as(u16, @intCast(out.rows.len)), countRows("| Name | Value |\n| --- | --- |\n| alpha beta gamma | delta |", 24));
}

test "strong markers are removed" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "**hello** world", 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.rows.len);
    try std.testing.expectEqual(Style.strong, out.rows[0].spans[0].style);
    try std.testing.expectEqualStrings("hello", out.rows[0].spans[0].text);
    try std.testing.expectEqualStrings("world", out.rows[0].spans[2].text);
}

fn containsStyledText(spans: []const Span, style: Style, text: []const u8) bool {
    for (spans) |span| {
        if (span.style != style) continue;
        if (std.mem.eql(u8, span.text, text)) return true;
    }
    return false;
}

fn containsText(spans: []const Span, text: []const u8) bool {
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, text) != null) return true;
    }
    return false;
}

test "wraps at word boundaries" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "hello world", 8);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), out.rows.len);
    try std.testing.expectEqualStrings("hello", out.rows[0].spans[0].text);
    try std.testing.expectEqualStrings("world", out.rows[1].spans[0].text);
    try std.testing.expectEqual(@as(u16, 2), countRows("hello world", 8));
}
