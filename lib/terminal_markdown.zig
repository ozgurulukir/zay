const std = @import("std");
const vaxis = @import("vaxis");
const CountingAllocator = @import("counting_allocator").CountingAllocator;

const assert = std.debug.assert;

pub const Style = enum {
    normal,
    heading,
    /// Second- and third-tier headings: `##`/`###` … map here while `#` keeps
    /// the single `.heading` style the historical renderer pinned.
    heading_h2,
    heading_h3,
    quote,
    list_marker,
    /// `- [ ]`/`- [x]` checkbox glyph in a list item prefix.
    task_marker,
    /// Horizontal-rule row (`---`).
    rule,
    table_border,
    code_border,
    code,
    strong,
    emphasis,
    /// `~~strikethrough~~`.
    strikethrough,
    /// `***strong emphasis***` — bold italic (run-of-3 delimiters).
    strong_emphasis,
    link,
    code_keyword,
    code_string,
    code_comment,
    code_number,
    /// Type-like identifiers (capitalized, or a language primitive).
    code_type,
    /// Call-position identifiers (`name(`).
    code_function,
    /// ALL_CAPS / true-false-null-style literals.
    code_constant,
    /// diff-mode `+` lines.
    code_added,
    /// diff-mode `-` lines.
    code_removed,
};

pub const Span = struct {
    text: []const u8,
    style: Style,
    link_url: []const u8 = "",
};

pub const Row = struct {
    indent: u16 = 0,
    spans: []Span,
};

pub const Rendered = struct {
    rows: []Row,
    spans: []Span,
    /// Heap-owned span texts synthesized during rendering (stacked-table
    /// keys). Row spans borrow these; they must outlive the rows.
    owned_texts: []([]u8) = &.{},

    pub fn deinit(self: *Rendered, gpa: std.mem.Allocator) void {
        for (self.owned_texts) |text| gpa.free(text);
        gpa.free(self.owned_texts);
        gpa.free(self.spans);
        gpa.free(self.rows);
        self.* = undefined;
    }
};

/// Per-row record while building: an indent plus a (start, len) window into the
/// shared span pool. Resolved into `Row` subslices once the pool stops growing.
const RowMeta = struct { indent: u16, start: u32, len: u32 };

/// Accumulates rows by copying their spans into one growable pool rather than
/// handing each row its own heap slice. `push` is the single commit point used
/// by every block renderer.
const RowBuilder = struct {
    pool: std.ArrayList(Span) = .empty,
    rows: std.ArrayList(RowMeta) = .empty,
    scratch: std.ArrayList(Span) = .empty,
    /// Heap-owned span texts the pooled spans borrow. Most spans borrow the
    /// caller's body (which outlives the render); only synthesized text —
    /// currently stacked-table keys — needs a home here.
    texts: std.ArrayList([]u8) = .empty,

    /// Copy `text` into the builder's owned storage and return the copy. The
    /// copy lives as long as the builder (or the `Rendered` it converts to).
    fn ownSpanText(self: *RowBuilder, gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
        const copy = try gpa.dupe(u8, text);
        errdefer gpa.free(copy);
        try self.texts.append(gpa, copy);
        return copy;
    }

    fn push(self: *RowBuilder, gpa: std.mem.Allocator, indent: u16, spans: []const Span) !void {
        const start: u32 = @intCast(self.pool.items.len);
        try self.pool.appendSlice(gpa, spans);
        try self.rows.append(gpa, .{ .indent = indent, .start = start, .len = @intCast(spans.len) });
    }

    fn len(self: *const RowBuilder) usize {
        return self.rows.items.len;
    }

    /// The spans of an already-pushed row, read back from the pool. Valid only
    /// until the next `push` (which may realloc the pool).
    fn rowSpans(self: *const RowBuilder, index: usize) []const Span {
        const meta = self.rows.items[index];
        return self.pool.items[meta.start..][0..meta.len];
    }

    fn deinit(self: *RowBuilder, gpa: std.mem.Allocator) void {
        for (self.texts.items) |text| gpa.free(text);
        self.texts.deinit(gpa);
        self.pool.deinit(gpa);
        self.rows.deinit(gpa);
        self.scratch.deinit(gpa);
        self.* = undefined;
    }

    /// Freeze the pool and bind each row's metadata to a real span subslice.
    fn toRendered(self: *RowBuilder, gpa: std.mem.Allocator) !Rendered {
        const spans = try self.pool.toOwnedSlice(gpa);
        errdefer gpa.free(spans);
        const rows = try gpa.alloc(Row, self.rows.items.len);
        for (self.rows.items, 0..) |meta, index| {
            rows[index] = .{ .indent = meta.indent, .spans = spans[meta.start..][0..meta.len] };
        }
        const owned_texts = try self.texts.toOwnedSlice(gpa);
        errdefer gpa.free(owned_texts);
        self.rows.deinit(gpa);
        self.scratch.deinit(gpa);
        self.* = undefined;
        return .{ .rows = rows, .spans = spans, .owned_texts = owned_texts };
    }
};

pub fn render(gpa: std.mem.Allocator, text: []const u8, width: u16) !Rendered {
    return renderLimited(gpa, text, width, std.math.maxInt(usize));
}

/// Capacity-hint ceiling for `renderLimited`'s upfront reservation. The old
/// `countRows`-derived estimate was a u16 (≤ 65535 rows, +1 reserved) and the
/// new cap keeps the no-row-limit `render` path's worst case within one row of
/// that, without re-introducing the full-body scan. Under-reserving is safe —
/// the lists grow on demand.
const estimate_row_cap: usize = std.math.maxInt(u16);

pub fn renderLimited(gpa: std.mem.Allocator, text: []const u8, width: u16, max_rows: usize) !Rendered {
    assert(width > 0);
    var builder: RowBuilder = .{};
    errdefer builder.deinit(gpa);

    // Every rendered row consumes at least one input byte, except the single
    // empty-body row (table border rows are paid for by the >=3-byte table
    // lines that produce them). Bound reservation by the caller's row limit
    // instead of scanning the entire body to discover a capacity the renderer
    // may never use. This matters for large transcript messages whose surfaces
    // are clipped to the terminal's representable height. `estimate_row_cap`
    // keeps the no-row-limit `render` path at the old countRows-derived worst
    // case instead of reserving O(body) upfront.
    const est_rows = @min(@min(text.len +| 1, max_rows), estimate_row_cap);
    try builder.rows.ensureTotalCapacity(gpa, est_rows);
    try builder.pool.ensureTotalCapacity(gpa, est_rows *| 3 +| 8);

    var state: BlockState = .{};
    try renderInto(gpa, &builder, text, width, &state, max_rows, true);
    return builder.toRendered(gpa);
}

/// Render `text` into `b`, advancing `state` across the segment. `final` marks
/// `text` as the end of the body: it then renders the trailing-newline phantom
/// line and emits an empty row for an empty body, matching the historical
/// `renderLimited` behaviour. When `final` is false `text` is a strict prefix
/// (more bytes follow), so neither happens and the split renders identically to
/// rendering the whole — the invariant the incremental renderer relies on.
fn renderInto(
    gpa: std.mem.Allocator,
    b: *RowBuilder,
    text: []const u8,
    width: u16,
    state: *BlockState,
    max_rows: usize,
    final: bool,
) !void {
    var line_start: usize = 0;
    while (b.len() < max_rows) {
        if (line_start > text.len or (!final and line_start == text.len)) break;
        const line = lineAt(text, line_start);
        if (!state.in_code) {
            if (try renderTable(gpa, b, text, line_start, width)) |next_start| {
                state.list_continuation_indent = 0;
                if (next_start >= text.len) break;
                line_start = next_start;
                continue;
            }
        }
        try renderLine(gpa, b, line.bytes, width, state);
        if (line.next_start == null) break;
        line_start = line.next_start.?;
    }
}

pub fn countRows(gpa: std.mem.Allocator, text: []const u8, width: u16) u16 {
    assert(width > 0);
    if (text.len == 0) return 1;
    var rows: u16 = 0;
    var state: BlockState = .{};
    var line_start: usize = 0;
    while (line_start <= text.len) {
        const line = lineAt(text, line_start);
        if (!state.in_code) {
            if (countTableRows(gpa, text, line_start, width)) |table| {
                state.list_continuation_indent = 0;
                rows += table.rows;
                if (table.next_start >= text.len) break;
                line_start = table.next_start;
                continue;
            }
        }
        rows += countLineRows(gpa, line.bytes, width, &state);
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

pub const BlockState = struct {
    in_code: bool = false,
    code_lang: []const u8 = "",
    /// The open fence's marker byte and minimum closing length (a "```" opener
    /// leaves these 0/0 when no fence is open). Tilde fences and fences longer
    /// than three markers only close on a run of the SAME marker at least as
    /// long.
    fence_char: u8 = 0,
    fence_len: u8 = 0,
    /// Tokenizer state inside the open code block: block comment
    /// (slash-star, HTML angle-bracket comment) and multi-line string (triple
    /// quote, Lua double bracket) carry across lines so both render paths
    /// highlight consistently.
    code_block_comment: bool = false,
    code_block_string: bool = false,
    /// Continuation indent from a preceding list item for lazy continuation
    /// lines; cleared on any blank line, fence, heading, quote, rule, or table.
    list_continuation_indent: u16 = 0,
};

/// A code-fence opener line: which marker byte and how long the run was.
const Fence = struct { char: u8, len: u8 };

/// Parse a fence opener/closer line: three or more backticks or tildes (after
/// leading whitespace). Returns null for anything else. A longer run still
/// opens a fence (CommonMark) and only closes on a run at least as long.
fn parseFence(line: []const u8) ?Fence {
    const trimmed = trimLeft(line);
    if (trimmed.len < 3) return null;
    const char = trimmed[0];
    if (char != '`' and char != '~') return null;
    var run: u8 = 0;
    while (run < trimmed.len and trimmed[run] == char) : (run += 1) {}
    if (run < 3) return null;
    // Backtick fences must not contain backticks in the info string; tilde
    // fences may. Checking only the opener's marker keeps `parseFence` a pure
    // opener/closer test — `renderLine` reads the info string separately.
    if (char == '`' and std.mem.indexOfScalar(u8, trimmed[run..], '`') != null) return null;
    return .{ .char = char, .len = run };
}

/// What one line did to the code-fence state.
const FenceAction = enum { opened, closed, none };

/// Toggle the code-block state on a fence line. Shared by the render, count,
/// and `stableBoundary` paths so the three can never disagree about which
/// lines are fences. Returns `.none` for a non-fence line AND for a fence
/// line inside an open block whose marker/length doesn't match (it is code
/// content; the caller renders it as such).
fn applyFence(line: []const u8, state: *BlockState) FenceAction {
    const fence = parseFence(line) orelse return .none;
    if (state.in_code) {
        if (fence.char == state.fence_char and fence.len >= state.fence_len) {
            // CommonMark: a closing fence carries no info string — a marker
            // run followed by content ("```js" inside an open ``` block) is
            // code text, not a closer.
            const trimmed = trimLeft(line);
            if (std.mem.trim(u8, trimmed[fence.len..], " \t\r").len != 0) return .none;
            state.in_code = false;
            state.code_lang = "";
            state.fence_char = 0;
            state.fence_len = 0;
            state.code_block_comment = false;
            state.code_block_string = false;
            return .closed;
        }
        // A non-matching fence line inside a code block is code content.
        return .none;
    }
    state.in_code = true;
    state.fence_char = fence.char;
    state.fence_len = fence.len;
    state.code_block_comment = false;
    state.code_block_string = false;
    const trimmed = trimLeft(line);
    state.code_lang = if (trimmed.len > fence.len)
        std.mem.trim(u8, trimmed[fence.len..], " \t\r")
    else
        "";
    return .opened;
}

/// Block boundary for append-only incremental rendering: the byte offset just
/// after the most recent blank line that is not inside a ``` code fence.
/// Everything before it is immutable as more text is appended (a markdown
/// construct can be reinterpreted by following lines — e.g. a table header by
/// its separator — but never across a blank line outside code), so a renderer
/// may cache those rows and re-render only `text[boundary..]`.
pub fn stableBoundary(text: []const u8) usize {
    var fence_state: BlockState = .{};
    var boundary: usize = 0;
    var line_start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, line_start, '\n')) |nl| {
        const line = std.mem.trim(u8, text[line_start..nl], " \t");
        _ = applyFence(line, &fence_state);
        if (!fence_state.in_code and line.len == 0) boundary = nl + 1;
        line_start = nl + 1;
    }
    return boundary;
}

/// The module-level full-scan row counter. `Incremental.countRows` (the
/// method) is a struct declaration, so the bare name would shadow this inside
/// the struct body and self-recurs; the method calls the full scan through
/// this alias instead.
const countRowsFull = countRows;

/// Incremental renderer for an append-only body (a streaming agent message).
/// Caches the rendered rows of the stable prefix and re-renders only the
/// volatile trailing block on each call, turning the O(deltas x rows) full
/// re-render into roughly O(rows) over a stream. Reset on a wrap-width change.
pub const Incremental = struct {
    stable: RowBuilder = .{},
    /// Owned, immutable copies of each stabilized chunk `body[old..new)`. The
    /// cached stable rows' spans borrow *these*, not the caller's `body`: a
    /// streaming body is realloc-grown and may move, which would dangle persisted
    /// spans. Each chunk is a separate allocation that is never moved or freed
    /// until reset, so folding a new chunk never disturbs earlier spans (unlike a
    /// single growing buffer, which would force a costly rebuild on every move).
    segments: std.ArrayList([]u8) = .empty,
    boundary: usize = 0,
    width: u16 = 0,
    primed: bool = false,

    pub fn deinit(self: *Incremental, gpa: std.mem.Allocator) void {
        self.stable.deinit(gpa);
        for (self.segments.items) |seg| gpa.free(seg);
        self.segments.deinit(gpa);
        self.* = undefined;
    }

    fn reset(self: *Incremental, gpa: std.mem.Allocator, width: u16) void {
        self.stable.rows.clearRetainingCapacity();
        self.stable.pool.clearRetainingCapacity();
        for (self.stable.texts.items) |text| gpa.free(text);
        self.stable.texts.clearRetainingCapacity();
        for (self.segments.items) |seg| gpa.free(seg);
        self.segments.clearRetainingCapacity();
        self.boundary = 0;
        self.width = width;
        self.primed = true;
    }

    const max_cached_bytes: usize = 256 * 1024;

    fn boundedTailSlice(body: []const u8) []const u8 {
        if (body.len <= max_cached_bytes) return body;
        var tail_start = body.len - max_cached_bytes;
        // Advance past UTF-8 continuation bytes so slicing never splits a multi-byte codepoint.
        while (tail_start < body.len and (body[tail_start] & 0xC0) == 0x80) {
            tail_start += 1;
        }
        return body[tail_start..];
    }

    /// The full row list for `body` at `width`, materialized into `arena` (valid
    /// until the arena is reset). `gpa` owns the persistent stable cache; call
    /// `deinit` with the same `gpa`.
    pub fn rows(
        self: *Incremental,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        body: []const u8,
        width: u16,
    ) ![]const Row {
        // Cap persistent cache growth for multi-megabyte streaming bodies (#545):
        // if the body exceeds 256 KB, reset the stable cache and render only a
        // bounded tail into the frame arena.
        if (body.len > max_cached_bytes) {
            self.reset(gpa, width);
            const tail_slice = boundedTailSlice(body);
            var tail_only: RowBuilder = .{};
            var tail_only_state: BlockState = .{};
            try renderInto(arena, &tail_only, tail_slice, width, &tail_only_state, std.math.maxInt(usize), true);
            const out = try arena.alloc(Row, tail_only.rows.items.len);
            for (tail_only.rows.items, 0..) |meta, i| {
                out[i] = .{ .indent = meta.indent, .spans = tail_only.pool.items[meta.start..][0..meta.len] };
            }
            return out;
        }

        // A width change re-wraps everything; an append-only body never shrinks,
        // so a shorter `body` means it was replaced. Either way, start over.
        if (!self.primed or self.width != width or body.len < self.boundary) {
            self.reset(gpa, width);
        }

        // Fold blocks completed since last call into the stable cache, copying
        // and rendering only the newly stabilized chunk [boundary..nb). Every
        // boundary sits just after a blank line outside a code fence, so the
        // chunk is a self-contained block sequence (block state is clean there)
        // and renders identically in isolation.
        const nb = stableBoundary(body);
        if (nb > self.boundary) {
            const seg = try gpa.dupe(u8, body[self.boundary..nb]);
            errdefer gpa.free(seg);
            try self.segments.append(gpa, seg);
            var state: BlockState = .{};
            try renderInto(gpa, &self.stable, seg, width, &state, std.math.maxInt(usize), false);
            self.boundary = nb;
        }

        // Re-render only the volatile tail, into the ephemeral frame arena. Its
        // spans borrow `body` directly — fine, they live only for this frame.
        var tail: RowBuilder = .{};
        var tail_state: BlockState = .{};
        try renderInto(arena, &tail, body[self.boundary..], width, &tail_state, std.math.maxInt(usize), true);

        // Materialize stable ++ tail as one Row slice over the two span pools.
        const out = try arena.alloc(Row, self.stable.rows.items.len + tail.rows.items.len);
        for (self.stable.rows.items, 0..) |meta, i| {
            out[i] = .{ .indent = meta.indent, .spans = self.stable.pool.items[meta.start..][0..meta.len] };
        }
        const base = self.stable.rows.items.len;
        for (tail.rows.items, 0..) |meta, i| {
            out[base + i] = .{ .indent = meta.indent, .spans = tail.pool.items[meta.start..][0..meta.len] };
        }
        return out;
    }

    /// Count the visual rows `body` would render at `width` WITHOUT allocating
    /// or mutating the stable cache: the cached stable rows already own their
    /// count, and the unstabilized tail is counted with the allocation-free
    /// `countRows` scan. Must equal `rows().len` for the same (body, width) —
    /// the SSOT parity test enforces it — so the height request and the
    /// rendered rows never desync. A stale cache (width change or a replaced,
    /// shorter body) falls back to the full scan, mirroring `rows()`'s reset.
    pub fn countRows(self: *Incremental, body: []const u8, width: u16) u16 {
        if (body.len > max_cached_bytes) {
            return countRowsFull(std.heap.page_allocator, boundedTailSlice(body), width);
        }
        if (self.primed and self.width == width and body.len >= self.boundary) {
            const stable_rows: u16 = @intCast(self.stable.rows.items.len);
            // The tail sits just past a blank line outside a code fence, so its
            // block state is clean and counting it in isolation matches the
            // `final=true` render `rows()` applies to it.
            return stable_rows + countRowsFull(std.heap.page_allocator, body[self.boundary..], width);
        }
        return countRowsFull(std.heap.page_allocator, body, width);
    }
};

fn renderLine(gpa: std.mem.Allocator, b: *RowBuilder, line: []const u8, width: u16, state: *BlockState) !void {
    switch (applyFence(line, state)) {
        .opened => {
            state.list_continuation_indent = 0;
            return appendCodeHeader(gpa, b, state.code_lang, width);
        },
        .closed => {
            state.list_continuation_indent = 0;
            return appendCodeFooter(gpa, b, width);
        },
        .none => {},
    }
    if (line.len == 0) {
        if (!state.in_code) state.list_continuation_indent = 0;
        return appendEmptyRow(gpa, b);
    }
    if (state.in_code) {
        const prefix = [_]Span{.{ .text = "│ ", .style = .code_border }};
        const spans = tokenizeCodeLine(gpa, line, state.code_lang, state) catch null;
        if (spans) |s| {
            defer gpa.free(s);
            return appendWrapped(gpa, b, &prefix, 2, s, width);
        }
        return renderPlainLine(gpa, b, line, width, .code, 2, &prefix);
    }
    if (headingBody(line)) |heading| {
        state.list_continuation_indent = 0;
        const spans = try inlineSpans(gpa, heading.text, headingStyle(heading.level));
        defer gpa.free(spans);
        return appendWrapped(gpa, b, &.{}, 0, spans, width);
    }
    if (quoteBody(line)) |body| {
        state.list_continuation_indent = 0;
        const prefix = [_]Span{.{ .text = "┃ ", .style = .quote }};
        const spans = try inlineSpans(gpa, body, .quote);
        defer gpa.free(spans);
        return appendWrapped(gpa, b, &prefix, 2, spans, width);
    }
    if (isHorizontalRule(line)) {
        state.list_continuation_indent = 0;
        return appendRuleRow(gpa, b, width);
    }
    if (listBody(line)) |list| {
        const marker_width: u16 = @intCast(@min(list.indent + textWidth(list.marker), std.math.maxInt(u16)));
        state.list_continuation_indent = @min(marker_width, 8);
        return appendListItem(gpa, b, list, width);
    }
    const spans = try inlineSpans(gpa, line, .normal);
    defer gpa.free(spans);
    if (state.list_continuation_indent > 0) {
        const prefix = [_]Span{.{ .text = indentSpaces(state.list_continuation_indent), .style = .normal }};
        return appendWrapped(gpa, b, &prefix, state.list_continuation_indent, spans, width);
    }
    return appendWrapped(gpa, b, &.{}, 0, spans, width);
}

/// The inline base style for a heading level: `#` keeps the historical single
/// `.heading` style; `##`/`###+` get their own tiers.
fn headingStyle(level: u8) Style {
    return switch (level) {
        1 => .heading,
        2 => .heading_h2,
        else => .heading_h3,
    };
}

/// Opening header row for a fenced code block: `╭─ lang ───` (or `╭───` when
/// no language tag is present), bounded to `width`.
fn appendCodeHeader(gpa: std.mem.Allocator, b: *RowBuilder, code_lang: []const u8, width: u16) !void {
    if (width == 0) return b.push(gpa, 0, &.{});
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);
    if (code_lang.len > 0 and width >= 6) {
        try spans.append(gpa, .{ .text = "╭─ ", .style = .code_border });
        const max_lang_w = width -| 4;
        const lang_w = textWidth(code_lang);
        const owned_lang = try b.ownSpanText(gpa, if (lang_w <= max_lang_w) code_lang else clipToWidth(code_lang, max_lang_w));
        try spans.append(gpa, .{ .text = owned_lang, .style = .code_border });
        try spans.append(gpa, .{ .text = " ", .style = .code_border });
        const used: u16 = 4 + textWidth(owned_lang);
        try appendRepeatedSpan(gpa, &spans, "─", width -| used, .code_border);
    } else {
        try spans.append(gpa, .{ .text = "╭", .style = .code_border });
        try appendRepeatedSpan(gpa, &spans, "─", width -| 1, .code_border);
    }
    try b.push(gpa, 0, spans.items);
}

/// Closing footer row for a fenced code block: `╰───`, bounded to `width`.
fn appendCodeFooter(gpa: std.mem.Allocator, b: *RowBuilder, width: u16) !void {
    if (width == 0) return b.push(gpa, 0, &.{});
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);
    try spans.append(gpa, .{ .text = "╰", .style = .code_border });
    try appendRepeatedSpan(gpa, &spans, "─", width -| 1, .code_border);
    try b.push(gpa, 0, spans.items);
}

fn clipToWidth(text: []const u8, max_width: u16) []const u8 {
    var used: u16 = 0;
    var end: usize = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const w = textWidth(bytes);
        if (used + w > max_width) break;
        used += w;
        end += bytes.len;
    }
    return text[0..end];
}

/// One full-width rule row (`---`/`***`/`___`). Pushed unwrapped: the row is
/// exactly `width` cells, so `countRows` answers 1 without re-deriving it.
fn appendRuleRow(gpa: std.mem.Allocator, b: *RowBuilder, width: u16) !void {
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);
    try appendRepeatedSpan(gpa, &spans, "─", width, .rule);
    try b.push(gpa, 0, spans.items);
}

fn renderPlainLine(
    gpa: std.mem.Allocator,
    b: *RowBuilder,
    line: []const u8,
    width: u16,
    style: Style,
    continuation_indent: u16,
    prefix: []const Span,
) !void {
    const spans = [_]Span{.{ .text = line, .style = style }};
    return appendWrapped(gpa, b, prefix, continuation_indent, &spans, width);
}

fn countLineRows(gpa: std.mem.Allocator, line: []const u8, width: u16, state: *BlockState) u16 {
    switch (applyFence(line, state)) {
        .opened, .closed => {
            state.list_continuation_indent = 0;
            return 1;
        },
        .none => {},
    }
    if (line.len == 0) {
        if (!state.in_code) state.list_continuation_indent = 0;
        return 1;
    }
    if (state.in_code) {
        return countWrappedRows(gpa, line, width, 2, 2);
    }
    if (headingBody(line)) |heading| {
        state.list_continuation_indent = 0;
        // Headings render with no prefix and no continuation indent.
        return countWrappedRows(gpa, heading.text, width, 0, 0);
    }
    if (quoteBody(line)) |quote| {
        state.list_continuation_indent = 0;
        return countWrappedRows(gpa, quote, width, 2, 2);
    }
    if (isHorizontalRule(line)) {
        state.list_continuation_indent = 0;
        return 1;
    }
    if (listBody(line)) |list| {
        const marker_width: u16 = @intCast(@min(list.indent + textWidth(list.marker), std.math.maxInt(u16)));
        state.list_continuation_indent = @min(marker_width, 8);
        return countWrappedRows(gpa, list.body, width, marker_width, marker_width);
    }
    const ind = state.list_continuation_indent;
    return countWrappedRows(gpa, line, width, ind, ind);
}

const CountTable = struct { rows: u16, next_start: usize };

fn renderTable(
    gpa: std.mem.Allocator,
    b: *RowBuilder,
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
        try renderTableRows(gpa, b, table_rows.items, separator.bytes, width);
        return text.len;
    };
    while (row_start <= text.len) {
        const line = lineAt(text, row_start);
        if (!isTableRow(line.bytes)) {
            try renderTableRows(gpa, b, table_rows.items, separator.bytes, width);
            return row_start;
        }
        try table_rows.append(gpa, try tableCells(gpa, line.bytes));
        row_start = line.next_start orelse {
            try renderTableRows(gpa, b, table_rows.items, separator.bytes, width);
            return text.len;
        };
    }
    try renderTableRows(gpa, b, table_rows.items, separator.bytes, width);
    return text.len;
}

fn countTableRows(gpa: std.mem.Allocator, text: []const u8, table_start: usize, width: u16) ?CountTable {
    const header = lineAt(text, table_start);
    const separator_start = header.next_start orelse return null;
    const separator = lineAt(text, separator_start);
    if (!isTableRow(header.bytes)) return null;
    if (!isTableSeparator(separator.bytes)) return null;

    // The layout depends on every row's cells (content-sized widths), so the
    // count path materializes the same cells the render path collects and
    // calls the same `computeTableLayout` — the two can never drift. The count
    // path's contract is error-free, so allocation failure bails to null (the
    // caller falls back to counting the lines as plain text; the render path
    // would be failing on the same OOM anyway).
    var table_rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (table_rows.items) |cells| gpa.free(cells);
        table_rows.deinit(gpa);
    }
    const header_cells = tableCells(gpa, header.bytes) catch return null;
    table_rows.append(gpa, header_cells) catch {
        gpa.free(header_cells);
        return null;
    };
    var row_start = separator.next_start orelse return countCollectedTable(gpa, table_rows.items, separator.bytes, width, text.len);
    while (row_start <= text.len) {
        const line = lineAt(text, row_start);
        if (!isTableRow(line.bytes)) return countCollectedTable(gpa, table_rows.items, separator.bytes, width, row_start);
        const cells = tableCells(gpa, line.bytes) catch return null;
        table_rows.append(gpa, cells) catch {
            gpa.free(cells);
            return null;
        };
        row_start = line.next_start orelse return countCollectedTable(gpa, table_rows.items, separator.bytes, width, text.len);
    }
    return countCollectedTable(gpa, table_rows.items, separator.bytes, width, text.len);
}

/// Count the visual rows of an already-collected table under the shared
/// layout. `next_start` is the byte offset where the table body ended. On
/// allocation failure the fallback is a per-line over-count, never a clip.
fn countCollectedTable(gpa: std.mem.Allocator, table_rows: []const []const []const u8, separator_line: []const u8, width: u16, next_start: usize) CountTable {
    const over_count: u16 = 2 * @as(u16, @intCast(table_rows.len)) + 1;
    var layout = computeTableLayout(gpa, table_rows, separator_line, width) catch
        return .{ .rows = over_count, .next_start = next_start };
    defer layout.deinit(gpa);
    const rows: u16 = if (layout.stacked)
        countStackedTableRows(gpa, table_rows, width)
    else
        countColumnTableRows(gpa, table_rows, layout.widths) + @as(u16, @intCast(table_rows.len)) + 1;
    return .{ .rows = rows, .next_start = next_start };
}

/// Border rows for a column-layout table (n rows → n+1 borders) plus each
/// row's tallest wrapped cell column.
fn countColumnTableRows(gpa: std.mem.Allocator, table_rows: []const []const []const u8, widths: []const u16) u16 {
    var visual: u16 = 0;
    for (table_rows) |cells| {
        visual += countTableVisualRows(gpa, cells, widths);
    }
    return visual;
}

/// Stacked fallback: one "key: value" group per data row plus a blank row
/// between groups (none after the last), mirroring `renderStackedTable`.
fn countStackedTableRows(gpa: std.mem.Allocator, table_rows: []const []const []const u8, width: u16) u16 {
    const data = table_rows[1..];
    var rows: u16 = 0;
    for (data, 0..) |cells, index| {
        rows += countStackedRow(gpa, table_rows[0], cells, width);
        if (index + 1 < data.len) rows += 1; // blank row between groups
    }
    return rows;
}

fn countStackedRow(gpa: std.mem.Allocator, header: []const []const u8, cells: []const []const u8, width: u16) u16 {
    var rows: u16 = 0;
    for (header, 0..) |key, col| {
        const value = if (col < cells.len) cells[col] else "";
        rows += countStackedCellRows(gpa, key, value, width);
    }
    return rows;
}

fn countStackedCellRows(gpa: std.mem.Allocator, key: []const u8, value: []const u8, width: u16) u16 {
    var stack: std.ArrayList(Span) = .empty;
    defer stack.deinit(gpa);
    var key_text: ?[]u8 = null;
    defer if (key_text) |kt| gpa.free(kt);
    if (key.len > 0) key_text = fusedKeyText(gpa, key) catch return 1;
    stackedCellSpans(gpa, &stack, key_text orelse "", value) catch return 1;
    return countWrappedSpanRows(gpa, stack.items, width, stacked_indent, stacked_indent) catch 1;
}

/// The stacked-line key: the header cell's inline-stripped text with the
/// colon fused into the same span (the wrap engine joins spans with a space,
/// which would detach a standalone `:` span). Caller owns the result.
fn fusedKeyText(gpa: std.mem.Allocator, key: []const u8) ![]u8 {
    const key_spans = try inlineSpans(gpa, key, .strong);
    defer gpa.free(key_spans);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (key_spans) |span| try text.appendSlice(gpa, span.text);
    try text.append(gpa, ':');
    return text.toOwnedSlice(gpa);
}

fn renderTableRows(gpa: std.mem.Allocator, b: *RowBuilder, table_rows: []const []const []const u8, separator_line: []const u8, width: u16) !void {
    if (table_rows.len == 0) return;
    const ncol = table_rows[0].len;
    if (ncol == 0) return;
    var layout = try computeTableLayout(gpa, table_rows, separator_line, width);
    defer layout.deinit(gpa);

    if (layout.stacked) {
        return renderStackedTable(gpa, b, table_rows, width);
    }
    try appendTableBorder(gpa, b, layout.widths, .top);
    var row_index: usize = 0;
    while (row_index < table_rows.len) : (row_index += 1) {
        try appendTableDataRow(gpa, b, table_rows[row_index], layout.widths, layout.aligns, row_index == 0);
        if (row_index + 1 == table_rows.len) {
            try appendTableBorder(gpa, b, layout.widths, .bottom);
        } else {
            try appendTableBorder(gpa, b, layout.widths, .middle);
        }
    }
}

/// Column alignment parsed from the separator row's `:` markers.
pub const CellAlign = enum { left, center, right };

/// The shared table layout decision: content-sized column widths (or the
/// stacked fallback when columns cannot fit above the minimum width) plus the
/// per-column alignment. Both the render and count paths call this once per
/// table so their width computation is identical by construction.
const TableLayout = struct {
    stacked: bool,
    widths: []u16,
    aligns: []CellAlign,

    fn deinit(self: *TableLayout, gpa: std.mem.Allocator) void {
        gpa.free(self.widths);
        gpa.free(self.aligns);
        self.* = undefined;
    }
};

/// Minimum content cells a column must get before the stacked fallback fires.
const table_min_col_width: u16 = 3;

fn computeTableLayout(gpa: std.mem.Allocator, table_rows: []const []const []const u8, separator_line: []const u8, width: u16) !TableLayout {
    const ncol = table_rows[0].len;
    const content_total = tableContentWidth(ncol, width);
    const aligns = try parseTableAligns(gpa, separator_line, ncol);
    errdefer gpa.free(aligns);

    if (content_total < ncol * table_min_col_width) {
        const empty_widths = try gpa.alloc(u16, 0);
        errdefer gpa.free(empty_widths);
        return .{ .stacked = true, .widths = empty_widths, .aligns = aligns };
    }

    const widths = try gpa.alloc(u16, ncol);
    errdefer gpa.free(widths);
    var sum: u32 = 0;
    for (widths, 0..) |*col, index| {
        col.* = tableNaturalColumnWidth(gpa, table_rows, index);
        sum += col.*;
    }
    fitColumnWidths(widths, sum, content_total);
    return .{ .stacked = false, .widths = widths, .aligns = aligns };
}

/// Shrink the widest columns first until the total fits `content_total`, never
/// going below `table_min_col_width`, then spread any leftover evenly so the
/// borders still span the full row width.
fn fitColumnWidths(widths: []u16, sum: u32, content_total: u16) void {
    var total = sum;
    while (total > content_total) {
        var widest: usize = 0;
        for (widths, 0..) |col, index| {
            if (col > widths[widest]) widest = index;
        }
        if (widths[widest] <= table_min_col_width) break;
        const reduce: u32 = @min(@as(u32, widths[widest] - table_min_col_width), total - content_total);
        widths[widest] -= @intCast(reduce);
        total -= reduce;
    }
    if (total < content_total) {
        const extra: u16 = content_total - @as(u16, @intCast(total));
        for (widths) |*col| col.* += extra / @as(u16, @intCast(widths.len));
        for (widths[0 .. extra % widths.len]) |*col| col.* += 1;
    }
}

/// A column's natural width: the widest cell's rendered inline width. Inline
/// markers (`**`, backticks) do not count — the cells render without them.
fn tableNaturalColumnWidth(gpa: std.mem.Allocator, table_rows: []const []const []const u8, col: usize) u16 {
    var natural: u16 = 0;
    for (table_rows) |cells| {
        if (col >= cells.len) continue;
        const spans = inlineSpans(gpa, cells[col], .normal) catch continue;
        defer gpa.free(spans);
        natural = @max(natural, @min(spansWidth(spans), std.math.maxInt(u16) - 1));
    }
    return natural;
}

/// Parse `:---:` style alignment from each separator cell. Missing or
/// malformed cells fall back to left.
fn parseTableAligns(gpa: std.mem.Allocator, separator_line: []const u8, ncol: usize) ![]CellAlign {
    const aligns = try gpa.alloc(CellAlign, ncol);
    for (aligns) |*a| a.* = .left;
    var col: usize = 0;
    var iter = TableCellIterator.init(separator_line);
    while (iter.next()) |cell| {
        if (col >= ncol) break;
        const trimmed = std.mem.trim(u8, cell, " \t");
        const left = trimmed.len > 0 and trimmed[0] == ':';
        const right = trimmed.len > 0 and trimmed[trimmed.len - 1] == ':';
        aligns[col] = if (left and right) .center else if (right) .right else .left;
        col += 1;
    }
    return aligns;
}

fn tableCells(gpa: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var cells: std.ArrayList([]const u8) = .empty;
    errdefer cells.deinit(gpa);
    var iter = TableCellIterator.init(line);
    while (iter.next()) |cell| try cells.append(gpa, cell);
    return cells.toOwnedSlice(gpa);
}

fn tableContentWidth(ncol: usize, width: u16) u16 {
    const border_count: u16 = @intCast(ncol + 1);
    const padding_count: u16 = @intCast(ncol * 2);
    return @max(width -| border_count -| padding_count, @as(u16, @intCast(ncol)));
}

const BorderKind = enum { top, middle, bottom };

fn appendTableBorder(gpa: std.mem.Allocator, b: *RowBuilder, widths: []const u16, kind: BorderKind) !void {
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);
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
    try b.push(gpa, 0, spans.items);
}

fn appendTableDataRow(gpa: std.mem.Allocator, b: *RowBuilder, cells: []const []const u8, widths: []const u16, aligns: []const CellAlign, header: bool) !void {
    var cell_builders = try gpa.alloc(RowBuilder, widths.len);
    defer gpa.free(cell_builders);
    for (cell_builders) |*entry| entry.* = .{};
    defer for (cell_builders) |*entry| entry.deinit(gpa);

    var max_rows: usize = 1;
    for (widths, 0..) |col_width, index| {
        const cell = if (index < cells.len) cells[index] else "";
        const style: Style = if (header) .strong else .normal;
        const cell_spans = try inlineSpans(gpa, cell, style);
        defer gpa.free(cell_spans);
        try appendWrapped(gpa, &cell_builders[index], &.{}, 0, cell_spans, col_width);
        max_rows = @max(max_rows, cell_builders[index].len());
    }

    var visual_row: usize = 0;
    while (visual_row < max_rows) : (visual_row += 1) {
        var spans: std.ArrayList(Span) = .empty;
        defer spans.deinit(gpa);
        try spans.append(gpa, .{ .text = "│", .style = .table_border });
        for (widths, 0..) |col_width, index| {
            try spans.append(gpa, .{ .text = " ", .style = .normal });
            const rendered_cell = if (visual_row < cell_builders[index].len()) cell_builders[index].rowSpans(visual_row) else &.{};
            const pad_total: u16 = col_width -| spansWidth(rendered_cell);
            switch (aligns[index]) {
                .left => {
                    try spans.appendSlice(gpa, rendered_cell);
                    try appendRepeatedSpan(gpa, &spans, " ", pad_total, .normal);
                },
                .center => {
                    try appendRepeatedSpan(gpa, &spans, " ", pad_total / 2, .normal);
                    try spans.appendSlice(gpa, rendered_cell);
                    try appendRepeatedSpan(gpa, &spans, " ", pad_total - pad_total / 2, .normal);
                },
                .right => {
                    try appendRepeatedSpan(gpa, &spans, " ", pad_total, .normal);
                    try spans.appendSlice(gpa, rendered_cell);
                },
            }
            try spans.append(gpa, .{ .text = " │", .style = .table_border });
        }
        try b.push(gpa, 0, spans.items);
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

/// A table row's visual rows: the tallest wrapped cell column. Counts the
/// cell's inline spans (the exact sequence `appendTableDataRow` wraps), so
/// marker stripping and span joins match the render path exactly.
fn countTableVisualRows(gpa: std.mem.Allocator, cells: []const []const u8, widths: []const u16) u16 {
    var rows: u16 = 1;
    for (widths, 0..) |col_width, col| {
        if (col >= cells.len) continue;
        rows = @max(rows, countWrappedSpanCell(gpa, cells[col], col_width));
    }
    return rows;
}

fn countWrappedSpanCell(gpa: std.mem.Allocator, cell: []const u8, col_width: u16) u16 {
    var stack: std.ArrayList(Span) = .empty;
    defer stack.deinit(gpa);
    const spans = inlineSpans(gpa, cell, .normal) catch return 1;
    defer gpa.free(spans);
    stack.appendSlice(gpa, spans) catch return 1;
    return countWrappedSpanRows(gpa, stack.items, col_width, 0, 0) catch 1;
}

/// Count-only twin of `appendWrapped`: runs the same `wrapCore` over the same
/// span sequence with the count sink. Returns the row count.
fn countWrappedSpanRows(gpa: std.mem.Allocator, body: []const Span, width: u16, first_prefix_width: u16, continuation_indent: u16) !u16 {
    var state: CountState = .{ .rows = 0 };
    var prefix_buf: [2]Span = undefined;
    var prefix_len: usize = 0;
    if (first_prefix_width > 0) {
        prefix_buf[0] = Span{ .text = padString(first_prefix_width), .style = .normal };
        prefix_len = 1;
    }
    try wrapCore(gpa, .{ .count = &state }, prefix_buf[0..prefix_len], continuation_indent, body, width);
    return state.rows;
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

/// First-line and continuation indent for the stacked table fallback.
const stacked_indent: u16 = 2;

/// Stacked fallback for tables too wide to give every column a usable width:
/// each data row renders as `key: value` lines at `stacked_indent`, with a
/// blank row between rows. `countStackedTableRows` mirrors this exactly.
fn renderStackedTable(gpa: std.mem.Allocator, b: *RowBuilder, table_rows: []const []const []const u8, width: u16) !void {
    if (table_rows.len < 2) return;
    const header = table_rows[0];
    const prefix = [_]Span{.{ .text = "  ", .style = .normal }};
    const data = table_rows[1..];
    for (data, 0..) |cells, index| {
        for (header, 0..) |key, col| {
            const value = if (col < cells.len) cells[col] else "";
            var stack: std.ArrayList(Span) = .empty;
            defer stack.deinit(gpa);
            var key_text: []const u8 = "";
            if (key.len > 0) {
                const fused = try fusedKeyText(gpa, key);
                key_text = try b.ownSpanText(gpa, fused);
                gpa.free(fused);
            }
            try stackedCellSpans(gpa, &stack, key_text, value);
            try appendWrapped(gpa, b, &prefix, stacked_indent, stack.items, width);
        }
        if (index + 1 < data.len) try appendEmptyRow(gpa, b);
    }
}

/// The spans of one stacked `key: value` line: the pre-built bold `key:` span
/// (empty when the header cell is empty) followed by the cell's inline spans.
/// Shared by the render and count paths so both wrap identical span lists.
fn stackedCellSpans(gpa: std.mem.Allocator, stack: *std.ArrayList(Span), key_text: []const u8, value: []const u8) !void {
    if (key_text.len > 0) try stack.append(gpa, .{ .text = key_text, .style = .strong });
    const spans = try inlineSpans(gpa, value, .normal);
    defer gpa.free(spans);
    try stack.appendSlice(gpa, spans);
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
        const pipe = self.cellEnd();
        self.index = @min(pipe + 1, self.end);
        return trim(self.line[start..@min(pipe, self.end)]);
    }

    /// Find the `|` terminating the cell starting at `self.index`, skipping pipes
    /// that sit inside an inline code span: `` ` `` toggles `in_code` and a pipe
    /// only ends a cell while no code span is open. If the scan reaches the row
    /// end with a code span still open, the backtick is unterminated — fall back
    /// to plain pipe splitting (treat the backtick literally) so a lone backtick
    /// can never swallow the rest of the row.
    fn cellEnd(self: *const TableCellIterator) usize {
        var in_code = false;
        var index = self.index;
        while (index < self.end) : (index += 1) {
            const byte = self.line[index];
            if (byte == '`') {
                in_code = !in_code;
            } else if (byte == '|' and !in_code) {
                return index;
            }
        }
        if (in_code) {
            return std.mem.indexOfScalarPos(u8, self.line, self.index, '|') orelse self.end;
        }
        return self.end;
    }
};

const Heading = struct { text: []const u8, level: u8 };

fn headingBody(line: []const u8) ?Heading {
    var level: u8 = 0;
    while (level < line.len) : (level += 1) {
        if (line[level] != '#') break;
        if (level == 6) return null;
    }
    if (level == 0) return null;
    if (level >= line.len) return null;
    if (line[level] != ' ') return null;
    return .{ .text = trimLeft(line[level + 1 ..]), .level = level };
}

fn quoteBody(line: []const u8) ?[]const u8 {
    if (line.len == 0) return null;
    if (line[0] != '>') return null;
    return trimLeft(line[1..]);
}

/// A list-item line: leading indent (nesting), the display marker
/// (`"• "` or the original `"3. "`), an optional task checkbox, and the body.
pub const ListInfo = struct {
    indent: u16,
    marker: []const u8,
    body: []const u8,
    /// `.task_marker` for `- [ ]`/`- [x]` checkboxes, `.list_marker` otherwise.
    style: Style = .list_marker,
};

/// Maximum nesting indent (in cells) recognized for list items; deeper
/// indentation stays a plain paragraph.
const list_max_indent: u16 = 8;

fn listBody(line: []const u8) ?ListInfo {
    if (line.len < 2) return null;
    const indent: u16 = @intCast(@min(skipSpaces(line, 0), list_max_indent));
    const rest = line[indent..];
    if (rest.len < 2) return null;

    var marker: []const u8 = undefined;
    var body: []const u8 = undefined;
    if (isListMarker(rest[0]) and rest[1] == ' ') {
        marker = "• ";
        body = rest[2..];
    } else if (orderedListMarker(rest)) |ordered| {
        marker = ordered;
        body = rest[ordered.len..];
    } else {
        return null;
    }
    body = trimLeft(body);
    // `- [ ]`/`- [x]` task items: the checkbox replaces the bullet marker and
    // gets its own style. Any other `[` starts the body verbatim.
    if (std.mem.startsWith(u8, body, "[ ] ")) {
        return .{ .indent = indent, .marker = "☐ ", .body = trimLeft(body[4..]), .style = .task_marker };
    }
    if (std.mem.startsWith(u8, body, "[x] ") or std.mem.startsWith(u8, body, "[X] ")) {
        return .{ .indent = indent, .marker = "☑ ", .body = trimLeft(body[4..]), .style = .task_marker };
    }
    return .{ .indent = indent, .marker = marker, .body = body };
}

/// An ordered marker `1. `/`12)` — up to nine digits, then `.` or `)`, then a
/// space. The full original text (number included) becomes the display marker.
fn orderedListMarker(rest: []const u8) ?[]const u8 {
    var digits: usize = 0;
    while (digits < rest.len and digits < 9 and std.ascii.isDigit(rest[digits])) : (digits += 1) {}
    if (digits == 0) return null;
    if (digits + 1 >= rest.len) return null;
    if (rest[digits] != '.' and rest[digits] != ')') return null;
    if (rest[digits + 1] != ' ') return null;
    return rest[0 .. digits + 2];
}

fn isListMarker(byte: u8) bool {
    return byte == '-' or byte == '*' or byte == '+';
}

/// A list-item row: an indent-space prefix, the marker span, then the wrapped
/// inline body. Continuation rows sit at `indent + marker_width`, matching
/// `countLineRows`'s prefix computation.
fn appendListItem(gpa: std.mem.Allocator, b: *RowBuilder, list: ListInfo, width: u16) !void {
    // Unindented items start at the marker (pinned by tests); indented items
    // prepend the indent-space span. The slice selects among fully-defined
    // slots — never an undefined one.
    var prefix: [2]Span = .{
        .{ .text = indentSpaces(list.indent), .style = .normal },
        .{ .text = list.marker, .style = list.style },
    };
    const prefix_spans: []const Span = if (list.indent > 0) prefix[0..2] else prefix[1..2];
    const spans = try inlineSpans(gpa, list.body, .normal);
    defer gpa.free(spans);
    const marker_width: u16 = @intCast(@min(list.indent + textWidth(list.marker), std.math.maxInt(u16)));
    return appendWrapped(gpa, b, prefix_spans, marker_width, spans, width);
}

/// Static space runs for the list-item indent prefix (capped at
/// `list_max_indent`, always even in practice).
fn indentSpaces(indent: u16) []const u8 {
    return switch (indent) {
        0 => "",
        1 => " ",
        2 => "  ",
        3 => "   ",
        4 => "    ",
        5 => "     ",
        6 => "      ",
        7 => "       ",
        else => "        ",
    };
}

/// A thematic-break line: three or more of the same marker byte (`-`, `*`, or
/// `_`), optionally space-separated, and nothing else. Runs after the table
/// check (a `---` under a table row is a separator) and before the list check
/// (`- - -` is a rule, not a nested bullet).
fn isHorizontalRule(line: []const u8) bool {
    const trimmed = trim(line);
    if (trimmed.len < 3) return false;
    const char = trimmed[0];
    if (char != '-' and char != '*' and char != '_') return false;
    var count: usize = 0;
    for (trimmed) |byte| {
        if (byte == char) {
            count += 1;
        } else if (byte != ' ' and byte != '\t') {
            return false;
        }
    }
    return count >= 3;
}

/// Code-block highlight modes selected by the fence info string. Unknown
/// languages fall back to a conservative generic mode that only highlights
/// near-universal keywords, so words like `type`/`use`/`match` stay plain.
const CodeMode = enum { generic, zig, python, shell, json, sql, lua, diff, html, rust, go, c, js };

fn codeModeFor(lang: []const u8) CodeMode {
    const aliases = [_]struct { mode: CodeMode, names: []const []const u8 }{
        .{ .mode = .zig, .names = &.{ "zig", "zst" } },
        .{ .mode = .python, .names = &.{ "python", "py", "py3" } },
        .{ .mode = .shell, .names = &.{ "bash", "sh", "shell", "zsh", "console" } },
        .{ .mode = .json, .names = &.{"json"} },
        .{ .mode = .sql, .names = &.{ "sql", "postgres", "postgresql", "mysql", "sqlite" } },
        .{ .mode = .lua, .names = &.{"lua"} },
        .{ .mode = .diff, .names = &.{ "diff", "patch" } },
        .{ .mode = .html, .names = &.{ "html", "xml" } },
        .{ .mode = .rust, .names = &.{ "rust", "rs" } },
        .{ .mode = .go, .names = &.{"go"} },
        .{ .mode = .c, .names = &.{ "c", "h", "cpp", "hpp" } },
        .{ .mode = .js, .names = &.{ "js", "ts", "javascript", "typescript", "jsx", "tsx" } },
    };
    for (aliases) |entry| {
        for (entry.names) |name| {
            if (std.ascii.eqlIgnoreCase(lang, name)) return entry.mode;
        }
    }
    return .generic;
}

/// Per-language keyword tables and comment syntax. A language absent here
/// (and not aliased to a mode) uses the conservative `generic` table.
const LangConfig = struct {
    keywords: []const []const u8,
    hash_comment: bool = false,
    dash_comment: bool = false,
    slash_comment: bool = false,
    block_comment: bool = false,
    /// Keyword matching is case-insensitive (SQL).
    case_insensitive: bool = false,
    /// Multi-line string delimiter (Lua `[[`).
    multi_line_string: ?[]const u8 = null,
};

fn langConfig(mode: CodeMode) LangConfig {
    return switch (mode) {
        .zig => .{
            .keywords = &.{
                "pub",   "fn",       "const",    "var",     "return",      "if",     "else",   "while",  "for",   "switch",
                "case",  "break",    "continue", "try",     "catch",       "orelse", "struct", "enum",   "union", "errdefer",
                "defer", "comptime", "inline",   "test",    "unreachable", "error",  "export", "extern", "align", "async",
                "await", "suspend",  "resume",   "anytype", "anyerror",    "type",   "void",   "bool",   "usize", "u8",
                "u16",   "u32",      "u64",      "i8",      "i16",         "i32",    "i64",    "f32",    "f64",
            },
            .slash_comment = true,
            .block_comment = false,
        },
        .python => .{
            .keywords = &.{
                "def",   "class", "import", "from", "as",  "with", "except", "finally", "lambda", "pass",
                "yield", "raise", "elif",   "try",  "if",  "else", "while",  "for",     "return", "True",
                "False", "None",  "and",    "or",   "not", "in",   "is",     "global",  "assert", "del",
                "async", "await", "self",
            },
            .hash_comment = true,
        },
        .shell => .{
            .keywords = &.{
                "if",    "then",     "else",  "elif",   "fi",   "do",   "done",   "esac",   "for", "while",
                "case",  "function", "local", "export", "echo", "exit", "return", "source", "set", "unset",
                "until", "in",       "shift", "trap",
            },
            .hash_comment = true,
        },
        .json => .{
            .keywords = &.{ "true", "false", "null" },
        },
        .sql => .{
            .keywords = &.{
                "select",  "from",       "where",    "insert", "into",  "update", "delete", "set",    "values",  "join",
                "left",    "right",      "inner",    "outer",  "on",    "group",  "order",  "having", "limit",   "offset",
                "union",   "all",        "as",       "and",    "or",    "not",    "null",   "is",     "in",      "between",
                "like",    "exists",     "create",   "table",  "alter", "drop",   "index",  "view",   "primary", "key",
                "foreign", "references", "distinct", "count",  "sum",   "avg",    "min",    "max",    "case",    "when",
                "then",    "else",       "end",
            },
            .dash_comment = true,
            .case_insensitive = true,
        },
        .lua => .{
            .keywords = &.{
                "local",  "function", "end",    "if",    "then", "else", "elseif", "for", "while", "do",
                "return", "break",    "repeat", "until", "nil",  "true", "false",  "and", "or",    "not",
                "in",     "goto",
            },
            .dash_comment = true,
            .multi_line_string = "[[",
        },
        .diff, .html, .generic => .{
            // Conservative fallback: only near-universal words highlight.
            .keywords = &.{ "true", "false", "null", "nil", "None", "self", "this", "return", "if", "else", "for", "while" },
            .slash_comment = true,
        },
        .rust => .{
            .keywords = &.{
                "fn",    "let",  "mut",   "const", "struct", "enum", "impl",   "trait", "use",      "pub",
                "match", "if",   "else",  "while", "for",    "loop", "return", "break", "continue", "where",
                "dyn",   "ref",  "move",  "async", "await",  "type", "as",     "in",    "mod",      "crate",
                "self",  "Self", "super",
            },
            .slash_comment = true,
            .block_comment = true,
        },
        .go => .{
            .keywords = &.{
                "func",   "var",    "const",       "type",  "struct", "interface", "map",    "chan",  "go",       "defer",
                "if",     "else",   "for",         "range", "switch", "case",      "return", "break", "continue", "package",
                "import", "select", "fallthrough", "goto",
            },
            .slash_comment = true,
            .block_comment = true,
        },
        .c => .{
            .keywords = &.{
                "int",   "char", "float",   "double", "void",   "long",  "short",    "signed", "unsigned", "struct",
                "union", "enum", "typedef", "static", "extern", "const", "volatile", "return", "if",       "else",
                "while", "do",   "for",     "switch", "case",   "break", "continue", "goto",   "sizeof",   "inline",
            },
            .slash_comment = true,
            .block_comment = true,
        },
        .js => .{
            .keywords = &.{
                "function", "var",    "let",        "const", "return", "if",      "else",  "while", "for",     "switch",
                "case",     "break",  "continue",   "try",   "catch",  "finally", "throw", "class", "extends", "new",
                "this",     "typeof", "instanceof", "in",    "of",     "async",   "await", "yield", "import",  "export",
                "default",  "delete", "void",
            },
            .slash_comment = true,
            .block_comment = true,
        },
    };
}

/// Highlight one code-block line for its language, carrying multi-line token
/// state (block comments, Lua bracket strings, HTML comments) in `state`. The
/// count path never tokenizes, so highlighting is row-count-neutral.
fn tokenizeCodeLine(gpa: std.mem.Allocator, line: []const u8, lang: []const u8, state: *BlockState) ![]Span {
    const mode = codeModeFor(lang);
    if (mode == .json) return tokenizeJsonLine(gpa, line);
    if (mode == .diff) return tokenizeDiffLine(gpa, line);
    if (mode == .html) return tokenizeHtmlLine(gpa, line, state);

    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(gpa);
    if (line.len == 0) return spans.toOwnedSlice(gpa);

    const config = langConfig(mode);

    var i: usize = 0;
    while (i < line.len) {
        // Continuing a multi-line string (Lua brackets).
        if (state.code_block_string) {
            const end = std.mem.indexOf(u8, line[i..], "]]") orelse line.len;
            const close_found = end < line.len - i;
            const stop = i + end + (if (close_found) @as(usize, 2) else 0);
            try appendSpan(&spans, gpa, line[i..stop], .code_string);
            i = stop;
            if (close_found) state.code_block_string = false;
            continue;
        }
        // Continuing a block comment (slash-star).
        if (state.code_block_comment) {
            const end = std.mem.indexOf(u8, line[i..], "*/") orelse line.len;
            const close_found = end < line.len - i;
            const stop = i + end + (if (close_found) @as(usize, 2) else 0);
            try appendSpan(&spans, gpa, line[i..stop], .code_comment);
            i = stop;
            if (close_found) state.code_block_comment = false;
            continue;
        }

        // Comments: rest-of-line and block openers.
        if ((config.hash_comment and line[i] == '#') or
            (config.dash_comment and i + 1 < line.len and line[i] == '-' and line[i + 1] == '-') or
            (config.slash_comment and i + 1 < line.len and line[i] == '/' and line[i + 1] == '/'))
        {
            try appendSpan(&spans, gpa, line[i..], .code_comment);
            break;
        }
        if (config.block_comment and i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
            const end = std.mem.indexOf(u8, line[i..], "*/") orelse line.len;
            const close_found = end < line.len - i;
            const stop = i + end + (if (close_found) @as(usize, 2) else 0);
            try appendSpan(&spans, gpa, line[i..stop], .code_comment);
            i = stop;
            if (!close_found) state.code_block_comment = true;
            continue;
        }

        // Strings: `"`, `'`, and Lua's bracket string.
        if (config.multi_line_string != null and std.mem.startsWith(u8, line[i..], config.multi_line_string.?)) {
            const end = std.mem.indexOf(u8, line[i + 2 ..], "]]") orelse line.len - i - 2;
            const close_found = end < line.len - i - 2;
            const stop = i + 2 + end + (if (close_found) @as(usize, 2) else 0);
            try appendSpan(&spans, gpa, line[i..stop], .code_string);
            i = stop;
            if (!close_found) state.code_block_string = true;
            continue;
        }
        if (line[i] == '"' or line[i] == '\'') {
            const quote = line[i];
            var end = i + 1;
            while (end < line.len) {
                if (line[end] == '\\') {
                    end = @min(end + 2, line.len);
                    continue;
                }
                if (line[end] == quote) {
                    end += 1;
                    break;
                }
                end += 1;
            }
            try appendSpan(&spans, gpa, line[i..end], .code_string);
            i = end;
            continue;
        }

        // Identifiers & keywords, with semantic fallbacks for the rest:
        // call position -> function, ALL_CAPS -> constant, capitalized -> type.
        if (std.ascii.isAlphabetic(line[i]) or line[i] == '_') {
            var end = i + 1;
            while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) : (end += 1) {}
            const word = line[i..end];
            try appendSpan(&spans, gpa, word, identifierStyle(config, word, line, end));
            i = end;
            continue;
        }

        // Numbers:
        if (std.ascii.isDigit(line[i])) {
            var end = i + 1;
            if (line[i] == '0' and end < line.len and (line[end] == 'x' or line[end] == 'b' or line[end] == 'o')) end += 1;
            while (end < line.len and (std.ascii.isHex(line[end]) or line[end] == '.' or line[end] == '_')) : (end += 1) {}
            try appendSpan(&spans, gpa, line[i..end], .code_number);
            i = end;
            continue;
        }

        // Punctuation, operators, whitespace:
        var end = i + 1;
        while (end < line.len) {
            const c = line[end];
            if (c == '"' or c == '\'' or std.ascii.isAlphanumeric(c) or c == '_' or
                (config.hash_comment and c == '#') or
                (config.dash_comment and c == '-' and end + 1 < line.len and line[end + 1] == '-') or
                (config.slash_comment and c == '/' and end + 1 < line.len and line[end + 1] == '/')) break;
            end += 1;
        }
        try appendSpan(&spans, gpa, line[i..end], .code);
        i = end;
    }

    if (spans.items.len == 0) try appendSpan(&spans, gpa, "", .code);
    return spans.toOwnedSlice(gpa);
}

/// Style for an identifier: keyword table first, then semantic heuristics —
/// call position -> function, ALL_CAPS with an underscore -> constant (before
/// the capitalized check, which would classify STATE_MAX as a type),
/// capitalized -> type.
fn identifierStyle(config: LangConfig, word: []const u8, line: []const u8, word_end: usize) Style {
    for (config.keywords) |kw| {
        const matched = if (config.case_insensitive)
            std.ascii.eqlIgnoreCase(word, kw)
        else
            std.mem.eql(u8, word, kw);
        if (matched) return .code_keyword;
    }
    if (word_end < line.len and line[word_end] == '(') return .code_function;
    var all_caps = true;
    for (word) |byte| {
        if (std.ascii.isAlphabetic(byte) and std.ascii.isLower(byte)) all_caps = false;
    }
    if (all_caps and std.mem.indexOfScalar(u8, word, '_') != null) return .code_constant;
    if (std.ascii.isUpper(word[0])) return .code_type;
    return .code;
}

/// JSON code blocks: same token taxonomy as the tool-parts JSON view
/// (punctuation/key/string/number/boolean/null) so both read alike.
fn tokenizeJsonLine(gpa: std.mem.Allocator, line: []const u8) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(gpa);
    if (line.len == 0) return spans.toOwnedSlice(gpa);

    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '"') {
            var end = i + 1;
            while (end < line.len) {
                if (line[end] == '\\') {
                    end = @min(end + 2, line.len);
                    continue;
                }
                if (line[end] == '"') {
                    end += 1;
                    break;
                }
                end += 1;
            }
            // A string followed by a colon is a key.
            var after = end;
            while (after < line.len and std.ascii.isWhitespace(line[after])) after += 1;
            const kind: Style = if (after < line.len and line[after] == ':') .code_function else .code_string;
            try appendSpan(&spans, gpa, line[i..end], kind);
            i = end;
            continue;
        }
        if (std.ascii.isDigit(line[i]) or (line[i] == '-' and i + 1 < line.len and std.ascii.isDigit(line[i + 1]))) {
            var end = i + 1;
            while (end < line.len and (std.ascii.isDigit(line[end]) or line[end] == '.' or line[end] == 'e' or line[end] == 'E' or line[end] == '-' or line[end] == '+')) : (end += 1) {}
            try appendSpan(&spans, gpa, line[i..end], .code_number);
            i = end;
            continue;
        }
        var literal_matched = false;
        for ([_][]const u8{ "true", "false", "null" }) |literal| {
            if (std.mem.startsWith(u8, line[i..], literal)) {
                try appendSpan(&spans, gpa, literal, .code_constant);
                i += literal.len;
                literal_matched = true;
                break;
            }
        }
        if (!literal_matched) {
            try appendSpan(&spans, gpa, line[i .. i + 1], .code);
            i += 1;
        }
    }
    if (spans.items.len == 0) try appendSpan(&spans, gpa, "", .code);
    return spans.toOwnedSlice(gpa);
}

/// diff/patch blocks: whole-line coloring keyed on the line prefix.
fn tokenizeDiffLine(gpa: std.mem.Allocator, line: []const u8) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);
    const style: Style = blk: {
        if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---")) break :blk .code_comment;
        if (std.mem.startsWith(u8, line, "@@")) break :blk .code_number;
        if (std.mem.startsWith(u8, line, "+")) break :blk .code_added;
        if (std.mem.startsWith(u8, line, "-")) break :blk .code_removed;
        break :blk .code;
    };
    try appendSpan(&spans, gpa, line, style);
    return spans.toOwnedSlice(gpa);
}

/// HTML/XML blocks: comments (carried across lines), tag names,
/// and attribute-value strings.
fn tokenizeHtmlLine(gpa: std.mem.Allocator, line: []const u8, state: *BlockState) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(gpa);
    if (line.len == 0) return spans.toOwnedSlice(gpa);

    var i: usize = 0;
    while (i < line.len) {
        if (state.code_block_comment) {
            const end = std.mem.indexOf(u8, line[i..], "-->") orelse line.len;
            const close_found = end < line.len - i;
            const stop = i + end + (if (close_found) @as(usize, 3) else 0);
            try appendSpan(&spans, gpa, line[i..stop], .code_comment);
            i = stop;
            if (close_found) state.code_block_comment = false;
            continue;
        }
        if (std.mem.startsWith(u8, line[i..], "<!--")) {
            const end = std.mem.indexOf(u8, line[i + 4 ..], "-->") orelse line.len - i - 4;
            const close_found = end < line.len - i - 4;
            const stop = i + 4 + end + (if (close_found) @as(usize, 3) else 0);
            try appendSpan(&spans, gpa, line[i..stop], .code_comment);
            i = stop;
            if (!close_found) state.code_block_comment = true;
            continue;
        }
        if (line[i] == '"') {
            var end = i + 1;
            while (end < line.len and line[end] != '"') : (end += 1) {}
            end = @min(end + 1, line.len);
            try appendSpan(&spans, gpa, line[i..end], .code_string);
            i = end;
            continue;
        }
        if (line[i] == '<') {
            // Tag name up to whitespace / `>` / `/`.
            var end = i + 1;
            while (end < line.len and line[end] != ' ' and line[end] != '>' and line[end] != '/' and line[end] != '\t') : (end += 1) {}
            try appendSpan(&spans, gpa, line[i .. i + 1], .code);
            if (end > i + 1) try appendSpan(&spans, gpa, line[i + 1 .. end], .code_keyword);
            i = end;
            continue;
        }
        var end = i + 1;
        while (end < line.len and line[end] != '"' and line[end] != '<') : (end += 1) {}
        try appendSpan(&spans, gpa, line[i..end], .code);
        i = end;
    }
    if (spans.items.len == 0) try appendSpan(&spans, gpa, "", .code);
    return spans.toOwnedSlice(gpa);
}

fn inlineSpans(gpa: std.mem.Allocator, line: []const u8, base: Style) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(gpa);

    // Plain text is emitted lazily: bytes that fail every construct attempt
    // accumulate into one span so a failed `_`/`*`/`` ` `` candidate never
    // splits a word — span boundaries are word boundaries in `wrapCore`
    // (adjacent spans join with a space), which would mangle `snake_case_name`.
    var index: usize = 0;
    var plain_start: usize = 0;
    while (index < line.len) {
        if (try consumeInlineConstruct(gpa, &spans, line, index, plain_start, base)) |next_index| {
            index = next_index;
            plain_start = next_index;
            continue;
        }
        index += 1;
    }
    try flushPlainSpan(&spans, gpa, line, plain_start, line.len, base);

    if (spans.items.len == 0) try appendSpan(&spans, gpa, "", base);
    return spans.toOwnedSlice(gpa);
}

/// Emit the pending plain run `[start..end)` as one span, if non-empty.
fn flushPlainSpan(spans: *std.ArrayList(Span), gpa: std.mem.Allocator, line: []const u8, start: usize, end: usize, style: Style) !void {
    if (end > start) try appendSpanWithLink(spans, gpa, line[start..end], style, "");
}

/// Attempt to consume one inline construct at `index`. On success the pending
/// plain run is flushed first and the new scan position is returned; on
/// failure nothing is emitted and the caller advances one byte.
fn consumeInlineConstruct(
    gpa: std.mem.Allocator,
    spans: *std.ArrayList(Span),
    line: []const u8,
    index: usize,
    plain_start: usize,
    base: Style,
) error{OutOfMemory}!?usize {
    // Backslash escape: `\X` renders X literally for ASCII punctuation.
    if (line[index] == '\\' and index + 1 < line.len and isInlinePunctuation(line[index + 1])) {
        try flushPlainSpan(spans, gpa, line, plain_start, index, base);
        try appendSpan(spans, gpa, line[index + 1 .. index + 2], base);
        return index + 2;
    }
    // Inline code: a run of n backticks closes on the next run of >= n.
    if (line[index] == '`') {
        const run = delimRunLen(line, index);
        if (findBacktickClose(line, index + run, run)) |close_start| {
            try flushPlainSpan(spans, gpa, line, plain_start, index, base);
            try appendSpan(spans, gpa, line[index + run .. close_start], .code);
            return close_start + run;
        }
        return null;
    }
    // Strikethrough: `~~text~~`.
    if (delimRunLen(line, index) >= 2 and line[index] == '~') {
        if (canOpenDelim(line, index, '~', 2)) {
            if (findDelimClose(line, index + 2, '~', 2)) |close| {
                try flushPlainSpan(spans, gpa, line, plain_start, index, base);
                const nested_base: Style = if (base == .heading) .heading else .strikethrough;
                const nested = try inlineSpans(gpa, line[index + 2 .. close], nested_base);
                defer gpa.free(nested);
                try spans.appendSlice(gpa, nested);
                return close + 2;
            }
        }
        return null;
    }
    // Strong: a run of two `*` or `_`.
    if (delimRunLen(line, index) >= 2 and (line[index] == '*' or line[index] == '_')) {
        if (canOpenDelim(line, index, line[index], 2)) {
            // `***content***` — a run-of-3 opener and closer — consumes the
            // whole run on both sides and renders bold italic (CommonMark
            // nests em inside strong for exactly this shape). Consuming only
            // two markers would leave the run's third marker embedded in the
            // bold content and literal at the close.
            const run = delimRunLen(line, index);
            if (run == 3) {
                if (findDelimCloseRun(line, index + 3, line[index], 3)) |close| {
                    try flushPlainSpan(spans, gpa, line, plain_start, index, base);
                    const nested_base: Style = if (base == .heading) .heading else .strong_emphasis;
                    const nested = try inlineSpans(gpa, line[index + 3 .. close], nested_base);
                    defer gpa.free(nested);
                    try spans.appendSlice(gpa, nested);
                    return close + 3;
                }
            }
            if (findDelimClose(line, index + 2, line[index], 2)) |close| {
                try flushPlainSpan(spans, gpa, line, plain_start, index, base);
                const nested_base: Style = if (base == .heading) .heading else .strong;
                const nested = try inlineSpans(gpa, line[index + 2 .. close], nested_base);
                defer gpa.free(nested);
                try spans.appendSlice(gpa, nested);
                return close + 2;
            }
        }
        return null;
    }
    // Emphasis: a single `*` or `_` (only reached for runs of exactly one —
    // longer runs already failed the strong attempt above and a single opener
    // inside a longer run would match an empty or shifted span).
    if ((line[index] == '*' or line[index] == '_') and delimRunLen(line, index) == 1) {
        if (canOpenDelim(line, index, line[index], 1)) {
            if (findDelimClose(line, index + 1, line[index], 1)) |close| {
                try flushPlainSpan(spans, gpa, line, plain_start, index, base);
                const nested_base: Style = if (base == .heading) .heading else .emphasis;
                const nested = try inlineSpans(gpa, line[index + 1 .. close], nested_base);
                defer gpa.free(nested);
                try spans.appendSlice(gpa, nested);
                return close + 1;
            }
        }
        return null;
    }
    // Anchored link: `[text](url)`.
    if (line[index] == '[') {
        if (std.mem.indexOfScalarPos(u8, line, index + 1, ']')) |close_bracket| {
            if (close_bracket + 1 < line.len and line[close_bracket + 1] == '(') {
                if (std.mem.indexOfScalarPos(u8, line, close_bracket + 2, ')')) |close_paren| {
                    try flushPlainSpan(spans, gpa, line, plain_start, index, base);
                    const anchor_text = line[index + 1 .. close_bracket];
                    const raw_url = line[close_bracket + 2 .. close_paren];
                    const link_url = if (isSafeHyperlinkUri(raw_url)) raw_url else "";
                    try appendSpanWithLink(spans, gpa, anchor_text, .link, link_url);
                    return close_paren + 1;
                }
            }
        }
        return null;
    }
    // Bare URL.
    if (isBareUrlStart(line, index)) {
        const url_end = bareUrlEnd(line, index);
        try flushPlainSpan(spans, gpa, line, plain_start, index, base);
        const raw_url = line[index..url_end];
        const link_url = if (isSafeHyperlinkUri(raw_url)) raw_url else "";
        try appendSpanWithLink(spans, gpa, raw_url, .link, link_url);
        return url_end;
    }
    return null;
}

/// Length of the run of the same byte starting at `index` (>= 1).
fn delimRunLen(line: []const u8, index: usize) usize {
    var end = index + 1;
    while (end < line.len and line[end] == line[index]) : (end += 1) {}
    return end - index;
}

/// The first run of >= `n` backticks at or after `from`.
fn findBacktickClose(line: []const u8, from: usize, n: usize) ?usize {
    var index = from;
    while (index < line.len) {
        if (line[index] == '`') {
            const run = delimRunLen(line, index);
            if (run >= n) return index;
            index += run;
        } else {
            index += 1;
        }
    }
    return null;
}

/// The next run of exactly `n` `char` delimiters at or after `from` whose
/// position passes the right-flanking check. Extra delimiters in a longer run
/// stay literal (CommonMark consumes `n` from the run start).
fn findDelimClose(line: []const u8, from: usize, char: u8, n: usize) ?usize {
    var index = from;
    while (index + n <= line.len) : (index += 1) {
        if (line[index] == char and canCloseDelim(line, index, char, n)) {
            if (n == 1 or line[index + 1] == char) return index;
        }
    }
    return null;
}

/// The first run of EXACTLY `n` `char` markers at or after `from` that passes
/// the right-flanking check — the closer shape for a run-of-3 opener, where a
/// longer run (`****`) must not be eaten whole.
fn findDelimCloseRun(line: []const u8, from: usize, char: u8, n: usize) ?usize {
    var index = from;
    while (index + n <= line.len) : (index += 1) {
        if (line[index] == char and canCloseDelim(line, index, char, n)) {
            if (delimRunLen(line, index) == n) return index;
            index += delimRunLen(line, index) - 1;
        }
    }
    return null;
}

/// Left-flanking check for an opening delimiter run of `n` markers at `index`:
/// not followed by whitespace; underscore additionally requires a word
/// boundary on its left when followed by punctuation.
fn canOpenDelim(line: []const u8, index: usize, char: u8, n: usize) bool {
    const next = index + n;
    if (next >= line.len) return false;
    if (isSpace(line[next])) return false;
    if (char == '_') {
        const preceded_by_boundary = index == 0 or isSpace(line[index - 1]) or isInlinePunctuation(line[index - 1]);
        if (isInlinePunctuation(line[next]) and !preceded_by_boundary) return false;
    }
    return true;
}

/// Right-flanking check for a closing delimiter run of `n` markers at `index`:
/// not preceded by whitespace; underscore additionally refuses to close when
/// followed by an alphanumeric word char, so `snake_case_name` stays literal.
fn canCloseDelim(line: []const u8, index: usize, char: u8, n: usize) bool {
    if (index == 0) return false;
    if (isSpace(line[index - 1])) return false;
    if (char == '_') {
        const after = index + n;
        const followed_by_word = after < line.len and std.ascii.isAlphanumeric(line[after]);
        if (followed_by_word and !isInlinePunctuation(line[index - 1])) return false;
    }
    return true;
}

/// ASCII punctuation per CommonMark's backslash-escape definition.
fn isInlinePunctuation(byte: u8) bool {
    return switch (byte) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

fn isBareUrlStart(line: []const u8, index: usize) bool {
    return std.mem.startsWith(u8, line[index..], "https://") or std.mem.startsWith(u8, line[index..], "http://");
}

fn bareUrlEnd(line: []const u8, index: usize) usize {
    var url_end = index;
    while (url_end < line.len and !std.ascii.isWhitespace(line[url_end]) and line[url_end] != ')' and line[url_end] != ']' and line[url_end] != '>') : (url_end += 1) {}
    // Trailing sentence punctuation is not part of the URL (a bare link to
    // "https://x.test/a." does not include the final dot).
    while (url_end > index and isTrailingUrlPunctuation(line[url_end - 1])) : (url_end -= 1) {}
    return url_end;
}

/// A hyperlink URI is emitted as an OSC 8 cell link only when it uses an
/// allow-listed scheme and carries no control bytes. `javascript:`/`data:`/
/// custom-scheme URIs from model output render as styled plain text instead of
/// clickable links. `file:` is deliberately not allow-listed: verifying "an
/// existing local path" needs filesystem access this pure leaf module must not
/// perform, so file URIs render unlinked (the safe default).
fn isSafeHyperlinkUri(uri: []const u8) bool {
    if (uri.len == 0 or uri.len > 2048) return false;
    for (uri) |b| {
        if (b < 0x20 or b == 0x7f) return false;
        if (b >= 0x80 and b <= 0x9f) return false;
    }
    return allowedHyperlinkScheme(uri);
}

/// Case-insensitive scheme allow-list: `http:`, `https:`, `mailto:` (a scheme
/// is `<name>:`; relative destinations have none and are not linked).
fn allowedHyperlinkScheme(uri: []const u8) bool {
    const schemes = [_][]const u8{ "http:", "https:", "mailto:" };
    for (schemes) |scheme| {
        if (uri.len >= scheme.len and std.ascii.eqlIgnoreCase(uri[0..scheme.len], scheme)) return true;
    }
    return false;
}

/// Sentence punctuation that is not part of a bare URL when it trails one.
fn isTrailingUrlPunctuation(byte: u8) bool {
    return switch (byte) {
        '.', ',', ':', ';', '!', '?', '\'', '"', '*', '_', '~' => true,
        else => false,
    };
}

fn appendSpanWithLink(spans: *std.ArrayList(Span), gpa: std.mem.Allocator, text: []const u8, style: Style, link_url: []const u8) !void {
    if (text.len == 0) return;
    try spans.append(gpa, .{ .text = text, .style = style, .link_url = link_url });
}

fn appendSpan(spans: *std.ArrayList(Span), gpa: std.mem.Allocator, text: []const u8, style: Style) !void {
    return appendSpanWithLink(spans, gpa, text, style, "");
}

/// The two consumers of word-wrapping: rendering (emit spans into the builder
/// pool) and sizing (count rows to derive a surface height). They MUST apply
/// identical line-boundary decisions, or the sized surface will clip rendered
/// rows. `RowSink` funnels both through the single `wrapCore` engine so the two
/// can never drift — the count path simply ignores span text and increments.
const RowSink = union(enum) {
    /// Emit rows. Borrows `b.scratch` as the in-progress span buffer.
    push: *RowBuilder,
    /// Count rows. Touches no heap; `current` stays empty.
    count: *CountState,
};

const CountState = struct { rows: u16, has_content: bool = false };

/// Sink-aware span addition: the push sink materializes spans into the
/// builder's scratch buffer for rendering; the count sink only tracks whether
/// the current row has content (via `has_content`), so it touches no heap.
fn addSpan(sink: RowSink, current: *std.ArrayList(Span), gpa: std.mem.Allocator, text: []const u8, style: Style, link_url: []const u8) !void {
    switch (sink) {
        .push => try appendSpanWithLink(current, gpa, text, style, link_url),
        .count => |state| {
            if (text.len > 0) state.has_content = true;
        },
    }
}

fn appendWrapped(
    gpa: std.mem.Allocator,
    b: *RowBuilder,
    first_prefix: []const Span,
    continuation_indent: u16,
    body: []const Span,
    width: u16,
) !void {
    try wrapCore(gpa, .{ .push = b }, first_prefix, continuation_indent, body, width);
}

fn appendEmptyRow(gpa: std.mem.Allocator, b: *RowBuilder) !void {
    try b.push(gpa, 0, &.{});
}

/// Count the visual rows `body` would occupy at `width`. Mirrors the render
/// path's two insets: the first line is indented by `first_prefix_width` (the
/// visual space a list marker `• ` or quote bar `┃ ` consumes) and every
/// continuation line by `continuation_indent` (the content indent). Both reduce
/// the line's usable width identically to `appendWrapped`, so the count and the
/// rendered rows can never disagree. Allocation-free: it runs `wrapCore` with a
/// count sink whose `addSpan` skips the ArrayList, so no spans are materialized
/// and `gpa` is never used to allocate.
fn countWrappedRows(gpa: std.mem.Allocator, body: []const u8, width: u16, first_prefix_width: u16, continuation_indent: u16) u16 {
    if (body.len == 0) return 1;
    var state: CountState = .{ .rows = 0 };
    const span = Span{ .text = body, .style = .normal };
    // Build a padding prefix whose width equals first_prefix_width without
    // allocating text: a run of spaces is width-1 each, which the count sink
    // measures via textWidth. This makes the first line consume exactly
    // first_prefix_width cells, matching the render path's `• `/`┃ ` prefix.
    var prefix_buf: [2]Span = undefined;
    var prefix_len: usize = 0;
    if (first_prefix_width > 0) {
        prefix_buf[0] = Span{ .text = padString(first_prefix_width), .style = .normal };
        prefix_len = 1;
    }
    wrapCore(
        gpa, // unused by the count sink; addSpan skips allocation for .count
        .{ .count = &state },
        prefix_buf[0..prefix_len],
        continuation_indent,
        &.{span},
        width,
    ) catch {};
    return state.rows;
}

/// A static space run of a given cell width, for the count sink's synthetic
/// prefix. The count sink only reads widths, not bytes, so these literals never
/// escape into a rendered row.
fn padString(width: u16) []const u8 {
    return switch (width) {
        1 => " ",
        2 => "  ",
        3 => "   ",
        else => "  ", // list/quote insets are always 2 in practice
    };
}

/// Single source of truth for word wrapping. Mirrors a line into one or more
/// rows of at most `width` cells: words break at spaces when they fit, and
/// hard-break (grapheme-aware) when a single word exceeds the remaining row.
/// `current_indent` starts at 0 (the first_prefix already accounts for the
/// first-line inset) and switches to `continuation_indent` after the first
/// committed row — matching list/quote rendering where `• `/`┃ ` mark only the
/// first line and continuation lines sit at the content indent.
fn wrapCore(
    gpa: std.mem.Allocator,
    sink: RowSink,
    first_prefix: []const Span,
    continuation_indent: u16,
    body: []const Span,
    width: u16,
) !void {
    // The push sink reuses the builder's scratch buffer so span capacity carries
    // across rows (the sub-linear-allocation invariant). The count sink never
    // allocates — `addSpan` skips the ArrayList for `.count` and only flips a
    // `has_content` bool on the CountState, so `empty_scratch` stays empty.
    var empty_scratch: std.ArrayList(Span) = .empty;
    const current: *std.ArrayList(Span) = switch (sink) {
        .push => |b| &b.scratch,
        .count => &empty_scratch,
    };
    var current_width = try startRow(gpa, sink, current, first_prefix, 0);
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
                    try commitRow(gpa, sink, current, current_indent);
                    current_indent = continuation_indent;
                    current_width = try startRow(gpa, sink, current, &.{}, current_indent);
                } else {
                    try addSpan(sink, current, gpa, " ", span.style, span.link_url);
                    current_width += 1;
                }
            }
            if (word_width > width -| current_width) {
                var hi: usize = 0;
                while (hi < word.len) {
                    // A too-wide prefix or continuation indent can leave no
                    // room on the row. Still consume one grapheme to guarantee
                    // forward progress at narrow widths.
                    const capacity = @max(width -| current_width, 1);
                    const end = graphemeSliceEnd(word, hi, capacity);
                    const slice = word[hi..end];
                    try addSpan(sink, current, gpa, slice, span.style, span.link_url);
                    current_width += textWidth(slice);
                    hi = end;
                    if (hi < word.len) {
                        try commitRow(gpa, sink, current, current_indent);
                        current_indent = continuation_indent;
                        current_width = try startRow(gpa, sink, current, &.{}, current_indent);
                    }
                }
            } else {
                try addSpan(sink, current, gpa, word, span.style, span.link_url);
                current_width += word_width;
            }
            index = word_end;
        }
    }

    const row_is_empty = switch (sink) {
        .push => current.items.len == 0,
        .count => |state| !state.has_content,
    };
    if (row_is_empty) {
        try addSpan(sink, current, gpa, "", .normal, "");
    }
    try commitRow(gpa, sink, current, current_indent);
}

/// Begin a row: clear the scratch buffer and, for the push sink only, copy the
/// prefix spans in. Returns the row's used width (prefix + indent) so the count
/// sink needs no heap — it just adds widths.
fn startRow(
    gpa: std.mem.Allocator,
    sink: RowSink,
    current: *std.ArrayList(Span),
    prefix: []const Span,
    indent: u16,
) !u16 {
    current.clearRetainingCapacity();
    var used: u16 = indent;
    switch (sink) {
        .push => {
            for (prefix) |span| {
                try current.append(gpa, span);
                used += textWidth(span.text);
            }
        },
        .count => |state| {
            for (prefix) |span| used += textWidth(span.text);
            state.has_content = false;
        },
    }
    return used;
}

/// Commit the current row: push it into the builder pool (render) or bump the
/// counter (count). `current` is cleared for the next row either way.
fn commitRow(gpa: std.mem.Allocator, sink: RowSink, current: *std.ArrayList(Span), indent: u16) !void {
    switch (sink) {
        .push => |b| try b.push(gpa, indent, current.items),
        .count => |state| {
            state.rows += 1;
            state.has_content = false;
        },
    }
    current.clearRetainingCapacity();
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
    try std.testing.expectEqual(@as(u16, 5), countRows(gpa, "| **Name** | Value |\n| --- | --- |\n| alpha | beta |", 80));
}

test "table cells wrap within column width" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "| Name | Value |\n| --- | --- |\n| alpha beta gamma | delta |", 24);
    defer out.deinit(gpa);

    try std.testing.expect(out.rows.len > 5);
    try std.testing.expectEqual(@as(u16, @intCast(out.rows.len)), countRows(gpa, "| Name | Value |\n| --- | --- |\n| alpha beta gamma | delta |", 24));
}

// Ported intent of upstream zigdown `9720b68`: a `|` inside an inline code span
// is literal, not a table column separator. The header fixes ncol at 2, so the
// data row's code-span pipe must not split off a third cell. `containsStyledText`
// proves the code span survived verbatim (row index 3 = top border, header,
// middle border, data row).
test "pipe inside inline code does not split table cells" {
    const gpa = std.testing.allocator;
    const table = "| a | b |\n| --- | --- |\n| `x|y` | z |";
    var out = try render(gpa, table, 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 5), out.rows.len);
    try std.testing.expect(containsStyledText(out.rows[3].spans, .code, "x|y"));
    try std.testing.expect(containsText(out.rows[3].spans, "z"));

    // SSOT guard: countRows and render share `TableCellIterator`, so they must
    // agree on the new column boundaries exactly.
    try std.testing.expectEqual(@as(u16, @intCast(out.rows.len)), countRows(gpa, table, 80));
}

// Pins the unterminated-backtick fallback: when a row's code span never closes,
// the backtick is treated literally and the row splits on the next pipe as
// before, so a lone backtick can never swallow the rest of the row.
test "unterminated backtick in a table row keeps pipe splitting" {
    const gpa = std.testing.allocator;
    const table = "| a | b |\n| --- | --- |\n| `x | y |";
    var out = try render(gpa, table, 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 5), out.rows.len);
    try std.testing.expect(containsText(out.rows[3].spans, "`x"));
    try std.testing.expect(containsText(out.rows[3].spans, "y"));
    try std.testing.expectEqual(@as(u16, @intCast(out.rows.len)), countRows(gpa, table, 80));
}

// Verification-style port of upstream `d93231d`: table padding is display-width
// based (vaxis gwidth), so multi-byte cells must not overflow the column. UTF-8
// continuation bytes can never equal '|' (0x7C), so cell splitting is byte-safe.
test "table cells with multi-byte content pad by display width" {
    const gpa = std.testing.allocator;
    const table = "| 名前 | 値 |\n| --- | --- |\n| 日本語 | データ |";
    for ([_]u16{ 80, 24 }) |width| {
        var out = try render(gpa, table, width);
        defer out.deinit(gpa);

        for (out.rows) |row| {
            try std.testing.expect(spansWidth(row.spans) <= width);
        }
        try std.testing.expectEqual(@as(u16, @intCast(out.rows.len)), countRows(gpa, table, width));
    }
}

// Zay's inline parser never had upstream's `*x*:` italic-terminator bug
// (`af00b60`); this locks the correct literal rendering in place.
test "italic followed by colon renders literally" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "*x*: y", 80);
    defer out.deinit(gpa);

    // One row, no crash, and the emphasis is exactly `x` — the colon must not be
    // absorbed into the italic terminator.
    try std.testing.expectEqual(@as(usize, 1), out.rows.len);
    try std.testing.expect(containsStyledText(out.rows[0].spans, .emphasis, "x"));

    // Concatenate the row's spans: the colon and `y` survive as literal text and
    // no emphasis/code marker leaks. (The wrap engine joins adjacent inline spans
    // with a single space — pre-existing, unrelated to the terminator fix — so
    // assert the colon's presence rather than a byte-exact join.)
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (out.rows[0].spans) |span| try text.appendSlice(gpa, span.text);
    try std.testing.expect(std.mem.indexOf(u8, text.items, ": y") != null);
    try std.testing.expect(std.mem.indexOfAny(u8, text.items, "*`") == null);
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

fn expectRowsEqual(expected: []const Row, actual: []const Row) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try std.testing.expectEqual(e.indent, a.indent);
        try std.testing.expectEqual(e.spans.len, a.spans.len);
        for (e.spans, a.spans) |es, as_| {
            try std.testing.expectEqual(es.style, as_.style);
            try std.testing.expectEqualStrings(es.text, as_.text);
        }
    }
}

test "incremental render matches full render at every append point" {
    const gpa = std.testing.allocator;
    const body =
        "# Title\n\nA paragraph with **bold** words long enough to wrap across this narrow column more than once.\n\n" ++
        "- item one with words\n- item two with `code`\n\n" ++
        "| Name | Value |\n| --- | --- |\n| alpha | beta |\n\n" ++
        "```\ncode line one\n\ncode line two\n```\n\nClosing paragraph here.\n";

    var inc: Incremental = .{};
    defer inc.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Feed every prefix length: each models a streaming delta boundary, and the
    // incrementally-cached result must be byte-identical to a full re-render.
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const prefix = body[0..i];
        const got = try inc.rows(gpa, arena.allocator(), prefix, 40);
        var full = try render(gpa, prefix, 40);
        defer full.deinit(gpa);
        expectRowsEqual(full.rows, got) catch |err| {
            std.debug.print("\nmismatch at prefix len {d}\n", .{i});
            return err;
        };
    }
}

test "incremental render survives a body buffer that moves on growth" {
    const gpa = std.testing.allocator;
    const source =
        "First paragraph that wraps a little at this width here now.\n\n" ++
        "## Heading two\n\nSecond paragraph also wraps somewhat across the column.\n\n" ++
        "- bullet alpha\n- bullet beta with `code`\n\nDone.\n";

    // A real streaming body: appended in chunks into an ArrayList, whose backing
    // buffer is reallocated (and may move) as it grows. The stable cache must not
    // hold spans into the old buffer.
    var inc: Incremental = .{};
    defer inc.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    var pos: usize = 0;
    while (pos < source.len) {
        const chunk = @min(@as(usize, 7), source.len - pos);
        // Force a fresh, differently-located allocation each step so a dangling
        // pointer into the previous buffer would surface as wrong text.
        try body.ensureTotalCapacityPrecise(gpa, body.items.len + chunk);
        body.appendSliceAssumeCapacity(source[pos .. pos + chunk]);
        pos += chunk;

        _ = arena.reset(.retain_capacity);
        const got = try inc.rows(gpa, arena.allocator(), body.items, 32);
        var full = try render(gpa, body.items, 32);
        defer full.deinit(gpa);
        try expectRowsEqual(full.rows, got);
    }
}

test "incremental render rebuilds on width change" {
    const gpa = std.testing.allocator;
    const body = "A paragraph that wraps differently at different widths.\n\nAnd a second block.\n";

    var inc: Incremental = .{};
    defer inc.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    _ = try inc.rows(gpa, arena.allocator(), body, 40);
    const got = try inc.rows(gpa, arena.allocator(), body, 20);
    var full = try render(gpa, body, 20);
    defer full.deinit(gpa);
    try expectRowsEqual(full.rows, got);
}

test "wraps at word boundaries" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "hello world", 8);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), out.rows.len);
    try std.testing.expectEqualStrings("hello", out.rows[0].spans[0].text);
    try std.testing.expectEqualStrings("world", out.rows[1].spans[0].text);
    try std.testing.expectEqual(@as(u16, 2), countRows(gpa, "hello world", 8));
}

// SSOT guard: `countRows` derives the surface height and `render`/`Incremental`
// fills it, so the two MUST agree or rows get clipped. This sweeps the cases
// that previously diverged by tens of rows (long words, CJK, lists, quotes,
// headings) across every width. If it ever fails, wrapCore has drifted from
// countWrappedRows — make them share one path again.
test "countRows matches render across widths and content shapes" {
    const gpa = std.testing.allocator;
    const Case = struct { name: []const u8, text: []const u8, min_width: u16 };
    const cases = [_]Case{
        .{ .name = "plain_long", .text = "the quick brown fox jumps over the lazy dog repeatedly", .min_width = 1 },
        .{ .name = "list_multiline", .text = "- this is a list item with enough words to wrap across several lines at moderate widths", .min_width = 1 },
        .{ .name = "quote_multiline", .text = "> quoted text that is long enough to wrap across multiple terminal lines here now", .min_width = 1 },
        .{ .name = "heading_wrap", .text = "# A fairly long heading that should wrap at narrower widths", .min_width = 1 },
        .{ .name = "list_longword", .text = "- short then aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa tail", .min_width = 1 },
        .{ .name = "cjk", .text = "日本語の文章です this is mixed ascii and wide chars wrapping", .min_width = 1 },
        .{ .name = "many_short", .text = "a b c d e f g h i j k l m n o p q r s t u v w x y z", .min_width = 1 },
        .{ .name = "multiword_hardwrap", .text = "aa bb cc dd ee ff", .min_width = 1 },
    };
    // One shared incremental across the sweep: on a cold (unprimed) cache it
    // falls back to the full scan, so this exercises the fallback parity.
    var inc: Incremental = .{};
    defer inc.deinit(gpa);
    for (cases) |c| {
        var w: u16 = c.min_width;
        while (w <= 60) : (w += 1) {
            const counted = countRows(gpa, c.text, w);
            var out = try render(gpa, c.text, w);
            defer out.deinit(gpa);
            const rendered: u16 = @intCast(out.rows.len);
            try std.testing.expectEqual(counted, rendered);
            try std.testing.expectEqual(counted, inc.countRows(c.text, w));
        }
    }
}

// Regression (#134): list/quote content uses continuation_indent = 2, and the
// hard-break loop used to commit rows forever without advancing when
// width <= 2 left zero capacity. These exact repros must terminate — a
// regression shows up as this test hanging, not failing an assertion.
test "list and quote wrapping terminate at width <= 2" {
    const gpa = std.testing.allocator;
    const repros = [_][]const u8{
        "- a b c",
        "> a b c",
        "- aaaaaaaaaaaaaaaaaaaa",
        "> aaaaaaaaaaaaaaaaaaaa",
    };
    for (repros) |text| {
        for ([_]u16{ 1, 2 }) |w| {
            const counted = countRows(gpa, text, w);
            var out = try render(gpa, text, w);
            defer out.deinit(gpa);
            try std.testing.expectEqual(counted, @as(u16, @intCast(out.rows.len)));
            try std.testing.expect(counted > 0);
        }
    }
}

// Invariant behind `renderLimited`'s byte-bound capacity estimate: every
// rendered row consumes at least one input byte, except the single empty-body
// row (table border rows are paid for by the >=3-byte lines that produce them).
// `"\n\n\n"` is the tight case — it renders exactly 4 = 3 + 1 rows, so the
// `+| 1` may not be "simplified" away.
test "rendered rows never exceed text length plus one" {
    const gpa = std.testing.allocator;
    const Case = struct { name: []const u8, text: []const u8, min_width: u16 };
    const cases = [_]Case{
        .{ .name = "empty", .text = "", .min_width = 1 },
        .{ .name = "single_char", .text = "a", .min_width = 1 },
        .{ .name = "single_line", .text = "a\n", .min_width = 1 },
        .{ .name = "blank_lines", .text = "\n\n\n", .min_width = 1 },
        .{ .name = "mixed_blank", .text = "a\n\n\nb\n", .min_width = 1 },
        .{ .name = "whitespace_only", .text = "   \n\t\n", .min_width = 1 },
        .{ .name = "heading", .text = "# A fairly long heading that should wrap at narrower widths", .min_width = 1 },
        .{ .name = "list_longword", .text = "- short then aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa tail", .min_width = 1 },
        .{ .name = "quote", .text = "> quoted text that is long enough to wrap across multiple terminal lines here now", .min_width = 1 },
        .{ .name = "table_cjk", .text = "| Name | Value |\n| --- | --- |\n| 日本語のとても長い内容 | beta with words that wrap |\n", .min_width = 1 },
        .{ .name = "code", .text = "```\ncode line one\n\ncode line two\n```\n", .min_width = 1 },
    };
    for (cases) |c| {
        var w: u16 = c.min_width;
        while (w <= 40) : (w += 1) {
            var out = try render(gpa, c.text, w);
            defer out.deinit(gpa);
            try std.testing.expect(out.rows.len <= c.text.len + 1);
        }
    }
}

// The `estimate_row_cap` on the reservation is a hint, never a clip: a body
// producing more rows than the cap must still render every row. Width 10 gives
// one row per "x" line, plus the trailing-newline phantom row.
test "render renders past the estimate cap without clipping" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.ensureTotalCapacity(gpa, 2 * (estimate_row_cap + 1));
    var i: usize = 0;
    while (i <= estimate_row_cap) : (i += 1) body.appendSliceAssumeCapacity("x\n");

    var out = try render(gpa, body.items, 10);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, estimate_row_cap + 2), out.rows.len);
}

// `max_rows` is a soft per-block budget: each blank line commits exactly one
// row, so the loop guard can stop to the row here — a sound early-stop probe
// without over-claiming a hard cap for multi-row blocks.
test "renderLimited stops at the row budget on blank lines" {
    const gpa = std.testing.allocator;
    var out = try renderLimited(gpa, "\n\n\n\n", 10, 2);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), out.rows.len);
}

// The `Incremental` count must also match on a *warm* cache — where it is
// `stable.rows.len` plus a count of the volatile tail — because that is exactly
// the state `messageRowsCached` sees mid-session. Feeding every prefix through
// `rows()` (as a stream would) then counting must agree with the full scan.
test "Incremental.countRows matches the full count across streaming appends" {
    const gpa = std.testing.allocator;
    const body =
        "# Title\n\nA paragraph with **bold** words long enough to wrap across this narrow column more than once.\n\n" ++
        "- item one with words\n- item two with `code`\n\n" ++
        "| Name | Value |\n| --- | --- |\n| alpha | beta |\n\n" ++
        "```\ncode line one\n\ncode line two\n```\n\nClosing paragraph here.\n";

    var inc: Incremental = .{};
    defer inc.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const prefix = body[0..i];
        _ = try inc.rows(gpa, arena.allocator(), prefix, 40);
        const counted = countRows(gpa, prefix, 40);
        try std.testing.expectEqual(counted, inc.countRows(prefix, 40));
    }
}

// SSOT guard: a hard-wrapped word in a list/quote must continue at the content
// indent, not the first-line indent. The count path is covered above; this
// fixes the rendered indent in place so the visual matches the count.
test "hard-wrapped continuation lines keep the continuation indent" {
    const gpa = std.testing.allocator;
    // width 12: "• " prefix = 2, leaving 10; the 30-char word hard-wraps.
    var out = try render(gpa, "- aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 12);
    defer out.deinit(gpa);

    try std.testing.expect(out.rows.len >= 3);
    try std.testing.expectEqual(@as(u16, 0), out.rows[0].indent); // first line: prefix already inset
    for (out.rows[1..]) |row| {
        try std.testing.expectEqual(@as(u16, 2), row.indent); // continuation at content indent
    }
}

// SSOT guard: the count path must stay allocation-free. It runs every draw
// frame per message on a cache miss, so a leak here would compound. We prove
// zero allocations with a CountingAllocator — std.testing.allocator only
// catches leaks, not allocations that are freed, so a counter is the correct
// tool to lock the "no allocation" invariant in place.
test "countRows returns expected values and makes no allocations" {
    const gpa = std.testing.allocator;

    // Explicit return-value checks for known (text, width) pairs.
    try std.testing.expectEqual(@as(u16, 4), countRows(gpa, "the quick brown fox", 8));
    try std.testing.expectEqual(@as(u16, 1), countRows(gpa, "the quick brown fox", 80));
    try std.testing.expectEqual(@as(u16, 2), countRows(gpa, "hello world", 8));

    // Allocation proof: wrap each countRows call with a CountingAllocator
    // whose child is std.testing.allocator. The count path's addSpan skips
    // the ArrayList for .count (only flipping a has_content bool), so
    // alloc_count must stay 0. std.testing.allocator also catches leaks at
    // teardown as a secondary guard.
    const texts = [_][]const u8{
        "the quick brown fox",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "- list with aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "> quote 日本語 wide aaaaaaaaaaaaaa",
    };
    for (texts) |t| {
        var w: u16 = 8;
        while (w <= 40) : (w += 1) {
            var counting: CountingAllocator = .{ .child = gpa };
            _ = countRows(counting.allocator(), t, w);
            try std.testing.expectEqual(@as(usize, 0), counting.count);
        }
    }
}

test "code blocks highlight syntax tokens" {
    const gpa = std.testing.allocator;
    const code =
        \\```zig
        \\pub fn main() void {
        \\    // comment
        \\    const x = 42;
        \\    const s = "hello";
        \\}
        \\```
    ;
    var out = try render(gpa, code, 80);
    defer out.deinit(gpa);

    try std.testing.expect(out.rows.len >= 7);
    // Row 0 is the fenced header ("╭─ zig ─..."), rows 1..4 are code, last row is footer.
    try std.testing.expect(containsStyledText(out.rows[0].spans, .code_border, "zig"));
    // Line 1: pub (keyword), fn (keyword)
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code_keyword, "pub"));
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code_keyword, "fn"));
    // Line 2: // comment tokens
    try std.testing.expect(containsStyledText(out.rows[2].spans, .code_comment, "//"));
    try std.testing.expect(containsStyledText(out.rows[2].spans, .code_comment, "comment"));
    // Line 3: const (keyword), 42 (number)
    try std.testing.expect(containsStyledText(out.rows[3].spans, .code_keyword, "const"));
    try std.testing.expect(containsStyledText(out.rows[3].spans, .code_number, "42"));
    // Line 4: "hello" (string)
    try std.testing.expect(containsStyledText(out.rows[4].spans, .code_string, "\"hello\""));
    try std.testing.expect(containsStyledText(out.rows[out.rows.len - 1].spans, .code_border, "╰"));
}

test "markdown links and bare urls attach link_url" {
    const gpa = std.testing.allocator;
    const text = "Visit [Zay Home](https://zay.org) or bare https://github.com/ozgurulukir/zay today";
    var out = try render(gpa, text, 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.rows.len);
    var found_named = false;
    var found_bare = false;
    for (out.rows[0].spans) |span| {
        if (std.mem.eql(u8, span.text, "Zay")) {
            try std.testing.expectEqual(Style.link, span.style);
            try std.testing.expectEqualStrings("https://zay.org", span.link_url);
            found_named = true;
        }
        if (std.mem.eql(u8, span.text, "https://github.com/ozgurulukir/zay")) {
            try std.testing.expectEqual(Style.link, span.style);
            try std.testing.expectEqualStrings("https://github.com/ozgurulukir/zay", span.link_url);
            found_bare = true;
        }
    }
    try std.testing.expect(found_named);
    try std.testing.expect(found_bare);
}

test "ordered lists keep their original number marker" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "3. third item\n12. twelfth item", 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), out.rows.len);
    try std.testing.expectEqualStrings("3. ", out.rows[0].spans[0].text);
    try std.testing.expectEqual(Style.list_marker, out.rows[0].spans[0].style);
    try std.testing.expect(containsText(out.rows[0].spans, "third"));
    try std.testing.expect(containsText(out.rows[0].spans, "item"));
    try std.testing.expectEqualStrings("12. ", out.rows[1].spans[0].text);
    try std.testing.expectEqual(@as(u16, 2), countRows(gpa, "3. third item\n12. twelfth item", 80));
}

test "nested lists indent by leading whitespace" {
    const gpa = std.testing.allocator;
    const text = "- top\n  - nested\n    - deeper";
    var out = try render(gpa, text, 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), out.rows.len);
    try std.testing.expectEqualStrings("• ", out.rows[0].spans[0].text);
    try std.testing.expectEqualStrings("  ", out.rows[1].spans[0].text);
    try std.testing.expectEqualStrings("• ", out.rows[1].spans[1].text);
    try std.testing.expectEqual(@as(u16, 3), countRows(gpa, text, 80));
}

test "task list items render checkbox markers" {
    const gpa = std.testing.allocator;
    const text = "- [ ] open task\n- [x] done task";
    var out = try render(gpa, text, 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), out.rows.len);
    try std.testing.expectEqual(Style.task_marker, out.rows[0].spans[0].style);
    try std.testing.expectEqual(Style.task_marker, out.rows[1].spans[0].style);
    try std.testing.expect(containsText(out.rows[0].spans, "open"));
    try std.testing.expect(containsText(out.rows[1].spans, "done"));
    try std.testing.expect(!containsText(out.rows[0].spans, "[ ]"));
    try std.testing.expect(!containsText(out.rows[1].spans, "[ ]"));
    try std.testing.expectEqual(@as(u16, 2), countRows(gpa, text, 80));
}

test "horizontal rules render one full-width row" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "---", "***", "___", "- - -", "------" }) |rule| {
        var out = try render(gpa, rule, 40);
        defer out.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), out.rows.len);
        try std.testing.expectEqual(Style.rule, out.rows[0].spans[0].style);
        try std.testing.expectEqual(@as(u16, 1), countRows(gpa, rule, 40));
    }
    // Not rules: shorter than three markers, or mixed content.
    for ([_][]const u8{ "--", "- x -", "a---" }) |not_rule| {
        var out = try render(gpa, not_rule, 40);
        defer out.deinit(gpa);
        try std.testing.expect(out.rows[0].spans[0].style != .rule);
    }
}

test "heading levels map to distinct styles" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "# one\n## two\n### three", 80);
    defer out.deinit(gpa);

    try std.testing.expectEqual(Style.heading, out.rows[0].spans[0].style);
    try std.testing.expectEqual(Style.heading_h2, out.rows[1].spans[0].style);
    try std.testing.expectEqual(Style.heading_h3, out.rows[2].spans[0].style);
}

test "tilde fences and longer fences open and close code blocks" {
    const gpa = std.testing.allocator;
    // Tilde fence: row 0 = header, row 1 = code, row 2 = footer, row 3 = normal.
    var out = try render(gpa, "~~~\ncode here\n~~~\nafter", 80);
    defer out.deinit(gpa);
    // Content lines tokenize with the generic code styles.
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code, "code"));
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code, "here"));
    try std.testing.expectEqual(Style.normal, out.rows[3].spans[0].style);

    // A four-backtick fence closes only on a four-backtick run; three backticks
    // inside are content.
    var long = try render(gpa, "````\ninner ``` line\n````\nafter", 80);
    defer long.deinit(gpa);
    try std.testing.expect(containsStyledText(long.rows[1].spans, .code, "```"));
    try std.testing.expectEqual(Style.normal, long.rows[3].spans[0].style);
    try std.testing.expectEqual(@as(u16, 4), countRows(gpa, "````\ninner ``` line\n````\nafter", 80));

    // A marker run followed by an info string inside an open block is code
    // text, not a closer (CommonMark: closing fences carry no info string);
    // the block ends only at the bare closer.
    var info_close = try render(gpa, "```js\nconst x = 1;\n```js\n```\nafter", 80);
    defer info_close.deinit(gpa);
    try std.testing.expect(containsStyledText(info_close.rows[1].spans, .code_keyword, "const"));
    try std.testing.expect(containsStyledText(info_close.rows[2].spans, .code, "js"));
    try std.testing.expectEqual(Style.normal, info_close.rows[4].spans[0].style);
    try std.testing.expectEqual(@as(u16, 5), countRows(gpa, "```js\nconst x = 1;\n```js\n```\nafter", 80));
}

test "strikethrough and underscore emphasis render as styled spans" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "~~gone~~ and _soft_ and __hard__", 80);
    defer out.deinit(gpa);

    try std.testing.expect(containsStyledText(out.rows[0].spans, .strikethrough, "gone"));
    try std.testing.expect(containsStyledText(out.rows[0].spans, .emphasis, "soft"));
    try std.testing.expect(containsStyledText(out.rows[0].spans, .strong, "hard"));
    try std.testing.expect(!containsText(out.rows[0].spans, "~~"));
}

test "run-of-3 emphasis renders bold italic with no stray markers" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "***bold italic*** and plain", 80);
    defer out.deinit(gpa);

    // The wrap engine splits at spaces, so each word is its own span.
    try std.testing.expect(containsStyledText(out.rows[0].spans, .strong_emphasis, "bold"));
    try std.testing.expect(containsStyledText(out.rows[0].spans, .strong_emphasis, "italic"));
    try std.testing.expect(!containsText(out.rows[0].spans, "*"));
    try std.testing.expect(containsText(out.rows[0].spans, "plain"));
    try std.testing.expectEqual(@as(u16, 1), countRows(gpa, "***bold italic*** and plain", 80));
}

test "multi-backtick code spans keep inner backticks literal" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "`` `quoted` `` literal", 80);
    defer out.deinit(gpa);

    try std.testing.expect(containsStyledText(out.rows[0].spans, .code, "`quoted`"));
    try std.testing.expect(!containsText(out.rows[0].spans, "``"));
}

test "arithmetic asterisks and snake_case render verbatim" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "2 * 3 * 4", "snake_case_name", "a_b_c_d" }) |literal| {
        var out = try render(gpa, literal, 80);
        defer out.deinit(gpa);

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        for (out.rows[0].spans) |span| try text.appendSlice(gpa, span.text);
        try std.testing.expectEqualStrings(literal, std.mem.trim(u8, text.items, " "));
        try std.testing.expectEqual(@as(u16, 1), countRows(gpa, literal, 80));
    }
}

test "backslash escapes render the escaped character literally" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "2 \\* 3 \\* 4 and \\`code\\`", 80);
    defer out.deinit(gpa);

    // Each escaped character is its own span, and the wrap engine joins spans
    // with a space — pre-existing behavior, so assert on characters, not on a
    // byte-exact join.
    try std.testing.expect(!containsText(out.rows[0].spans, "\\"));
    try std.testing.expect(containsText(out.rows[0].spans, "`"));
    try std.testing.expect(!containsStyledText(out.rows[0].spans, .emphasis, "3"));
    try std.testing.expect(!containsStyledText(out.rows[0].spans, .code, "code"));
}

test "tables size columns by content and honour alignment" {
    const gpa = std.testing.allocator;
    const table = "| ID | Description |\n| :-- | --: |\n| a | a fairly long description column value |\n| b | short |";
    var out = try render(gpa, table, 60);
    defer out.deinit(gpa);

    // Count parity at multiple widths.
    for ([_]u16{ 60, 30, 20 }) |w| {
        var wide = try render(gpa, table, w);
        defer wide.deinit(gpa);
        try std.testing.expectEqual(@as(u16, @intCast(wide.rows.len)), countRows(gpa, table, w));
    }

    // The description column (natural width ~41) must be wider than the ID
    // column (natural width 1): compare the two columns' rendered content rows.
    const data_row = out.rows[3].spans;
    try std.testing.expect(data_row.len > 4);
    // Header cells right-aligned in column 2: "Description" starts after padding.
    try std.testing.expect(containsText(out.rows[1].spans, "Description"));
}

test "wide tables fall back to stacked key-value rows" {
    const gpa = std.testing.allocator;
    const table = "| C1 | C2 | C3 | C4 | C5 | C6 | C7 | C8 | C9 | C10 |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n| v1 | v2 | v3 | v4 | v5 | v6 | v7 | v8 | v9 | v10 |";
    var out = try render(gpa, table, 40);
    defer out.deinit(gpa);

    // Stacked: 10 key-value lines for the one data row, no border rows, no
    // trailing blank (blank rows only separate groups).
    try std.testing.expectEqual(@as(usize, 10), out.rows.len);
    try std.testing.expectEqual(@as(u16, @intCast(out.rows.len)), countRows(gpa, table, 40));
    try std.testing.expect(containsStyledText(out.rows[0].spans, .strong, "C1:"));
    try std.testing.expect(containsText(out.rows[0].spans, "v1"));
    try std.testing.expect(!containsText(out.rows[0].spans, "┌"));
}

test "highlighting differs by language for the same token" {
    const gpa = std.testing.allocator;
    // `type` is a Zig keyword; in Python it is an ordinary identifier.
    var zig_out = try render(gpa, "```zig\nconst T = type;\n```", 80);
    defer zig_out.deinit(gpa);
    try std.testing.expect(containsStyledText(zig_out.rows[1].spans, .code_keyword, "type"));

    var py_out = try render(gpa, "```python\ndef use_type(): pass\n```", 80);
    defer py_out.deinit(gpa);
    try std.testing.expect(containsStyledText(py_out.rows[1].spans, .code_keyword, "def"));
    try std.testing.expect(!containsStyledText(py_out.rows[1].spans, .code_keyword, "type"));
}

test "unknown languages fall back without mis-highlighting common words" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "```txt\nuse match type void\n```", 80);
    defer out.deinit(gpa);
    try std.testing.expect(!containsStyledText(out.rows[1].spans, .code_keyword, "match"));
    try std.testing.expect(!containsStyledText(out.rows[1].spans, .code_keyword, "use"));
    try std.testing.expect(!containsStyledText(out.rows[1].spans, .code_keyword, "type"));
}

test "identifiers get semantic styles by shape and call position" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "```zig\nMyType.doThing(STATE_MAX)\n```", 80);
    defer out.deinit(gpa);
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code_type, "MyType"));
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code_function, "doThing"));
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code_constant, "STATE_MAX"));
}

test "block comments carry highlighting state across lines" {
    const gpa = std.testing.allocator;
    const body = "```rust\n/* first line\nstill comment\nend */\nfn after()\n```";
    var out = try render(gpa, body, 80);
    defer out.deinit(gpa);
    // Row 0 = header, rows 1-3 = comment lines, row 4 = fn line, row 5 = footer.
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code_comment, "/*"));
    try std.testing.expect(containsStyledText(out.rows[2].spans, .code_comment, "still"));
    try std.testing.expect(containsStyledText(out.rows[3].spans, .code_comment, "*/"));
    try std.testing.expect(containsText(out.rows[3].spans, "end"));
    try std.testing.expect(containsStyledText(out.rows[4].spans, .code_keyword, "fn"));

    // The same body through the incremental renderer must produce identical
    // spans — the multi-line state lives in BlockState on both paths.
    var inc: Incremental = .{};
    defer inc.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const got = try inc.rows(gpa, arena.allocator(), body, 80);
    try expectRowsEqual(out.rows, got);
}

test "diff blocks color added and removed lines" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "```diff\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old line\n+new line\n```", 80);
    defer out.deinit(gpa);
    // Row 0 = header; rows 1-5 = diff lines.
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code_comment, "---"));
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code_comment, "a/file"));
    try std.testing.expect(containsStyledText(out.rows[2].spans, .code_comment, "+++"));
    try std.testing.expect(containsStyledText(out.rows[3].spans, .code_number, "@@"));
    try std.testing.expect(containsStyledText(out.rows[4].spans, .code_removed, "-old"));
    try std.testing.expect(containsStyledText(out.rows[5].spans, .code_added, "+new"));
}

test "json blocks highlight keys, literals, and numbers" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "```json\n{\"ok\": true, \"n\": 42}\n```", 80);
    defer out.deinit(gpa);
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code_function, "\"ok\""));
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code_constant, "true"));
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code_number, "42"));
}

test "sql keywords match case-insensitively" {
    const gpa = std.testing.allocator;
    var out = try render(gpa, "```sql\nselect count(*) from users;\n```", 80);
    defer out.deinit(gpa);
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code_keyword, "select"));
    try std.testing.expect(containsStyledText(out.rows[1].spans, .code_keyword, "from"));
}

test "disallowed schemes render as styled text without a link" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "[click](javascript:alert(1))", "[doc](file:///etc/passwd)", "[x](data:text/plain,hi)" }) |text| {
        var out = try render(gpa, text, 80);
        defer out.deinit(gpa);
        for (out.rows[0].spans) |span| {
            if (span.style == .link) {
                try std.testing.expectEqualStrings("", span.link_url);
            }
        }
    }
    // Allowed schemes keep their destination (case-insensitive match).
    var ok = try render(gpa, "[site](HTTPS://example.com)", 80);
    defer ok.deinit(gpa);
    var linked = false;
    for (ok.rows[0].spans) |span| {
        if (std.mem.eql(u8, span.text, "site")) {
            try std.testing.expectEqualStrings("HTTPS://example.com", span.link_url);
            linked = true;
        }
    }
    try std.testing.expect(linked);
}

test "bare urls exclude trailing sentence punctuation" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "see https://x.test/a. and go", "at https://x.test/b, then", "ask https://x.test/c?q! ok" }) |text| {
        var out = try render(gpa, text, 80);
        defer out.deinit(gpa);
        var found = false;
        for (out.rows[0].spans) |span| {
            if (span.link_url.len > 0) {
                try std.testing.expect(isTrailingUrlPunctuation(span.link_url[span.link_url.len - 1]) == false);
                try std.testing.expect(std.mem.startsWith(u8, span.link_url, "https://x.test/"));
                found = true;
            }
        }
        try std.testing.expect(found);
    }
}

test "fenced code blocks emit header/footer and countRows matches render" {
    const gpa = std.testing.allocator;
    const with_lang = "```zig\nconst x = 1;\n```";
    var out1 = try render(gpa, with_lang, 30);
    defer out1.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), out1.rows.len);
    try std.testing.expectEqual(out1.rows.len, countRows(gpa, with_lang, 30));
    try std.testing.expect(containsStyledText(out1.rows[0].spans, .code_border, "zig"));
    try std.testing.expect(containsStyledText(out1.rows[1].spans, .code_border, "│ "));
    try std.testing.expect(containsStyledText(out1.rows[2].spans, .code_border, "╰"));

    const no_lang = "```\nplain code\n```";
    var out2 = try render(gpa, no_lang, 30);
    defer out2.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), out2.rows.len);
    try std.testing.expectEqual(out2.rows.len, countRows(gpa, no_lang, 30));
    try std.testing.expect(containsStyledText(out2.rows[0].spans, .code_border, "╭"));
}

test "list items support lazy continuation lines with countRows and incremental parity" {
    const gpa = std.testing.allocator;
    const inputs = [_][]const u8{
        "- item one\ncontinued here",
        "1. ordered\ncontinued ordered",
        "- [x] done\ncontinued task",
        "  - nested\ncontinued nested",
    };
    for (inputs) |text| {
        var out = try render(gpa, text, 40);
        defer out.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 2), out.rows.len);
        try std.testing.expectEqual(@as(u16, 2), countRows(gpa, text, 40));
        try std.testing.expect(out.rows[1].spans.len > 0);
        // Continuation line is indented past column 0.
        try std.testing.expect(out.rows[1].spans[0].text[0] == ' ');

        var inc: Incremental = .{};
        defer inc.deinit(gpa);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const got = try inc.rows(gpa, arena.allocator(), text, 40);
        try expectRowsEqual(out.rows, got);
    }
}

test "Incremental.boundedTailSlice aligns past UTF-8 continuation bytes and preserves rows/countRows parity" {
    const gpa = std.testing.allocator;
    // Build a body > 256 KB whose tail_start lands inside a 4-byte emoji.
    const prefix_len = Incremental.max_cached_bytes + 4;
    var body = try gpa.alloc(u8, prefix_len + 10);
    defer gpa.free(body);
    for (body, 0..) |*b, idx| {
        b.* = if (idx % 64 == 63) '\n' else 'a';
    }
    // Place a 4-byte UTF-8 character straddling body.len - max_cached_bytes (= 14).
    const emoji = "🚀"; // 4 bytes: F0 9F 9A 80
    @memcpy(body[12..16], emoji);
    @memcpy(body[16..20], "\nhi!");

    const tail = Incremental.boundedTailSlice(body);
    try std.testing.expect((tail[0] & 0xC0) != 0x80);
    try std.testing.expect(std.unicode.utf8ValidateSlice(tail));

    var inc: Incremental = .{};
    defer inc.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rendered = try inc.rows(gpa, arena.allocator(), body, 80);
    try std.testing.expectEqual(@as(u16, @intCast(rendered.len)), inc.countRows(body, 80));
}
