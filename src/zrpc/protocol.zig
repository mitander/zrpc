const std = @import("std");
const mem = std.mem;
const io = std.io;
const testing = std.testing;

const snapshot = @import("testing/snapshot.zig");
const snap = snapshot.Snap.snap;

pub const WIRE_ENDIAN = std.builtin.Endian.little;
pub const PROC_ID_ADD = 1;
pub const MAX_MESSAGE_SIZE = 1024 * 1024; // 1 MiB Example

pub const Status = enum(u8) {
    ok = 0,
    app_error,
};

pub const MessageHeader = extern struct {
    request_id: u64,
    procedure_id: u32,
    status: Status,
    _padding: [3]u8 = .{ 0, 0, 0 },

    comptime {
        std.debug.assert(@sizeOf(MessageHeader) == 16);
    }
};

pub const ProtocolError = error{
    IoError,
    UnknownProcedure,
    MessageBodyTooShort,
    InvalidPayload,
};

pub const ParsedMessage = struct {
    header: MessageHeader,
    payload: []const u8,
};

pub fn parse_message_body(body: []const u8) ProtocolError!ParsedMessage {
    const header_size = @sizeOf(MessageHeader);
    if (body.len < header_size) {
        return ProtocolError.MessageBodyTooShort;
    }
    const header = mem.bytesAsValue(MessageHeader, body[0..header_size]).*;
    const payload = body[header_size..];
    return ParsedMessage{ .header = header, .payload = payload };
}

pub const AddRequest = struct {
    a: i32,
    b: i32,
};

pub fn serialize_add_request(
    req: AddRequest,
    allocator: mem.Allocator,
    writer: anytype,
) ProtocolError!void {
    _ = allocator;
    writer.writeInt(i32, req.a, WIRE_ENDIAN) catch |err| {
        std.log.warn("Failed to write AddRequest.a: {any}", .{err});
        return ProtocolError.IoError;
    };
    writer.writeInt(i32, req.b, WIRE_ENDIAN) catch |err| {
        std.log.warn("Failed to write AddRequest.b: {any}", .{err});
        return ProtocolError.IoError;
    };
}

pub fn deserialize_add_request(
    payload: []const u8,
    allocator: mem.Allocator,
) ProtocolError!AddRequest {
    _ = allocator;
    const expected_size = @sizeOf(AddRequest);
    if (payload.len < expected_size) {
        std.log.warn("Payload too short for AddRequest: got {d}, want {d}", .{ payload.len, expected_size });
        return ProtocolError.InvalidPayload;
    }
    var stream = io.fixedBufferStream(payload);
    var reader = stream.reader();

    const a = reader.readInt(i32, WIRE_ENDIAN) catch |err| {
        std.log.warn("Failed to read AddRequest.a: {any}", .{err});
        return ProtocolError.IoError;
    };
    const b = reader.readInt(i32, WIRE_ENDIAN) catch |err| {
        std.log.warn("Failed to read AddRequest.b: {any}", .{err});
        return ProtocolError.IoError;
    };

    return AddRequest{ .a = a, .b = b };
}

pub const AddResponse = struct {
    result: i32,
};

pub fn serialize_add_response(
    res: AddResponse,
    allocator: mem.Allocator,
    writer: anytype,
) ProtocolError!void {
    _ = allocator;
    writer.writeInt(i32, res.result, WIRE_ENDIAN) catch |err| {
        std.log.warn("Failed to write AddResponse.result: {any}", .{err});
        return ProtocolError.IoError;
    };
}

pub fn deserialize_add_response(
    reader: anytype,
) ProtocolError!AddResponse {
    const result = reader.readInt(i32, WIRE_ENDIAN) catch |err| {
        std.log.warn("Failed to read AddResponse.result: {any}", .{err});
        return ProtocolError.InvalidPayload;
    };

    return AddResponse{ .result = result };
}

test "protocol: MessageHeader size" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(MessageHeader));
}

test "protocol: endianness conversion" {
    const value: u32 = 0x12345678;
    const expected_little_endian: u32 = 0x12345678; // Value stays the same for little-endian
    const expected_big_endian: u32 = 0x78563412; // Byte-swapped value for big-endian

    const wire_endian = if (std.builtin.Endian.little == WIRE_ENDIAN)
        value
    else
        @byteSwap(value);
    try testing.expectEqual(expected_little_endian, wire_endian);

    const opposite_endian = if (std.builtin.Endian.little == WIRE_ENDIAN)
        @byteSwap(value)
    else
        value;
    try testing.expectEqual(expected_big_endian, opposite_endian);
}

test "protocol: parse_message_body basic" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const header = MessageHeader{
        .request_id = 12345,
        .procedure_id = PROC_ID_ADD,
        .status = .ok,
    };
    const payload_bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    try buffer.writer().writeAll(mem.asBytes(&header));
    try buffer.writer().writeAll(&payload_bytes);

    const parsed = try parse_message_body(buffer.items);

    try testing.expectEqual(header.request_id, parsed.header.request_id);
    try testing.expectEqual(header.procedure_id, parsed.header.procedure_id);
    try testing.expectEqual(header.status, parsed.header.status);

    try testing.expectEqualSlices(u8, &payload_bytes, parsed.payload);
}

test "protocol: parse_message_body too short" {
    const short_body = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try testing.expectEqual(true, short_body.len < @sizeOf(MessageHeader));

    const result = parse_message_body(&short_body);
    try testing.expectError(ProtocolError.MessageBodyTooShort, result);
}

test "protocol: serialize AddRequest" {
    const req = AddRequest{ .a = 100, .b = -50 };
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    try serialize_add_request(req, testing.allocator, buf.writer());

    const expected_bytes = [_]u8{
        0x64, 0x00, 0x00, 0x00, // a = 100 (little endian)
        0xCE, 0xFF, 0xFF, 0xFF, // b = -50 (little endian)
    };

    try testing.expectEqualSlices(u8, &expected_bytes, buf.items);
    try snap(@src(), &expected_bytes).diff(buf.items);
}

test "protocol: deserialize AddRequest basic" {
    const payload_bytes = [_]u8{
        0x64, 0x00, 0x00, 0x00, // a = 100
        0xCE, 0xFF, 0xFF, 0xFF, // b = -50
    };

    const req = try deserialize_add_request(&payload_bytes, testing.allocator);

    try testing.expectEqual(@as(i32, 100), req.a);
    try testing.expectEqual(@as(i32, -50), req.b);
}

test "protocol: deserialize AddRequest too short" {
    const short_payload = [_]u8{
        0x64,
        0x00,
        0x00,
    }; // Missing bytes

    var stream = io.fixedBufferStream(&short_payload);
    const test_reader = stream.reader();
    const result = deserialize_add_response(test_reader);
    try testing.expectError(ProtocolError.InvalidPayload, result);
}

test "protocol: deserialize AddRequest extra data" {
    const payload_bytes = [_]u8{
        0x64, 0x00, 0x00, 0x00, // a = 100
        0xCE, 0xFF, 0xFF, 0xFF, // b = -50
        0xAA, 0xBB, // Extra data
    };

    const req = try deserialize_add_request(&payload_bytes, testing.allocator);
    try testing.expectEqual(@as(i32, 100), req.a);
    try testing.expectEqual(@as(i32, -50), req.b);
}

test "protocol: serialize AddResponse" {
    const res = AddResponse{ .result = -123 };
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    try serialize_add_response(res, testing.allocator, buf.writer());

    // Expected bytes for -123 (0x85FFFFFF in 2's complement LE)
    const expected_bytes = [_]u8{ 0x85, 0xFF, 0xFF, 0xFF };

    try testing.expectEqualSlices(u8, &expected_bytes, buf.items);
    try snap(@src(), &expected_bytes).diff(buf.items);
}

test "protocol: deserialize AddResponse basic" {
    const payload_bytes = [_]u8{ 0x85, 0xFF, 0xFF, 0xFF }; // -123 LE
    var stream = io.fixedBufferStream(&payload_bytes);
    const test_reader = stream.reader();

    const result = try deserialize_add_response(test_reader);
    try testing.expectEqual(@as(i32, -123), result.result);
}

test "protocol: deserialize AddResponse too short" {
    const short_payload = [_]u8{ 0x85, 0xFF }; // Missing bytes
    var stream = io.fixedBufferStream(&short_payload);
    const test_reader = stream.reader();

    const result = deserialize_add_response(test_reader);
    try testing.expectError(ProtocolError.InvalidPayload, result);
}
