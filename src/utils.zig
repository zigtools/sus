const std = @import("std");
const lsp = @import("lsp");

pub fn randomPosition(random: std.Random, data: []const u8) lsp.types.Position {
    // TODO: Consider offsets
    var index = random.uintAtMost(usize, data.len);
    while (index != 0 and index < data.len and !isFirstUtf8Byte(data[index])) index -= 1;
    return lsp.offsets.indexToPosition(data, index, .@"utf-16");
}

pub fn randomRange(random: std.Random, data: []const u8) lsp.types.Range {
    // TODO: Consider offsets
    var loc: lsp.offsets.Loc = .{
        .start = random.uintAtMost(usize, data.len),
        .end = random.uintAtMost(usize, data.len),
    };
    while (loc.start != 0 and loc.start < data.len and !isFirstUtf8Byte(data[loc.start])) loc.start -= 1;
    while (loc.end != 0 and loc.end < data.len and !isFirstUtf8Byte(data[loc.end])) loc.end -= 1;
    if (loc.start > loc.end) std.mem.swap(usize, &loc.start, &loc.end);

    return lsp.offsets.locToRange(data, loc, .@"utf-16");
}

fn isFirstUtf8Byte(byte: u8) bool {
    return byte & 0b11000000 != 0b10000000;
}

pub fn waitForResponseToRequest(
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    id: i64,
) !void {
    while (true) {
        const json_message = try transport.readJsonMessage(allocator);
        defer allocator.free(json_message);

        const result = try std.json.parseFromSlice(
            struct { id: ?lsp.JsonRPCMessage.ID = null },
            allocator,
            json_message,
            .{
                .ignore_unknown_fields = true,
            },
        );

        defer result.deinit();

        if (result.value.id) |received_id| {
            if (received_id == .number and received_id.number == id) {
                return;
            }
        }
    }
}

pub fn waitForResponseToRequests(
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    ids: *std.AutoArrayHashMapUnmanaged(i64, void),
) !void {
    while (ids.count() != 0) {
        const json_message = try transport.readJsonMessage(allocator);
        defer allocator.free(json_message);

        const result = try std.json.parseFromSlice(
            struct { id: ?lsp.JsonRPCMessage.ID = null },
            allocator,
            json_message,
            .{
                .ignore_unknown_fields = true,
            },
        );
        defer result.deinit();

        if (result.value.id) |received_id| {
            if (received_id != .number) continue;
            std.debug.assert(ids.swapRemove(received_id.number));
        }
    }
}
