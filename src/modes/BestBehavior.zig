const std = @import("std");
const utils = @import("../utils.zig");

const BestBehavior = @This();

random: std.rand.DefaultPrng,
tests: std.ArrayListUnmanaged([]const u8),

const usage =
    \\Usage best behavior Mode:
    \\     --source-dir   - directory to be used for fuzzing. searched for .zig files recursively.
;

fn fatalWithUsage(comptime format: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writeAll(usage) catch {};
    std.log.err(format, args);
    std.process.exit(1);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.process.exit(1);
}

pub fn init(
    allocator: std.mem.Allocator,
    progress: *std.Progress,
    arg_it: *std.process.ArgIterator,
    envmap: std.process.EnvMap,
) !*BestBehavior {
    var bb = try allocator.create(BestBehavior);
    errdefer allocator.destroy(bb);

    var seed: u64 = 0;
    try std.os.getrandom(std.mem.asBytes(&seed));

    bb.* = .{
        .random = std.rand.DefaultPrng.init(seed),
        .tests = .{},
    };
    errdefer bb.deinit(allocator);

    var source_dir: ?[]const u8 = envmap.get("best_behavior_source_dir");

    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            try std.io.getStdOut().writeAll(usage);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--source-dir")) {
            source_dir = arg_it.next() orelse fatalWithUsage("expected directory path after --source-dir", .{});
        } else {
            fatalWithUsage("invalid best_behavior arg '{s}'", .{arg});
        }
    }

    // make sure required args weren't skipped
    if (source_dir == null or source_dir.?.len == 0) {
        fatalWithUsage("missing mode argument '--source-dir'", .{});
    }

    progress.log(
        \\
        \\source-dir:     {s}
        \\
        \\
    , .{source_dir.?});

    var progress_node = progress.start("best behavior: loading files", 0);
    defer progress_node.end();

    var iterable_dir = try std.fs.cwd().openDir(source_dir.?, .{ .iterate = true });
    defer iterable_dir.close();

    {
        var walker = try iterable_dir.walk(allocator);
        defer walker.deinit();
        var file_count: usize = 0;
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.eql(u8, std.fs.path.extension(entry.basename), ".zig")) continue;
            file_count += 1;
            progress_node.setEstimatedTotalItems(file_count);
        }
    }

    var walker = try iterable_dir.walk(allocator);
    defer walker.deinit();

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    var file_buf = std.ArrayListUnmanaged(u8){};
    defer file_buf.deinit(allocator);

    progress_node.activate();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.extension(entry.basename), ".zig")) continue;

        // std.log.info("found file {s}", .{entry.path});

        var file = try entry.dir.openFile(entry.basename, .{});
        defer file.close();

        const size = std.math.cast(usize, try file.getEndPos()) orelse return error.FileTooBig;
        try file_buf.ensureTotalCapacity(allocator, size);
        file_buf.items.len = size;
        _ = try file.readAll(file_buf.items);

        try bb.tests.ensureUnusedCapacity(allocator, 1);
        bb.tests.appendAssumeCapacity(try file_buf.toOwnedSlice(allocator));

        progress_node.completeOne();
    }

    return bb;
}

pub fn deinit(bb: *BestBehavior, allocator: std.mem.Allocator) void {
    for (bb.tests.items) |file_content| {
        allocator.free(file_content);
    }
    bb.tests.deinit(allocator);
}

pub fn gen(bb: *BestBehavior, allocator: std.mem.Allocator) ![]const u8 {
    const random = bb.random.random();

    const index = random.intRangeLessThan(usize, 0, bb.tests.items.len);
    const file_content = bb.tests.items[index];

    return try allocator.dupe(u8, file_content);
}
