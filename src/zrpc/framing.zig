const std = @import("std");
const mem = std.mem;
const io = std.io;
const testing = std.testing;

const protocol = @import("protocol.zig");
const snapshot = @import("testing/snapshot.zig");

pub const WIRE_ENDIAN = std.builtin.Endian.little;
pub const MAX_MESSAGE_SIZE = 1024 * 1024; // 1 MiB Example

pub const FramingError = error{
    IoError,
    MessageTooLarge,
    AllocationFailed,
    InvalidMessageLength,
    WriteHeaderFailed,
    WritePayloadFailed,
    WriteLengthFailed,
    WriteBodyFailed,
    ReadLengthFailed,
    ReadBodyFailed,
    InvalidHeaderSize,
};

pub fn write_framed_message(
    writer: anytype,
    allocator: mem.Allocator,
    header: protocol.MessageHeader,
    comptime serialize_payload_fn: ?fn (anytype, mem.Allocator, anytype) anyerror!void,
    payload: anytype,
) FramingError!void {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var buffer_writer = buffer.writer();

    const Header = @TypeOf(header);
    if (@sizeOf(Header) != 16) {
        std.log.err("MessageHeader size is {d}, expected 16. Check definition/packing.", .{@sizeOf(Header)});
        return FramingError.InvalidHeaderSize;
    }
    buffer_writer.writeAll(std.mem.asBytes(&header)) catch |err| {
        std.log.err("Failed to write header bytes: {any}", .{err});
        return FramingError.WriteHeaderFailed;
    };

    if (serialize_payload_fn) |serialize_fn| {
        serialize_fn(payload, allocator, buffer_writer) catch |err| {
            std.log.err("Failed to serialize payload: {any}", .{err});
            return FramingError.WritePayloadFailed;
        };
    }

    const message_len: u32 = @intCast(buffer.items.len);
    if (message_len > MAX_MESSAGE_SIZE) {
        std.log.err("Message body size ({d}) exceeds MAX_MESSAGE_SIZE ({d})", .{ message_len, MAX_MESSAGE_SIZE });
        return FramingError.MessageTooLarge;
    }

    writer.writeInt(u32, message_len, WIRE_ENDIAN) catch |err| {
        std.log.err("Failed to write message length prefix: {any}", .{err});
        return FramingError.WriteLengthFailed;
    };

    writer.writeAll(buffer.items) catch |err| {
        std.log.err("Failed to write message body: {any}", .{err});
        return FramingError.WriteBodyFailed;
    };
}

pub fn read_framed_message(
    reader: anytype,
    allocator: mem.Allocator,
) FramingError![]u8 {
    const message_len = reader.readInt(u32, WIRE_ENDIAN) catch |err| {
        if (err == error.EndOfStream) {
            std.log.warn("End of stream while reading message length.", .{});
            return FramingError.ReadLengthFailed;
        }
        std.log.err("Failed to read message length: {any}", .{err});
        return FramingError.ReadLengthFailed;
    };

    if (message_len == 0) {
        std.log.warn("Received message frame with zero length.", .{});
        return allocator.alloc(u8, 0) catch |err| {
            std.log.err("Failed to allocate zero-byte slice: {any}", .{err});
            return FramingError.AllocationFailed;
        };
    }

    if (message_len > MAX_MESSAGE_SIZE) {
        return FramingError.MessageTooLarge;
    }

    const buffer = allocator.alloc(u8, message_len) catch |err| {
        std.log.err("Failed to allocate buffer for message size {d}: {any}", .{ message_len, err });
        return FramingError.AllocationFailed;
    };

    for (buffer) |*byte_ptr| {
        byte_ptr.* = reader.readByte() catch {
            allocator.free(buffer);
            return FramingError.ReadBodyFailed;
        };
    }
    return buffer;
}

// =============================================================================
// Test Section
// =============================================================================
const snap = snapshot.Snap.snap;

fn default_header(request_id: u64, procedure_id: u32, status: protocol.Status) protocol.MessageHeader {
    return protocol.MessageHeader{
        .request_id = request_id,
        .procedure_id = procedure_id,
        .status = status,
    };
}

test "framing: write and read empty message body" {
    var stream_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stream_buffer.deinit();

    const header_to_write = default_header(1, 1, .ok);
    const message_body_len = @sizeOf(@TypeOf(header_to_write));
    try testing.expectEqual(@as(usize, 16), message_body_len);

    try write_framed_message(stream_buffer.writer(), testing.allocator, header_to_write, null, {});

    const expected_frame_len_bytes = @as(u32, message_body_len);
    var expected_bytes_list = std.ArrayList(u8).init(testing.allocator);
    defer expected_bytes_list.deinit();
    try expected_bytes_list.writer().writeInt(u32, expected_frame_len_bytes, WIRE_ENDIAN);
    try expected_bytes_list.writer().writeAll(std.mem.asBytes(&header_to_write));

    try testing.expectEqualSlices(u8, expected_bytes_list.items, stream_buffer.items);

    var stream = io.fixedBufferStream(stream_buffer.items);
    var reader = stream.reader();
    const read_message_body = try read_framed_message(reader, testing.allocator);
    defer testing.allocator.free(read_message_body);

    try testing.expectEqualSlices(u8, std.mem.asBytes(&header_to_write), read_message_body);

    // FIXED: Use readByte() for reliable EOF check
    try testing.expectError(error.EndOfStream, reader.readByte());
}

test "framing: write message and check snapshot" {
    const header_to_write = default_header(1, 1, .ok);
    try testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(header_to_write)));

    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    try write_framed_message(buf.writer(), testing.allocator, header_to_write, null, {});

    const expected_bytes = [_]u8{
        0x10, 0x00, 0x00, 0x00, // Frame length (16 bytes message header)
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // request_id = 1
        0x01, 0x00, 0x00, 0x00, // procedure_id = 1
        0x00, // status = ok (assuming 0)
        0x00, 0x00, 0x00, // Padding to 16 bytes? Check struct def!
    };

    try snap(@src(), &expected_bytes).diff(buf.items);
}

test "framing: read zero length message" {
    const framed_bytes = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    var stream = io.fixedBufferStream(&framed_bytes);
    const message_body = try read_framed_message(stream.reader(), testing.allocator);
    defer testing.allocator.free(message_body); // free the 0-byte slice

    try testing.expectEqualSlices(u8, &[_]u8{}, message_body);

    // FIXED: Use readByte() for reliable EOF check
    var reader_after = stream.reader();
    try testing.expectError(error.EndOfStream, reader_after.readByte());
}

test "framing: read error MessageTooLarge" {
    const bad_len = MAX_MESSAGE_SIZE + 1;
    var framed_bytes_buf: [4]u8 = undefined;
    mem.writeInt(u32, &framed_bytes_buf, bad_len, WIRE_ENDIAN);

    var stream = io.fixedBufferStream(&framed_bytes_buf);
    // No change needed here, assertion is correct, logs are acceptable.
    try testing.expectError(FramingError.MessageTooLarge, read_framed_message(stream.reader(), testing.allocator));
}

test "framing: read error ReadLengthFailed (EndOfStream during length read)" {
    const framed_bytes = [_]u8{};
    var stream = io.fixedBufferStream(&framed_bytes);

    // No change needed here, assertion is correct.
    try testing.expectError(FramingError.ReadLengthFailed, read_framed_message(stream.reader(), testing.allocator));
}

test "framing: read error ReadBodyFailed (EndOfStream during body read)" {
    var framed_bytes_buf: [4]u8 = undefined;
    mem.writeInt(u32, &framed_bytes_buf, 10, WIRE_ENDIAN); // Expect 10 bytes body

    var stream = io.fixedBufferStream(&framed_bytes_buf); // But only provide 4 bytes

    // FIXED: Capture result explicitly before checking error
    const result = read_framed_message(stream.reader(), testing.allocator);
    try testing.expectError(FramingError.ReadBodyFailed, result);

    // If expectError passes, the error was returned, and the buffer should
    // have been freed internally by read_framed_message's catch block.
    // If expectError fails (meaning it succeeded returning a buffer),
    // the test fails *before* reaching here, but the buffer would leak.
    // Correcting the expectError usage ensures we correctly test the error path.
}
