const std = @import("std");
const tres = @import("tres");
const lsp = @import("zig-lsp");
const utils = @import("utils.zig");
const binary = @import("binary.zig");
const lsp_types = lsp.types;

pub fn help() void {
    std.debug.print(
        \\ decomp [log|json] [path]
    , .{});
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (argv.len != 3) {
        help();
        return;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);

    const path = argv[2];

    var in_file = try std.fs.cwd().openFile(path, .{});
    defer in_file.close();

    var out_file = try std.fs.cwd().createFile(try std.fmt.allocPrint(arena.allocator(), "d_{s}", .{std.fs.path.basename(path)}), .{});
    defer out_file.close();

    var of_buffered = std.io.bufferedWriter(out_file.writer());

    var decomp = try std.compress.deflate.decompressor(arena.allocator(), in_file.reader(), null);

    if (std.mem.eql(u8, argv[1], "log")) {
        var lf = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
        try lf.pump(decomp.reader(), out_file.writer());
    } else if (std.mem.eql(u8, argv[1], "json")) {
        a: while (true) {
            var decomp_res = binary.decode(arena.allocator(), struct { id: ?lsp_types.RequestId, kind: lsp.MessageKind, method: []const u8 }, decomp.reader()) catch |err| switch (err) {
                error.EndOfStream => break :a,
                else => return err,
            };

            inline for (lsp_types.notification_metadata) |notif| {
                if (std.mem.eql(u8, decomp_res.method, notif.method)) {
                    if (decomp_res.kind != .notification) @panic("invalid");
                    var decomp2 = try binary.decode(arena.allocator(), notif.Params orelse void, decomp.reader());
                    try tres.stringify(.{
                        .jsonrpc = "2.0",
                        .method = decomp_res.method,
                        .params = decomp2,
                    }, .{}, of_buffered.writer());
                    try of_buffered.writer().writeByte('\n');
                    continue :a;
                }
            }

            inline for (lsp_types.request_metadata) |req| {
                if (std.mem.eql(u8, decomp_res.method, req.method)) {
                    switch (decomp_res.kind) {
                        .request => {
                            @setEvalBranchQuota(10000);
                            var decomp2 = try binary.decode(arena.allocator(), req.Params orelse void, decomp.reader());
                            try tres.stringify(.{
                                .jsonrpc = "2.0",
                                .id = decomp_res.id.?,
                                .method = decomp_res.method,
                                .params = decomp2,
                            }, .{}, of_buffered.writer());
                            try of_buffered.writer().writeByte('\n');
                            continue :a;
                        },
                        .response => {
                            @setEvalBranchQuota(10000);
                            var decomp2 = try binary.decode(arena.allocator(), req.Result, decomp.reader());
                            try tres.stringify(.{
                                .jsonrpc = "2.0",
                                .id = decomp_res.id.?,
                                .result = decomp2,
                            }, .{}, of_buffered.writer());
                            try of_buffered.writer().writeByte('\n');
                            continue :a;
                        },
                        else => @panic("invalid"),
                    }
                    return;
                }
            }
        }

        try of_buffered.flush();
    } else {
        help();
    }
}
