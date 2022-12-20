const std = @import("std");
const uri = @import("../uri.zig");
const lsp = @import("../lsp.zig");
const tres = @import("../tres.zig");
const utils = @import("../utils.zig");
const markov = @import("../markov.zig");
const Fuzzer = @import("../Fuzzer.zig");
const build_options = @import("build_options");

const Markov = @This();

const MarkovModel = markov.Model(build_options.block_len, false);

allocator: std.mem.Allocator,
fuzzer: *Fuzzer,

model_allocator: std.heap.ArenaAllocator,
model: MarkovModel,

file: std.fs.File,
file_uri: []const u8,
file_buf: std.ArrayListUnmanaged(u8),

cycle: usize = 0,

pub fn init(allocator: std.mem.Allocator, fuzzer: *Fuzzer) !Markov {
    std.debug.assert(fuzzer.args.base == .markov);
    var itd = try std.fs.cwd().openIterableDir(fuzzer.args.base.markov.training_dir, .{});
    defer itd.close();

    var walker = try itd.walk(allocator);
    defer walker.deinit();

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    var model_allocator = std.heap.ArenaAllocator.init(allocator);
    var model = MarkovModel.init(model_allocator.allocator(), fuzzer.random());

    var file_buf = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 1024 * 1024);

    while (try walker.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        var file = try entry.dir.openFile(entry.basename, .{});
        defer file.close();

        const size = (try file.stat()).size;
        try file_buf.ensureTotalCapacity(allocator, size);
        file_buf.items.len = size;

        _ = try file.readAll(file_buf.items);

        try model.feed(file_buf.items);
    }

    model.prep();

    const pj = try std.fs.path.join(allocator, &.{ cwd, "staging", "markov", "principal.zig" });
    defer allocator.free(pj);

    file_buf.items.len = 0;
    try model.gen(file_buf.writer(allocator), .{
        .maxlen = fuzzer.args.base.markov.maxlen,
    });

    var file = try std.fs.cwd().createFile(pj, .{});
    _ = try file.writeAll(file_buf.items);

    const file_uri = try uri.fromPath(allocator, pj);

    try fuzzer.open(file_uri, file_buf.items);

    return .{
        .allocator = allocator,
        .fuzzer = fuzzer,

        .model_allocator = model_allocator,
        .model = model,

        .file = file,
        .file_uri = file_uri,
        .file_buf = file_buf,
    };
}

pub fn openPrincipal(mm: *Markov) !void {
    mm.file_buf.items.len = 0;
    try mm.model.gen(mm.file_buf.writer(mm.allocator), .{
        .maxlen = mm.fuzzer.args.base.markov.maxlen,
    });
    try mm.file.seekTo(0);
    try mm.file.setEndPos(0);
    _ = try mm.file.writeAll(mm.file_buf.items);
    try mm.fuzzer.open(mm.file_uri, mm.file_buf.items);
}

pub fn fuzz(mm: *Markov, arena: std.mem.Allocator) !void {
    try mm.fuzzer.fuzzFeatureRandom(arena, mm.file_uri, mm.file_buf.items);

    if (mm.cycle == mm.fuzzer.args.base.markov.cycles_per_gen) {
        // std.log.info("Regenerating file...", .{});

        mm.file_buf.items.len = 0;
        try mm.model.gen(mm.file_buf.writer(mm.allocator), .{
            .maxlen = mm.fuzzer.args.base.markov.maxlen,
        });
        try mm.file.seekTo(0);
        try mm.file.setEndPos(0);
        _ = try mm.file.writeAll(mm.file_buf.items);

        try mm.fuzzer.change(mm.file_uri, mm.file_buf.items);

        mm.cycle = 0;
    }

    mm.cycle += 1;
}

pub fn deinit(mm: *Markov) void {
    mm.file.close();
    mm.file_buf.deinit(mm.allocator);
    mm.allocator.free(mm.file_uri);
    mm.model_allocator.deinit();
}
