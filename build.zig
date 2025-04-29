const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module
    const lib = b.addModule("zrpc", .{
        .root_source_file = b.path("src/zrpc.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library
    const safe_lib = b.addStaticLibrary(.{
        .name = "zrpc-safe",
        .root_source_file = b.path("src/zrpc.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const opts = b.addOptions();
    opts.addOption(bool, "enable_assertions", true);
    opts.addOption(bool, "enable_logging", false);
    opts.addOption(bool, "enable_safety", true);
    safe_lib.root_module.addOptions("build_options", opts);

    // Client executable
    const client_exe = b.addExecutable(.{
        .name = "client",
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_exe.root_module.addImport("zrpc", lib);

    // Server executable
    const server_exe = b.addExecutable(.{
        .name = "server",
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_exe.root_module.addImport("zrpc", lib);

    // Testing
    const tests = b.addTest(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Steps
    b.step("client", "Run client").dependOn(&b.addRunArtifact(client_exe).step);
    b.step("server", "Run server").dependOn(&b.addRunArtifact(server_exe).step);
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
    b.step("check", "ReleaseSafe validation").dependOn(&safe_lib.step);
}
