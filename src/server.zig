const std = @import("std");
const zrpc = @import("zrpc");
const stdnet = zrpc.stdnet;

const log = std.log.scoped(.server_main);

const SERVER_ADDR = "127.0.0.1";
const SERVER_PORT: u16 = 9000;

/// Concrete implementation of the 'add' RPC method for our simple server.
fn app_add(req: zrpc.protocol.AddRequest) !zrpc.protocol.AddResponse {
    log.debug("app_handler: Executing add({d}, {d})", .{ req.a, req.b });
    const result = std.math.add(i32, req.a, req.b) catch |err| {
        std.debug.assert(err == error.Overflow);
        log.warn("app_handler: Add operation overflowed: a={d}, b={d}", .{ req.a, req.b });
        return error.Overflow;
    };
    log.debug("app_handler: Add result: {d}", .{result});
    return zrpc.protocol.AddResponse{ .result = result };
}

// Wrapper function to match the expected 'anyerror' signature
fn listen_wrapper(address: std.net.Address, options: std.net.Address.ListenOptions) anyerror!stdnet.Listener {
    const listener = stdnet.listen(address, options) catch |err| return err;
    return listener;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.info("--- Starting Zig RPC Server MVP (Generic) ---", .{});
    log.info("Using StdNetTransport on {s}:{d}", .{ SERVER_ADDR, SERVER_PORT });

    const app_handler = zrpc.Handler{
        .add_fn = &app_add,
    };

    const address = std.net.Address.parseIp(SERVER_ADDR, SERVER_PORT) catch |err| {
        log.err("Failed to parse server address '{s}:{d}': {any}", .{ SERVER_ADDR, SERVER_PORT, err });
        return error.InvalidAddress;
    };

    const ConcreteServer = zrpc.Server(stdnet.Listener, stdnet.Connection);
    var server = ConcreteServer.listen(
        allocator,
        app_handler,
        address,
        .{ .reuse_address = true },
        listen_wrapper,
    ) catch |err| {
        log.err("Failed to start server listener: {any}", .{err});
        return err;
    };
    defer server.shutdown();

    log.info("Server successfully listening on {any}", .{address});

    server.run_blocking() catch |err| {
        log.err("Server run_blocking exited with error: {any}", .{err});
        return err;
    };

    log.info("--- Server shutting down cleanly ---", .{});
}
