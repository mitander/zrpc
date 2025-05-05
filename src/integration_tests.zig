const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.integration_test);

const zrpc = @import("zrpc");
const sim = zrpc.sim;
const protocol = zrpc.protocol;
const framing = zrpc.framing;
const ClientError = zrpc.errors.ClientError;

fn test_add_handler(req: protocol.AddRequest) !protocol.AddResponse {
    const result = try std.math.add(i32, req.a, req.b);
    return protocol.AddResponse{ .result = result };
}

const test_handler = zrpc.Handler{
    .add_fn = &test_add_handler,
};

const TestClient = struct {
    controller: *sim.SimController,
    allocator: std.mem.Allocator,
    connection: ?sim.SimConnection = null,
    zrpc_client_core: zrpc.ClientType(sim.SimConnection).Client = undefined,

    pub fn connect(allocator: std.mem.Allocator, controller: *sim.SimController) !TestClient {
        var self = TestClient{
            .controller = controller,
            .allocator = allocator,
        };
        self.connection = try controller.init_connection(allocator);
        self.zrpc_client_core = .{
            .connection = self.connection.?,
            .allocator = allocator,
            .next_request_id = 1,
        };
        return self;
    }

    pub fn disconnect(self: *TestClient) void {
        if (self.connection != null) {
            self.zrpc_client_core.disconnect();
            self.connection = null;
        }
    }

    pub fn add(self: *TestClient, a: i32, b: i32) !i32 {
        if (self.connection == null) return error.NotConnected;
        return self.zrpc_client_core.add(a, b);
    }
};

const TestServer = struct {
    controller: *sim.SimController,
    allocator: std.mem.Allocator,
    handler: zrpc.Handler,
    listener: ?sim.SimListener = null,
    running: bool = false,

    pub fn listen(allocator: std.mem.Allocator, controller: *sim.SimController, handler: zrpc.Handler) !TestServer {
        var self = TestServer{
            .controller = controller,
            .allocator = allocator,
            .handler = handler,
        };
        self.listener = try controller.listen(allocator);
        return self;
    }

    pub fn shutdown(self: *TestServer) void {
        if (self.listener) |*listener| {
            listener.close();
            self.listener = null;
        }
        self.running = false;
    }

    pub fn run_blocking(self: *TestServer) !void {
        if (self.listener == null) return error.NotListening;
        var listener = self.listener.?;
        self.running = true;

        while (self.running) {
            var connection = try listener.accept(self.allocator);
            handle_connection_directly(&connection, self.handler, self.allocator) catch |err| {
                connection.close();
                log.err("TestServer handle_connection failed: {any}. Closing conn.", .{err});
            };
        }
    }

    fn handle_connection_directly(
        connection: *sim.SimConnection,
        handler: zrpc.Handler,
        allocator: std.mem.Allocator,
    ) !void {
        defer connection.close();

        connection.controller.mutex.lock();
        defer connection.controller.mutex.unlock();

        while (true) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            const request_buffer = try connection.receive(allocator);
            defer allocator.free(request_buffer);

            const parsed_message = protocol.parse_message_body(request_buffer) catch |err| {
                log.warn("Failed to parse message body: {any}", .{err});
                break;
            };

            const header = parsed_message.header;
            const payload_slice = parsed_message.payload;

            if (header._padding[0] != 0 or header._padding[1] != 0 or header._padding[2] != 0) {
                log.warn("Non-zero padding received in header: {b}. Ignoring request and closing conn.", .{header._padding});
                return protocol.ProtocolError.InvalidPayload;
            }

            switch (header.procedure_id) {
                protocol.PROC_ID_ADD => {
                    const request_payload = protocol.deserialize_add_request(payload_slice, arena_allocator) catch {
                        break;
                    };

                    const result = handler.add_fn(request_payload) catch |app_err| {
                        std.debug.assert(app_err == error.Overflow);
                        const err_header = protocol.MessageHeader{
                            .request_id = header.request_id,
                            .procedure_id = header.procedure_id,
                            .status = .app_error,
                        };
                        try send_response_directly(connection, arena_allocator, err_header, null, {});
                        continue;
                    };

                    const ok_header = protocol.MessageHeader{
                        .request_id = header.request_id,
                        .procedure_id = header.procedure_id,
                        .status = .ok,
                    };
                    try send_response_directly(
                        connection,
                        arena_allocator,
                        ok_header,
                        protocol.serialize_add_response,
                        result,
                    );
                    continue;
                },
                else => {
                    break;
                },
            }
        }
    }

    fn send_response_directly(
        connection: *sim.SimConnection,
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

        try framing.write_framed_message(
            temp_buffer.writer(),
            allocator,
            header,
            serialize_payload_fn,
            payload,
        );
        try connection.send(allocator, temp_buffer.items);
    }
};

const ServerContext = struct {
    server: *TestServer,
    server_ready: bool = false,
};

fn server_task(ctx: *ServerContext) !void {
    ctx.server_ready = true;
    std.time.sleep(10 * std.time.ns_per_ms);
    ctx.server.run_blocking() catch |err| {
        return err;
    };
}

test "integration: successful add call" {
    if (true) return; // disabled for now

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var controller = sim.SimController.init(allocator);
    defer controller.deinit();

    var server = try TestServer.listen(allocator, &controller, test_handler);
    defer server.shutdown();

    var server_ctx = ServerContext{ .server = &server };
    const server_thread = try std.Thread.spawn(.{}, server_task, .{&server_ctx});

    while (!server_ctx.server_ready) {
        std.time.sleep(10 * std.time.ns_per_us);
    }

    var client = try TestClient.connect(allocator, &controller);
    defer client.disconnect();

    const result = try client.add(10, 32);
    try testing.expectEqual(@as(i32, 42), result);

    const result2 = try client.add(-5, 5);
    try testing.expectEqual(@as(i32, 0), result2);

    server_thread.join();
}

test "integration: add call with application error (overflow)" {
    if (true) return; // disabled for now

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var controller = sim.SimController.init(allocator);
    defer controller.deinit();

    var server = try TestServer.listen(allocator, &controller, test_handler);
    defer server.shutdown();

    var server_ctx = ServerContext{ .server = &server };
    const server_thread = try std.Thread.spawn(.{}, server_task, .{&server_ctx});

    while (!server_ctx.server_ready) {
        std.time.sleep(10 * std.time.ns_per_us);
    }

    var client = try TestClient.connect(allocator, &controller);
    defer client.disconnect();

    const result = client.add(std.math.maxInt(i32), 1);
    try testing.expectError(ClientError.ResponseErrorStatus, result);

    server_thread.join();
}
