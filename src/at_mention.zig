//! `@`-mention parsing and message assembly.
//!
//! Two concerns live here:
//!   1. Pure parsing of `@<path>` tokens — `activeQuery` drives the live
//!      autocomplete in the TUI, `collectMentions` finds every mention in a
//!      submitted prompt.
//!   2. Assembling the message actually sent to the model — text files are
//!      embedded inline as `<file src="…">…</file>`, images are attached as
//!      real `ai.ContentBlock.image` blocks so vision models receive them via
//!      the API's image field. Image mentions are magic-byte sniffed (the
//!      sniffed MIME wins over the extension) and every non-attached image
//!      gets a visible `<image … error="…" />` marker — the model is never
//!      told an image exists without it actually being attached.
//!
//! The thread still shows the raw text the user typed; only the outgoing
//! message is augmented here.
const std = @import("std");

const ai = @import("ai.zig");
const common = @import("tools/common.zig");
const sigil_query = @import("sigil_query.zig");
const skill_mod = @import("skill.zig");

const log = std.log.scoped(.at_mention);

const assert = std.debug.assert;

/// Max bytes embedded for ONE @-mentioned text file. Larger files are
/// inlined as a head+tail sandwich (first half + last half, joined by
/// `common.elideMiddle`) with a visible notice, so the file's conclusion
/// survives alongside its start.
pub const per_file_mention_max_bytes: usize = 64 * 1024;
/// Max aggregate bytes of inlined mention text per user message. Once
/// exhausted, further mentions become error markers instead of content.
pub const turn_mention_aggregate_max_bytes: usize = 256 * 1024;
/// Max image blocks attached per user message. Vision cost is per-image; the
/// cap bounds the request regardless of file sizes.
pub const max_images_per_message: u32 = 4;
/// Max bytes read for an image mention before we skip attaching it.
const max_image_bytes: usize = 5 * 1024 * 1024;

/// One `@`-mention token ending at the cursor (shared sigil scanner shape).
pub const Active = sigil_query.Token;

/// The active `@`-mention token ending at the cursor, given the text *before*
/// the cursor. The token starts right after an `@` that sits at the start of
/// the text or just after whitespace, and runs to the cursor with no
/// intervening whitespace. Returns null when there is no such token (e.g. the
/// cursor is mid-word, after a space, or the `@` is embedded like an email).
pub fn activeQuery(before_cursor: []const u8) ?Active {
    return sigil_query.activeQuery(before_cursor, '@');
}

/// Every distinct `@<path>` mention in `prompt`, in first-seen order. The
/// returned slices borrow from `prompt`; only the outer array is owned.
pub fn collectMentions(gpa: std.mem.Allocator, prompt: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);

    var i: usize = 0;
    while (i < prompt.len) {
        const at_boundary = i == 0 or isBoundary(prompt[i - 1]);
        if (prompt[i] == '@' and at_boundary) {
            var j = i + 1;
            while (j < prompt.len and !isBoundary(prompt[j])) j += 1;
            const path = trimTrailingPunctuation(prompt[i + 1 .. j]);
            if (path.len > 0) {
                const gop = try seen.getOrPut(gpa, path);
                if (!gop.found_existing) {
                    try list.append(gpa, path);
                }
            }
            i = j;
        } else {
            i += 1;
        }
    }
    return list.toOwnedSlice(gpa);
}

/// `image/png`, `image/jpeg`, `image/gif`, `image/webp` for recognised image
/// extensions, else null. This is the EXTENSION guess only — the magic-byte
/// sniff (`sniffImageKind`) wins at attach time.
pub fn mimeForPath(path: []const u8) ?[]const u8 {
    if (endsWithIgnoreCase(path, ".png")) return "image/png";
    if (endsWithIgnoreCase(path, ".jpg") or endsWithIgnoreCase(path, ".jpeg")) return "image/jpeg";
    if (endsWithIgnoreCase(path, ".gif")) return "image/gif";
    if (endsWithIgnoreCase(path, ".webp")) return "image/webp";
    return null;
}

/// Image containers zay recognises but never attaches — no major provider
/// accepts them (Claude/OpenAI take JPEG/PNG/GIF/WebP only). Mentioned files
/// route down the image path so they get a visible error marker instead of
/// being embedded as binary text.
const unsupported_image_extensions = [_][]const u8{ ".heic", ".heif", ".bmp", ".tif", ".tiff", ".avif" };

fn isUnsupportedImagePath(path: []const u8) bool {
    for (unsupported_image_extensions) |ext| {
        if (endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

pub fn isImagePath(path: []const u8) bool {
    return mimeForPath(path) != null or isUnsupportedImagePath(path);
}

pub const ImageKind = enum { png, jpeg, gif, webp, heic, unknown };

/// Magic-byte sniff of an image container — the first 12 bytes identify every
/// supported family. `.heic` covers the whole ISO-BMFF image family
/// (`heic`/`heix`/`hevc`/…/`mif1`/`msf1` brands); none of them are attachable.
pub fn sniffImageKind(bytes: []const u8) ImageKind {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .png;
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return .jpeg;
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return .gif;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and
        std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[4..8], "ftyp")) {
        const brands = [_][]const u8{ "heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1" };
        for (brands) |brand| {
            if (std.mem.eql(u8, bytes[8..12], brand)) return .heic;
        }
    }
    return .unknown;
}

fn kindMime(kind: ImageKind) ?[]const u8 {
    return switch (kind) {
        .png => "image/png",
        .jpeg => "image/jpeg",
        .gif => "image/gif",
        .webp => "image/webp",
        .heic, .unknown => null,
    };
}

/// `prompt` followed by an embedded `<file>` block per text mention and an
/// `<image>` marker per image mention. This is the text half of
/// `buildUserMessage`: the outgoing message's first content block. Caller owns
/// the result. When there are no mentions this is just a copy of `prompt`.
///
/// Image mentions are read and magic-byte-sniffed HERE so the marker carries
/// the real outcome: sniff-confirmed images print `<image src="…" />`, and
/// everything else (missing, oversized, corrupt, unsupported container)
/// prints `<image src="…" error="…" />` — the model is never told an image
/// exists without it actually being attached.
pub fn buildAugmentedText(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    prompt: []const u8,
) ![]u8 {
    return assemble(gpa, io, cwd, prompt, null);
}

fn writeImageMarker(writer: *std.Io.Writer, path: []const u8, err_reason: ?[]const u8) !void {
    try writer.print("\n\n<image src=\"", .{});
    try skill_mod.writeXmlEscaped(writer, path);
    if (err_reason) |reason| {
        try writer.print("\" error=\"{s}\" />", .{reason});
    } else {
        try writer.print("\" />", .{});
    }
}

/// Read + magic-byte-sniff one image mention and either attach it (when
/// `blocks_out` is non-null) with the SNIFFED mime — extension mismatches log
/// a warning; the sniff wins — or emit a visible `<image … error="…" />`
/// marker. Never attaches silently-truncated bytes.
fn attachOrMarkImage(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    path: []const u8,
    blocks_out: ?*std.ArrayList(ai.ContentBlock),
    writer: *std.Io.Writer,
) !void {
    const absolute = common.joinPath(gpa, cwd, path) catch {
        try writeImageMarker(writer, path, "out of memory");
        return;
    };
    defer gpa.free(absolute);

    var file = std.Io.Dir.openFileAbsolute(io, absolute, .{}) catch |err| {
        const reason = if (err == error.FileNotFound) "not found" else @errorName(err);
        try writeImageMarker(writer, path, reason);
        return;
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| {
        try writeImageMarker(writer, path, @errorName(err));
        return;
    };
    const size: usize = @intCast(stat.size);
    if (size > max_image_bytes) {
        var reason_buf: [64]u8 = undefined;
        const mb = size / (1024 * 1024) + @intFromBool(size % (1024 * 1024) != 0);
        const reason = std.fmt.bufPrint(
            &reason_buf,
            "too large ({d} MB > {d} MB max)",
            .{ mb, max_image_bytes / (1024 * 1024) },
        ) catch "too large";
        try writeImageMarker(writer, path, reason);
        return;
    }

    const bytes = common.readFileBytes(gpa, io, absolute, max_image_bytes) catch |err| {
        // A file grown past the cap between stat and read lands here.
        try writeImageMarker(writer, path, if (err == error.StreamTooLong) "too large" else @errorName(err));
        return;
    };
    defer gpa.free(bytes);

    const kind = sniffImageKind(bytes);
    switch (kind) {
        .unknown => {
            const reason: []const u8 = if (mimeForPath(path) != null)
                // Attachable extension but no known image magic → corrupt or
                // exotic encoding; either way the provider would reject it.
                "unreadable or unsupported image format"
            else
                "unsupported format (convert to JPEG or PNG)";
            try writeImageMarker(writer, path, reason);
        },
        .heic => try writeImageMarker(writer, path, "unsupported format (HEIC/HEIF; convert to JPEG or PNG)"),
        .png, .jpeg, .gif, .webp => {
            const sniffed = kindMime(kind).?;
            if (mimeForPath(path)) |ext_mime| {
                if (!std.mem.eql(u8, ext_mime, sniffed)) {
                    log.warn("image {s}: extension says {s}, magic bytes say {s}; sending the sniffed format", .{ path, ext_mime, sniffed });
                }
            }
            // Else: an unsupported extension (.bmp, …) holding an attachable
            // payload — rescued by the sniff, nothing to report.
            try writeImageMarker(writer, path, null);
            if (blocks_out) |blocks| {
                const encoded = try encodeBase64(gpa, bytes);
                errdefer gpa.free(encoded);
                const mime_owned = try gpa.dupe(u8, sniffed);
                errdefer gpa.free(mime_owned);
                try blocks.append(gpa, .{ .image = .{ .mime_type = mime_owned, .data_base64 = encoded } });
            }
        },
    }
}

/// Single pass over the mentions: text mentions become `<file>` embeds,
/// image mentions become markers + (when `blocks_out` is non-null) attached
/// image blocks. Shared by both public entry points so the marker text and
/// the attached blocks can never drift apart.
fn assemble(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    prompt: []const u8,
    blocks_out: ?*std.ArrayList(ai.ContentBlock),
) ![]u8 {
    const mentions = try collectMentions(gpa, prompt);
    defer gpa.free(mentions);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll(prompt);

    var remaining: usize = turn_mention_aggregate_max_bytes;
    var image_count: u32 = 0;
    for (mentions) |path| {
        if (!isImagePath(path)) {
            try appendFileTag(gpa, io, cwd, &out.writer, path, &remaining);
            continue;
        }
        image_count += 1;
        if (image_count > max_images_per_message) {
            try writeImageMarker(&out.writer, path, "too many images");
            continue;
        }
        try attachOrMarkImage(gpa, io, cwd, path, blocks_out, &out.writer);
    }
    return out.toOwnedSlice();
}

/// The content blocks for the outgoing user message: one text block (the
/// augmented text above) followed by one image block per sniff-confirmed
/// image mention. Caller owns the returned slice and every block in it.
pub fn buildUserMessage(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    prompt: []const u8,
) ![]ai.ContentBlock {
    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    errdefer {
        for (blocks.items) |*block| block.deinit(gpa);
        blocks.deinit(gpa);
    }
    const text = try assemble(gpa, io, cwd, prompt, &blocks);
    {
        errdefer gpa.free(text);
        try blocks.insert(gpa, 0, .{ .text = .{ .text = text } });
    }
    return blocks.toOwnedSlice(gpa);
}

fn appendFileTag(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    writer: *std.Io.Writer,
    path: []const u8,
    remaining: *usize,
) !void {
    if (remaining.* == 0) {
        try writer.print("\n\n<file src=\"", .{});
        try skill_mod.writeXmlEscaped(writer, path);
        try writer.print("\" error=\"turn mention budget exhausted\"></file>", .{});
        return;
    }
    const absolute = common.joinPath(gpa, cwd, path) catch {
        try writer.print("\n\n<file src=\"", .{});
        try skill_mod.writeXmlEscaped(writer, path);
        try writer.print("\" error=\"out of memory\"></file>", .{});
        return;
    };
    defer gpa.free(absolute);

    var file = std.Io.Dir.openFileAbsolute(io, absolute, .{}) catch |err| {
        const reason = if (err == error.FileNotFound) "not found" else @errorName(err);
        try writer.print("\n\n<file src=\"", .{});
        try skill_mod.writeXmlEscaped(writer, path);
        try writer.print("\" error=\"{s}\"></file>", .{reason});
        return;
    };
    defer file.close(io);

    const cap: usize = per_file_mention_max_bytes;
    const stat = file.stat(io) catch |err| {
        try writer.print("\n\n<file src=\"", .{});
        try skill_mod.writeXmlEscaped(writer, path);
        try writer.print("\" error=\"{s}\"></file>", .{@errorName(err)});
        return;
    };
    const size: usize = @intCast(stat.size);

    // Read the file's REAL head+tail, not just its head. A plan's load-bearing
    // steps/decisions often live at the tail; reading only the first `cap`
    // bytes (as before) silently dropped them even though the sandwich then
    // preserved the tail of that truncated window. For oversized files we read
    // the first half and the last half of the budget and join them with an
    // elision marker (shared `common.elideMiddle` SSOT).
    try writer.print("\n\n<file src=\"", .{});
    try skill_mod.writeXmlEscaped(writer, path);
    if (size <= cap) {
        const buf = try gpa.alloc(u8, size);
        defer gpa.free(buf);
        var reader = file.reader(io, &.{});
        // readSliceShort returns the actual count (never error.EndOfStream),
        // so a file truncated between stat and read yields its partial content
        // instead of an error marker (TOCTOU) — matching assembly.zig.
        const n = reader.interface.readSliceShort(buf) catch |err| {
            try writer.print("\" error=\"{s}\"></file>", .{@errorName(err)});
            return;
        };
        try writer.print("\">\n", .{});
        try skill_mod.writeXmlEscaped(writer, buf[0..n]);
        try writer.print("\n</file>", .{});
        remaining.* -= @min(n, remaining.*);
        return;
    }

    const half = cap / 2;
    const head_len = half;
    const tail_len = cap - half;
    const head = try gpa.alloc(u8, head_len);
    defer gpa.free(head);
    const tail = try gpa.alloc(u8, tail_len);
    defer gpa.free(tail);
    // readPositionalAll returns a short count on TOCTOU shrinkage (same as
    // readSliceShort), not an error — head_n/tail_n carry the actual bytes
    // read, so the slices stay correctly bounded even if the file shrank
    // between stat and read. The elision marker's total_size may be stale
    // in that edge case, but the content slices are safe.
    const head_n = file.readPositionalAll(io, head, 0) catch |err| {
        try writer.print("\" error=\"{s}\"></file>", .{@errorName(err)});
        return;
    };
    const tail_offset: u64 = @intCast(size - tail_len);
    const tail_n = file.readPositionalAll(io, tail, tail_offset) catch |err| {
        try writer.print("\" error=\"{s}\"></file>", .{@errorName(err)});
        return;
    };
    const pruned = try common.elideMiddle(gpa, head[0..head_n], tail[0..tail_n], size);
    defer gpa.free(pruned);
    try writer.print("\">\n", .{});
    try skill_mod.writeXmlEscaped(writer, pruned);
    try writer.print("\n[file truncated: {d} bytes — re-read via shell if you need the rest]\n</file>", .{size});
    remaining.* -= @min(cap, remaining.*);
}

fn encodeBase64(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const buffer = try gpa.alloc(u8, encoder.calcSize(bytes.len));
    errdefer gpa.free(buffer);
    _ = encoder.encode(buffer, bytes);
    return buffer;
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (suffix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

// Shared sigil-token boundary/punctuation rules (see sigil_query.zig) so the
// autocomplete scan and collectMentions can never drift apart.
const isBoundary = sigil_query.isBoundary;
const trimTrailingPunctuation = sigil_query.trimTrailingPunctuation;
