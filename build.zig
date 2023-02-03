const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "sus",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
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

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = .Debug,
    });

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
