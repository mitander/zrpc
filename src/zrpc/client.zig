const std = @import("std");
const protocol = @import("protocol.zig");
const framing = @import("framing.zig");
const errors = @import("errors.zig");

const ClientError = errors.ClientError;

const log = std.log.scoped(.zrpc_client);

pub fn Client(comptime ConnectionType: type) type {
    comptime {
        std.debug.assert(@hasDecl(ConnectionType, "send"));
        std.debug.assert(@hasDecl(ConnectionType, "receive"));
        std.debug.assert(@hasDecl(ConnectionType, "close"));
    }

    return struct {
        connection: ConnectionType,
        allocator: std.mem.Allocator,
        next_request_id: u64 = 1,

        pub const Self = @This();

        pub fn connect(
            alloc: std.mem.Allocator,
            address: std.net.Address,
            comptime connect_fn: fn (std.mem.Allocator, std.net.Address) anyerror!ConnectionType,
        ) !Self {
            log.debug("Client connecting to {any}...", .{address});
            const connection = connect_fn(alloc, address) catch |err| {
                log.err("Client connect failed: {any}", .{err});
                return ClientError.ConnectionFailed;
            };
            log.info("Client connected successfully.", .{});
            return Self{
                .connection = connection,
                .allocator = alloc,
            };
        }

        pub fn disconnect(self: *Self) void {
            log.debug("Client disconnecting.", .{});
            self.connection.close();
            log.info("Client disconnected.", .{});
        }

        fn generate_request_id(self: *Self) u64 {
            const id = self.next_request_id;
            self.next_request_id +%= 1;
            if (self.next_request_id == 0) self.next_request_id = 1;
            std.debug.assert(id != 0);
            return id;
        }

        pub fn add(self: *Self, a: i32, b: i32) !i32 {
            const request_id = self.generate_request_id();
            const request_payload = protocol.AddRequest{ .a = a, .b = b };
            const request_header = protocol.MessageHeader{
                .request_id = request_id,
                .procedure_id = protocol.PROC_ID_ADD,
                .status = .ok,
                ._padding1 = 0,
                ._padding2 = 0,
            };

            log.debug("add RPC call: req_id={d}, payload={any}", .{ request_id, request_payload });

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const req_allocator = arena.allocator();

            var send_buffer = std.ArrayList(u8).init(req_allocator);

            framing.write_framed_message(
                send_buffer.writer(),
                req_allocator,
                request_header,
                protocol.serialize_add_request,
                request_payload,
            ) catch |frame_err| {
                log.err("add RPC call: Failed to frame request (req_id={d}): {any}", .{ request_id, frame_err });
                return ClientError.FramingFailed;
            };

            self.connection.send(req_allocator, send_buffer.items) catch |err| {
                log.err("add RPC call: Failed to send request (req_id={d}): {any}", .{ request_id, err });
                return ClientError.WriteFailed;
            };
            log.debug("add RPC call: Request sent (req_id={d})", .{request_id});

            log.debug("add RPC call: Waiting for response (req_id={d})...", .{request_id});
            const response_buffer = self.connection.receive(self.allocator) catch |err| {
                log.err("add RPC call: Failed to receive response (req_id={d}): {any}", .{ request_id, err });
                return switch (err) {
                    error.MessageTooLarge => ClientError.FramingFailed,
                    else => ClientError.ReadFailed,
                };
            };
            defer self.allocator.free(response_buffer);
            log.debug("add RPC call: Received {d} response bytes (req_id={d})", .{ response_buffer.len, request_id });

            var fixed_stream = std.io.fixedBufferStream(response_buffer);
            const reader = fixed_stream.reader();

            const response_header = protocol.deserialize_message_header(reader) catch |err| {
                log.err("add RPC call: Failed to deserialize response header (req_id={d}): {any}", .{ request_id, err });
                return switch (err) {
                    error.InvalidFormat => ClientError.InvalidResponseFormat,
                    else => ClientError.ReadFailed,
                };
            };
            log.debug("add RPC call: Parsed response header (req_id={d}): {any}", .{ request_id, response_header });

            if (response_header.request_id != request_id) {
                log.err("add RPC call: Response ID mismatch! Expected {d}, got {d}.", .{ request_id, response_header.request_id });
                return ClientError.RequestIdMismatch;
            }
            if (response_header.procedure_id != protocol.PROC_ID_ADD) {
                log.warn("add RPC call: Response procedure ID mismatch! Expected {d}, got {d}.", .{ protocol.PROC_ID_ADD, response_header.procedure_id });
                return ClientError.InvalidResponseFormat;
            }

            switch (response_header.status) {
                .ok => {
                    const response_payload = protocol.deserialize_add_response(reader) catch |err| {
                        log.err("add RPC call: Failed to deserialize OK payload (req_id={d}): {any}", .{ request_id, err });
                        return switch (err) {
                            else => ClientError.DeserializeFailed,
                        };
                    };
                    _ = reader.readByte() catch |err| {
                        if (err == error.EndOfStream) {
                            log.info("RPC Success! Result({d} + {d}): {d}", .{ a, b, response_payload.result });
                            return response_payload.result;
                        } else {
                            log.err("Trailing data after OK payload", .{});
                            return ClientError.InvalidResponseFormat;
                        }
                    };
                    return ClientError.InvalidResponseFormat;
                },
                .app_error => {
                    log.warn("add RPC call: Received AppError status from server (req_id={d}).", .{request_id});
                    _ = reader.readByte() catch |err| {
                        if (err != error.EndOfStream) {
                            log.err("Trailing data after AppError header", .{});
                            return ClientError.InvalidResponseFormat;
                        }
                    };
                    return ClientError.ResponseErrorStatus;
                },
            }

            return ClientError.InvalidResponseFormat;
        }
    };
}
