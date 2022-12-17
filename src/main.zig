const std = @import("std");
const tres = @import("tres.zig");
const Fuzzer = @import("Fuzzer.zig");
const ChildProcess = std.ChildProcess;

const Markov = @import("modes/Markov.zig");
// const ColdGarbo = @import("modes/ColdGarbo.zig");
// const BestBehavior = @import("modes/BestBehavior.zig");

pub const FuzzKind = enum {
    /// Just absolutely random body data (valid header)
    hot_garbo,
    /// Absolutely random JSON-RPC LSP data
    cold_garbo,
    /// Zig behavior tests
    best_behavior,
    /// Zig behavior tests w/ random by valid syntax mutations
    worst_behavior,
    markov,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (std.mem.indexOfScalar(usize, &.{ 3, 4 }, args.len) == null) {
        std.log.err("buzz <zls executable path> <fuzz kind: cold_garbo> <?markov input dir>", .{});
        return;
    }

    const zls_path = args[1];
    const fuzz_kind = std.meta.stringToEnum(FuzzKind, args[2]) orelse {
        std.log.err("Invalid fuzz kind!", .{});
        return;
    };
    var markov_input_dir: []const u8 = "sus directory name";
    if (fuzz_kind == .markov) {
        if (args.len != 4) {
            std.log.err("Missing markov input dir!", .{});
            return;
        } else markov_input_dir = args[3];
    }

    var fuzzer = try Fuzzer.create(allocator, zls_path);
    defer fuzzer.deinit();

    try fuzzer.initCycle();

    switch (fuzz_kind) {
        inline else => |a| {
            const T = switch (a) {
                // .cold_garbo => ColdGarbo,
                // .best_behavior => BestBehavior,
                .markov => Markov,
                else => @panic("bruh"),
            };

            var mode = try T.init(allocator, fuzzer, markov_input_dir);

            while (true) {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();

                try mode.fuzz(arena.allocator());
            }
        },
    }
}
