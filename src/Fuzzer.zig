const std = @import("std");
const lsp = @import("lsp.zig");
const tres = @import("tres.zig");
const ChildProcess = std.ChildProcess;

const Fuzzer = @This();

proc: ChildProcess,
write_buf: std.ArrayList(u8),
loggies: std.fs.File,
prng: std.rand.DefaultPrng,
id: usize = 0,

pub fn init(allocator: std.mem.Allocator, zls_path: []const u8) !Fuzzer {
    var loggies = try std.fs.cwd().createFile("loggies.txt", .{});

    var zls = std.ChildProcess.init(&.{ zls_path, "--enable-debug-log" }, allocator);
    zls.stdin_behavior = .Pipe;
    try zls.spawn();

    var seed: u64 = 0;
    try std.os.getrandom(std.mem.asBytes(&seed));

    return .{
        .proc = zls,
        .write_buf = std.ArrayList(u8).init(allocator),
        .loggies = loggies,
        .prng = std.rand.DefaultPrng.init(seed),
    };
}

pub fn deinit(fuzzer: *Fuzzer) void {
    _ = fuzzer.proc.kill() catch @panic("a");
    fuzzer.loggies.close();
}

pub fn random(fuzzer: *Fuzzer) std.rand.Random {
    return fuzzer.prng.random();
}

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

    try fuzzer.loggies.writeAll(fuzzer.write_buf.items);
    try fuzzer.loggies.writeAll("\n\n");
}

pub fn initCycle(fuzzer: *Fuzzer) !void {
    try fuzzer.writeJson(.{
        .jsonrpc = "2.0",
        .id = fuzzer.id,
        .method = "initialize",
        .params = lsp.InitializeParams{
            .capabilities = .{},
        },
    });
    fuzzer.id += 1;
    std.time.sleep(std.time.ns_per_ms * 500);

    try fuzzer.writeJson(.{
        .jsonrpc = "2.0",
        .method = "initialized",
        .params = lsp.InitializedParams{},
    });
    std.time.sleep(std.time.ns_per_ms * 500);
}
