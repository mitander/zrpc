const std = @import("std");
const protocol = @import("protocol.zig");

const log = std.log.scoped(.framing);

pub const MAX_MESSAGE_SIZE: u32 = 1 * 1024 * 1024; // 1 MiB

pub const FramingError = error{
    IoError,
    AllocationFailed,
    MessageTooLarge,
};

/// Serializes header and optional payload into a temporary buffer, prepends the
/// total length as a u32 prefix, and writes the result to the `transport_writer`.
/// Uses the provided allocator for the temporary buffer.
/// Returns FramingError or serialization error from serialize_payload_fn.
pub fn write_framed_message(
    transport_writer: anytype,
    allocator: std.mem.Allocator,
    header: protocol.MessageHeader,
    serialize_payload_fn: ?fn (anytype, anytype) anyerror!void, // Allow anyerror from payload fn
    payload: anytype,
) FramingError!void {
    var temp_buffer = std.ArrayList(u8).init(allocator);
    defer temp_buffer.deinit();
    const buffer_writer = temp_buffer.writer();

    protocol.serialize_message_header(buffer_writer, header) catch |e| {
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

    if (message_len_u64 > MAX_MESSAGE_SIZE) {
        log.err("Serialized message size {d} exceeds MAX_MESSAGE_SIZE {d}", .{ message_len_u64, MAX_MESSAGE_SIZE });
        return FramingError.MessageTooLarge;
    }
    if (message_len_u64 > std.math.maxInt(u32)) {
        log.err("Serialized message size {d} exceeds u32 max value", .{message_len_u64});
        return FramingError.MessageTooLarge;
    }
    const message_len: u32 = @intCast(message_len_u64);

    transport_writer.writeInt(u32, message_len, protocol.WIRE_ENDIAN) catch |e| {
        log.err("Failed writing length prefix ({d} bytes): {any}", .{ @sizeOf(u32), e });
        return FramingError.IoError;
    };
    transport_writer.writeAll(message_bytes) catch |e| {
        log.err("Failed writing message body ({d} bytes): {any}", .{ message_len, e });
        return FramingError.IoError;
    };

    log.debug("Wrote framed message: len={d}, header={any}", .{ message_len, header });
}

/// Reads the u32 length prefix, checks against MAX_MESSAGE_SIZE, allocates a buffer
/// of that exact size using the provided allocator, and reads the full message
/// body into the buffer. Caller owns the returned buffer.
/// Returns `FramingError` on failure.
pub fn read_framed_message(
    transport_reader: anytype,
    allocator: std.mem.Allocator,
) FramingError![]u8 {
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

    _ = transport_reader.readAll(buffer) catch |e| {
        if (e == error.EndOfStream) {
            log.warn("EOF reading message body (expected {d} bytes).", .{message_len});
        } else {
            log.err("Failed reading message body ({d} bytes): {any}", .{ message_len, e });
        }
        return FramingError.IoError;
    };

    log.debug("Successfully read {d} message bytes.", .{message_len});
    return buffer;
}

const testing = std.testing;
const ArrayList = std.ArrayList;
const fixedBufferStream = std.io.fixedBufferStream;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;

test "write and read framed message - success" {
    var gpa = GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const header = protocol.MessageHeader{ .request_id = 1, .procedure_id = protocol.PROC_ID_ADD, .status = .ok };
    const payload = protocol.AddRequest{ .a = 10, .b = 20 };

    var network_sim = ArrayList(u8).init(allocator);
    defer network_sim.deinit();

    try write_framed_message(network_sim.writer(), allocator, header, protocol.serialize_add_request, payload);

    const reader = fixedBufferStream(network_sim.items).reader();
    const received_buffer = try read_framed_message(reader, allocator);
    defer allocator.free(received_buffer);

    var received_reader = fixedBufferStream(received_buffer).reader();
    const received_header = try protocol.deserialize_message_header(received_reader);
    const received_payload = try protocol.deserialize_add_request(received_reader);

    try testing.expectEqual(header.request_id, received_header.request_id);
    try testing.expectEqual(payload.a, received_payload.a);
    try testing.expectEqual(payload.b, received_payload.b);

    try testing.expectError(error.EndOfStream, received_reader.readByte());
}

test "read_framed_message - message too large" {
    var gpa = GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var network_sim = ArrayList(u8).init(allocator);
    defer network_sim.deinit();
    const writer = network_sim.writer();

    const large_len: u32 = MAX_MESSAGE_SIZE + 1;
    try writer.writeInt(u32, large_len, protocol.WIRE_ENDIAN);

    const reader = fixedBufferStream(network_sim.items).reader();
    try testing.expectError(FramingError.MessageTooLarge, read_framed_message(reader, allocator));
}

test "read_framed_message - EOF reading length" {
    var gpa = GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var network_sim = ArrayList(u8).init(allocator);
    defer network_sim.deinit();
    const writer = network_sim.writer();

    try writer.writeAll(&[2]u8{ 0x01, 0x02 });

    const reader = fixedBufferStream(network_sim.items).reader();
    try testing.expectError(FramingError.IoError, read_framed_message(reader, allocator));
}

test "read_framed_message - EOF reading body" {
    var gpa = GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var network_sim = ArrayList(u8).init(allocator);
    defer network_sim.deinit();
    const writer = network_sim.writer();

    const expected_len: u32 = 100;
    try writer.writeInt(u32, expected_len, protocol.WIRE_ENDIAN);
    try writer.writeAll(&[50]u8{0} ** 50); // Only 50 bytes

    const reader = fixedBufferStream(network_sim.items).reader();
    // read_framed_message allocates, so need to catch the error to free
    read_framed_message(reader, allocator) catch |err| {
        try testing.expectEqual(FramingError.IoError, err);
        return; // Success
    };
    testing.expect(false) catch @panic("Expected error"); // Should not reach here
}
