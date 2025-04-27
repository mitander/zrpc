const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zrpc library
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/zrpc.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addIncludePath(.{ .src_path = .{ .owner = b, .sub_path = "src" } });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zrpc",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // client executable
    const client_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/client_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_exe_mod.addImport("zrpc_lib", lib_mod);
    client_exe_mod.addIncludePath(.{ .src_path = .{ .owner = b, .sub_path = "src" } });
    const client_exe = b.addExecutable(.{
        .name = "zrpc-client",
        .root_module = client_exe_mod,
    });
    b.installArtifact(client_exe);

    const client_run_cmd = b.addRunArtifact(client_exe);
    client_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        client_run_cmd.addArgs(args);
    }
    const client_run_step = b.step("run-client", "Run the client");
    client_run_step.dependOn(&client_run_cmd.step);

    // server executable
    const server_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/server_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_exe_mod.addImport("zrpc_lib", lib_mod);
    server_exe_mod.addIncludePath(.{ .src_path = .{ .owner = b, .sub_path = "src" } });
    const server_exe = b.addExecutable(.{
        .name = "zrpc-server",
        .root_module = server_exe_mod,
    });
    b.installArtifact(server_exe);

    const server_run_cmd = b.addRunArtifact(server_exe);
    server_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        server_run_cmd.addArgs(args);
    }
    const server_run_step = b.step("run-server", "Run the server");
    server_run_step.dependOn(&server_run_cmd.step);

    // tests
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
