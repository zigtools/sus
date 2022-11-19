const std = @import("std");
const lsp = @import("lsp.zig");
const tres = @import("tres.zig");
const ChildProcess = std.ChildProcess;

pub fn randomize(comptime T: type, allocator: std.mem.Allocator, random: std.rand.Random) anyerror!T {
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
        .Int => random.int(T),
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

pub const FuzzKind = enum {
    /// Just absolutely random body data (valid header)
    hot_garbo,
    /// Absolutely random JSON data
    cold_garbo,
};

pub const Fuzzer = struct {
    proc: ChildProcess,
    write_buf: std.ArrayList(u8),

    pub fn writeJson(fuzzer: *Fuzzer, data: anytype) !void {
        fuzzer.write_buf.items.len = 0;

        try tres.stringify(
            data,
            .{ .emit_null_optional_fields = false },
            fuzzer.write_buf.writer(),
        );

        var zls_stdin = fuzzer.proc.stdin.?.writer();
        try zls_stdin.print("Content-Length: {d}\r\n\r\n", .{fuzzer.write_buf.items.len});
        try zls_stdin.writeAll(fuzzer.write_buf.items);

        // fuzzer.proc.stdout.?.reader().skipBytes(1024, .{}) catch {};
        // std.io.

        // try loggies.writeAll(fuzzer.write_buf.items);
        // try loggies.writeAll("\n\n");
    }
};

var loggies: std.fs.File.Writer = undefined;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var loggies_f = try std.fs.cwd().createFile("loggies.txt", .{});
    defer loggies_f.close();

    loggies = loggies_f.writer();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.log.err("buzz <zls executable path> <fuzz kind: poke>", .{});
        return;
    }

    const zls_path = args[1];
    const fuzz_kind = std.meta.stringToEnum(FuzzKind, args[2]) orelse {
        std.log.err("Invalid fuzz kind!", .{});
        return;
    };
    _ = fuzz_kind;

    var zls = std.ChildProcess.init(&.{ zls_path, "--enable-debug-log" }, allocator);
    zls.stdin_behavior = .Pipe;
    // zls.stdout_behavior = .Pipe;
    try zls.spawn();

    var fuzzer = Fuzzer{
        .proc = zls,
        .write_buf = std.ArrayList(u8).init(allocator),
    };

    var seed: u64 = 0;
    try std.os.getrandom(std.mem.asBytes(&seed));

    var rng = std.rand.DefaultPrng.init(seed);
    var random = rng.random();
    var id: usize = 0;

    try fuzzer.writeJson(.{
        .jsonrpc = "2.0",
        .id = id,
        .method = "initialize",
        .params = lsp.InitializeParams{
            .capabilities = .{},
        },
    });
    id += 1;
    std.time.sleep(std.time.ns_per_ms * 500);

    try fuzzer.writeJson(.{
        .jsonrpc = "2.0",
        .method = "initialized",
        .params = lsp.InitializedParams{},
    });
    std.time.sleep(std.time.ns_per_ms * 500);

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const selection_notif = random.intRangeLessThan(usize, 0, lsp.notification_metadata.len);

        inline for (lsp.notification_metadata) |notif, index| {
            if (index == selection_notif and !std.mem.eql(u8, notif.method, "exit")) {
                const rz = try randomize(notif.Params orelse void, arena.allocator(), random);
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
                const rz = try randomize(req.Params orelse void, arena.allocator(), random);
                // std.log.info("Sending {s}...", .{notif.method});
                try fuzzer.writeJson(.{
                    .jsonrpc = "2.0",
                    .id = id,
                    .method = req.method,
                    .params = rz,
                });
                id += 1;
            }
        }
    }

    // var al = std.ArrayList(u8).init(allocator);
    // defer al.deinit();

    // try tres.stringify(
    //     .{
    //         .jsonrpc = "2.0",
    //         .id = 1,
    //         .method = "initialize",
    //         .params = lsp.InitializeParams{
    //             .processId = null,
    //             .clientInfo = .{
    //                 .name = "buzz",
    //                 .version = "bruh",
    //             },
    //             .capabilities = .{},
    //         },
    //     },
    //     .{ .emit_null_optional_fields = false },
    //     al.writer(),
    // );

    // var zls_stdin = zls.stdin.?.writer();
    // try zls_stdin.print("Content-Length: {d}\r\n\r\n", .{al.items.len});
    // try zls_stdin.writeAll(al.items);
}
