const std = @import("std");

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

pub const FrameHeader = struct {
    fin: bool,
    opcode: Opcode,
    masked: bool,
    payload_len: u64,
    header_len: u8,
    mask: [4]u8 = .{ 0, 0, 0, 0 },
};

pub const client_close_frame_bytes: u32 = 6;

pub fn makeKey(io: std.Io) [24]u8 {
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    var out: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &nonce);
    return out;
}

pub fn acceptValue(out: *[28]u8, key: []const u8) void {
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(guid);
    sha1.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

pub fn encodeClientTextFrame(gpa: std.mem.Allocator, io: std.Io, payload: []const u8) ![]u8 {
    var mask: [4]u8 = undefined;
    io.random(&mask);
    return try encodeClientFrameWithMask(gpa, .text, payload, mask);
}

pub fn encodeClientCloseFrame(out: *[client_close_frame_bytes]u8, io: std.Io) void {
    var mask: [4]u8 = undefined;
    io.random(&mask);
    encodeClientCloseFrameWithMask(out, mask);
}

pub fn encodeClientCloseFrameWithMask(out: *[client_close_frame_bytes]u8, mask: [4]u8) void {
    out[0] = 0x80 | @as(u8, @intFromEnum(Opcode.close));
    out[1] = 0x80;
    @memcpy(out[2..6], &mask);
}

pub fn encodeClientFrameWithMask(gpa: std.mem.Allocator, opcode: Opcode, payload: []const u8, mask: [4]u8) ![]u8 {
    const extra: usize = if (payload.len < 126) 0 else if (payload.len <= 0xffff) 2 else 8;
    const header_len: usize = 2 + extra + 4;
    const frame = try gpa.alloc(u8, header_len + payload.len);
    frame[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    if (payload.len < 126) {
        frame[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= 0xffff) {
        frame[1] = 0x80 | 126;
        std.mem.writeInt(u16, frame[2..4], @intCast(payload.len), .big);
    } else {
        frame[1] = 0x80 | 127;
        std.mem.writeInt(u64, frame[2..10], @intCast(payload.len), .big);
    }
    @memcpy(frame[2 + extra .. header_len], &mask);
    for (payload, 0..) |byte, index| frame[header_len + index] = byte ^ mask[index % 4];
    return frame;
}

pub fn parseFrameHeader(bytes: []const u8) !FrameHeader {
    if (bytes.len < 2) return error.IncompleteFrameHeader;
    const opcode: Opcode = @enumFromInt(bytes[0] & 0x0f);
    const masked = (bytes[1] & 0x80) != 0;
    const len_code = bytes[1] & 0x7f;
    var payload_len: u64 = len_code;
    var offset: u8 = 2;
    if (len_code == 126) {
        if (bytes.len < 4) return error.IncompleteFrameHeader;
        payload_len = std.mem.readInt(u16, bytes[2..4], .big);
        offset = 4;
    } else if (len_code == 127) {
        if (bytes.len < 10) return error.IncompleteFrameHeader;
        payload_len = std.mem.readInt(u64, bytes[2..10], .big);
        if ((payload_len & (@as(u64, 1) << 63)) != 0) return error.InvalidFrameLength;
        offset = 10;
    }
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        if (bytes.len < offset + 4) return error.IncompleteFrameHeader;
        @memcpy(&mask, bytes[offset .. offset + 4]);
        offset += 4;
    }
    return .{ .fin = (bytes[0] & 0x80) != 0, .opcode = opcode, .masked = masked, .payload_len = payload_len, .header_len = offset, .mask = mask };
}

pub fn unmask(payload: []u8, mask: [4]u8) void {
    for (payload, 0..) |*byte, index| byte.* ^= mask[index % 4];
}

test "RFC 6455 accept value example" {
    var out: [28]u8 = undefined;
    acceptValue(&out, "dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}

test "client frames are masked per RFC 6455" {
    const gpa = std.testing.allocator;
    const frame = try encodeClientFrameWithMask(gpa, .text, "Hi", .{ 1, 2, 3, 4 });
    defer gpa.free(frame);
    try std.testing.expectEqual(@as(u8, 0x81), frame[0]);
    try std.testing.expectEqual(@as(u8, 0x82), frame[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, frame[2..6]);
    try std.testing.expectEqual(@as(u8, 'H' ^ 1), frame[6]);
    try std.testing.expectEqual(@as(u8, 'i' ^ 2), frame[7]);
}

test "client close frame is masked per RFC 6455" {
    var frame: [client_close_frame_bytes]u8 = undefined;
    encodeClientCloseFrameWithMask(&frame, .{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(u8, 0x88), frame[0]);
    try std.testing.expectEqual(@as(u8, 0x80), frame[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, frame[2..6]);
}

test "parse extended server frame header" {
    const bytes = [_]u8{ 0x81, 126, 0x01, 0x00 };
    const header = try parseFrameHeader(&bytes);
    try std.testing.expect(header.fin);
    try std.testing.expectEqual(Opcode.text, header.opcode);
    try std.testing.expect(!header.masked);
    try std.testing.expectEqual(@as(u64, 256), header.payload_len);
    try std.testing.expectEqual(@as(u8, 4), header.header_len);
}
