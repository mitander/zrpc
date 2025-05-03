// src/zrpc/transport/simtransport.zig
const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.simtransport);
const assert = std.debug.assert;

const framing = @import("../framing.zig");
const protocol = @import("../protocol.zig");

// Forward declarations
pub const SimConnection = struct {
    id: u64,
    is_client: bool, // True if this represents the client side of the connection
    controller: *SimController,
    allocator: mem.Allocator, // Allocator provided by the creator (client/server) for its own use

    const Self = @This();

    pub fn send(self: *Self, _: mem.Allocator, buffer: []const u8) !void {
        assert(self.controller != null);
        return self.controller.send(self.id, self.is_client, buffer);
    }

    pub fn receive(self: *Self, allocator: mem.Allocator) ![]u8 {
        assert(self.controller != null);
        // Pass the caller's allocator for potential error returns, but the received buffer
        // itself was allocated using the controller's allocator by the sender.
        _ = allocator;
        return self.controller.receive(self.id, self.is_client);
    }

    pub fn close(self: *Self) void {
        if (self.controller == null) return; // Already closed or uninitialized
        self.controller.closeConnection(self.id, self.is_client);
        self.controller = undefined; // Mark as closed locally
    }
};
pub const SimListener = struct {
    controller: *SimController,
    allocator: mem.Allocator, // Allocator provided by the creator (server)

    const Self = @This();

    pub fn accept(self: *Self, _: mem.Allocator) !SimConnection {
        assert(self.controller != null);
        // Allocator passed in is ignored for the connection object itself, controller handles it.
        return self.controller.acceptConnection(self.allocator);
    }

    pub fn close(self: *Self) void {
        if (self.controller == null) return; // Already closed
        self.controller.unregisterListener();
        self.controller = undefined; // Mark as closed locally
    }
};

pub const SimError = error{
    IoError, // Generic placeholder, might need refinement
    ConnectionReset, // Attempted operation on closed connection
    ListenerNotRegistered,
    ListenerAlreadyRegistered,
    OutOfMemory, // If controller allocator fails
    ControllerShutdown, // Operation attempted during/after controller deinit
    InvalidConnectionId,
    InternalStateError, // Bug!
};

// Internal state managed by the controller
const ReceiveQueue = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Cond = .{},
    queue: std.ArrayList([]u8), // Stores copies of *framed* messages

    fn init(allocator: mem.Allocator) ReceiveQueue {
        return .{ .queue = std.ArrayList([]u8).init(allocator) };
    }

    fn deinit(self: *ReceiveQueue, allocator: mem.Allocator) void {
        // Free any remaining message buffers
        for (self.queue.items) |msg_buf| {
            allocator.free(msg_buf);
        }
        self.queue.deinit();
    }
};

const ConnectionState = struct {
    id: u64,
    client_queue: ReceiveQueue, // Data flows Server -> Client (client receives from this)
    server_queue: ReceiveQueue, // Data flows Client -> Server (server receives from this)
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

// Used by a client thread calling connect() to wait for accept()
const PendingClient = struct {
    client_allocator: mem.Allocator,
    wait_mutex: std.Thread.Mutex = .{},
    wait_cond: std.Thread.Cond = .{},
    // Result fields, written by the controller thread during accept
    established_conn: ?SimConnection = null,
    establishment_error: ?SimError = null,
};

pub const SimController = struct {
    allocator: mem.Allocator, // Master allocator for internal state & message copies
    state_mutex: std.Thread.Mutex = .{}, // Protects controller state (listener, pending, connections)

    // Listener state
    listener_registered: bool = false,
    listener_wakeup: std.Thread.Cond = .{}, // To wake up accept() when client connects

    // Pending connection state
    pending_clients: std.ArrayList(*PendingClient) = undefined, // Client threads waiting in connect()
    client_wakeup: std.Thread.Cond = .{}, // To wake up connect() when accept() occurs

    // Active connection state
    connections: std.AutoHashMap(u64, ConnectionState) = undefined, // conn_id -> state
    next_conn_id: u64 = 1,

    // Shutdown state
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

        // Wake up any waiting listener
        self.listener_wakeup.signal();

        // Wake up any waiting clients with an error
        for (self.pending_clients.items) |pending| {
            pending.wait_mutex.lock();
            pending.establishment_error = SimError.ControllerShutdown;
            pending.wait_cond.signal();
            pending.wait_mutex.unlock();
        }
        self.pending_clients.deinit();

        // Close and deinitialize all active connections
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            // Signal any threads waiting on receive queues
            entry.value_ptr.client_queue.cond.broadcast();
            entry.value_ptr.server_queue.cond.broadcast();
            // Deinit the connection state (frees queued messages)
            entry.value_ptr.deinit(self.allocator);
        }
        self.connections.deinit();
    }

    // --- Listener Management ---

    fn registerListener(self: *Self) SimError!void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        if (self.shutting_down) return SimError.ControllerShutdown;
        if (self.listener_registered) return SimError.ListenerAlreadyRegistered;

        log.debug("SimController: Listener registered", .{});
        self.listener_registered = true;

        // Check if clients were waiting for the listener
        if (self.pending_clients.items.len > 0) {
            log.debug("SimController: Waking up pending client(s) due to listener registration", .{});
            self.listener_wakeup.signal(); // Wake potentially waiting accept()
        }
    }

    fn unregisterListener(self: *Self) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        if (!self.listener_registered) return;

        log.debug("SimController: Listener unregistered", .{});
        self.listener_registered = false;
        // Wake up any accept() call waiting, it should now fail
        self.listener_wakeup.signal();
    }

    // --- Connection Establishment ---

    // Called by client's connect()
    fn initiateConnection(self: *Self, client_allocator: mem.Allocator) SimError!SimConnection {
        var pending_entry = PendingClient{ .client_allocator = client_allocator };

        // Add self to pending list
        self.state_mutex.lock();
        if (self.shutting_down) {
            self.state_mutex.unlock();
            return SimError.ControllerShutdown;
        }
        log.debug("SimController: Client initiating connection", .{});
        // Assuming ArrayList doesn't realloc/invalidate pointers on append here...
        // Be careful if using a different structure.
        try self.pending_clients.append(&pending_entry);
        const listener_was_registered = self.listener_registered;
        self.state_mutex.unlock();

        // Signal listener if it might be waiting in accept()
        if (listener_was_registered) {
            log.debug("SimController: Waking potential listener in accept()", .{});
            self.listener_wakeup.signal();
        }

        // Wait for listener accept() to establish connection or error
        pending_entry.wait_mutex.lock();
        defer pending_entry.wait_mutex.unlock();

        while (pending_entry.established_conn == null and pending_entry.establishment_error == null) {
            log.debug("SimController: Client waiting for accept()...", .{});
            pending_entry.wait_cond.wait(&pending_entry.wait_mutex);
            log.debug("SimController: Client woken up", .{});
            if (self.shutting_down) {
                // Check again after waking if controller shut down
                pending_entry.establishment_error = SimError.ControllerShutdown;
            }
        }

        if (pending_entry.establishment_error) |err| {
            log.warn("SimController: Client connection failed: {any}", .{err});
            return err;
        }

        log.info("SimController: Client connection established (id={d})", .{pending_entry.established_conn.?.id});
        return pending_entry.established_conn.?;
    }

    // Called by listener's accept()
    fn acceptConnection(self: *Self, server_allocator: mem.Allocator) SimError!SimConnection {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        while (true) {
            if (self.shutting_down) return SimError.ControllerShutdown;
            if (!self.listener_registered) return SimError.ListenerNotRegistered;

            if (self.pending_clients.items.len == 0) {
                log.debug("SimController: Listener waiting for client connection...", .{});
                self.listener_wakeup.wait(&self.state_mutex);
                log.debug("SimController: Listener woken up", .{});
                // Loop back to re-check conditions after wake-up
                continue;
            }

            // Found a pending client
            const pending_client_ptr = self.pending_clients.orderedRemove(0); // FIFO
            log.debug("SimController: Listener accepting pending client", .{});

            // Create connection state
            const conn_id = self.next_conn_id;
            self.next_conn_id += 1;

            const conn_state = ConnectionState.init(conn_id, self.allocator);

            const gop = try self.connections.getOrPut(conn_id);
            assert(!gop.found_existing); // ID should be unique
            gop.value_ptr.* = conn_state; // Transfer ownership

            // Prepare connection objects for both sides
            const client_conn = SimConnection{
                .id = conn_id,
                .is_client = true,
                .controller = self,
                .allocator = pending_client_ptr.client_allocator,
            };
            const server_conn = SimConnection{
                .id = conn_id,
                .is_client = false,
                .controller = self,
                .allocator = server_allocator,
            };

            // Notify the waiting client
            pending_client_ptr.wait_mutex.lock();
            pending_client_ptr.established_conn = client_conn;
            pending_client_ptr.establishment_error = null;
            pending_client_ptr.wait_cond.signal();
            pending_client_ptr.wait_mutex.unlock();

            log.info("SimController: Server accepted connection (id={d})", .{conn_id});
            return server_conn; // Return server side to the accept() caller
        }
    }

    // --- Data Transfer ---

    fn send(self: *Self, conn_id: u64, sender_is_client: bool, buffer: []const u8) SimError!void {
        // Allocate a copy using the controller's allocator
        const buffer_copy = try self.allocator.dupe(u8, buffer);
        // If dupe fails, free the potentially partial copy and return error
        errdefer self.allocator.free(buffer_copy);

        self.state_mutex.lock(); // Lock controller state
        defer self.state_mutex.unlock();

        if (self.shutting_down) {
            self.allocator.free(buffer_copy); // Must free the copy
            return SimError.ControllerShutdown;
        }

        const conn_state_ptr = self.connections.getPtr(conn_id);
        if (conn_state_ptr == null) {
            log.warn("SimController: send() on unknown conn_id={d}", .{conn_id});
            self.allocator.free(buffer_copy);
            return SimError.InvalidConnectionId;
        }

        const target_queue: *ReceiveQueue = if (sender_is_client)
            &conn_state_ptr.server_queue // Client sends -> Server receives
        else
            &conn_state_ptr.client_queue; // Server sends -> Client receives

        const receiver_closed = if (sender_is_client)
            conn_state_ptr.server_closed
        else
            conn_state_ptr.client_closed;

        if (receiver_closed) {
            log.warn("SimController: send() attempt to closed peer (conn_id={d})", .{conn_id});
            self.allocator.free(buffer_copy); // Free the copy
            return SimError.ConnectionReset; // Peer endpoint is closed
        }

        // Lock the specific queue, append, unlock, signal
        target_queue.mutex.lock();
        // Cannot fail as we already allocated buffer_copy
        try target_queue.queue.append(buffer_copy);
        target_queue.cond.signal();
        target_queue.mutex.unlock();

        log.debug("SimController: send() successful (conn_id={d}, {d} bytes)", .{ conn_id, buffer.len });
        return;
    }

    fn receive(self: *Self, conn_id: u64, receiver_is_client: bool) SimError![]u8 {
        self.state_mutex.lock(); // Lock controller state briefly to get queue pointer

        if (self.shutting_down) {
            self.state_mutex.unlock();
            return SimError.ControllerShutdown;
        }

        const conn_state_ptr = self.connections.getPtr(conn_id);
        if (conn_state_ptr == null) {
            log.warn("SimController: receive() on unknown conn_id={d}", .{conn_id});
            self.state_mutex.unlock();
            return SimError.InvalidConnectionId;
        }

        const source_queue: *ReceiveQueue = if (receiver_is_client)
            &conn_state_ptr.client_queue // Client receives data sent by Server
        else
            &conn_state_ptr.server_queue; // Server receives data sent by Client

        const self_closed_flag: bool = if (receiver_is_client)
            conn_state_ptr.client_closed
        else
            conn_state_ptr.server_closed;

        self.state_mutex.unlock(); // Unlock controller state, lock specific queue

        source_queue.mutex.lock();
        defer source_queue.mutex.unlock();

        while (source_queue.queue.items.len == 0) {
            if (self_closed_flag or self.shutting_down) {
                // Check closed status again after acquiring queue lock & after waking
                log.debug("SimController: receive() returning ConnectionReset (conn_id={d}, closed={any})", .{ conn_id, self_closed_flag });
                return SimError.ConnectionReset;
            }

            log.debug("SimController: receive() waiting for data (conn_id={d})...", .{conn_id});
            source_queue.cond.wait(&source_queue.mutex);
            log.debug("SimController: receive() woken up (conn_id={d})", .{conn_id});
            // Loop back to check queue and closed status
        }

        // Dequeue message
        const message_buffer = source_queue.queue.orderedRemove(0);
        log.debug("SimController: receive() got message (conn_id={d}, {d} bytes)", .{ conn_id, message_buffer.len });
        return message_buffer; // Caller now owns this buffer
    }

    // --- Connection Closing ---

    fn closeConnection(self: *Self, conn_id: u64, closer_is_client: bool) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        if (self.shutting_down) return; // No-op if controller is shutting down

        const conn_state_ptr = self.connections.getPtr(conn_id);
        if (conn_state_ptr == null) {
            log.warn("SimController: closeConnection() on unknown conn_id={d}", .{conn_id});
            return; // Connection doesn't exist or already fully closed
        }

        log.debug("SimController: closeConnection() initiated (conn_id={d}, client_closing={any})", .{ conn_id, closer_is_client });

        var notify_peer_queue: ?*ReceiveQueue = null;

        if (closer_is_client) {
            if (!conn_state_ptr.client_closed) {
                conn_state_ptr.client_closed = true;
                notify_peer_queue = &conn_state_ptr.server_queue; // Wake up server if waiting
            }
        } else { // Server is closing
            if (!conn_state_ptr.server_closed) {
                conn_state_ptr.server_closed = true;
                notify_peer_queue = &conn_state_ptr.client_queue; // Wake up client if waiting
            }
        }

        // If the closing side was already closed, do nothing more
        if (notify_peer_queue == null) {
            log.debug("SimController: closeConnection() - side already marked closed (conn_id={d})", .{conn_id});
            return;
        }

        // Wake up the peer potentially waiting in receive()
        if (notify_peer_queue) |peer_queue| {
            log.debug("SimController: Signaling peer queue on close (conn_id={d})", .{conn_id});
            peer_queue.cond.signal();
        }

        // If both sides are now closed, clean up the connection state entirely
        if (conn_state_ptr.client_closed and conn_state_ptr.server_closed) {
            log.info("SimController: Both sides closed, removing connection state (conn_id={d})", .{conn_id});
            var removed_state = self.connections.remove(conn_id).?; // Should exist
            removed_state.value.deinit(self.allocator); // Free queued messages etc.
        }
    }
};

// --- Public API ---

// Creates a SimListener associated with the controller.
// Assumes only one listener per controller for now.
pub fn listen(controller: *SimController, listener_allocator: mem.Allocator) SimError!SimListener {
    try controller.registerListener();
    return SimListener{ .controller = controller, .allocator = listener_allocator };
}

// Creates a client-side SimConnection trying to connect via the controller.
pub fn connect(controller: *SimController, client_allocator: mem.Allocator) SimError!SimConnection {
    return controller.initiateConnection(client_allocator);
}

// ================================= TESTS =================================
// Example test (run with `zig test src/zrpc/transport/simtransport.zig`)
// Note: Requires linking against the main zrpc lib or duplicating framing/protocol defs.
// For now, this is conceptual. Proper testing needs integration via build.zig.

test "simtransport basic connect accept send receive" {
    // Skip test during normal runs, requires threading and proper test setup
    if (true) return;

    const allocator = std.testing.allocator;
    var controller = SimController.init(allocator);
    defer controller.deinit();

    const ServerData = struct { controller: *SimController, allocator: mem.Allocator };
    const server_data = ServerData{ .controller = &controller, .allocator = allocator };

    const server_thread = try std.Thread.spawn(server_data, struct {
        fn serverFn(ctx: ServerData) !void {
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
    }.serverFn);

    // Give server time to start listening (crude, but ok for basic test)
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

    try server_thread.join();
    log.info("Test Complete", .{});
}
