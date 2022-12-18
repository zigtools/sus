const std = @import("std");
const tres = @import("tres.zig");
const builtin = @import("builtin");
const Fuzzer = @import("Fuzzer.zig");
const ChildProcess = std.ChildProcess;

const Markov = @import("modes/Markov.zig");

pub fn main() !void {
    var allocator = std.heap.page_allocator;

    const zls_path = "repos/zls/zig-out/bin/zls" ++ if (builtin.os.tag == .windows) ".exe" else "";
    const markov_input_dir = "repos/zig/lib/std";

    var fuzzer = try Fuzzer.create(allocator, zls_path);
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
