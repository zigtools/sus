const std = @import("std");
const lsp = @import("../lsp.zig");
const tres = @import("../tres.zig");
const utils = @import("../utils.zig");
const Fuzzer = @import("../Fuzzer.zig");

const ColdGarbo = @This();

allocator: std.mem.Allocator,
fuzzer: *Fuzzer,

pub fn init(allocator: std.mem.Allocator, fuzzer: *Fuzzer) !ColdGarbo {
    return .{
        .allocator = allocator,
        .fuzzer = fuzzer,
    };
}

pub fn fuzz(cg: *ColdGarbo, arena: std.mem.Allocator) !void {
    var fuzzer = cg.fuzzer;
    const random = cg.fuzzer.random();

    const selection_notif = random.intRangeLessThan(usize, 0, lsp.notification_metadata.len);

    inline for (lsp.notification_metadata) |notif, index| {
        if (index == selection_notif and !std.mem.eql(u8, notif.method, "exit")) {
            const rz = try utils.randomize(notif.Params orelse void, arena, random);
            // std.log.info("Sending {s}...", .{notif.method});
            try fuzzer.writeJson(.{
                .jsonrpc = "2.0",
                .method = notif.method,
                .params = rz,
            });
        }
    }

    const selection_req = random.intRangeLessThan(usize, 0, lsp.notification_metadata.len);

    inline for (lsp.request_metadata) |req, index| {
        if (index == selection_req) {
            const rz = try utils.randomize(req.Params orelse void, arena, random);
            // std.log.info("Sending {s}...", .{notif.method});
            try fuzzer.writeJson(.{
                .jsonrpc = "2.0",
                .id = fuzzer.id,
                .method = req.method,
                .params = rz,
            });
            fuzzer.id += 1;
        }
    }
}
