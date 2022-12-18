const std = @import("std");
const tres = @import("tres.zig");
const builtin = @import("builtin");
const Fuzzer = @import("Fuzzer.zig");
const ChildProcess = std.ChildProcess;

const Markov = @import("modes/Markov.zig");

pub fn main() !void {
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // var allocator = gpa.allocator();
    // defer _ = gpa.deinit();
    var allocator = std.heap.c_allocator;

    // const zls_path = "repos/zls/zig-out/bin/zls" ++ if (builtin.os.tag == .windows) ".exe" else "";
    const zls_path = "repos/old_zlses/zls.exe";
    const markov_input_dir = "repos/zig/lib/std";
    // const markov_input_dir = "repos/zig/test/behavior";

    var fuzzer = try Fuzzer.create(allocator, zls_path);
    try fuzzer.initCycle();
    var markov = try Markov.init(allocator, fuzzer, markov_input_dir);

    // var saved_logs = try std.fs.cwd().makeOpenPath("saved_logs", .{});
    // defer saved_logs.close();
    try std.fs.cwd().makePath("saved_logs");

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        markov.fuzz(arena.allocator()) catch {
            std.log.info("Restarting fuzzer...", .{});
            fuzzer.deinit();
            markov.cycle = 0;

            var buf: [512]u8 = undefined;
            const sub = try std.fmt.bufPrint(&buf, "saved_logs/logs-{d}", .{std.time.milliTimestamp()});
            try std.fs.cwd().rename("logs", sub);

            fuzzer = try Fuzzer.create(allocator, zls_path);
            try fuzzer.initCycle();
            markov.fuzzer = fuzzer;
        };
    }
}
