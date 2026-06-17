const vendor = @import("websocket_vendor");

pub const Client = vendor.Client;
pub const Message = vendor.Message;
pub const MessageType = vendor.MessageType;
pub const MessageTextType = vendor.MessageTextType;
pub const OpCode = vendor.OpCode;
pub const proto = vendor.proto;

test {
    @import("std").testing.refAllDecls(@This());
}
