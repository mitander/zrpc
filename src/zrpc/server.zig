const std = @import("std");
const protocol = @import("protocol.zig");
const framing = @import("framing.zig");

const log = std.log.scoped(.zrpc_server);

// Define expected errors from transport methods used by server
// These are placeholders; the actual errors depend on the specific ListenerType/ConnectionType used.
// Using anyerror allows flexibility but hides details. For stdnet, we know the specific errors.
const AcceptError = anyerror;
const ReceiveError = framing.FramingError;
const SendError = anyerror; // std.posix.WriteError for stdnet

// Application handler interface
pub const Handler = struct {
    add_fn: *const fn (req: protocol.AddRequest) anyerror!protocol.AddResponse, // Allow app error
};

/// Generic Server struct - parameterized by transport types.
pub fn Server(
    comptime ListenerType: type,
    comptime ConnectionType: type,
) type {
    // Ensure the provided types have the methods we need (compile-time check)
    comptime {
        std.debug.assert(@hasDecl(ListenerType, "accept"));
        std.debug.assert(@hasDecl(ListenerType, "close"));
        std.debug.assert(@hasDecl(ConnectionType, "send"));
        std.debug.assert(@hasDecl(ConnectionType, "receive"));
        std.debug.assert(@hasDecl(ConnectionType, "close"));
    }

    return struct {
        listener: ListenerType,
        handler: Handler,
        allocator: std.mem.Allocator,

        pub const Self = @This();

        /// Creates a new Server instance by listening on the given address.
        pub fn listen(
            alloc: std.mem.Allocator,
            handler_impl: Handler,
            address: std.net.Address,
            listen_options: std.net.Address.ListenOptions,
            comptime listen_fn: fn (std.net.Address, std.net.Address.ListenOptions) anyerror!ListenerType,
        ) !Self {
            log.debug("Server.listen attempting on {any}", .{address});
            const listener = try listen_fn(address, listen_options);
            log.info("Server.listen success.", .{});
            return Self{
                .listener = listener,
                .handler = handler_impl,
                .allocator = alloc,
            };
        }

        /// Shuts down the server by closing the listener.
        pub fn shutdown(self: *Self) void {
            log.debug("Server shutting down...", .{});
            self.listener.close();
            log.info("Server shutdown complete.", .{});
        }

        /// Runs the main server loop, accepting and handling connections.
        pub fn run_blocking(self: *Self) !void {
            log.info("Server entering blocking accept loop...", .{});
            while (true) {
                log.debug("Server waiting to accept connection...", .{});
                const connection = try self.listener.accept(self.allocator) catch |err| {
                    log.err("Accept failed: {any}, continuing", .{err});
                    continue;
                };
                try handle_connection(ConnectionType, @constCast(&connection), self.handler, self.allocator);
            }
        }
    };
}

/// Generic function to handle a single connection.
fn handle_connection(
    comptime ConnType: type,
    connection: *ConnType,
    handler: Handler,
    allocator: std.mem.Allocator,
) !void {
    defer connection.close();

    var func_arena = std.heap.ArenaAllocator.init(allocator);
    defer func_arena.deinit();
    const func_allocator = func_arena.allocator();

    log.debug("Handling connection...", .{});

    const request_buffer = try connection.receive(func_allocator) catch |err| {
        log.warn("Receive failed: {any}. Closing connection.", .{err});
        return;
    };

    log.debug("Received {d} bytes.", .{request_buffer.len});
    var fixed_stream = std.io.fixedBufferStream(request_buffer);
    const reader = fixed_stream.reader();

    const header = protocol.deserialize_message_header(reader) catch |e| {
        log.warn("Failed deserializing header: {any}. Closing connection.", .{e});
        return;
    };

    log.debug("Parsed header: {any}", .{header});

    switch (header.procedure_id) {
        protocol.PROC_ID_ADD => {
            const request_payload = protocol.deserialize_add_request(reader) catch |e| {
                log.err("Failed deserializing AddRequest: {any}", .{e});
                return;
            };

            _ = reader.readByte() catch |eof| {
                if (eof == error.EndOfStream) {
                    log.debug("Parsed AddRequest: {any}", .{request_payload});

                    const result = handler.add_fn(request_payload) catch |app_err| {
                        std.debug.assert(app_err == error.Overflow);
                        const err_header = protocol.MessageHeader{
                            .request_id = header.request_id,
                            .procedure_id = header.procedure_id,
                            .status = .app_error,
                            ._padding1 = 0,
                            ._padding2 = 0,
                        };
                        log.warn("Handler returned AppError. Sending error response: {any}", .{err_header});
                        try send_response(ConnType, connection, func_allocator, err_header, null, {});
                        return;
                    };

                    const ok_header = protocol.MessageHeader{
                        .request_id = header.request_id,
                        .procedure_id = header.procedure_id,
                        .status = .ok,
                        ._padding1 = 0,
                        ._padding2 = 0,
                    };
                    log.debug("Handler success. Sending response: header={any}, payload={any}", .{ ok_header, result });
                    try send_response(ConnType, connection, func_allocator, ok_header, protocol.serialize_add_response, result);
                    return;
                } else {
                    log.err("Unexpected IO error after reading payload: {any}", .{eof});
                    return;
                }
            };
            log.warn("Trailing data found after AddRequest payload. Ignoring request.", .{});
            return;
        },
        else => {
            log.warn("Received unknown procedure ID {d}.", .{header.procedure_id});
            const err_header = protocol.MessageHeader{
                .request_id = header.request_id,
                .procedure_id = header.procedure_id,
                .status = .app_error,
                ._padding1 = 0,
                ._padding2 = 0,
            };
            try send_response(ConnType, connection, func_allocator, err_header, null, {});
            return;
        },
    }
}

/// Generic helper to frame and send a response.
fn send_response(
    comptime ConnType: type,
    connection: *const ConnType,
    allocator: std.mem.Allocator,
    header: protocol.MessageHeader,
    serialize_payload_fn: ?fn (anytype, anytype) anyerror!void,
    payload: anytype,
) !void {
    var temp_buffer = std.ArrayList(u8).init(allocator);
    defer temp_buffer.deinit();

    framing.write_framed_message(
        temp_buffer.writer(),
        allocator,
        header,
        serialize_payload_fn,
        payload,
    ) catch |frame_err| {
        log.err("Send Response: Failed to frame message: {any}", .{frame_err});
        return;
    };

    try connection.send(allocator, temp_buffer.items) catch |send_err| {
        log.warn("Send Response: Network send failed: {any}", .{send_err});
    };
}
