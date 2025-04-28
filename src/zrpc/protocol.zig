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

pub const DeserializeError = error{
    InvalidFormat,
    IoError,
};

pub fn deserialize_message_header(reader: anytype) DeserializeError!MessageHeader {
    const request_id = reader.readInt(u64, WIRE_ENDIAN) catch |e| {
        log.debug("IO error reading request_id: {any}", .{e});
        return DeserializeError.IoError;
    };
    const procedure_id = reader.readInt(u32, WIRE_ENDIAN) catch |e| {
        log.debug("IO error reading procedure_id: {any}", .{e});
        return DeserializeError.IoError;
    };
    const status_byte = reader.readByte() catch |e| {
        log.debug("IO error reading status byte: {any}", .{e});
        return DeserializeError.IoError;
    };
    const padding1 = reader.readByte() catch |e| {
        log.debug("IO error reading padding1: {any}", .{e});
        return DeserializeError.IoError;
    };
    const padding2 = reader.readInt(u16, WIRE_ENDIAN) catch |e| {
        log.debug("IO error reading padding2: {any}", .{e});
        return DeserializeError.IoError;
    };

    const status = Status.from_u8(status_byte) catch |e| {
        std.debug.assert(e == error.InvalidFormat);
        return DeserializeError.InvalidFormat;
    };

    if (padding1 != 0 or padding2 != 0) {
        log.warn("Received non-zero value in header padding fields: p1={d}, p2={d}", .{ padding1, padding2 });
        return DeserializeError.InvalidFormat;
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

const testing = std.testing;
const std_err = std.debug.print;
const ArrayList = std.ArrayList;
const fixedBufferStream = std.io.fixedBufferStream;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;

test "serialize and deserialize MessageHeader" {
    var gpa = GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const original_header = MessageHeader{
        .request_id = 0x123456789ABCDEF0,
        .procedure_id = PROC_ID_ADD,
        .status = .ok,
        ._padding1 = 0, // Initialize padding
        ._padding2 = 0,
    };

    var buffer = ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try serialize_message_header(buffer.writer(), original_header);

    const reader = fixedBufferStream(buffer.items).reader();
    const deserialized_header = try deserialize_message_header(reader);

    try testing.expectEqual(original_header.request_id, deserialized_header.request_id);
    try testing.expectEqual(original_header.procedure_id, deserialized_header.procedure_id);
    try testing.expectEqual(original_header.status, deserialized_header.status);
    try testing.expectEqual(@as(u8, 0), deserialized_header._padding1);
    try testing.expectEqual(@as(u16, 0), deserialized_header._padding2);

    // Test EOF during read
    const short_buffer = buffer.items[0 .. buffer.items.len - 1];
    const short_reader = fixedBufferStream(short_buffer).reader();
    try testing.expectError(DeserializeError.IoError, deserialize_message_header(short_reader));

    // Test invalid status
    buffer.items[12] = 0xFF; // Corrupt the status byte (index 8+4=12)
    const corrupt_reader = fixedBufferStream(buffer.items).reader();
    try testing.expectError(DeserializeError.InvalidFormat, deserialize_message_header(corrupt_reader));

    // Test invalid reserved padding
    buffer.items[12] = @intFromEnum(Status.ok); // Fix status
    buffer.items[13] = 0x01; // Corrupt padding1 (index 13)
    const corrupt_padding_reader = fixedBufferStream(buffer.items).reader();
    try testing.expectError(DeserializeError.InvalidFormat, deserialize_message_header(corrupt_padding_reader));
}

test "serialize and deserialize AddRequest/AddResponse" {
    var gpa = GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Request
    const original_req = AddRequest{ .a = -100, .b = 999 };
    var req_buffer = ArrayList(u8).init(allocator);
    defer req_buffer.deinit();
    try serialize_add_request(req_buffer.writer(), original_req);
    try testing.expectEqual(@sizeOf(AddRequest), req_buffer.items.len);

    const req_reader = fixedBufferStream(req_buffer.items).reader();
    const deserialized_req = try deserialize_add_request(req_reader);
    try testing.expectEqual(original_req.a, deserialized_req.a);
    try testing.expectEqual(original_req.b, deserialized_req.b);

    // Response
    const original_res = AddResponse{ .result = 12345 };
    var res_buffer = ArrayList(u8).init(allocator); // Use different var name
    defer res_buffer.deinit();
    try serialize_add_response(res_buffer.writer(), original_res);
    try testing.expectEqual(@sizeOf(AddResponse), res_buffer.items.len);

    const res_reader = fixedBufferStream(res_buffer.items).reader();
    const deserialized_res = try deserialize_add_response(res_reader);
    try testing.expectEqual(original_res.result, deserialized_res.result);
}
