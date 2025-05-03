pub const errors = @import("zrpc/errors.zig");
pub const framing = @import("zrpc/framing.zig");
pub const protocol = @import("zrpc/protocol.zig");
pub const stdnet = @import("zrpc/transport/stdnet.zig");
pub const simtransport = @import("zrpc/transport/simtransport.zig");

pub const ClientType = @import("zrpc/client.zig").ClientType;
pub const ServerType = @import("zrpc/server.zig").ServerType;
pub const Handler = @import("zrpc/server.zig").Handler;

const std = @import("std");
pub const WIRE_ENDIAN = std.builtin.Endian.little;
pub const PROC_ID_ADD: u32 = 1;
