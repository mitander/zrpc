const std = @import("std");
const protocol = @import("protocol.zig");
const framing = @import("framing.zig");
const errors = @import("errors.zig");

const ClientError = errors.ClientError;

const log = std.log.scoped(.zrpc_client);

pub fn ClientType(comptime ConnectionType: type) type {
    comptime {
        std.debug.assert(@hasDecl(ConnectionType, "send"));
        std.debug.assert(@hasDecl(ConnectionType, "receive"));
        std.debug.assert(@hasDecl(ConnectionType, "close"));
    }

    return struct {
        connection: ConnectionType,
        allocator: std.mem.Allocator,
        next_request_id: u64 = 1,

        const Client = @This();

        pub fn connect(
            alloc: std.mem.Allocator,
            address: std.net.Address,
            comptime connect_fn: fn (std.mem.Allocator, std.net.Address) anyerror!ConnectionType,
        ) !Client {
            log.debug("Client connecting to {any}...", .{address});
            const connection = connect_fn(alloc, address) catch |err| {
                log.err("Client connect failed: {any}", .{err});
                return ClientError.ConnectionFailed;
            };
            log.info("Client connected successfully.", .{});

            const client_instance = Client{
                .connection = connection,
                .allocator = alloc,
                .next_request_id = 1,
            };
            std.debug.assert(client_instance.next_request_id == 1);
            return client_instance;
        }

        pub fn disconnect(self: *Client) void {
            log.debug("Client disconnecting.", .{});
            self.connection.close();
            log.info("Client disconnected.", .{});
        }

        fn generate_request_id(self: *Client) u64 {
            std.debug.assert(self.next_request_id != 0);

            const id = self.next_request_id;
            self.next_request_id +%= 1;
            if (self.next_request_id == 0) self.next_request_id = 1;

            std.debug.assert(id != 0);
            std.debug.assert(self.next_request_id != 0);
            return id;
        }

        pub fn add(self: *Client, a: i32, b: i32) ClientError!i32 {
            const request_id = self.generate_request_id();
            std.debug.assert(request_id != 0);

            const request_payload = protocol.AddRequest{ .a = a, .b = b };
            const request_header = protocol.MessageHeader{
                .request_id = request_id,
                .procedure_id = protocol.PROC_ID_ADD,
                .status = .ok,
            };

            std.debug.assert(request_header.status == .ok);
            std.debug.assert(request_header.request_id == request_id);
            std.debug.assert(request_header.procedure_id == protocol.PROC_ID_ADD);

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
            std.debug.assert(send_buffer.items.len >= @sizeOf(protocol.MessageHeader));

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

            const parsed_message = protocol.parse_message_body(response_buffer) catch |parse_err| {
                log.err("add RPC call: Failed to parse response body (req_id={d}): {any}", .{ request_id, parse_err });
                return ClientError.InvalidResponseFormat;
            };

            const response_header = parsed_message.header;
            const response_payload_slice = parsed_message.payload;

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
                    var payload_stream = std.io.fixedBufferStream(response_payload_slice);
                    var payload_reader = payload_stream.reader();

                    const response_payload = protocol.deserialize_add_response(payload_reader) catch |err| {
                        log.err("add RPC call: Failed to deserialize OK payload (req_id={d}): {any}", .{ request_id, err });
                        return ClientError.DeserializeFailed;
                    };

                    _ = payload_reader.readByte() catch |err| {
                        if (err == error.EndOfStream) {
                            const result_value = response_payload.result;
                            log.info("RPC Success! Result({d} + {d}): {d}", .{ a, b, result_value });
                            return result_value;
                        } else {
                            log.err("Trailing data or IO error after OK payload: {any}", .{err});
                            return ClientError.InvalidResponseFormat;
                        }
                    };
                    log.err("Trailing data after OK payload", .{});
                    return ClientError.InvalidResponseFormat;
                },

                .app_error => {
                    var payload_stream = std.io.fixedBufferStream(response_payload_slice);
                    var payload_reader = payload_stream.reader();

                    log.warn("add RPC call: Received AppError status from server (req_id={d}).", .{request_id});
                    _ = payload_reader.readByte() catch |err| {
                        if (err != error.EndOfStream) {
                            log.err("Unexpected payload or IO error after AppError header: {any}", .{err});
                            return ClientError.InvalidResponseFormat;
                        }
                    };
                    return ClientError.ResponseErrorStatus;
                },
            }
        }
    };
}
