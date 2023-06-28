const std = @import("std");
const lsp = @import("zig-lsp");
const lsp_types = lsp.types;

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
                    var n = random.intRangeLessThan(usize, 0, 10);
                    var slice = try allocator.alloc(pi.child, n);
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

pub fn randomPosition(random: std.rand.Random, data: []const u8) lsp_types.Position {
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

pub fn randomRange(random: std.rand.Random, data: []const u8) lsp_types.Range {
    var a = randomPosition(random, data);
    var b = randomPosition(random, data);

    const is_a_first = a.line < b.line or (a.line == b.line and a.character < b.character);

    return if (is_a_first) .{ .start = a, .end = b } else .{ .start = b, .end = a };
}
