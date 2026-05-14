const std = @import("std");

const BestBehavior = @This();

tests: std.ArrayList([]const u8),

const usage =
    \\Usage best behavior Mode:
    \\     --source-dir   - directory to be used for fuzzing. searched for .zig files recursively.
    \\
;

fn fatalWithUsage(comptime format: []const u8, args: anytype) noreturn {
    const stderr = std.debug.lockStderr(&.{}).terminal();
    defer std.debug.unlockStderr();
    stderr.writer.writeAll(usage) catch {};
    std.log.err(format, args);
    std.process.exit(1);
}

const fatal = std.process.fatal;

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    progress: std.Progress.Node,
    arg_it: *std.process.Args.Iterator,
    envmap: *const std.process.Environ.Map,
) !*BestBehavior {
    var bb = try allocator.create(BestBehavior);
    errdefer allocator.destroy(bb);

    bb.* = .{
        .tests = .empty,
    };
    errdefer bb.deinit(allocator);

    var source_dir: ?[]const u8 = envmap.get("best_behavior_source_dir");

    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(io, usage);
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

    std.debug.print(
        \\
        \\source-dir:     {s}
        \\
        \\
    , .{source_dir.?});

    var progress_node = progress.start("best behavior: loading files", 0);
    defer progress_node.end();

    var iterable_dir = try std.Io.Dir.cwd().openDir(io, source_dir.?, .{ .iterate = true });
    defer iterable_dir.close(io);

    {
        var walker = try iterable_dir.walk(allocator);
        defer walker.deinit();
        var file_count: usize = 0;
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.eql(u8, std.Io.Dir.path.extension(entry.basename), ".zig")) continue;
            file_count += 1;
            progress_node.setEstimatedTotalItems(file_count);
        }
    }

    var walker = try iterable_dir.walk(allocator);
    defer walker.deinit();

    var file_buf: std.ArrayList(u8) = .empty;
    defer file_buf.deinit(allocator);

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.Io.Dir.path.extension(entry.basename), ".zig")) continue;

        const node = progress_node.start(entry.basename, 0);
        defer node.end();

        var file = try entry.dir.openFile(io, entry.basename, .{});
        defer file.close(io);

        const size = std.math.cast(usize, try file.length(io)) orelse return error.FileTooBig;
        try file_buf.ensureTotalCapacity(allocator, size);
        file_buf.items.len = size;
        var reader = file.reader(io, &.{});
        try reader.interface.readSliceAll(file_buf.items);

        try bb.tests.ensureUnusedCapacity(allocator, 1);
        bb.tests.appendAssumeCapacity(try file_buf.toOwnedSlice(allocator));
    }

    return bb;
}

pub fn deinit(bb: *BestBehavior, allocator: std.mem.Allocator) void {
    for (bb.tests.items) |file_content| {
        allocator.free(file_content);
    }
    bb.tests.deinit(allocator);
}

pub fn gen(bb: *BestBehavior, allocator: std.mem.Allocator, random: std.Random) error{OutOfMemory}![]const u8 {
    const index = random.intRangeLessThan(usize, 0, bb.tests.items.len);
    const file_content = bb.tests.items[index];

    return try allocator.dupe(u8, file_content);
}
