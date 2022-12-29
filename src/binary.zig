//! LSP binary encoding to save space

const std = @import("std");
const tres = @import("tres.zig");
const lsp = @import("lsp.zig");
const utils = @import("utils.zig");

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

const NullMeaning = enum {
    /// ?T; a null leads to the field not being written
    field,
    /// ?T; a null leads to the field being written with the value null
    value,
    /// ??T; first null is field, second null is value
    dual,
};

fn dualable(comptime T: type) bool {
    return @typeInfo(T) == .Optional and @typeInfo(@typeInfo(T).Optional.child) == .Optional;
}

// TODO: Respect stringify options
fn nullMeaning(comptime T: type, comptime field: std.builtin.Type.StructField) ?NullMeaning {
    const true_default = td: {
        if (dualable(T)) break :td NullMeaning.dual;
        break :td null;
    };
    if (!@hasDecl(T, "tres_null_meaning")) return true_default;
    const tnm = @field(T, "tres_null_meaning");
    if (!@hasField(@TypeOf(tnm), field.name)) return true_default;
    return @field(tnm, field.name);
}

pub fn encode(writer: anytype, value: anytype) @TypeOf(writer).Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Float => |f| {
            try encode(writer, @bitCast(@Type(.{ .Int = .{ .bits = f.bits, .signedness = .unsigned } }), value));
            return;
        },
        .Int => |i| {
            try (if (i.signedness == .unsigned) std.leb.writeULEB128 else std.leb.writeILEB128)(writer, value);
            return;
        },
        .Bool => {
            try writer.writeByte(@boolToInt(value));
            return;
        },
        .Null => {
            try writer.writeByte(0);
            return;
        },
        .Optional => {
            // 0 first byte - null
            // 1 first byte - non-null

            if (value) |payload| {
                try writer.writeByte(1);
                return try encode(writer, payload);
            } else {
                try writer.writeByte(0);
                return;
            }
        },
        .Enum => {
            if (comptime std.meta.trait.hasFn("lspBinaryEncode")(T)) {
                return value.lspBinaryEncode(writer, value);
            }

            try encode(writer, @enumToInt(value));
            return;
        },
        .Union => |info| {
            if (comptime std.meta.trait.hasFn("lspBinaryEncode")(T)) {
                return value.lspBinaryEncode(writer, value);
            }

            if (info.tag_type) |UnionTagType| {
                try encode(writer, std.meta.activeTag(value));

                inline for (info.fields) |u_field| {
                    if (value == @field(UnionTagType, u_field.name)) {
                        return try encode(writer, @field(value, u_field.name));
                    }
                }
                return;
            } else {
                @compileError("Unable to encode untagged union '" ++ @typeName(T) ++ "'");
            }
        },
        .Struct => |S| {
            if (comptime std.meta.trait.hasFn("lspBinaryEncode")(T)) {
                return value.lspBinaryEncode(writer, value);
            }

            if (comptime isArrayList(T)) {
                try encode(writer, value.items);
            } else if (comptime isHashMap(T)) {
                try encode(writer, value.count());

                var iterator = value.iterator();

                while (iterator.next()) |entry| {
                    try encode(writer, entry.key_ptr.*);
                    try encode(writer, entry.value_ptr.*);
                }
            } else {
                inline for (S.fields) |Field| {
                    // don't include void fields
                    if (Field.type == void) continue;

                    try encode(writer, @field(value, Field.name));
                }
            }

            return;
        },
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .One => switch (@typeInfo(ptr_info.child)) {
                .Array => {
                    const Slice = []const std.meta.Elem(ptr_info.child);
                    return encode(writer, @as(Slice, value));
                },
                else => {
                    return encode(writer, value.*);
                },
            },
            // TODO: .Many when there is a sentinel (waiting for https://github.com/ziglang/zig/pull/3972)
            .Slice => {
                try encode(writer, value.len);

                if (ptr_info.child == u8) {
                    try writer.writeAll(value);
                    return;
                }

                for (value) |x| {
                    try encode(writer, x);
                }

                return;
            },
            else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
        },
        .Array => return encode(writer, &value),
        .Vector => |info| {
            const array: [info.len]info.child = value;
            return encode(writer, &array);
        },
        .Void => return,
        else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
    }

    unreachable;
}

pub fn decode(
    allocator: std.mem.Allocator,
    comptime T: type,
    reader: anytype,
) (@TypeOf(reader).Error || std.mem.Allocator.Error || error{ InvalidData, Overflow })!T {
    switch (@typeInfo(T)) {
        .Float => |f| {
            return @bitCast(T, try decode(allocator, @Type(.{ .Int = .{ .bits = f.bits, .signedness = .unsigned } }), reader));
        },
        .Int => |i| {
            return (if (i.signedness == .unsigned) std.leb.readULEB128 else std.leb.readILEB128)(T, reader);
        },
        .Bool => {
            return (try reader.readByte()) != 0;
        },
        .Null => {
            std.debug.assert(try reader.readByte() == 0);
            return null;
        },
        .Optional => |o| {
            // 0 first byte - null
            // 1 first byte - non-null

            const has_value = try decode(allocator, bool, reader);

            return if (has_value)
                return try decode(allocator, o.child, reader)
            else
                null;
        },
        .Enum => |e| {
            if (comptime std.meta.trait.hasFn("lspBinaryDecode")(T)) {
                return T.lspBinaryDecode(allocator, reader);
            }

            return @intToEnum(T, try decode(allocator, e.tag_type, reader));
        },
        .Union => |info| {
            if (comptime std.meta.trait.hasFn("lspBinaryDecode")(T)) {
                return T.lspBinaryDecode(allocator, reader);
            }

            const tag = try decode(allocator, std.meta.Tag(T), reader);

            inline for (info.fields) |u_field| {
                if (tag == @field(std.meta.Tag(T), u_field.name)) {
                    return @unionInit(T, u_field.name, try decode(
                        allocator,
                        u_field.type,
                        reader,
                    ));
                }
            }

            @panic("Union fell through!");
        },
        .Struct => |S| {
            if (comptime std.meta.trait.hasFn("lspBinaryDecode")(T)) {
                return T.lspBinaryDecode(allocator, reader);
            }

            if (comptime isArrayList(T)) {
                const Child = @typeInfo(T.Slice).Pointer.child;
                const len = try decode(allocator, usize, reader);

                var arr = try T.initCapacity(allocator, len);

                if (Child == u8) {
                    try reader.readAll(arr.items);
                } else for (arr.items) |*x| {
                    x.* = try decode(allocator, Child, reader);
                }

                return arr;
            } else if (comptime isHashMap(T)) {
                const Key = std.meta.fields(T.KV)[std.meta.fieldIndex(T.KV, "key") orelse unreachable].type;
                const Value = std.meta.fields(T.KV)[std.meta.fieldIndex(T.KV, "value") orelse unreachable].type;
                const len = try decode(allocator, usize, reader);

                var map = if (comptime isManaged(T)) T.init(allocator) else T{};
                if (comptime isManaged(T))
                    try map.ensureTotalCapacity(len)
                else
                    try map.ensureTotalCapacity(allocator, len);

                var index: usize = 0;
                while (index < len) : (index += 1) {
                    const key = try decode(allocator, Key, reader);
                    const val = try decode(allocator, Value, reader);
                    if (comptime isManaged(T))
                        try map.put(key, val)
                    else
                        try map.put(allocator, key, val);
                }

                return map;
            } else {
                var str: T = undefined;

                inline for (S.fields) |Field| {
                    // don't include void fields
                    if (Field.type == void) continue;
                    @field(str, Field.name) = try decode(allocator, Field.type, reader);
                }

                return str;
            }
        },
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .One => switch (@typeInfo(ptr_info.child)) {
                .Array => {
                    const Slice = []const std.meta.Elem(ptr_info.child);
                    return decode(allocator, Slice, reader);
                },
                else => {
                    return decode(allocator, ptr_info.child, reader);
                },
            },
            // TODO: .Many when there is a sentinel (waiting for https://github.com/ziglang/zig/pull/3972)
            .Slice => {
                var slice = try allocator.alloc(ptr_info.child, try decode(allocator, usize, reader));

                if (ptr_info.child == u8) {
                    _ = try reader.readAll(slice);
                    return slice;
                }

                for (slice) |*x| {
                    x.* = try decode(allocator, ptr_info.child, reader);
                }

                return slice;
            },
            else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
        },
        .Array => |a| return decode(allocator, a.child, reader)[0..a.len],
        .Vector => |info| {
            return @as(T, try decode(allocator, [info.len]info.child, reader));
        },
        .Void => return,
        else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
    }
}

test {
    var seed: u64 = 0;
    try std.os.getrandom(std.mem.asBytes(&seed));
    var rng = std.rand.DefaultPrng.init(seed);

    var json_total: usize = 0;
    var binary_total: usize = 0;

    var index: usize = 0;
    while (index < 1000) : (index += 1) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var a = std.ArrayListUnmanaged(u8){};
        var b = std.ArrayListUnmanaged(u8){};
        var c = std.ArrayListUnmanaged(u8){};

        var comp = try std.compress.deflate.compressor(arena.allocator(), a.writer(arena.allocator()), .{});
        const val = try utils.randomize(lsp.ServerCapabilities, arena.allocator(), rng.random());
        try encode(comp.writer(), val);
        try comp.flush();

        try tres.stringify(val, .{}, b.writer(arena.allocator()));

        // Decode

        var afbs = std.io.fixedBufferStream(a.items);
        var decomp = try std.compress.deflate.decompressor(arena.allocator(), afbs.reader(), null);
        var decomp_res = try decode(arena.allocator(), lsp.ServerCapabilities, decomp.reader());
        try tres.stringify(decomp_res, .{}, c.writer(arena.allocator()));

        try std.testing.expectEqualStrings(b.items, c.items);

        json_total += b.items.len;
        binary_total += a.items.len;
    }

    std.debug.print("\n\n{d} json vs {d} binary\n\n", .{ json_total, binary_total });
}
