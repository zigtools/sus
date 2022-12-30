const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("sus", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const tres = std.build.Pkg{
        .name = "tres",
        .source = .{ .path = "libs/zig-lsp/libs/tres/tres.zig" },
    };

    const zig_lsp = std.build.Pkg{
        .name = "zig-lsp",
        .source = .{ .path = "libs/zig-lsp/src/zig_lsp.zig" },
        .dependencies = &.{tres},
    };

    exe.addPackage(tres);
    exe.addPackage(zig_lsp);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Log decompressor

    const exe_decomp = b.addExecutable("decomp", "src/decompressor.zig");
    exe_decomp.setTarget(target);
    exe_decomp.setBuildMode(mode);
    exe_decomp.install();

    exe_decomp.addPackage(tres);
    exe_decomp.addPackage(zig_lsp);

    const run_cmd_decomp = exe_decomp.run();
    run_cmd_decomp.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd_decomp.addArgs(args);
    }

    const run_step_decomp = b.step("decomp", "Run the app");
    run_step_decomp.dependOn(&run_cmd_decomp.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);

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
}
