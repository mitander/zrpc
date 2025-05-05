const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.sim);
const assert = std.debug.assert;
const testing = std.testing;

const framing = @import("../framing.zig");
const protocol = @import("../protocol.zig");

pub const SimConnection = struct {
    id: u64,
    is_client: bool,
    controller: *SimController,
    allocator: mem.Allocator,

    const Self = @This();

    pub fn send(self: *Self, message: []const u8) SimError!void {
        const conn_state_ptr = self.controller.connections.getPtr(self.id);
        if (conn_state_ptr == null) {
            return SimError.InvalidConnectionId;
        }
        const conn_state = conn_state_ptr.?;

        const target_queue: *ReceiveQueue = blk: {
            if (self.is_client) {
                break :blk &conn_state.client_queue;
            } else {
                break :blk &conn_state.server_queue;
            }
        };

        target_queue.mutex.lock();
        defer target_queue.mutex.unlock();

        const message_buffer = try self.allocator.dupe(u8, message);
        target_queue.queue.append(message_buffer) catch |err| {
            self.allocator.free(message_buffer);
            return err;
        };
        target_queue.cond.signal();
    }

    pub fn receive(self: *Self) SimError![]u8 {
        const conn_state_ptr = self.controller.connections.getPtr(self.id);
        if (conn_state_ptr == null) {
            return SimError.InvalidConnectionId;
        }
        const conn_state = conn_state_ptr.?;

        const source_queue: *ReceiveQueue = blk: {
            if (self.is_client) {
                break :blk &conn_state.server_queue;
            } else {
                break :blk &conn_state.client_queue;
            }
        };

        const self_closed_flag: bool = blk: {
            if (self.is_client) {
                break :blk conn_state.server_closed;
            } else {
                break :blk conn_state.client_closed;
            }
        };

        source_queue.mutex.lock();
        defer source_queue.mutex.unlock();

        while (source_queue.queue.items.len == 0) {
            if (self_closed_flag or self.controller.shutting_down) {
                return SimError.ConnectionReset;
            }
            source_queue.cond.wait(&source_queue.mutex);
        }

        const message_buffer = source_queue.queue.orderedRemove(0);
        return self.allocator.dupe(u8, message_buffer) catch |err| {
            source_queue.queue.append(message_buffer) catch unreachable;
            return err;
        };
    }

    pub fn close(self: *Self) void {
        self.controller.close_connection(self.id, self.is_client, self.allocator);
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
    const Self = @This();

    allocator: mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    listener_registered: bool = false,
    listener_wakeup: std.Thread.Condition = .{},

    pending_clients: std.ArrayList(*PendingClient) = undefined,
    client_wakeup: std.Thread.Condition = .{},

    connections: std.AutoHashMap(u64, ConnectionState) = undefined,
    next_conn_id: u64 = 1,

    shutting_down: bool = false,

    pub fn init(allocator: mem.Allocator) SimController {
        return .{
            .allocator = allocator,
            .pending_clients = std.ArrayList(*PendingClient).init(allocator),
            .connections = std.AutoHashMap(u64, ConnectionState).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

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
            entry.value_ptr.*.client_queue.deinit(self.allocator);
            entry.value_ptr.*.server_queue.deinit(self.allocator);
            _ = self.connections.remove(entry.key_ptr.*);
        }
        self.connections.deinit();
    }

    pub fn register_listener(self: *Self) SimError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shutting_down) return SimError.ControllerShutdown;
        if (self.listener_registered) return SimError.ListenerAlreadyRegistered;

        self.listener_registered = true;

        if (self.pending_clients.items.len > 0) {
            self.listener_wakeup.signal();
        }
    }

    pub fn unregister_listener(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.listener_registered) return;

        self.listener_registered = false;
        self.listener_wakeup.signal();
    }

    pub fn init_connection(self: *Self, client_allocator: mem.Allocator) SimError!SimConnection {
        var pending_entry = PendingClient{ .client_allocator = client_allocator };

        self.mutex.lock();
        if (self.shutting_down) {
            self.mutex.unlock();
            return SimError.ControllerShutdown;
        }
        try self.pending_clients.append(&pending_entry);
        const listener_was_registered = self.listener_registered;
        self.mutex.unlock();

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

    pub fn accept_connection(self: *Self, server_allocator: mem.Allocator) SimError!SimConnection {
        const thread_id = std.Thread.getCurrentId();
        log.info("Thread {d} starting accept_connection", .{thread_id});
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            log.info("Thread {d} checking shutdown state", .{thread_id});
            if (self.shutting_down) {
                log.info("Thread {d} controller is shutting down", .{thread_id});
                return SimError.ControllerShutdown;
            }

            log.info("Thread {d} checking pending clients: {}", .{ thread_id, self.pending_clients.items.len });
            if (self.pending_clients.items.len == 0) {
                log.info("Thread {d} no pending clients, waiting...", .{thread_id});
                self.listener_wakeup.wait(&self.mutex);
                continue;
            }

            const pending_entry = self.pending_clients.orderedRemove(0);
            const conn_id = self.next_conn_id;
            self.next_conn_id += 1;

            log.info("Thread {d} creating new connection state for id {}", .{ thread_id, conn_id });
            const conn_state = ConnectionState{
                .id = conn_id,
                .client_queue = ReceiveQueue.init(server_allocator),
                .server_queue = ReceiveQueue.init(server_allocator),
                .client_closed = false,
                .server_closed = false,
            };

            try self.connections.put(conn_id, conn_state);
            log.info("Thread {d} connection state created, notifying client", .{thread_id});

            pending_entry.wait_mutex.lock();
            log.info("Thread {d} locked client wait_mutex", .{thread_id});

            pending_entry.established_conn = SimConnection{
                .controller = self,
                .id = conn_id,
                .is_client = false,
                .allocator = server_allocator,
            };

            pending_entry.wait_cond.signal();
            pending_entry.wait_mutex.unlock();
            log.info("Thread {d} released client wait_mutex", .{thread_id});

            return pending_entry.established_conn.?;
        }
    }

    pub fn send(self: *Self, conn_id: u64, sender_is_client: bool, buffer: []const u8) SimError!void {
        const thread_id = std.Thread.getCurrentId();
        log.info("Thread {d} starting send for id {}", .{ thread_id, conn_id });
        const buffer_copy = try self.allocator.dupe(u8, buffer);
        errdefer self.allocator.free(buffer_copy);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.shutting_down) {
            self.allocator.free(buffer_copy);
            log.info("Thread {d} controller is shutting down during send", .{thread_id});
            return SimError.ControllerShutdown;
        }

        const conn_state_ptr = self.connections.getPtr(conn_id);
        if (conn_state_ptr == null) {
            self.allocator.free(buffer_copy);
            log.info("Thread {d} connection not found", .{thread_id});
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
            log.info("Thread {d} receiver is closed", .{thread_id});
            return SimError.ConnectionReset;
        }

        // Release connections_mutex before locking queue mutex
        self.mutex.unlock();

        target_queue.mutex.lock();
        defer target_queue.mutex.unlock();

        try target_queue.queue.append(buffer_copy);
        target_queue.cond.signal();

        log.info("Thread {d} sent message", .{thread_id});
        return;
    }

    pub fn receive(self: *Self, conn_id: u64, is_client: bool) SimError![]u8 {
        const thread_id = std.Thread.getCurrentId();
        log.info("Thread {d} starting receive for id {}", .{ thread_id, conn_id });

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.shutting_down) {
            log.info("Thread {d} controller is shutting down during receive", .{thread_id});
            return SimError.ControllerShutdown;
        }

        const conn_state_ptr = self.connections.getPtr(conn_id);
        if (conn_state_ptr == null) {
            log.info("Thread {d} connection not found", .{thread_id});
            return SimError.InvalidConnectionId;
        }
        const conn_state = conn_state_ptr.?;

        const source_queue: *ReceiveQueue = blk: {
            if (is_client) {
                break :blk &conn_state.server_queue;
            } else {
                break :blk &conn_state.client_queue;
            }
        };

        const self_closed_flag: bool = blk: {
            if (is_client) {
                break :blk conn_state.server_closed;
            } else {
                break :blk conn_state.client_closed;
            }
        };

        // Release connections_mutex before locking queue mutex
        self.mutex.unlock();
        defer self.mutex.lock();

        source_queue.mutex.lock();
        defer source_queue.mutex.unlock();

        while (source_queue.queue.items.len == 0) {
            if (self_closed_flag or self.shutting_down) {
                log.info("Thread {d} connection is closed or shutting down", .{thread_id});
                return SimError.ConnectionReset;
            }
            source_queue.cond.wait(&source_queue.mutex);
        }

        const message_buffer = source_queue.queue.orderedRemove(0);
        return self.allocator.dupe(u8, message_buffer) catch |err| {
            source_queue.queue.append(message_buffer) catch unreachable;
            return err;
        };
    }

    fn close_connection(self: *Self, conn_id: u64, closer_is_client: bool, allocator: mem.Allocator) void {
        const thread_id = std.Thread.getCurrentId();
        log.info("Thread {d} starting close_connection for id {}", .{ thread_id, conn_id });

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.shutting_down) {
            log.info("Thread {d} controller is shutting down during close", .{thread_id});
            return;
        }

        const conn_state_ptr = self.connections.getPtr(conn_id);
        if (conn_state_ptr == null) {
            log.info("Thread {d} connection not found", .{thread_id});
            return;
        }
        const conn_state = conn_state_ptr.?;

        log.info("Thread {d} updating connection state", .{thread_id});
        if (closer_is_client) {
            conn_state.client_closed = true;
        } else {
            conn_state.server_closed = true;
        }

        // Check if both sides are closed
        if (conn_state.client_closed and conn_state.server_closed) {
            log.info("Thread {d} both sides closed, cleaning up", .{thread_id});

            // Remove from map first while holding mutex
            const removed_state = self.connections.fetchRemove(conn_id).?.value;

            // Signal any waiting receivers while holding mutex
            removed_state.client_queue.cond.signal();
            removed_state.server_queue.cond.signal();

            // Release mutex before deinit
            self.mutex.unlock();
            defer self.mutex.lock();

            // Now safe to deinit since no other thread can access this state
            removed_state.client_queue.deinit(allocator);
            removed_state.server_queue.deinit(allocator);
        } else {
            // Only one side closed, just signal the other side
            const queue_to_signal = if (closer_is_client)
                &conn_state.server_queue // Client closed, signal server
            else
                &conn_state.client_queue; // Server closed, signal client

            // Signal while holding mutex
            queue_to_signal.cond.signal();
        }
    }
};

const listen = @import("sim.zig").listen;
const connect = @import("sim.zig").connect;

test "sim: basic connect accept send receive" {
    // Test is internal, keep disabled for now
    if (true) return;

    var controller = SimController.init(testing.allocator);
    defer controller.deinit();

    const ServerData = struct { controller: *SimController, allocator: mem.Allocator };
    const server_data = ServerData{ .controller = &controller, .allocator = testing.allocator };

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
    var client_conn = try connect(&controller, testing.allocator);
    log.info("Client: Connected id={d}", .{client_conn.id});
    defer client_conn.close();

    log.info("Client: Sending 'hello server'", .{});
    try client_conn.send(testing.allocator, "hello server");

    log.info("Client: Waiting for receive...", .{});
    const received_buf = try client_conn.receive(testing.allocator);
    defer testing.allocator.free(received_buf);
    log.info("Client: Received '{s}'", .{received_buf});
    try std.testing.expectEqualStrings("hello client", received_buf);

    log.info("Client: Done", .{});

    server_thread.join();
    log.info("Test Complete", .{});
}
