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
    b.step("check", "ReleaseSafe validation").dependOn(&safe_lib.step);

    // Client executable
    const client_exe = b.addExecutable(.{
        .name = "client",
        .root_source_file = b.path("src/client_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_exe.root_module.addImport("zrpc", lib);
    b.step("client", "Run client").dependOn(&b.addRunArtifact(client_exe).step);

    // Server executable
    const server_exe = b.addExecutable(.{
        .name = "server",
        .root_source_file = b.path("src/server_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_exe.root_module.addImport("zrpc", lib);
    b.step("server", "Run server").dependOn(&b.addRunArtifact(server_exe).step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("zrpc", lib);

    // Integration tests
    const integration_tests = b.addTest(.{
        .name = "integration-tests",
        .root_source_file = b.path("src/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests.root_module.addImport("zrpc", lib);
    const integration_test_step = b.addRunArtifact(integration_tests);

    // Testing Step (both unit and integration tests)
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&integration_test_step.step);
}
