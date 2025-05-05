const std = @import("std");
const framing = @import("../framing.zig");
const protocol = @import("../protocol.zig");
const errors = @import("../errors.zig");

const log = std.log.scoped(.stdnet);

pub const Connection = struct {
    stream: std.net.Stream,

    pub fn send(self: *Connection, allocator: std.mem.Allocator, buffer: []const u8) !void {
        _ = allocator;
        log.debug("stdnet.send: writing {d} bytes", .{buffer.len});
        try self.stream.writer().writeAll(buffer);
        log.debug("stdnet.send: write complete", .{});
    }

    pub fn receive(self: *Connection, allocator: std.mem.Allocator) ![]u8 {
        log.debug("stdnet.receive: reading framed message", .{});
        const buffer = try framing.read_framed_message(self.stream.reader(), allocator);
        log.debug("stdnet.receive: read {d} bytes", .{buffer.len});
        return buffer;
    }

    pub fn close(self: *Connection) void {
        log.debug("stdnet.close(connection)", .{});
        self.stream.close();
    }
};

pub const Listener = struct {
    server: std.net.Server,

    pub fn accept(self: *Listener, allocator: std.mem.Allocator) !Connection {
        _ = allocator;
        log.debug("stdnet.accept: waiting on {any}", .{self.server.listen_address});

        const server_conn = try self.server.accept();
        log.info("stdnet.accept: accepted from {any}", .{server_conn.address});
        return Connection{ .stream = server_conn.stream };
    }

    pub fn close(self: *Listener) void {
        log.debug("stdnet.close(listener) on {any}", .{self.server.listen_address});
        self.server.deinit();
    }
};

pub fn listen(address: std.net.Address, options: std.net.Address.ListenOptions) !Listener {
    log.debug("stdnet.listen: attempting on {any}", .{address});

    const server = try std.net.Address.listen(address, options);
    std.debug.assert(server.listen_address.eql(address));

    log.info("stdnet.listen: success on {any}", .{server.listen_address});
    return Listener{ .server = server };
}

pub fn connect(allocator: std.mem.Allocator, address: std.net.Address) !Connection {
    _ = allocator;
    log.debug("stdnet.connect: attempting to {any}", .{address});

    const stream = try std.net.tcpConnectToAddress(address);
    log.info("stdnet.connect: success", .{});
    return Connection{ .stream = stream };
}
