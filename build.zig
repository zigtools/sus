const std = @import("std");

pub fn build(b: *std.Build) void {
    const zig_lsp = b.dependency("zig-lsp", .{}).module("zig-lsp");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "sus",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zig-lsp", zig_lsp);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const build_exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = .Debug,
    });
    const run_exe_tests = b.addRunArtifact(build_exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);

    const block_len = b.option(
        u8,
        "block-len",
        "how many bytes to consider when predicting the next character.  " ++
            "defaults to 8.  " ++
            "note: this may affect performance.",
    ) orelse 8;
    const options = b.addOptions();
    options.addOption(u8, "block_len", block_len);
    exe.root_module.addOptions("build_options", options);
}
