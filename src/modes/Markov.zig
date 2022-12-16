const std = @import("std");
const uri = @import("../uri.zig");
const lsp = @import("../lsp.zig");
const tres = @import("../tres.zig");
const utils = @import("../utils.zig");
const markov = @import("../markov.zig");
const Fuzzer = @import("../Fuzzer.zig");

const Markov = @This();

const MarkovModel = markov.Model(8, false);

allocator: std.mem.Allocator,
fuzzer: *Fuzzer,
model: MarkovModel,

pub fn init(allocator: std.mem.Allocator, fuzzer: *Fuzzer) !Markov {
    var itd = try std.fs.cwd().openIterableDir("repos/zig/test", .{});
    defer itd.close();

    var walker = try itd.walk(allocator);
    defer walker.deinit();

    // TODO: Arena

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    var model = MarkovModel.init(allocator, fuzzer.random());

    var read_buf = std.ArrayListUnmanaged(u8){};
    defer read_buf.deinit(allocator);

    while (try walker.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        var file = try entry.dir.openFile(entry.basename, .{});
        defer file.close();

        const size = (try file.stat()).size;
        try read_buf.ensureTotalCapacity(allocator, size);
        read_buf.items.len = size;
        _ = try file.readAll(read_buf.items);

        try model.feed(read_buf.items);
    }

    model.prep();

    var i: usize = 0;
    var uri_buf: [16]u8 = undefined;

    while (i < 500) : (i += 1) {
        const pj = try std.fs.path.join(allocator, &.{ cwd, "staging", "markov", try std.fmt.bufPrint(&uri_buf, "{d}.zig", .{i}) });
        defer allocator.free(pj);

        // (try std.fs.createFileAbsolute(pj, .{})).close();

        read_buf.items.len = 0;
        try model.gen(read_buf.writer(allocator), .{
            .maxlen = 1024 * 4,
        });

        try std.fs.cwd().writeFile(pj, read_buf.items);

        const f_uri = try uri.fromPath(allocator, pj);
        defer allocator.free(f_uri);

        try fuzzer.open(f_uri, read_buf.items);
    }

    return .{
        .allocator = allocator,
        .fuzzer = fuzzer,
        .model = model,
    };
}

pub fn fuzz(mm: *Markov, arena: std.mem.Allocator) !void {
    _ = mm;
    _ = arena;
}
