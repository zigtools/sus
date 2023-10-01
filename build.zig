const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const zig_lsp = b.dependency("zig-lsp", .{}).module("zig-lsp");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fuzzer

    const exe = b.addExecutable(.{
        .name = "sus",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("zig-lsp", zig_lsp);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const block_len = b.option(
        u8,
        "block-len",
        "how many bytes to consider when predicting the next character.  " ++
            "defaults to 8.  " ++
            "note: this may affect performance.",
    ) orelse 8;
    const options = b.addOptions();
    options.addOption(u8, "block_len", block_len);
    exe.addOptions("build_options", options);

    // Server

    const server_exe = b.addExecutable(.{
        .name = "sus-server",
        .root_source_file = .{ .path = "server/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(server_exe);

    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });

    server_exe.addModule("sqlite", sqlite.module("sqlite"));
    server_exe.linkLibrary(sqlite.artifact("sqlite"));

    const run_server_cmd = b.addRunArtifact(server_exe);
    run_server_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_server_cmd.addArgs(args);
    }

    const run_server_step = b.step("run-server", "Run the app");
    run_server_step.dependOn(&run_server_cmd.step);

    const server_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "server/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    server_unit_tests.addModule("sqlite", sqlite.module("sqlite"));
    server_unit_tests.linkLibrary(sqlite.artifact("sqlite"));

    const run_server_unit_tests = b.addRunArtifact(server_unit_tests);

    const test_server_step = b.step("test-server", "Run server unit tests");
    test_server_step.dependOn(&run_server_unit_tests.step);
}
