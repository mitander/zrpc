//! Defines the binary wire format structures and manual serialization/deserialization
//! logic for the MVP of the Zig RPC framework.
const std = @import("std");
const log = std.log.scoped(.protocol);

const WIRE_ENDIAN = std.builtin.Endian.little;

/// Represents the status of an RPC message.
pub const Status = enum(u8) {
    ok = 0,
    app_error = 1,

    /// Attempts to convert a raw u8 read from the wire into a Status enum tag.
    /// Returns `error.InvalidValue` if the value does not correspond to a defined tag.
    pub fn from_u8(value: u8) !Status {
        return @enumFromInt(value);
    }
};

/// Fixed-size header prepended to every RPC message. Expected Size: 16 bytes.
pub const MessageHeader = struct {
    request_id: u64,
    procedure_id: u32,
    status: Status,
    /// Reserved padding, MUST be zero!
    _reserved: u24 = 0,
};

/// Procedure ID for the 'add' function in the MVP.
pub const PROC_ID_ADD: u32 = 1;

/// Payload for an 'add' request. Size: 8 bytes.
pub const AddRequest = struct {
    a: i32,
    b: i32,

    pub const SIZE = @sizeOf(AddRequest);
    comptime {
        std.debug.assert(SIZE == 8);
    }
};

/// Payload for an 'add' response. Size: 4 bytes.
pub const AddResponse = struct {
    result: i32,

    pub const SIZE = @sizeOf(AddResponse);
    comptime {
        std.debug.assert(SIZE == 4);
    }
};

/// Serializes a `MessageHeader` to the `writer`.
pub fn serialize_message_header(writer: anytype, header: MessageHeader) !void {
    std.debug.assert(header._reserved == 0);

    try writer.writeInt(u64, header.request_id, WIRE_ENDIAN);
    try writer.writeInt(u32, header.procedure_id, WIRE_ENDIAN);
    try writer.writeByte(@intFromEnum(header.status));
    try writer.writeInt(u24, header._reserved, WIRE_ENDIAN);
}

/// Serializes an `AddRequest` to the `writer`.
pub fn serialize_add_request(writer: anytype, req: AddRequest) !void {
    try writer.writeInt(i32, req.a, WIRE_ENDIAN);
    try writer.writeInt(i32, req.b, WIRE_ENDIAN);
}

/// Serializes an `AddResponse` to the `writer`.
pub fn serialize_add_response(writer: anytype, res: AddResponse) !void {
    try writer.writeInt(i32, res.result, WIRE_ENDIAN);
}

/// Error set for header deserialization failures.
pub const DeserializeHeaderError = error{
    IoError,
    InvalidStatusValue,
};

/// Deserializes a `MessageHeader` from the `reader`.
pub fn deserialize_message_header(reader: anytype) DeserializeHeaderError!MessageHeader {
    const request_id = reader.readInt(u64, WIRE_ENDIAN) catch |e| {
        log.debug("IO error reading request_id: {any}", .{e});
        return DeserializeHeaderError.IoError;
    };
    const procedure_id = reader.readInt(u32, WIRE_ENDIAN) catch |e| {
        log.debug("IO error reading procedure_id: {any}", .{e});
        return DeserializeHeaderError.IoError;
    };
    const status_byte = reader.readByte() catch |e| {
        log.debug("IO error reading status byte: {any}", .{e});
        return DeserializeHeaderError.IoError;
    };
    const reserved = reader.readInt(u24, WIRE_ENDIAN) catch |e| {
        log.debug("IO error reading reserved bytes: {any}", .{e});
        return DeserializeHeaderError.IoError;
    };

    const status = Status.from_u8(status_byte) catch |err| {
        std.debug.assert(err == error.InvalidValue);
        log.warn("Received invalid status byte value: {d}", .{status_byte});
        return DeserializeHeaderError.InvalidStatusValue;
    };
    std.debug.assert(reserved == 0);

    return MessageHeader{
        .request_id = request_id,
        .procedure_id = procedure_id,
        .status = status,
        ._reserved = reserved,
    };
}

/// Deserializes an `AddRequest` from the `reader`.
pub fn deserialize_add_request(reader: anytype) !AddRequest {
    const a = try reader.readInt(i32, WIRE_ENDIAN);
    const b = try reader.readInt(i32, WIRE_ENDIAN);
    return AddRequest{ .a = a, .b = b };
}

/// Deserializes an `AddResponse` from the `reader`.
pub fn deserialize_add_response(reader: anytype) !AddResponse {
    const result = try reader.readInt(i32, WIRE_ENDIAN);
    return AddResponse{ .result = result };
}

/// Defines potential errors during message framing operations.
pub const FramingError = error{
    IoError,
    AllocationFailed,
    MessageTooLarge,
};

/// Maximum allowed message size (payload + header) for the MVP.
const MAX_MESSAGE_SIZE: u32 = 1 * 1024 * 1024;

/// Serializes header and optional payload into a temporary buffer, prepends the
/// total length as a u32 prefix, and writes the result to the `network_writer`.
pub fn write_framed_message(
    network_writer: anytype,
    allocator: std.mem.Allocator,
    header: MessageHeader,
    comptime serialize_payload_fn: ?fn (anytype, anytype) anyerror!void,
    payload: anytype,
) FramingError!void {
    var temp_buffer = std.ArrayList(u8).init(allocator);
    defer temp_buffer.deinit();
    const buffer_writer = temp_buffer.writer();

    serialize_message_header(buffer_writer, header) catch |e| {
        log.err("Failed serializing header to temp buffer: {any}", .{e});
        return FramingError.IoError;
    };
    if (serialize_payload_fn) |ser_fn| {
        ser_fn(buffer_writer, payload) catch |e| {
            log.err("Failed serializing payload to temp buffer: {any}", .{e});
            return FramingError.IoError;
        };
    }

    const message_bytes = temp_buffer.items;
    const message_len_u64 = message_bytes.len;
    std.debug.assert(message_len_u64 <= std.math.maxInt(u32));
    const message_len: u32 = @intCast(message_len_u64);
    std.debug.assert(message_len <= MAX_MESSAGE_SIZE);

    network_writer.writeInt(u32, message_len, WIRE_ENDIAN) catch |e| {
        log.err("Failed writing length prefix ({d} bytes): {any}", .{ @sizeOf(u32), e });
        return FramingError.IoError;
    };
    network_writer.writeAll(message_bytes) catch |e| {
        log.err("Failed writing message body ({d} bytes): {any}", .{ message_len, e });
        return FramingError.IoError;
    };

    log.debug("Wrote framed message: len={d}, header={any}", .{ message_len, header });
}

/// Reads the u32 length prefix, allocates a buffer of that size, and reads the
/// full message body into the buffer. Caller owns the returned buffer.
pub fn read_framed_message(
    reader: anytype,
    allocator: std.mem.Allocator,
) FramingError![]u8 {
    const message_len = reader.readInt(u32, WIRE_ENDIAN) catch |e| {
        if (e == error.EndOfStream) {
            log.debug("EOF reading length prefix.", .{});
        } else {
            log.err("Failed reading length prefix: {any}", .{e});
        }
        return FramingError.IoError;
    };
    log.debug("Read length prefix: {d}", .{message_len});

    if (message_len == 0) {
        log.warn("Received message with zero length.", .{});
        return allocator.alloc(u8, 0) catch |err| {
            log.err("Allocation failed for zero-length buffer: {any}", .{err});
            return FramingError.AllocationFailed;
        };
    }
    if (message_len > MAX_MESSAGE_SIZE) {
        log.err("Declared message length {d} exceeds MAX_MESSAGE_SIZE {d}", .{ message_len, MAX_MESSAGE_SIZE });
        return FramingError.MessageTooLarge;
    }

    const buffer = allocator.alloc(u8, message_len) catch |err| {
        log.err("Failed allocating read buffer (size {d}): {any}", .{ message_len, err });
        return FramingError.AllocationFailed;
    };
    errdefer allocator.free(buffer);

    _ = reader.readAll(buffer) catch |e| {
        if (e == error.EndOfStream) {
            log.warn("EOF reading message body (expected {d} bytes).", .{message_len});
        } else {
            log.err("Failed reading message body ({d} bytes): {any}", .{ message_len, e });
        }
        return FramingError.IoError;
    };
    std.debug.assert(buffer.len == message_len);

    log.debug("Successfully read {d} message bytes.", .{message_len});
    return buffer;
}
