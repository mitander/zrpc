const std = @import("std");
const protocol = @import("protocol.zig");
const errors = @import("errors.zig");
const log = std.log.scoped(.framing);

pub const MAX_MESSAGE_SIZE: u32 = 1 * 1024 * 1024;
comptime {
    std.debug.assert(MAX_MESSAGE_SIZE > 0);
}

pub const FramingError = error{
    IoError,
    AllocationFailed,
    MessageTooLarge,
};

pub fn write_framed_message(
    transport_writer: anytype,
    allocator: std.mem.Allocator,
    header: protocol.MessageHeader,
    serialize_payload_fn: ?fn (anytype, anytype) anyerror!void,
    payload: anytype,
) FramingError!void {
    std.debug.assert(header._padding1 == 0);
    std.debug.assert(header._padding2 == 0);
    if (serialize_payload_fn == null) {
        std.debug.assert(@TypeOf(payload) == void);
    } else {
        std.debug.assert(serialize_payload_fn != null);
    }

    var temp_buffer = std.ArrayList(u8).init(allocator);
    defer temp_buffer.deinit();
    const buffer_writer = temp_buffer.writer();

    protocol.serialize_message_header(buffer_writer, header) catch |e| {
        log.err("Failed serializing header to temp buffer: {any}", .{e});
        return FramingError.IoError;
    };
    if (serialize_payload_fn) |ser_fn| {
        std.debug.assert(@TypeOf(payload) != void);
        ser_fn(buffer_writer, payload) catch |e| {
            log.err("Failed serializing payload to temp buffer: {any}", .{e});
            return FramingError.IoError;
        };
    } else {
        std.debug.assert(@TypeOf(payload) == void);
    }

    const message_bytes = temp_buffer.items;
    const message_len_u64 = message_bytes.len;

    if (message_len_u64 > MAX_MESSAGE_SIZE) {
        log.err("Serialized message size {d} exceeds MAX_MESSAGE_SIZE {d}", .{ message_len_u64, MAX_MESSAGE_SIZE });
        return FramingError.MessageTooLarge;
    }
    std.debug.assert(message_len_u64 <= std.math.maxInt(u32));
    if (message_len_u64 > std.math.maxInt(u32)) {
        log.err("Serialized message size {d} exceeds u32 max value", .{message_len_u64});
        return FramingError.MessageTooLarge;
    }
    const message_len: u32 = @intCast(message_len_u64);

    std.debug.assert(message_len <= MAX_MESSAGE_SIZE);
    transport_writer.writeInt(u32, message_len, protocol.WIRE_ENDIAN) catch |e| {
        log.err("Failed writing length prefix ({d} bytes): {any}", .{ @sizeOf(u32), e });
        return FramingError.IoError;
    };
    std.debug.assert(message_bytes.len == message_len);
    transport_writer.writeAll(message_bytes) catch |e| {
        log.err("Failed writing message body ({d} bytes): {any}", .{ message_len, e });
        return FramingError.IoError;
    };

    log.debug("Wrote framed message: len={d}, header={any}", .{ message_len, header });
}

pub fn read_framed_message(
    transport_reader: anytype,
    allocator: std.mem.Allocator,
) FramingError![]u8 {
    std.debug.assert(MAX_MESSAGE_SIZE > 0);

    const message_len = transport_reader.readInt(u32, protocol.WIRE_ENDIAN) catch |e| {
        if (e == error.EndOfStream) {
            log.debug("EOF reading length prefix.", .{});
        } else {
            log.err("Failed reading length prefix: {any}", .{e});
        }
        return FramingError.IoError;
    };
    log.debug("Read length prefix: {d}", .{message_len});

    if (message_len == 0) {
        log.warn("Received message frame with zero length.", .{});
        std.debug.assert(message_len == 0);
        const empty_buffer = allocator.alloc(u8, 0) catch |err| {
            log.err("Allocation failed for zero-length buffer: {any}", .{err});
            return FramingError.AllocationFailed;
        };
        std.debug.assert(empty_buffer.len == 0);
        return empty_buffer;
    }

    if (message_len > MAX_MESSAGE_SIZE) {
        log.err("Message size {d} exceeds MAX_MESSAGE_SIZE {d}", .{ message_len, MAX_MESSAGE_SIZE });
        return FramingError.MessageTooLarge;
    }
    std.debug.assert(message_len > 0);
    std.debug.assert(message_len <= MAX_MESSAGE_SIZE);

    const buffer = allocator.alloc(u8, message_len) catch |err| {
        log.err("Failed allocating read buffer (size {d}): {any}", .{ message_len, err });
        return FramingError.AllocationFailed;
    };
    std.debug.assert(buffer.len == message_len);
    errdefer allocator.free(buffer);

    std.debug.assert(buffer.len == message_len);
    const bytes_read = transport_reader.readAll(buffer) catch |e| {
        if (e == error.EndOfStream) {
            log.warn("EOF reading message body (expected {d} bytes).", .{message_len});
        } else {
            log.err("Failed reading message body ({d} bytes): {any}", .{ message_len, e });
        }
        return FramingError.IoError;
    };

    log.debug("Successfully read {d} message bytes.", .{bytes_read});
    std.debug.assert(buffer.len == message_len);
    return buffer;
}
