const std = @import("std");
const lsp = @import("../lsp.zig");
const tres = @import("../tres.zig");
const Fuzzer = @import("../Fuzzer.zig");

const BestBehavior = @This();

allocator: std.mem.Allocator,
fuzzer: *Fuzzer,
tests: std.ArrayListUnmanaged([]const u8),

pub fn init(allocator: std.mem.Allocator, fuzzer: *Fuzzer) !BestBehavior {
    var tests = std.ArrayListUnmanaged([]const u8){};

    var itd = try std.fs.cwd().openIterableDir("repos/zig/test", .{});
    defer itd.close();

    var walker = try itd.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        std.log.info("Found test {s}", .{entry.path});
        try tests.append(allocator, entry.path);
    }

    return .{
        .allocator = allocator,
        .fuzzer = fuzzer,
        .tests = tests,
    };
}

pub fn fuzz(bb: *BestBehavior, arena: std.mem.Allocator) !void {
    _ = bb;
    _ = arena;
}
