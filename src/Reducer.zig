const std = @import("std");
const ChildProcess = std.ChildProcess;

const utils = @import("utils.zig");
const Fuzzer = @import("Fuzzer.zig");
const lsp = @import("lsp.zig");

const Reducer = @This();

allocator: std.mem.Allocator,
env_map: *const std.process.EnvMap,
read_buffer: std.ArrayListUnmanaged(u8),
sent_data: []const u8,
sent_messages: []const Fuzzer.SentMessage,
principal_file_source: []const u8,
principal_file_uri: []const u8,
config: Fuzzer.Config,

zls_process: ChildProcess,
id: i64 = 0,
buffered_reader: std.io.BufferedReader(4096, std.fs.File.Reader),
write_buffer: std.ArrayListUnmanaged(u8) = .{},

pub fn fromFuzzer(fuzzer: *Fuzzer) Reducer {
    return .{
        .allocator = fuzzer.allocator,
        .env_map = fuzzer.env_map,
        .read_buffer = fuzzer.read_buffer,
        .sent_data = fuzzer.sent_data.items,
        .sent_messages = fuzzer.sent_messages.items,
        .config = fuzzer.config,
        .principal_file_source = fuzzer.principal_file_source,
        .principal_file_uri = fuzzer.principal_file_uri,

        .zls_process = undefined,
        .id = 0,
        .buffered_reader = undefined,
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

    var zls_process = std.ChildProcess.init(&.{ reducer.config.zls_path, "--enable-debug-log" }, reducer.allocator);
    zls_process.env_map = reducer.env_map;
    zls_process.stdin_behavior = .Pipe;
    zls_process.stderr_behavior = .Inherit;
    zls_process.stdout_behavior = .Pipe;

    try zls_process.spawn();
    errdefer _ = zls_process.kill() catch @panic("failed to kill zls process");

    reducer.zls_process = zls_process;
    reducer.buffered_reader = std.io.bufferedReader(reducer.zls_process.stdout.?.reader());

    try reducer.sendRequest("initialize", lsp.InitializeParams{
        .capabilities = .{},
    });
    try reducer.sendNotification("initialized", .{});

    var settings = std.json.ObjectMap.init(reducer.allocator);
    defer settings.deinit();
    try settings.putNoClobber("skip_std_references", .{ .bool = true }); // references collection into std is very slow
    try settings.putNoClobber("zig_exe_path", .{ .string = reducer.config.zig_env.value.zig_exe });

    try reducer.sendNotification("workspace/didChangeConfiguration", lsp.DidChangeConfigurationParams{
        .settings = .{ .object = settings },
    });

    try reducer.sendNotification("textDocument/didOpen", lsp.DidOpenTextDocumentParams{ .textDocument = .{
        .uri = reducer.principal_file_uri,
        .languageId = .{ .custom_value = "zig" },
        .version = 0,
        .text = reducer.principal_file_source,
    } });
}

pub fn reduce(reducer: *Reducer) !void {
    try reducer.createNewProcessAndInitialize();

    for (0..reducer.sent_messages.len) |msg_idx| {
        const msg = reducer.message(@intCast(msg_idx));
        reducer.repeatMessage(msg) catch {
            std.log.info("found cause! {d} {s}", .{ msg_idx, msg.data });
        };
    }
}

fn repeatMessage(reducer: *Reducer, msg: Message) !void {
    try reducer.zls_process.stdout.?.writer().writeAll(msg.data);
    try utils.waitForResponseToRequest(
        reducer.allocator,
        reducer.buffered_reader.reader(),
        &reducer.read_buffer,
        msg.id,
    );
}

fn sendRequest(reducer: *Reducer, comptime method: []const u8, params: utils.Params(method)) !void {
    const request_id = reducer.id;
    reducer.write_buffer.items.len = 0;

    try utils.stringifyRequest(
        reducer.write_buffer.writer(reducer.allocator),
        &reducer.id,
        method,
        params,
    );

    try utils.send(
        reducer.zls_process.stdin.?,
        reducer.write_buffer.items,
    );

    try utils.waitForResponseToRequest(
        reducer.allocator,
        reducer.buffered_reader.reader(),
        &reducer.read_buffer,
        request_id,
    );
}

fn sendNotification(reducer: *Reducer, comptime method: []const u8, params: utils.Params(method)) !void {
    reducer.write_buffer.items.len = 0;

    try utils.stringifyNotification(
        reducer.write_buffer.writer(reducer.allocator),
        method,
        params,
    );

    return utils.send(
        reducer.zls_process.stdin.?,
        reducer.write_buffer.items,
    );
}
