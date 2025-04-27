const std = @import("std");
const protocol = @import("protocol.zig");

const log = std.log.scoped(.client);

const SERVER_ADDR = "127.0.0.1";
const SERVER_PORT: u16 = 9000;

var next_request_id: u64 = 1;

/// Generates a unique request ID for this client instance.
fn generate_request_id() u64 {
    const id = next_request_id;
    next_request_id +%= 1;
    return id;
}

/// Error set for high-level client RPC operation failures.
const RpcError = error{
    ConnectionFailed,
    NetworkWriteError,
    NetworkReadError,
    InvalidResponseFormat,
    InvalidResponsePayload,
    RequestIdMismatch,
    UnknownStatus,
};

/// Performs a single Add RPC call.
fn perform_add_rpc(allocator: std.mem.Allocator, operand_a: i32, operand_b: i32) RpcError!void {
    log.info("Attempting Add RPC: a={d}, b={d}", .{ operand_a, operand_b });

    const stream = std.net.tcpConnectToHost(allocator, SERVER_ADDR, SERVER_PORT) catch |err| {
        log.err("Connection failed: {any}", .{err});
        return RpcError.ConnectionFailed;
    };
    defer stream.close();
    log.info("Connected.", .{});

    const request_payload = protocol.AddRequest{ .a = operand_a, .b = operand_b };
    const request_id = generate_request_id();
    const request_header = protocol.MessageHeader{
        .request_id = request_id,
        .procedure_id = protocol.PROC_ID_ADD,
        .status = .ok,
    };
    std.debug.assert(request_id != 0);
    log.debug("Sending request: header={any}, payload={any}", .{ request_header, request_payload });
    protocol.write_framed_message(
        stream.writer(),
        allocator,
        request_header,
        protocol.serialize_add_request,
        request_payload,
    ) catch |e| {
        log.err("Failed writing request: {any}", .{e});
        return RpcError.NetworkWriteError;
    };

    log.debug("Request sent (ID: {d}). Waiting for response...", .{request_id});

    const response_buffer = protocol.read_framed_message(stream.reader(), allocator) catch |e| {
        log.err("Failed reading response: {any}", .{e});
        return RpcError.NetworkReadError;
    };
    defer allocator.free(response_buffer);

    var fixed_stream = std.io.fixedBufferStream(response_buffer);
    const buffer_reader = fixed_stream.reader();

    const response_header = protocol.deserialize_message_header(buffer_reader) catch |e| {
        log.err("Failed deserializing response header: {any}", .{e});
        return RpcError.InvalidResponseFormat;
    };
    log.debug("Received response: header={any}", .{response_header});

    if (response_header.request_id != request_id) {
        log.err("Request ID mismatch! Expected {d}, got {d}.", .{ request_id, response_header.request_id });
        return RpcError.RequestIdMismatch;
    }
    std.debug.assert(response_header.request_id == request_id);

    switch (response_header.status) {
        .ok => {
            const response_payload = protocol.deserialize_add_response(buffer_reader) catch |e| {
                log.err("Failed deserializing AddResponse payload on success: {any}", .{e});
                return RpcError.InvalidResponsePayload;
            };
            log.info("RPC Success! Result({d} + {d}): {d}", .{ operand_a, operand_b, response_payload.result });
        },
        .app_error => {
            log.warn("RPC Failed: Server reported application error (request_id={d}).", .{request_id});
        },
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    std.log.info("--- Starting Zig RPC Client MVP ---", .{});

    log.info("--- Test Case 1: Add(10, 32) -> Expect Success (42) ---", .{});
    perform_add_rpc(allocator, 10, 32) catch |err| {
        log.err("Test Case 1 failed: {any}", .{err});
    };

    std.log.info("\n---------------------------------------\n", .{});

    log.info("--- Test Case 2: Add(MAX_i32, 1) -> Expect Application Error ---", .{});
    perform_add_rpc(allocator, std.math.maxInt(i32), 1) catch |err| {
        log.err("Test Case 2 failed: {any}", .{err});
    };

    std.log.info("\n--- Client finished. ---", .{});
}
