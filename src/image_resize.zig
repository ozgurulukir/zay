//! Attach-time downscaling for oversized @-mentioned images (#119).
//!
//! Raw phone photos (3–6 MB JPEG) blow past wire-level provider limits —
//! Bedrock/Vertex cap one base64 image at 5 MB and Claude's whole request at
//! 32 MB — while token cost is unchanged (providers downscale server-side to
//! ~1568 px anyway). Decoding, resampling to the 1568 px long edge, and
//! re-encoding JPEG q85 turns a 5 MB photo into ~300–500 KB and removes
//! those failure modes before the request is ever built.
//!
//! Scope: JPEG and PNG inputs — the codecs zigimg decodes that dominate
//! mentions. GIF passes through untouched (an animated GIF would lose its
//! frames; zigimg 0.1.0 has no WebP codec). Every decode, resize, or encode
//! failure degrades to attaching the ORIGINAL bytes: downscaling must never
//! be the reason an image stops attaching.

const std = @import("std");
const zigimg = @import("zigimg");

const log = std.log.scoped(.image_resize);

/// Long edge kept after downscaling. 1568 matches Claude's server-side
/// vision tile size; OpenAI tiles at 512 px — no provider gains anything
/// from more pixels.
pub const target_long_edge: usize = 1568;
/// Raw bytes above which decoding is worth the effort. Smaller images
/// (typical screenshots) attach unchanged.
pub const downscale_threshold_bytes: usize = 1024 * 1024;

/// JPEG re-encode quality.
const jpeg_quality: u8 = 85;

pub const Downscale = union(enum) {
    /// Attach the original bytes — small, unsupported codec, or a decode
    /// failure (degrade gracefully, never drop).
    unchanged: void,
    /// Re-encoded JPEG; caller owns the bytes.
    jpeg: []u8,
};

pub fn downscaleIfNeeded(gpa: std.mem.Allocator, bytes: []const u8) !Downscale {
    return downscaleWith(gpa, bytes, downscale_threshold_bytes, target_long_edge);
}

/// Parameterized core so tests can drive tiny thresholds and targets with
/// small fixtures.
pub fn downscaleWith(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    threshold_bytes: usize,
    target_edge: usize,
) !Downscale {
    if (bytes.len <= threshold_bytes) return .unchanged;
    // Only the codecs this path can shrink; anything else attaches as-is.
    const is_png = std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n");
    const is_jpeg = std.mem.startsWith(u8, bytes, "\xff\xd8\xff");
    if (!is_png and !is_jpeg) return .unchanged;

    var img = zigimg.Image.fromMemory(gpa, bytes) catch return .unchanged;
    defer img.deinit(gpa);
    if (img.width == 0 or img.height == 0) return .unchanged;

    // One resampler for every source pixel format: convert to rgba32 first.
    img.convert(gpa, .rgba32) catch return .unchanged;

    const dst = targetDims(img.width, img.height, target_edge);
    var out = zigimg.Image.create(gpa, dst.w, dst.h, .rgb24) catch return .unchanged;
    defer out.deinit(gpa);
    compositeResize(img.pixels.rgba32, img.width, img.height, out.pixels.rgb24, dst.w, dst.h);

    const jpeg = encodeJpeg(gpa, out) catch return .unchanged;
    log.info("downscaled image mention: {d}B -> {d}B, {d}x{d} -> {d}x{d}", .{
        bytes.len, jpeg.len, img.width, img.height, dst.w, dst.h,
    });
    return .{ .jpeg = jpeg };
}

const Dims = struct { w: usize, h: usize };

/// Destination dimensions: shrink proportionally so the long edge is
/// `target_edge`; never upscale (an image already within the edge keeps its
/// exact dimensions — only the re-encode applies then).
fn targetDims(src_w: usize, src_h: usize, target_edge: usize) Dims {
    const long = @max(src_w, src_h);
    if (long <= target_edge) return .{ .w = src_w, .h = src_h };
    return .{
        .w = @max(1, src_w * target_edge / long),
        .h = @max(1, src_h * target_edge / long),
    };
}

/// Box-filter resample (average every source pixel mapping onto each
/// destination pixel) with straight-alpha composited over white — JPEG has
/// no alpha channel, and white preserves screenshot/diagram legibility.
/// Source dimensions are always >= destination dimensions here.
fn compositeResize(
    src: []const zigimg.color.Rgba32,
    src_w: usize,
    src_h: usize,
    dst: []zigimg.color.Rgb24,
    dst_w: usize,
    dst_h: usize,
) void {
    for (0..dst_h) |dy| {
        const sy0 = dy * src_h / dst_h;
        const sy1 = @max(sy0 + 1, (dy + 1) * src_h / dst_h);
        for (0..dst_w) |dx| {
            const sx0 = dx * src_w / dst_w;
            const sx1 = @max(sx0 + 1, (dx + 1) * src_w / dst_w);

            var acc_r: u64 = 0;
            var acc_g: u64 = 0;
            var acc_b: u64 = 0;
            var acc_a: u64 = 0;
            var count: u64 = 0;
            var sy = sy0;
            while (sy < sy1) : (sy += 1) {
                var sx = sx0;
                while (sx < sx1) : (sx += 1) {
                    const p = src[sy * src_w + sx];
                    acc_r += p.r;
                    acc_g += p.g;
                    acc_b += p.b;
                    acc_a += p.a;
                    count += 1;
                }
            }

            dst[dy * dst_w + dx] = .{
                .r = blendOverWhite(acc_r / count, acc_a / count),
                .g = blendOverWhite(acc_g / count, acc_a / count),
                .b = blendOverWhite(acc_b / count, acc_a / count),
            };
        }
    }
}

/// Straight-alpha color `c` (0–255) over a white background.
fn blendOverWhite(c: u64, a: u64) u8 {
    return @intCast((c * a + 255 * (255 - a)) / 255);
}

/// `writeToMemory` renders into the caller's buffer; the result is a slice
/// INTO that buffer, so it is duped out before the buffer is freed. The
/// buffer is sized from the destination pixels — after downscaling the long
/// edge is <= target, so `w*h*3 + slack` cannot overflow and comfortably
/// bounds a q85 JPEG of the same pixels.
fn encodeJpeg(gpa: std.mem.Allocator, image: zigimg.Image) ![]u8 {
    const buf_len = image.width * image.height * 3 + 4096;
    const buf = try gpa.alloc(u8, buf_len);
    defer gpa.free(buf);
    const written = try image.writeToMemory(gpa, buf, .{ .jpeg = .{
        .quality = jpeg_quality,
        .auto_convert = true,
    } });
    return gpa.dupe(u8, written);
}

// ─── Tests ────────────────────────────────────────────────────────────────

fn gradientPng(gpa: std.mem.Allocator, w: usize, h: usize) ![]u8 {
    var img = try zigimg.Image.create(gpa, w, h, .rgb24);
    defer img.deinit(gpa);
    const px = img.pixels.rgb24;
    for (0..h) |y| {
        for (0..w) |x| {
            px[y * w + x] = .{
                .r = @intCast((x * 255) / @max(1, w - 1)),
                .g = @intCast((y * 255) / @max(1, h - 1)),
                .b = 128,
            };
        }
    }
    const buf_len = w * h * 3 + 65536;
    const buf = try gpa.alloc(u8, buf_len);
    defer gpa.free(buf);
    const written = try img.writeToMemory(gpa, buf, .{ .png = .{} });
    return gpa.dupe(u8, written);
}

test "downscaleWith shrinks the long edge and re-encodes JPEG" {
    const gpa = std.testing.allocator;
    const png = try gradientPng(gpa, 64, 48);
    defer gpa.free(png);

    const result = try downscaleWith(gpa, png, 10, 32);
    const jpeg = switch (result) {
        .jpeg => |j| j,
        .unchanged => return error.TestUnexpectedResult,
    };
    defer gpa.free(jpeg);

    try std.testing.expect(std.mem.startsWith(u8, jpeg, "\xff\xd8\xff"));

    // Decoding the re-encode proves the pipeline produced a valid image at
    // the requested long edge (64 -> 32 keeps aspect: 48 -> 24).
    var decoded = try zigimg.Image.fromMemory(gpa, jpeg);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 32), decoded.width);
    try std.testing.expectEqual(@as(usize, 24), decoded.height);
}

test "downscaleWith re-encodes without resizing when already within the edge" {
    const gpa = std.testing.allocator;
    const png = try gradientPng(gpa, 48, 32);
    defer gpa.free(png);

    const result = try downscaleWith(gpa, png, 10, 1568);
    const jpeg = switch (result) {
        .jpeg => |j| j,
        .unchanged => return error.TestUnexpectedResult,
    };
    defer gpa.free(jpeg);

    var decoded = try zigimg.Image.fromMemory(gpa, jpeg);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 48), decoded.width);
    try std.testing.expectEqual(@as(usize, 32), decoded.height);
}

test "downscaleWith leaves small bytes and unsupported codecs untouched" {
    const gpa = std.testing.allocator;

    // Below the (tiny test) threshold: never decoded.
    const png = try gradientPng(gpa, 16, 16);
    defer gpa.free(png);
    try std.testing.expectEqual(Downscale.unchanged, try downscaleWith(gpa, png, png.len + 1, 32));

    // GIF (even oversized) passes through — resizing would drop animation.
    const oversized_gif = try gpa.alloc(u8, 64);
    defer gpa.free(oversized_gif);
    @memset(oversized_gif, 0);
    @memcpy(oversized_gif[0..6], "GIF89a");
    try std.testing.expectEqual(Downscale.unchanged, try downscaleWith(gpa, oversized_gif, 10, 32));

    // A >threshold buffer with PNG magic but undecodable contents degrades
    // to unchanged rather than failing the attach.
    const corrupt = try gpa.alloc(u8, 64);
    defer gpa.free(corrupt);
    @memset(corrupt, 0xAB);
    @memcpy(corrupt[0..8], "\x89PNG\r\n\x1a\n");
    try std.testing.expectEqual(Downscale.unchanged, try downscaleWith(gpa, corrupt, 10, 32));
}

test "targetDims keeps aspect and never upscales" {
    const wide = targetDims(4000, 3000, 1568);
    try std.testing.expectEqual(@as(usize, 1568), wide.w);
    try std.testing.expectEqual(@as(usize, 1176), wide.h);

    const tall = targetDims(3000, 4000, 1568);
    try std.testing.expectEqual(@as(usize, 1176), tall.w);
    try std.testing.expectEqual(@as(usize, 1568), tall.h);

    const within = targetDims(800, 600, 1568);
    try std.testing.expectEqual(@as(usize, 800), within.w);
    try std.testing.expectEqual(@as(usize, 600), within.h);

    // Degenerate extreme: a 1px sliver stays 1px on its short edge.
    const sliver = targetDims(4000, 1, 1568);
    try std.testing.expectEqual(@as(usize, 1), sliver.h);
}

test "compositeResize averages boxes and composites alpha over white" {
    // 2x2 opaque black/white checker -> 1x1 mid gray.
    const src = [_]zigimg.color.Rgba32{
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    var dst = [_]zigimg.color.Rgb24{.{ .r = 0, .g = 0, .b = 0 }};
    compositeResize(&src, 2, 2, &dst, 1, 1);
    try std.testing.expectEqual(@as(u8, 128), dst[0].r);
    try std.testing.expectEqual(@as(u8, 128), dst[0].g);
    try std.testing.expectEqual(@as(u8, 128), dst[0].b);

    // Fully transparent red over white -> white.
    const transparent = [_]zigimg.color.Rgba32{
        .{ .r = 255, .g = 0, .b = 0, .a = 0 },
    };
    var dst2 = [_]zigimg.color.Rgb24{.{ .r = 0, .g = 0, .b = 0 }};
    compositeResize(&transparent, 1, 1, &dst2, 1, 1);
    try std.testing.expectEqual(@as(u8, 255), dst2[0].r);
    try std.testing.expectEqual(@as(u8, 255), dst2[0].g);
    try std.testing.expectEqual(@as(u8, 255), dst2[0].b);

    // Identity dims: a straight copy.
    const identity_src = [_]zigimg.color.Rgba32{
        .{ .r = 7, .g = 8, .b = 9, .a = 255 },
    };
    var identity_dst = [_]zigimg.color.Rgb24{.{ .r = 0, .g = 0, .b = 0 }};
    compositeResize(&identity_src, 1, 1, &identity_dst, 1, 1);
    try std.testing.expectEqual(@as(u8, 7), identity_dst[0].r);
    try std.testing.expectEqual(@as(u8, 8), identity_dst[0].g);
    try std.testing.expectEqual(@as(u8, 9), identity_dst[0].b);
}
