const std = @import("std");
const uri = @import("../uri.zig");
const lsp = @import("../lsp.zig");
const tres = @import("../tres.zig");
const utils = @import("../utils.zig");
const Fuzzer = @import("../Fuzzer.zig");

const BestBehavior = @This();

allocator: std.mem.Allocator,
fuzzer: *Fuzzer,

tests: std.ArrayListUnmanaged([]const u8),
test_contents: std.StringHashMapUnmanaged([]const u8),

pub fn init(allocator: std.mem.Allocator, fuzzer: *Fuzzer) !BestBehavior {
    var tests = std.ArrayListUnmanaged([]const u8){};
    var test_contents = std.StringHashMapUnmanaged([]const u8){};

    var itd = try std.fs.cwd().openIterableDir("repos/zig/test", .{});
    defer itd.close();

    var walker = try itd.walk(allocator);
    defer walker.deinit();

    // TODO: Arena

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    // var lim: usize = 0;
    while (try walker.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        // lim += 1;

        // TODO: Fix this
        // if (lim > 100) break;

        std.log.info("Found test {s}", .{entry.path});

        var file = try entry.dir.openFile(entry.basename, .{});
        defer file.close();

        var data = try allocator.alloc(u8, (try file.stat()).size);
        _ = try file.readAll(data);

        const pj = try std.fs.path.join(allocator, &.{ cwd, "repos", "zig", "test", entry.path });
        defer allocator.free(pj);

        const file_uri = try uri.fromPath(allocator, pj);
        try tests.append(allocator, file_uri);
        try test_contents.put(allocator, file_uri, data);

        try fuzzer.writeJson(.{
            .jsonrpc = "2.0",
            .method = "textDocument/didOpen",
            .params = lsp.DidOpenTextDocumentParams{
                .textDocument = .{
                    .uri = file_uri,
                    .languageId = "zig",
                    .version = 0,
                    .text = data,
                },
            },
        });
    }

    return .{
        .allocator = allocator,
        .fuzzer = fuzzer,
        .tests = tests,
        .test_contents = test_contents,
    };
}

pub fn fuzz(bb: *BestBehavior, arena: std.mem.Allocator) !void {
    _ = arena;

    var fuzzer = bb.fuzzer;
    const random = fuzzer.random();

    var file_uri = bb.tests.items[random.intRangeLessThan(usize, 0, bb.tests.items.len)];
    var file_data = bb.test_contents.get(file_uri).?;

    try bb.fuzzer.fuzzFeatureRandom(file_uri, file_data);
}
