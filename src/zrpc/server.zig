const std = @import("std");
const protocol = @import("protocol.zig");
const framing = @import("framing.zig");
const errors = @import("errors.zig");

const log = std.log.scoped(.zrpc_server);

pub const Handler = struct {
    add_fn: *const fn (req: protocol.AddRequest) anyerror!protocol.AddResponse,
};

pub fn ServerType(
    comptime ListenerType: type,
    comptime ConnectionType: type,
) type {
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

        const Server = @This();

        pub fn listen(
            alloc: std.mem.Allocator,
            handler_impl: Handler,
            address: std.net.Address,
            listen_options: std.net.Address.ListenOptions,
            comptime listen_fn: fn (std.net.Address, std.net.Address.ListenOptions) anyerror!ListenerType,
        ) !Server {
            log.debug("Server.listen attempting on {any}", .{address});
            const listener = try listen_fn(address, listen_options);
            log.info("Server.listen success.", .{});

            return Server{
                .listener = listener,
                .handler = handler_impl,
                .allocator = alloc,
            };
        }

        pub fn shutdown(self: *Server) void {
            log.debug("Server shutting down...", .{});
            self.listener.close();
            log.info("Server shutdown complete.", .{});
        }

        pub fn run_blocking(self: *Server) !void {
            log.info("Server entering blocking accept loop...", .{});

            while (true) {
                log.debug("Server waiting to accept connection...", .{});
                var connection = self.listener.accept(self.allocator) catch |err| {
                    log.err("Accept failed: {any}, continuing", .{err});
                    continue;
                };

                handle_connection(ConnectionType, &connection, self.handler, self.allocator) catch |err| {
                    log.err("handle_connection failed unexpectedly: {any}. Closing conn.", .{err});
                    connection.close();
                };
            }
        }
    };
}

fn handle_connection(
    comptime ConnType: type,
    connection: *ConnType,
    handler: Handler,
    allocator: std.mem.Allocator,
) !void {
    defer connection.close();

    while (true) {
        var func_arena = std.heap.ArenaAllocator.init(allocator);
        defer func_arena.deinit();
        const func_allocator = func_arena.allocator();

        log.debug("Handling request within connection...", .{});
        const request_buffer = connection.receive(func_allocator) catch |err| {
            log.info("Receive failed (client likely disconnected or bad frame): {any}. Closing connection.", .{err});
            break;
        };

        log.debug("Received {d} bytes.", .{request_buffer.len});

        const parsed_message = protocol.parse_message_body(request_buffer) catch |parse_err| {
            log.warn("Failed parsing message body: {any}. Closing connection.", .{parse_err});
            break;
        };

        const header = parsed_message.header;
        const payload_slice = parsed_message.payload;

        if (header._padding[0] != 0 or header._padding[1] != 0 or header._padding[2] != 0) {
            log.warn("Non-zero padding received in header: {any}. Ignoring request and closing conn.", .{header._padding});
            break;
        }

        log.debug("Parsed header: {any}", .{header});

        switch (header.procedure_id) {
            protocol.PROC_ID_ADD => {
                const request_payload = protocol.deserialize_add_request(payload_slice, func_allocator) catch |e| {
                    log.err("Failed deserializing AddRequest: {any}. Closing connection.", .{e});
                    break;
                };

                log.debug("Parsed AddRequest: {any}", .{request_payload});

                const result = handler.add_fn(request_payload) catch |app_err| {
                    std.debug.assert(app_err == error.Overflow);
                    const err_header = protocol.MessageHeader{
                        .request_id = header.request_id,
                        .procedure_id = header.procedure_id,
                        .status = .app_error,
                    };
                    log.warn("Handler returned AppError. Sending error response: {any}", .{err_header});
                    send_response(ConnType, connection, func_allocator, err_header, null, {}) catch |send_err| {
                        log.warn("Failed sending AppError response (ignored): {any}", .{send_err});
                        break;
                    };
                    continue;
                };

                const ok_header = protocol.MessageHeader{
                    .request_id = header.request_id,
                    .procedure_id = header.procedure_id,
                    .status = .ok,
                };
                log.debug("Handler success. Sending response: header={any}, payload={any}", .{ ok_header, result });
                send_response(
                    ConnType,
                    connection,
                    func_allocator,
                    ok_header,
                    protocol.serialize_add_response,
                    result,
                ) catch |send_err| {
                    log.warn("Failed sending OK response (ignored): {any}", .{send_err});
                    break;
                };
                continue;
            },

            else => {
                log.warn("Received unknown procedure ID {d}. Closing connection.", .{header.procedure_id});
                return;
            },
        }
    }
}

fn send_response(
    comptime ConnType: type,
    connection: *ConnType,
    allocator: std.mem.Allocator,
    header: protocol.MessageHeader,
    serialize_payload_fn: ?fn (anytype, std.mem.Allocator, anytype) anyerror!void,
    payload: anytype,
) !void {
    if (serialize_payload_fn == null) {
        std.debug.assert(@TypeOf(payload) == void);
    }

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
        return frame_err;
    };

    connection.send(allocator, temp_buffer.items) catch |send_err| {
        log.warn("Send Response: Network send failed: {any}", .{send_err});
        return send_err;
    };
}
