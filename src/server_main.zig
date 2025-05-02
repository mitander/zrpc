const std = @import("std");
const zrpc = @import("zrpc");
const stdnet = zrpc.stdnet;

const log = std.log.scoped(.server_main);

const SERVER_ADDR = "127.0.0.1";
const SERVER_PORT: u16 = 9000;

const Server = zrpc.ServerType(stdnet.Listener, stdnet.Connection);

fn app_add(req: zrpc.protocol.AddRequest) !zrpc.protocol.AddResponse {
    log.debug("app_handler: Executing add({d}, {d})", .{ req.a, req.b });
    const result = std.math.add(i32, req.a, req.b) catch |err| {
        std.debug.assert(err == error.Overflow);
        log.warn("app_handler: Add operation overflowed: a={d}, b={d}", .{ req.a, req.b });
        return error.Overflow;
    };
    std.debug.assert(result == @as(i64, req.a) + @as(i64, req.b));
    log.debug("app_handler: Add result: {d}", .{result});
    return zrpc.protocol.AddResponse{ .result = result };
}

fn listen_wrapper(address: std.net.Address, options: std.net.Address.ListenOptions) anyerror!stdnet.Listener {
    const listener = try stdnet.listen(address, options);
    return listener;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const app_handler = zrpc.Handler{
        .add_fn = &app_add,
    };

    const address = std.net.Address.parseIp(SERVER_ADDR, SERVER_PORT) catch |err| {
        log.err("Failed to parse server address '{s}:{d}': {any}", .{ SERVER_ADDR, SERVER_PORT, err });
        return error.InvalidAddress;
    };

    log.info("=== Starting RPC Server ===", .{});
    log.info("Using transport: stdnet {s}:{d}", .{ SERVER_ADDR, SERVER_PORT });

    var server = try Server.listen(
        allocator,
        app_handler,
        address,
        .{ .reuse_address = true },
        listen_wrapper,
    );
    std.debug.assert(server.handler.add_fn == &app_add);
    defer server.shutdown();

    log.info("Server successfully listening on {any}", .{address});

    try server.run_blocking();

    log.info("=== Server main exiting normally (after run_blocking) ===", .{});
}
