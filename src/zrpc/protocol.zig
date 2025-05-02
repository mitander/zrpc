const std = @import("std");
const log = std.log.scoped(.protocol);

pub const WIRE_ENDIAN = std.builtin.Endian.little;

pub const Status = enum(u8) {
    ok = 0,
    app_error = 1,

    pub fn from_u8(value: u8) !Status {
        return std.meta.intToEnum(Status, value) catch |err| {
            std.debug.assert(err == error.InvalidValue);
            log.warn("Received invalid status byte value: {d}", .{value});
            return error.InvalidFormat;
        };
    }
};

pub const MessageHeader = extern struct {
    request_id: u64,
    procedure_id: u32,
    status: Status,
    _padding1: u8 = 0,
    _padding2: u16 = 0,

    pub const SIZE = @sizeOf(MessageHeader);
    comptime {
        std.debug.assert(SIZE == 16);
    }
};

pub const PROC_ID_ADD: u32 = 1;

pub const AddRequest = extern struct {
    a: i32,
    b: i32,

    pub const SIZE = @sizeOf(AddRequest);
    comptime {
        std.debug.assert(SIZE == 8);
    }
};

pub const AddResponse = extern struct {
    result: i32,

    pub const SIZE = @sizeOf(AddResponse);
    comptime {
        std.debug.assert(SIZE == 4);
    }
};

pub fn serialize_message_header(writer: anytype, header: MessageHeader) !void {
    std.debug.assert(header._padding1 == 0);
    std.debug.assert(header._padding2 == 0);
    try writer.writeInt(u64, header.request_id, WIRE_ENDIAN);
    try writer.writeInt(u32, header.procedure_id, WIRE_ENDIAN);
    try writer.writeByte(@intFromEnum(header.status));
    try writer.writeByte(header._padding1);
    try writer.writeInt(u16, header._padding2, WIRE_ENDIAN);
}

pub fn serialize_add_request(writer: anytype, req: AddRequest) !void {
    try writer.writeInt(i32, req.a, WIRE_ENDIAN);
    try writer.writeInt(i32, req.b, WIRE_ENDIAN);
}

pub fn serialize_add_response(writer: anytype, res: AddResponse) !void {
    try writer.writeInt(i32, res.result, WIRE_ENDIAN);
}

pub fn deserialize_message_header(reader: anytype) !MessageHeader {
    const request_id = reader.readInt(u64, WIRE_ENDIAN) catch |e| {
        log.debug("IO error reading request_id: {any}", .{e});
        return error.IoError;
    };
    const procedure_id = reader.readInt(u32, WIRE_ENDIAN) catch |e| {
        log.debug("IO error reading procedure_id: {any}", .{e});
        return error.IoError;
    };
    const status_byte = reader.readByte() catch |e| {
        log.debug("IO error reading status byte: {any}", .{e});
        return error.IoError;
    };
    const padding1 = reader.readByte() catch |e| {
        log.debug("IO error reading padding1: {any}", .{e});
        return error.IoError;
    };
    const padding2 = reader.readInt(u16, WIRE_ENDIAN) catch |e| {
        log.debug("IO error reading padding2: {any}", .{e});
        return error.IoError;
    };

    const status = Status.from_u8(status_byte) catch |e| {
        std.debug.assert(e == error.InvalidFormat);
        return error.InvalidFormat;
    };

    if (padding1 != 0 or padding2 != 0) {
        log.warn("Received non-zero value in header padding fields: p1={d}, p2={d}", .{ padding1, padding2 });
        return error.InvalidFormat;
    }

    return MessageHeader{
        .request_id = request_id,
        .procedure_id = procedure_id,
        .status = status,
        ._padding1 = padding1,
        ._padding2 = padding2,
    };
}

pub fn deserialize_add_request(reader: anytype) !AddRequest {
    const a = try reader.readInt(i32, WIRE_ENDIAN);
    const b = try reader.readInt(i32, WIRE_ENDIAN);
    return AddRequest{ .a = a, .b = b };
}

pub fn deserialize_add_response(reader: anytype) !AddResponse {
    const result = try reader.readInt(i32, WIRE_ENDIAN);
    return AddResponse{ .result = result };
}
