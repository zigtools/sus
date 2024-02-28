const std = @import("std");
const lsp = @import("lsp.zig");
const Header = @import("Header.zig");

/// Use after `isArrayList` and/or `isHashMap`
pub fn isManaged(comptime T: type) bool {
    return @hasField(T, "allocator");
}

pub fn isArrayList(comptime T: type) bool {
    // TODO: Improve this ArrayList check, specifically by actually checking the functions we use
    // TODO: Consider unmanaged ArrayLists
    if (!@hasField(T, "items")) return false;
    if (!@hasField(T, "capacity")) return false;

    return true;
}

pub fn isHashMap(comptime T: type) bool {
    // TODO: Consider unmanaged HashMaps

    if (!@hasDecl(T, "KV")) return false;

    if (!@hasField(T.KV, "key")) return false;
    if (!@hasField(T.KV, "value")) return false;

    const Key = std.meta.fields(T.KV)[std.meta.fieldIndex(T.KV, "key") orelse unreachable].type;
    const Value = std.meta.fields(T.KV)[std.meta.fieldIndex(T.KV, "value") orelse unreachable].type;

    if (!@hasDecl(T, "put")) return false;

    const put = @typeInfo(@TypeOf(T.put));

    if (put != .Fn) return false;

    switch (put.Fn.params.len) {
        3 => {
            if (put.Fn.params[0].type.? != *T) return false;
            if (put.Fn.params[1].type.? != Key) return false;
            if (put.Fn.params[2].type.? != Value) return false;
        },
        4 => {
            if (put.Fn.params[0].type.? != *T) return false;
            if (put.Fn.params[1].type.? != std.mem.Allocator) return false;
            if (put.Fn.params[2].type.? != Key) return false;
            if (put.Fn.params[3].type.? != Value) return false;
        },
        else => return false,
    }

    if (put.Fn.return_type == null) return false;

    const put_return = @typeInfo(put.Fn.return_type.?);
    if (put_return != .ErrorUnion) return false;
    if (put_return.ErrorUnion.payload != void) return false;

    return true;
}

pub fn randomize(
    comptime T: type,
    allocator: std.mem.Allocator,
    random: std.rand.Random,
) anyerror!T {
    if (T == std.json.Value) {
        const Valids = enum {
            Null,
            Bool,
            Integer,
            Float,
            String,
            Array,
            Object,
        };
        const selection = random.enumValue(Valids);
        inline for (@typeInfo(T).Union.fields) |field| {
            if (std.mem.eql(u8, field.name, @tagName(selection))) return @unionInit(T, field.name, try randomize(field.type, allocator, random));
        }
        unreachable;
    }

    return switch (@typeInfo(T)) {
        .Void => void{},
        .Bool => random.boolean(),
        .Int => switch (T) {
            i64 => random.int(i32),
            u64 => random.int(u32),
            else => random.int(T),
        },
        .Float => random.float(T),
        .Array => @compileError("bruh"),
        .Pointer => b: {
            const pi = @typeInfo(T).Pointer;
            switch (pi.size) {
                .Slice => {
                    const n = random.intRangeLessThan(usize, 0, 10);
                    const slice = try allocator.alloc(pi.child, n);
                    for (slice) |*v| {
                        if (pi.child == u8)
                            v.* = random.intRangeLessThan(u8, 32, 126)
                        else
                            v.* = try randomize(pi.child, allocator, random);
                    }
                    break :b slice;
                },
                else => @compileError("non-slice pointers not supported"),
            }
        },
        .Struct => b: {
            if (comptime isArrayList(T)) {
                return T.init(allocator);
            }
            if (comptime isHashMap(T)) {
                return T.init(allocator);
            }

            var s: T = undefined;
            inline for (@typeInfo(T).Struct.fields) |field| {
                if (!field.is_comptime) {
                    if (comptime std.mem.eql(u8, field.name, "uri"))
                        @field(s, "uri") = "file:///C:/Programming/Zig/buzz-test/hello.zig"
                    else
                        @field(s, field.name) = try randomize(comptime field.type, allocator, random);
                }
            }
            break :b s;
        },
        .Optional => if (random.boolean()) null else try randomize(@typeInfo(T).Optional.child, allocator, random),
        .Enum => random.enumValue(T),
        .Union => b: {
            const selection = random.intRangeLessThan(usize, 0, @typeInfo(T).Union.fields.len);
            inline for (@typeInfo(T).Union.fields, 0..) |field, index| {
                if (index == selection) break :b @unionInit(T, field.name, try randomize(field.type, allocator, random));
            }
            unreachable;
        },
        else => @compileError("not supported: " ++ @typeName(T)),
    };
}

pub fn randomPosition(random: std.rand.Random, data: []const u8) lsp.Position {
    // TODO: Consider offsets

    const line_count = std.mem.count(u8, data, "\n");
    const line = if (line_count == 0) 0 else random.intRangeLessThan(usize, 0, line_count);
    var lines = std.mem.split(u8, data, "\n");

    var character: usize = 0;

    var index: usize = 0;
    while (lines.next()) |line_content| : (index += 1) {
        if (index == line) {
            character = if (line_content.len == 0) 0 else random.intRangeLessThan(usize, 0, line_content.len);
            break;
        }
    }

    return .{
        .line = @intCast(line),
        .character = @intCast(character),
    };
}

pub fn randomRange(random: std.rand.Random, data: []const u8) lsp.Range {
    const a = randomPosition(random, data);
    const b = randomPosition(random, data);

    const is_a_first = a.line < b.line or (a.line == b.line and a.character < b.character);

    return if (is_a_first) .{ .start = a, .end = b } else .{ .start = b, .end = a };
}

pub fn Params(comptime method: []const u8) type {
    for (lsp.notification_metadata) |notif| {
        if (std.mem.eql(u8, method, notif.method)) return notif.Params orelse void;
    }

    for (lsp.request_metadata) |req| {
        if (std.mem.eql(u8, method, req.method)) return req.Params orelse void;
    }

    @compileError("Couldn't find params for method named " ++ method);
}

pub fn stringifyRequest(
    writer: anytype,
    id: *i64,
    comptime method: []const u8,
    params: Params(method),
) !void {
    try std.json.stringify(.{
        .jsonrpc = "2.0",
        .id = id.*,
        .method = method,
        .params = switch (@TypeOf(params)) {
            void => .{},
            ?void => null,
            else => params,
        },
    }, .{}, writer);
    id.* +%= 1;
}

pub fn stringifyNotification(
    writer: anytype,
    comptime method: []const u8,
    params: Params(method),
) !void {
    try std.json.stringify(.{
        .jsonrpc = "2.0",
        .method = method,
        .params = params,
    }, .{}, writer);
}

pub fn send(
    file: std.fs.File,
    data: []const u8,
) !void {
    var header_buf: [64]u8 = undefined;
    const header = try Header.writeToBuffer(.{ .content_length = data.len }, &header_buf);

    var iovecs = [2]std.posix.iovec_const{
        .{
            .iov_base = header.ptr,
            .iov_len = header.len,
        },
        .{
            .iov_base = data.ptr,
            .iov_len = data.len,
        },
    };

    return file.writevAll(&iovecs);
}

pub fn waitForResponseToRequest(
    allocator: std.mem.Allocator,
    reader: anytype,
    read_buffer: *std.ArrayListUnmanaged(u8),
    id: i64,
) !void {
    while (true) {
        const header = try Header.parse(reader);
        try read_buffer.resize(allocator, header.content_length);

        try reader.readNoEof(read_buffer.items);

        const result = try std.json.parseFromSlice(
            struct { id: ?lsp.RequestId },
            allocator,
            read_buffer.items,
            .{
                .ignore_unknown_fields = true,
            },
        );

        defer result.deinit();

        if (result.value.id) |received_id| {
            if (received_id == .integer and received_id.integer == id) {
                return;
            }
        }
    }
}

pub fn waitForResponseToRequests(
    allocator: std.mem.Allocator,
    reader: anytype,
    read_buffer: *std.ArrayListUnmanaged(u8),
    ids: *std.AutoArrayHashMapUnmanaged(i64, void),
) !void {
    while (ids.count() != 0) {
        const header = try Header.parse(reader);
        try read_buffer.resize(allocator, header.content_length);

        try reader.readNoEof(read_buffer.items);

        const result = try std.json.parseFromSlice(
            struct { id: ?lsp.RequestId },
            allocator,
            read_buffer.items,
            .{
                .ignore_unknown_fields = true,
            },
        );
        defer result.deinit();

        if (result.value.id) |received_id| {
            if (received_id != .integer) continue;
            std.debug.assert(ids.swapRemove(received_id.integer));
        }
    }
}
