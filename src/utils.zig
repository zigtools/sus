const std = @import("std");
const lsp = @import("lsp");

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
    random: std.Random,
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
    transport: *lsp.TransportOverStdio,
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
    transport: *lsp.TransportOverStdio,
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
