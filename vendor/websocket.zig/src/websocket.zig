const std = @import("std");

pub const buffer = @import("buffer.zig");
pub const proto = @import("proto.zig");

pub const OpCode = proto.OpCode;
pub const Message = proto.Message;
pub const MessageType = Message.Type;
pub const MessageTextType = Message.TextType;

pub const Client = @import("client/client.zig").Client;

pub const Compression = struct {
    write_threshold: ?usize = null,
    retain_write_buffer: bool = true,
};

pub fn bufferProvider(io: std.Io, allocator: std.mem.Allocator, config: buffer.Config) !buffer.Provider {
    return buffer.Provider.init(io, allocator, config);
}

pub fn frameText(comptime msg: []const u8) [proto.calculateFrameLen(msg)]u8 {
    return proto.frame(.text, msg);
}

pub fn frameBin(comptime msg: []const u8) [proto.calculateFrameLen(msg)]u8 {
    return proto.frame(.binary, msg);
}
