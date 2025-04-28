const std = @import("std");
const zrpc = @import("zrpc");
const stdnet = zrpc.stdnet;

const log = std.log.scoped(.client_main);

const SERVER_ADDR = "127.0.0.1";
const SERVER_PORT: u16 = 9000;

// Wrapper function to match the expected 'anyerror' signature for connect
fn connect_wrapper(alloc: std.mem.Allocator, address: std.net.Address) anyerror!stdnet.Connection {
    return stdnet.connect(alloc, address) catch |err| return err; // Coerce specific error to anyerror
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("--- Starting Zig RPC Client MVP (Generic) ---", .{});

    const ConcreteClient = zrpc.Client(stdnet.Connection);
    const address = std.net.Address.parseIp(SERVER_ADDR, SERVER_PORT) catch |err| {
        log.err("Failed to parse server address '{s}:{d}': {any}", .{ SERVER_ADDR, SERVER_PORT, err });
        return error.InvalidAddress;
    };

    var client = ConcreteClient.connect(
        allocator,
        address,
        connect_wrapper,
    ) catch |err| {
        log.err("Failed to connect: {any}", .{err});
        return;
    };
    defer client.disconnect();

    log.info("--- Test Case 1: Add(10, 32) -> Expect Success (42) ---", .{});
    const result = client.add(10, 32) catch |err| {
        log.err("Test Case 1 failed: {any}", .{err});
        std.debug.print("Test Case 1 Error: {any}\n", .{err});
        return; // Exit on failure for simplicity
    };

    log.info("Test Case 1 Result: {d}", .{result});
    std.debug.assert(result == 42);

    std.log.info("\n---------------------------------------\n", .{});

    log.info("--- Test Case 2: Add(MAX_i32, 1) -> Expect Application Error ---", .{});
    const result1 = client.add(std.math.maxInt(i32), 1) catch |err| {
        if (err == zrpc.ClientError.ResponseErrorStatus) {
            log.info("Test Case 2 correctly failed with server application error.", .{});
        } else {
            log.err("Test Case 2 failed with unexpected error: {any}", .{err});
            std.debug.print("Test Case 2 Error: Unexpected Error ({any})\n", .{err});
        }
        return;
    };
    log.err("Test Case 2 unexpectedly succeeded with result: {d}", .{result1});
    std.debug.print("Test Case 2 Error: Unexpected Success ({d})\n", .{result1});

    std.log.info("\n--- Client finished. ---", .{});
}
