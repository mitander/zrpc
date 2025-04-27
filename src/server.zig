const std = @import("std");
const protocol = @import("protocol.zig");
const log = std.log.scoped(.server);

const net = std.net;

const SERVER_ADDR = "127.0.0.1";
const SERVER_PORT: u16 = 9000;

fn local_add(a: i32, b: i32) error{Overflow}!i32 {
    const result = std.math.add(i32, a, b) catch |err| {
        std.debug.assert(err == error.Overflow);
        log.warn("Add operation overflowed: a={d}, b={d}", .{ a, b });
        return err;
    };
    return result;
}

/// Handles a single client connection session.
fn handle_connection(
    connection: net.Server.Connection,
    allocator: std.mem.Allocator,
) void {
    defer connection.stream.close();
    log.info("Accepted connection from {any}", .{connection.address});

    const request_buffer = protocol.read_framed_message(connection.stream.reader(), allocator) catch |e| {
        log.err("Failed reading message from {any}: {any}", .{ connection.address, e });
        return;
    };
    defer allocator.free(request_buffer);

    var fixed_stream = std.io.fixedBufferStream(request_buffer);
    const buffer_reader = fixed_stream.reader();

    const header = protocol.deserialize_message_header(buffer_reader) catch |e| {
        switch (e) {
            error.IoError => log.err("IO error deserializing header from {any}", .{connection.address}),
            error.InvalidStatusValue => log.warn("Received invalid status byte in header from {any}", .{connection.address}),
        }
        return;
    };

    log.debug("Received request: header={any}", .{header});
    std.debug.assert(header.procedure_id == protocol.PROC_ID_ADD);

    if (header.procedure_id == protocol.PROC_ID_ADD) {
        const request_payload = protocol.deserialize_add_request(buffer_reader) catch |e| {
            log.err("Failed deserializing AddRequest from {any}: {any}", .{ connection.address, e });
            return;
        };
        log.debug("Parsed AddRequest: {any}", .{request_payload});

        const result = local_add(request_payload.a, request_payload.b);

        if (result) |value| {
            const response_payload = protocol.AddResponse{ .result = value };
            const response_header = protocol.MessageHeader{
                .request_id = header.request_id,
                .procedure_id = header.procedure_id,
                .status = .ok,
            };
            log.debug("Sending success response: header={any}, payload={any}", .{ response_header, response_payload });
            protocol.write_framed_message(
                connection.stream.writer(),
                allocator,
                response_header,
                protocol.serialize_add_response,
                response_payload,
            ) catch |e| {
                log.err("Failed writing success response to {any}: {any}", .{ connection.address, e });
            };
        } else |app_error| {
            std.debug.assert(app_error == error.Overflow);
            const response_header = protocol.MessageHeader{
                .request_id = header.request_id,
                .procedure_id = header.procedure_id,
                .status = .app_error,
            };
            log.warn("Sending application error response (Overflow): header={any}", .{response_header});
            protocol.write_framed_message(
                connection.stream.writer(),
                allocator,
                response_header,
                null,
                {},
            ) catch |e| {
                log.err("Failed writing application error response to {any}: {any}", .{ connection.address, e });
            };
        }
    } else {
        log.warn("Received unknown procedure ID {d} from {any}", .{ header.procedure_id, connection.address });
    }
    log.info("Finished handling connection from {any}", .{connection.address});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    log.info("Starting Zig RPC Server MVP on {s}:{d}", .{ SERVER_ADDR, SERVER_PORT });

    const address = net.Address.parseIp(SERVER_ADDR, SERVER_PORT) catch |err| {
        log.err("Failed to parse server address: {s}:{d} - {any}", .{ SERVER_ADDR, SERVER_PORT, err });
        return error.InvalidAddress;
    };

    var server = try net.Address.listen(address, .{
        .reuse_address = true,
    });
    defer server.deinit();

    log.info("Server listening on {any}...", .{address});

    while (true) {
        const connection = server.accept() catch |err| {
            log.err("Failed to accept connection: {any}", .{err});
            continue;
        };
        handle_connection(connection, allocator);
    }
}
