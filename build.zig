const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const block_len = b.option(
        u8,
        "block-len",
        "how many bytes to consider when predicting the next character.  " ++
            "defaults to 8.  " ++
            "note: this may affect performance.",
    ) orelse 8;

    const options = b.addOptions();
    options.addOption(u8, "block_len", block_len);

    const lsp_module = b.dependency("lsp_kit", .{}).module("lsp");

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_module },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });

    const exe = b.addExecutable(.{
        .name = "sus",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const exe_check = b.addExecutable(.{
        .name = "zls",
        .root_module = root_module,
    });

    const check = b.step("check", "Check if sus compiles");
    check.dependOn(&exe_check.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
