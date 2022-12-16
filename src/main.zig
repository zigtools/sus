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

    if (args.len != 3) {
        std.log.err("buzz <zls executable path> <fuzz kind: cold_garbo>", .{});
        return;
    }

    const zls_path = args[1];
    const fuzz_kind = std.meta.stringToEnum(FuzzKind, args[2]) orelse {
        std.log.err("Invalid fuzz kind!", .{});
        return;
    };

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

            var mode = try T.init(allocator, fuzzer);

            while (true) {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();

                try mode.fuzz(arena.allocator());
            }
        },
    }
}
