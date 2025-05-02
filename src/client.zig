const std = @import("std");
const zrpc = @import("zrpc");
const stdnet = zrpc.stdnet;

const log = std.log.scoped(.client_main);

const ClientError = zrpc.errors.ClientError;

const SERVER_ADDR = "127.0.0.1";
const SERVER_PORT: u16 = 9000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.info("=== Starting RPC Client ===", .{});

    const address = std.net.Address.parseIp(SERVER_ADDR, SERVER_PORT) catch |err| {
        log.err("Failed to parse server address '{s}:{d}': {any}", .{ SERVER_ADDR, SERVER_PORT, err });
        return error.InvalidAddress;
    };

    var client = zrpc.Client(stdnet.Connection).connect(
        allocator,
        address,
        stdnet.connect,
    ) catch |err| {
        log.err("Failed to connect: {any}", .{err});
        return;
    };
    defer client.disconnect();

    log.info("=== Add(10, 32) -> Expect Success (42) ===", .{});
    const test_success = client.add(10, 32) catch |err| {
        log.err("Test Case 1 failed: {any}", .{err});
        return;
    };

    log.info("Result: {any}", .{test_success});
    std.debug.assert(test_success == 42);

    log.info("\n === Add(MAX_i32, 1) -> Expect Application Error ===", .{});
    const result_error = client.add(std.math.maxInt(i32), 1) catch |err| {
        // This test should fail.
        if (err == zrpc.errors.ClientError.ResponseErrorStatus) {
            log.info("Test Case 2 correctly failed with server application error.", .{});
        } else {
            log.err("Test Case 2 failed with unexpected error: {any}", .{err});
        }
        return;
    };

    log.err("Test Case 2 unexpectedly succeeded with result: {d}", .{result_error});
    log.info("=== Exited RPC Client ===", .{});
}
