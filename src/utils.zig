const std = @import("std");
const lsp = @import("lsp.zig");
const tres = @import("tres.zig");

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
            if (std.mem.eql(u8, field.name, @tagName(selection))) return @unionInit(T, field.name, try randomize(field.field_type, allocator, random));
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
                    var n = random.intRangeLessThan(usize, 0, 64);
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
            if (comptime tres.isArrayList(T)) {
                return T.init(allocator);
            }
            if (comptime tres.isHashMap(T)) {
                return T.init(allocator);
            }

            var s: T = undefined;
            inline for (@typeInfo(T).Struct.fields) |field| {
                if (!field.is_comptime) {
                    if (comptime std.mem.eql(u8, field.name, "uri"))
                        @field(s, "uri") = "file:///C:/Programming/Zig/buzz-test/hello.zig"
                    else
                        @field(s, field.name) = try randomize(comptime field.field_type, allocator, random);
                }
            }
            break :b s;
        },
        .Optional => if (random.boolean()) null else try randomize(@typeInfo(T).Optional.child, allocator, random),
        .Enum => random.enumValue(T),
        .Union => b: {
            const selection = random.intRangeLessThan(usize, 0, @typeInfo(T).Union.fields.len);
            inline for (@typeInfo(T).Union.fields) |field, index| {
                if (index == selection) break :b @unionInit(T, field.name, try randomize(field.field_type, allocator, random));
            }
            unreachable;
        },
        else => @compileError("not supported: " ++ @typeName(T)),
    };
}

pub fn randomPosition(random: std.rand.Random, data: []const u8) lsp.Position {
    const line = random.intRangeLessThan(usize, 0, std.mem.count(u8, data, "\n"));
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
        .line = line,
        .character = character,
    };
}
