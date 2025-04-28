const std = @import("std");
const framing = @import("../framing.zig"); // For read_framed_message
const protocol = @import("../protocol.zig"); // For framing hint

const log = std.log.scoped(.stdnet);

// Expose errors from underlying std.net calls directly where appropriate
pub const SendError = std.posix.WriteError;
pub const ReceiveError = framing.FramingError; // Framing handles read errors
pub const AcceptError = std.posix.AcceptError;
pub const ConnectError = std.net.TcpConnectToAddressError;
pub const ListenError = std.net.Address.ListenError;

/// Wrapper around an accepted std.net.Stream connection
pub const Connection = struct {
    stream: std.net.Stream,

    pub const Self = @This();

    /// Sends a pre-framed message buffer.
    pub fn send(self: *const Self, allocator: std.mem.Allocator, buffer: []const u8) !SendError!void {
        _ = allocator;
        log.debug("stdnet.send: writing {d} bytes", .{buffer.len});
        try self.stream.writer().writeAll(buffer);
        log.debug("stdnet.send: write complete", .{});
    }

    /// Receives one framed message, allocating a buffer. Caller owns the buffer.
    pub fn receive(self: *Self, allocator: std.mem.Allocator) !ReceiveError![]u8 {
        log.debug("stdnet.receive: reading framed message", .{});
        const buffer = try framing.read_framed_message(self.stream.reader(), allocator);
        log.debug("stdnet.receive: read {d} bytes", .{buffer.len});
        return buffer;
    }

    /// Closes the underlying stream.
    pub fn close(self: *Self) void {
        log.debug("stdnet.close(connection)", .{});
        self.stream.close();
    }
};

/// Wrapper around a listening std.net.Server
pub const Listener = struct {
    server: std.net.Server,

    pub const Self = @This();

    /// Accepts a new connection.
    pub fn accept(self: *Self, allocator: std.mem.Allocator) !AcceptError!Connection {
        _ = allocator;
        log.debug("stdnet.accept: waiting on {any}", .{self.server.listen_address});
        const server_conn = try self.server.accept(); // Returns std.net.Server.Connection
        log.info("stdnet.accept: accepted from {any}", .{server_conn.address});
        return Connection{ .stream = server_conn.stream };
    }

    /// Closes the listening socket.
    pub fn close(self: *Self) void {
        log.debug("stdnet.close(listener) on {any}", .{self.server.listen_address});
        self.server.deinit();
    }
};

/// Creates a Listener by calling std.net.Address.listen
pub fn listen(address: std.net.Address, options: std.net.Address.ListenOptions) !ListenError!Listener {
    log.debug("stdnet.listen: attempting on {any}", .{address});
    const server = try std.net.Address.listen(address, options);
    log.info("stdnet.listen: success on {any}", .{server.listen_address});
    return Listener{ .server = server };
}

/// Creates a Connection by calling std.net.tcpConnectToAddress
pub fn connect(allocator: std.mem.Allocator, address: std.net.Address) !ConnectError!Connection {
    _ = allocator;
    log.debug("stdnet.connect: attempting to {any}", .{address});
    const stream = try std.net.tcpConnectToAddress(address);
    log.info("stdnet.connect: success", .{});
    return Connection{ .stream = stream };
}
