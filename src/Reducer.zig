const std = @import("std");

const utils = @import("utils.zig");
const Fuzzer = @import("Fuzzer.zig");
const lsp = @import("lsp");

const Reducer = @This();

allocator: std.mem.Allocator,
sent_data: []const u8,
sent_messages: []const Fuzzer.SentMessage,
principal_file_source: []const u8,
principal_file_uri: []const u8,
config: Fuzzer.Config,
random: std.Random,

zls_process: std.process.Child,
transport: lsp.TransportOverStdio,
id: i64 = 0,
write_buffer: std.ArrayListUnmanaged(u8) = .{},

pub fn fromFuzzer(fuzzer: *Fuzzer) Reducer {
    return .{
        .allocator = fuzzer.allocator,
        .sent_data = fuzzer.sent_data.items,
        .sent_messages = fuzzer.sent_messages.items,
        .config = fuzzer.config,
        .principal_file_source = fuzzer.principal_file_source,
        .principal_file_uri = fuzzer.principal_file_uri,
        .random = fuzzer.random(),

        .zls_process = undefined,
        .transport = undefined,
    };
}

pub fn deinit(reducer: *Reducer) void {
    reducer.write_buffer.deinit(reducer.allocator);
}

const Message = struct { id: i64, data: []const u8 };
fn message(reducer: *Reducer, index: u32) Message {
    const msg = reducer.sent_messages[index];
    return .{
        .id = msg.id,
        .data = reducer.sent_data[msg.start..msg.end],
    };
}

/// Creates new process and does LSP init; does not kill old one
fn createNewProcessAndInitialize(reducer: *Reducer) !void {
    reducer.id = 0;

    var env_map = try std.process.getEnvMap(reducer.allocator);
    defer env_map.deinit();

    try env_map.put("NO_COLOR", "");

    var zls_process = std.process.Child.init(&.{ reducer.config.zls_path, "--enable-debug-log" }, reducer.allocator);
    zls_process.env_map = &env_map;
    zls_process.stdin_behavior = .Pipe;
    zls_process.stderr_behavior = .Pipe;
    zls_process.stdout_behavior = .Pipe;

    try zls_process.spawn();
    errdefer _ = zls_process.kill() catch @panic("failed to kill zls process");

    reducer.zls_process = zls_process;
    reducer.transport = lsp.TransportOverStdio.init(reducer.zls_process.stdout.?, reducer.zls_process.stdin.?);

    try reducer.sendRequest("initialize", lsp.types.InitializeParams{
        .capabilities = .{},
    });
    try reducer.sendNotification("initialized", .{});

    var settings = std.json.ObjectMap.init(reducer.allocator);
    defer settings.deinit();
    try settings.putNoClobber("skip_std_references", .{ .bool = true }); // references collection into std is very slow
    try settings.putNoClobber("zig_exe_path", .{ .string = reducer.config.zig_env.value.zig_exe });

    try reducer.sendNotification("workspace/didChangeConfiguration", lsp.types.DidChangeConfigurationParams{
        .settings = .{ .object = settings },
    });

    try reducer.sendNotification("textDocument/didOpen", lsp.types.DidOpenTextDocumentParams{ .textDocument = .{
        .uri = reducer.principal_file_uri,
        .languageId = "zig",
        .version = 0,
        .text = reducer.principal_file_source,
    } });
}

fn shutdownProcessCleanly(reducer: *Reducer) !void {
    _ = try reducer.sendNotification("textDocument/didClose", .{
        .textDocument = .{ .uri = reducer.principal_file_uri },
    });

    _ = try reducer.sendRequest("shutdown", {});
    try reducer.sendNotification("exit", {});
}

pub fn reduce(reducer: *Reducer) !void {
    try reducer.createNewProcessAndInitialize();

    var stderr = std.ArrayListUnmanaged(u8){};
    defer stderr.deinit(reducer.allocator);

    var keep_running_stderr = std.atomic.Value(bool).init(true);
    const stderr_thread = try std.Thread.spawn(.{}, readStderr, .{
        reducer.allocator,
        reducer.zls_process.stderr.?,
        &stderr,
        &keep_running_stderr,
    });

    const msg: Message = for (0..reducer.sent_messages.len) |msg_idx| {
        const msg = reducer.message(@intCast(msg_idx));
        reducer.repeatMessage(msg) catch {
            keep_running_stderr.store(false, .release);
            stderr_thread.join();
            _ = try reducer.zls_process.wait();
            break msg;
        };
    } else {
        std.log.err("Could not reproduce!", .{});
        try reducer.shutdownProcessCleanly();
        keep_running_stderr.store(false, .release);
        stderr_thread.join();
        _ = try reducer.zls_process.wait();
        return;
    };

    const processed_stderr = if (std.mem.indexOf(u8, stderr.items, "panic:")) |panic_start|
        stderr.items[panic_start..]
    else
        stderr.items;

    if (reducer.config.rpc) {
        var iovecs: [12]std.posix.iovec_const = undefined;

        for ([_][]const u8{
            std.mem.asBytes(&@as(u32, @intCast(
                8 +
                    1 + reducer.config.zig_env.value.version.len +
                    1 + reducer.config.zls_version.len +
                    4 + reducer.principal_file_source.len +
                    2 + msg.data.len +
                    2 + processed_stderr.len,
            ))),

            std.mem.asBytes(&std.time.milliTimestamp()),

            std.mem.asBytes(&@as(u8, @intCast(reducer.config.zig_env.value.version.len))),
            reducer.config.zig_env.value.version,

            std.mem.asBytes(&@as(u8, @intCast(reducer.config.zls_version.len))),
            reducer.config.zls_version,

            std.mem.asBytes(&@as(u32, @intCast(reducer.principal_file_source.len))),
            reducer.principal_file_source,

            std.mem.asBytes(&@as(u16, @intCast(msg.data.len))),
            msg.data,

            std.mem.asBytes(&@as(u16, @intCast(processed_stderr.len))),
            processed_stderr,
        }, 0..) |val, i| {
            iovecs[i] = .{ .base = val.ptr, .len = val.len };
        }

        try std.io.getStdOut().writevAll(&iovecs);
    } else {
        var bytes: [32]u8 = undefined;
        reducer.random.bytes(&bytes);

        try std.fs.cwd().makePath("saved_logs");

        const log_entry_path = try std.fmt.allocPrint(reducer.allocator, "saved_logs/{d}", .{std.fmt.fmtSliceHexLower(&bytes)});
        defer reducer.allocator.free(log_entry_path);

        const entry_file = try std.fs.cwd().createFile(log_entry_path, .{});
        defer entry_file.close();

        var timestamp_buf: [32]u8 = undefined;
        var iovecs: [16]std.posix.iovec_const = undefined;

        for ([_][]const u8{
            "timestamp: ",
            try std.fmt.bufPrint(&timestamp_buf, "{d}", .{std.time.milliTimestamp()}),
            "\n",
            "zig version: ",
            reducer.config.zig_env.value.version,
            "\nzls version: ",
            reducer.config.zls_version,
            "\n\n",
            "principal:\n",
            reducer.principal_file_source,
            "\n\n",
            "message:\n",
            msg.data,
            "\n\n",
            "stderr:\n",
            processed_stderr,
        }, &iovecs) |val, *iovec| {
            iovec.* = .{ .base = val.ptr, .len = val.len };
        }

        try entry_file.writevAll(&iovecs);
    }
}

fn repeatMessage(reducer: *Reducer, msg: Message) !void {
    try reducer.transport.writeJsonMessage(msg.data);

    try utils.waitForResponseToRequest(
        reducer.allocator,
        &reducer.transport,
        msg.id,
    );
}

fn sendRequest(reducer: *Reducer, comptime method: []const u8, params: lsp.ParamsType(method)) !void {
    const request_id = reducer.id;
    reducer.write_buffer.clearRetainingCapacity();

    try utils.stringifyRequest(
        reducer.write_buffer.writer(reducer.allocator),
        &reducer.id,
        method,
        params,
    );

    try reducer.transport.writeJsonMessage(reducer.write_buffer.items);

    try utils.waitForResponseToRequest(
        reducer.allocator,
        &reducer.transport,
        request_id,
    );
}

fn sendNotification(reducer: *Reducer, comptime method: []const u8, params: lsp.ParamsType(method)) !void {
    reducer.write_buffer.clearRetainingCapacity();

    try utils.stringifyNotification(
        reducer.write_buffer.writer(reducer.allocator),
        method,
        params,
    );

    try reducer.transport.writeJsonMessage(reducer.write_buffer.items);
}

fn readStderr(
    allocator: std.mem.Allocator,
    stderr: std.fs.File,
    out: *std.ArrayListUnmanaged(u8),
    keep_running: *std.atomic.Value(bool),
) void {
    var buffer: [4096]u8 = undefined;
    while (keep_running.load(.acquire)) {
        const amt = stderr.read(&buffer) catch break;
        out.appendSlice(allocator, buffer[0..amt]) catch break;
    }
}
