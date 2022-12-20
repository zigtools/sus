const std = @import("std");
const tres = @import("tres.zig");
const builtin = @import("builtin");
const Fuzzer = @import("Fuzzer.zig");
const ChildProcess = std.ChildProcess;

const Markov = @import("modes/Markov.zig");

pub const log_level = std.log.Level.info;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@enumToInt(level) > @enumToInt(log_level)) return;

    const level_txt = comptime level.asText();

    std.debug.print("{d} | {s}: ({s}): ", .{ std.time.milliTimestamp(), level_txt, @tagName(scope) });
    std.debug.print(format ++ "\n", args);
}

pub fn main() !void {
    var allocator = std.heap.page_allocator;

    // const zls_path = "repos/old_zlses/zls.exe";
    const zls_path = "repos/zls/zig-out/bin/zls" ++ if (builtin.os.tag == .windows) ".exe" else "";
    const markov_input_dir = "repos/zig/lib/std";

    const zig_version = std.fmt.comptimePrint("{any}", .{builtin.zig_version});

    const vers = try ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &.{ zls_path, "--version" },
    });
    defer allocator.free(vers.stdout);
    defer allocator.free(vers.stderr);

    const zls_version = vers.stdout;

    std.log.info("Running with Zig version {s} and zls version {s}", .{ zig_version, zls_version });

    var fuzzer = try Fuzzer.create(
        allocator,
        zls_path,
        zig_version,
        zls_version,
    );
    try fuzzer.initCycle();
    var markov = try Markov.init(allocator, fuzzer, markov_input_dir);

    try std.fs.cwd().makePath("saved_logs");

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        markov.fuzz(arena.allocator()) catch {
            std.log.info("Restarting fuzzer...", .{});
            markov.cycle = 0;
            fuzzer.kill();

            var buf: [512]u8 = undefined;
            const sub = try std.fmt.bufPrint(&buf, "saved_logs/logs-{d}", .{std.time.milliTimestamp()});
            try std.fs.cwd().rename("logs", sub);

            try fuzzer.reset(zls_path);
            try fuzzer.initCycle();
            try markov.openPrincipal();
        };
    }
}
