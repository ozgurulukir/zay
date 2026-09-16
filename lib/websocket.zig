const vendor = @import("websocket_vendor");

pub const Client = vendor.Client;
pub const Message = vendor.Message;
pub const MessageType = vendor.MessageType;
pub const MessageTextType = vendor.MessageTextType;
pub const OpCode = vendor.OpCode;
pub const proto = vendor.proto;
pub const socket_write_timeout_supported = vendor.socket_write_timeout_supported;

test {
    @import("std").testing.refAllDecls(@This());
}

test "Windows websocket write timeout delegates to an external watchdog" {
    const is_windows = @import("builtin").os.tag == .windows;
    try @import("std").testing.expectEqual(!is_windows, socket_write_timeout_supported);
}
