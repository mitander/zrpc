const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.sim);
const assert = std.debug.assert;

const framing = @import("../framing.zig");
const protocol = @import("../protocol.zig");

pub const SimConnection = struct {
    id: u64,
    is_client: bool,
    controller: *SimController,
    allocator: mem.Allocator,

    const Self = @This();

    pub fn send(self: *Self, _: mem.Allocator, buffer: []const u8) !void {
        return self.controller.send(self.id, self.is_client, buffer);
    }

    pub fn receive(self: *Self, _: mem.Allocator) ![]u8 {
        return self.controller.receive(self.id, self.is_client);
    }

    pub fn close(self: *Self) void {
        self.controller.close_connection(self.id, self.is_client);
    }
};
pub const SimListener = struct {
    controller: *SimController,
    allocator: mem.Allocator,

    const Self = @This();

    pub fn accept(self: *Self, _: mem.Allocator) !SimConnection {
        return self.controller.accept_connection(self.allocator);
    }

    pub fn close(self: *Self) void {
        self.controller.unregister_listener();
    }
};

pub const SimError = error{
    IoError,
    ConnectionReset,
    ListenerNotRegistered,
    ListenerAlreadyRegistered,
    OutOfMemory,
    ControllerShutdown,
    InvalidConnectionId,
    InternalStateError,
};

const ReceiveQueue = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    queue: std.ArrayList([]u8),

    fn init(allocator: mem.Allocator) ReceiveQueue {
        return .{ .queue = std.ArrayList([]u8).init(allocator) };
    }

    fn deinit(self: *ReceiveQueue, allocator: mem.Allocator) void {
        for (self.queue.items) |msg_buf| {
            allocator.free(msg_buf);
        }
        self.queue.deinit();
    }
};

const ConnectionState = struct {
    id: u64,
    client_queue: ReceiveQueue,
    server_queue: ReceiveQueue,
    client_closed: bool = false,
    server_closed: bool = false,

    fn init(id: u64, allocator: mem.Allocator) ConnectionState {
        return .{
            .id = id,
            .client_queue = ReceiveQueue.init(allocator),
            .server_queue = ReceiveQueue.init(allocator),
        };
    }

    fn deinit(self: *ConnectionState, allocator: mem.Allocator) void {
        self.client_queue.deinit(allocator);
        self.server_queue.deinit(allocator);
    }
};

const PendingClient = struct {
    client_allocator: mem.Allocator,
    wait_mutex: std.Thread.Mutex = .{},
    wait_cond: std.Thread.Condition = .{},
    established_conn: ?SimConnection = null,
    establishment_error: ?SimError = null,
};

pub const SimController = struct {
    allocator: mem.Allocator,
    state_mutex: std.Thread.Mutex = .{},

    listener_registered: bool = false,
    listener_wakeup: std.Thread.Condition = .{},

    pending_clients: std.ArrayList(*PendingClient) = undefined,
    client_wakeup: std.Thread.Condition = .{},

    connections: std.AutoHashMap(u64, ConnectionState) = undefined,
    next_conn_id: u64 = 1,

    shutting_down: bool = false,

    const Self = @This();

    pub fn init(allocator: mem.Allocator) SimController {
        return .{
            .allocator = allocator,
            .pending_clients = std.ArrayList(*PendingClient).init(allocator),
            .connections = std.AutoHashMap(u64, ConnectionState).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        self.shutting_down = true;
        self.listener_wakeup.signal();

        for (self.pending_clients.items) |pending| {
            pending.wait_mutex.lock();
            pending.establishment_error = SimError.ControllerShutdown;
            pending.wait_cond.signal();
            pending.wait_mutex.unlock();
        }
        self.pending_clients.deinit();

        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.client_queue.cond.broadcast();
            entry.value_ptr.*.server_queue.cond.broadcast();
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.connections.deinit();
    }

    fn register_listener(self: *Self) SimError!void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        if (self.shutting_down) return SimError.ControllerShutdown;
        if (self.listener_registered) return SimError.ListenerAlreadyRegistered;

        self.listener_registered = true;

        if (self.pending_clients.items.len > 0) {
            self.listener_wakeup.signal();
        }
    }

    fn unregister_listener(self: *Self) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        if (!self.listener_registered) return;

        self.listener_registered = false;
        self.listener_wakeup.signal();
    }

    fn init_connection(self: *Self, client_allocator: mem.Allocator) SimError!SimConnection {
        var pending_entry = PendingClient{ .client_allocator = client_allocator };

        self.state_mutex.lock();
        if (self.shutting_down) {
            self.state_mutex.unlock();
            return SimError.ControllerShutdown;
        }
        try self.pending_clients.append(&pending_entry);
        const listener_was_registered = self.listener_registered;
        self.state_mutex.unlock();

        if (listener_was_registered) {
            self.listener_wakeup.signal();
        }

        pending_entry.wait_mutex.lock();
        defer pending_entry.wait_mutex.unlock();

        while (pending_entry.established_conn == null and pending_entry.establishment_error == null) {
            pending_entry.wait_cond.wait(&pending_entry.wait_mutex);
            if (self.shutting_down) {
                pending_entry.establishment_error = SimError.ControllerShutdown;
            }
        }

        if (pending_entry.establishment_error) |err| {
            return err;
        }

        return pending_entry.established_conn.?;
    }

    fn accept_connection(self: *Self, server_allocator: mem.Allocator) SimError!SimConnection {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        while (true) {
            if (self.shutting_down) return SimError.ControllerShutdown;
            if (!self.listener_registered) return SimError.ListenerNotRegistered;

            if (self.pending_clients.items.len == 0) {
                self.listener_wakeup.wait(&self.state_mutex);
                continue;
            }

            const pending_client = self.pending_clients.orderedRemove(0);

            const conn_id = self.next_conn_id;
            self.next_conn_id += 1;

            const conn_state = ConnectionState.init(conn_id, self.allocator);
            const gop = try self.connections.getOrPut(conn_id);
            assert(!gop.found_existing);
            gop.value_ptr.* = conn_state;

            const client_conn = SimConnection{
                .id = conn_id,
                .is_client = true,
                .controller = self,
                .allocator = pending_client.client_allocator,
            };
            const server_conn = SimConnection{
                .id = conn_id,
                .is_client = false,
                .controller = self,
                .allocator = server_allocator,
            };

            pending_client.wait_mutex.lock();
            pending_client.established_conn = client_conn;
            pending_client.establishment_error = null;
            pending_client.wait_cond.signal();
            pending_client.wait_mutex.unlock();

            return server_conn;
        }
    }

    fn send(self: *Self, conn_id: u64, sender_is_client: bool, buffer: []const u8) SimError!void {
        const buffer_copy = try self.allocator.dupe(u8, buffer);
        errdefer self.allocator.free(buffer_copy);

        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        if (self.shutting_down) {
            self.allocator.free(buffer_copy);
            return SimError.ControllerShutdown;
        }

        const conn_state_ptr = self.connections.getPtr(conn_id);
        if (conn_state_ptr == null) {
            self.allocator.free(buffer_copy);
            return SimError.InvalidConnectionId;
        }
        const conn_state = conn_state_ptr.?;

        const target_queue: *ReceiveQueue = blk: {
            if (sender_is_client) {
                break :blk &conn_state.server_queue;
            } else {
                break :blk &conn_state.client_queue;
            }
        };

        const receiver_closed: bool = blk: {
            if (sender_is_client) {
                break :blk conn_state.server_closed;
            } else {
                break :blk conn_state.client_closed;
            }
        };

        if (receiver_closed) {
            self.allocator.free(buffer_copy);
            return SimError.ConnectionReset;
        }

        target_queue.mutex.lock();
        try target_queue.queue.append(buffer_copy);
        target_queue.cond.signal();
        target_queue.mutex.unlock();

        return;
    }

    fn receive(self: *Self, conn_id: u64, receiver_is_client: bool) SimError![]u8 {
        self.state_mutex.lock();

        if (self.shutting_down) {
            self.state_mutex.unlock();
            return SimError.ControllerShutdown;
        }

        const conn_state_ptr = self.connections.getPtr(conn_id);
        if (conn_state_ptr == null) {
            self.state_mutex.unlock();
            return SimError.InvalidConnectionId;
        }
        const conn_state = conn_state_ptr.?;

        const source_queue: *ReceiveQueue = blk: {
            if (receiver_is_client) {
                break :blk &conn_state.server_queue;
            } else {
                break :blk &conn_state.client_queue;
            }
        };

        const self_closed_flag: bool = blk: {
            if (receiver_is_client) {
                break :blk conn_state.server_closed;
            } else {
                break :blk conn_state.client_closed;
            }
        };

        self.state_mutex.unlock();
        source_queue.mutex.lock();
        defer source_queue.mutex.unlock();

        while (source_queue.queue.items.len == 0) {
            if (self_closed_flag or self.shutting_down) {
                return SimError.ConnectionReset;
            }
            source_queue.cond.wait(&source_queue.mutex);
        }

        const message_buffer = source_queue.queue.orderedRemove(0);
        return message_buffer;
    }

    fn close_connection(self: *Self, conn_id: u64, closer_is_client: bool) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        if (self.shutting_down) return;

        const conn_state_ptr = self.connections.getPtr(conn_id);
        if (conn_state_ptr == null) {
            return;
        }

        var notify_peer_queue: ?*ReceiveQueue = null;
        const conn_state = conn_state_ptr.?;

        if (closer_is_client) {
            if (!conn_state.client_closed) {
                conn_state.client_closed = true;
                notify_peer_queue = &conn_state.server_queue;
            }
        } else {
            if (!conn_state.server_closed) {
                conn_state.server_closed = true;
                notify_peer_queue = &conn_state.client_queue;
            }
        }

        if (notify_peer_queue == null) {
            return;
        }

        if (notify_peer_queue) |peer_queue| {
            peer_queue.cond.signal();
        }

        if (conn_state_ptr.?.client_closed and conn_state_ptr.?.server_closed) {
            conn_state_ptr.?.deinit(self.allocator);
            _ = self.connections.remove(conn_id);
        }
    }
};

pub fn listen(controller: *SimController, listener_allocator: mem.Allocator) SimError!SimListener {
    try controller.register_listener();
    return SimListener{ .controller = controller, .allocator = listener_allocator };
}

pub fn connect(controller: *SimController, client_allocator: mem.Allocator) SimError!SimConnection {
    return controller.init_connection(client_allocator);
}

test "sim: basic connect accept send receive" {
    // Test is internal, keep disabled for now
    if (true) return;

    const allocator = std.testing.allocator;
    var controller = SimController.init(allocator);
    defer controller.deinit();

    const ServerData = struct { controller: *SimController, allocator: mem.Allocator };
    const server_data = ServerData{ .controller = &controller, .allocator = allocator };

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn server_fn(ctx: ServerData) !void {
            log.info("Server: Starting", .{});
            var listener = try listen(ctx.controller, ctx.allocator);
            defer listener.close();

            log.info("Server: Waiting for accept...", .{});
            var conn = try listener.accept(ctx.allocator);
            defer conn.close();
            log.info("Server: Accepted connection id={d}", .{conn.id});

            log.info("Server: Waiting for receive...", .{});
            const received_buf = try conn.receive(ctx.allocator);
            defer ctx.allocator.free(received_buf);
            log.info("Server: Received '{s}'", .{received_buf});
            try std.testing.expectEqualStrings("hello server", received_buf);

            log.info("Server: Sending 'hello client'", .{});
            try conn.send(ctx.allocator, "hello client");

            log.info("Server: Done", .{});
        }
    }.server_fn, .{server_data});

    std.time.sleep(10 * std.time.ns_per_ms);

    log.info("Client: Connecting...", .{});
    var client_conn = try connect(&controller, allocator);
    log.info("Client: Connected id={d}", .{client_conn.id});
    defer client_conn.close();

    log.info("Client: Sending 'hello server'", .{});
    try client_conn.send(allocator, "hello server");

    log.info("Client: Waiting for receive...", .{});
    const received_buf = try client_conn.receive(allocator);
    defer allocator.free(received_buf);
    log.info("Client: Received '{s}'", .{received_buf});
    try std.testing.expectEqualStrings("hello client", received_buf);

    log.info("Client: Done", .{});

    server_thread.join();
    log.info("Test Complete", .{});
}
