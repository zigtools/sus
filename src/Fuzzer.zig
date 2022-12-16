const std = @import("std");
const lsp = @import("lsp.zig");
const uri = @import("uri.zig");
const tres = @import("tres.zig");
const ChildProcess = std.ChildProcess;

const Fuzzer = @This();

allocator: std.mem.Allocator,
proc: ChildProcess,
write_buf: std.ArrayListUnmanaged(u8),
open_buf: std.ArrayListUnmanaged(u8),
prng: std.rand.DefaultPrng,
id: usize = 0,

stdin: std.fs.File,
stderr: std.fs.File,
stdout: std.fs.File,

stderr_thread: std.Thread,
stdout_thread: std.Thread,

pub fn create(allocator: std.mem.Allocator, zls_path: []const u8) !*Fuzzer {
    var fuzzer = try allocator.create(Fuzzer);

    fuzzer.allocator = allocator;

    fuzzer.proc = std.ChildProcess.init(&.{ zls_path, "--enable-debug-log" }, allocator);

    fuzzer.proc.stdin_behavior = .Pipe;
    fuzzer.proc.stderr_behavior = .Pipe;
    fuzzer.proc.stdout_behavior = .Pipe;

    try fuzzer.proc.spawn();

    fuzzer.stdin = try std.fs.cwd().createFile("logs/stdin.log", .{});
    fuzzer.stderr = try std.fs.cwd().createFile("logs/stderr.log", .{});
    fuzzer.stdout = try std.fs.cwd().createFile("logs/stdout.log", .{});

    fuzzer.stderr_thread = try std.Thread.spawn(.{}, readStderr, .{fuzzer});
    fuzzer.stdout_thread = try std.Thread.spawn(.{}, readStdout, .{fuzzer});

    var seed: u64 = 0;
    try std.os.getrandom(std.mem.asBytes(&seed));

    fuzzer.write_buf = .{};
    fuzzer.open_buf = .{};
    fuzzer.prng = std.rand.DefaultPrng.init(seed);

    return fuzzer;
}

fn readStderr(fuzzer: *Fuzzer) void {
    var lf = std.fifo.LinearFifo(u8, .{ .Static = std.mem.page_size }).init();

    while (true) {
        var stderr = fuzzer.proc.stderr orelse break;
        lf.pump(stderr.reader(), fuzzer.stderr.writer()) catch break;
        // fuzzer.stderr.writer().writeByte(stderr.reader().readByte() catch return) catch return;
    }

    std.log.err("stderr failure", .{});
}

fn readStdout(fuzzer: *Fuzzer) void {
    var lf = std.fifo.LinearFifo(u8, .{ .Static = std.mem.page_size }).init();

    while (true) {
        var stdout = fuzzer.proc.stdout orelse break;
        lf.pump(stdout.reader(), fuzzer.stdout.writer()) catch break;
        // fuzzer.stdout.writer().writeByte(stdout.reader().readByte() catch break) catch break;
    }

    std.log.err("stdout failure", .{});
}

pub fn deinit(fuzzer: *Fuzzer) void {
    _ = fuzzer.proc.kill() catch |err| {
        std.log.err("{s}", .{@errorName(err)});
        @panic("abc");
    };

    fuzzer.stdin.close();
    fuzzer.stderr.close();
    fuzzer.stdout.close();

    fuzzer.stderr_thread.join();
    fuzzer.stdout_thread.join();

    fuzzer.allocator.destroy(fuzzer);
}

pub fn random(fuzzer: *Fuzzer) std.rand.Random {
    return fuzzer.prng.random();
}

pub fn writeJson(fuzzer: *Fuzzer, data: anytype) !void {
    fuzzer.write_buf.items.len = 0;

    try tres.stringify(
        data,
        .{ .emit_null_optional_fields = false },
        fuzzer.write_buf.writer(fuzzer.allocator),
    );

    var zls_stdin = fuzzer.proc.stdin.?.writer();
    try zls_stdin.print("Content-Length: {d}\r\n\r\n", .{fuzzer.write_buf.items.len});
    try zls_stdin.writeAll(fuzzer.write_buf.items);

    try fuzzer.stdin.writeAll(fuzzer.write_buf.items);
    try fuzzer.stdin.writeAll("\n\n");
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

pub fn open(fuzzer: *Fuzzer, f_uri: []const u8, data: []const u8) !void {
    try fuzzer.writeJson(.{
        .jsonrpc = "2.0",
        .method = "textDocument/didOpen",
        .params = lsp.DidOpenTextDocumentParams{ .textDocument = .{
            .uri = f_uri,
            .languageId = "zig",
            .version = 0,
            .text = data,
        } },
    });
}

/// Returns opened file URI; caller owns memory
pub fn openFile(fuzzer: *Fuzzer, path: []const u8) ![]const u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const size = (try file.stat()).size;

    try fuzzer.open_buf.ensureTotalCapacity(fuzzer.allocator, size);
    fuzzer.open_buf.items.len = size;
    _ = try file.readAll(fuzzer.open_buf.items);

    const f_uri = try uri.fromPath(fuzzer.allocator, path);

    try fuzzer.open(f_uri, fuzzer.open_buf);

    return f_uri;
}
