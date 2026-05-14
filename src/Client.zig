const std = @import("std");
const builtin = @import("builtin");

const utils = @import("utils.zig");
const lsp = @import("lsp");

const Client = @This();

allocator: std.mem.Allocator,
child_process: std.process.Child,
transport_read_buffer: [256]u8 = undefined,
stdio_transport: lsp.Transport.Stdio,
text_document_uri: []const u8,
zig_path: []const u8,

pub fn init(
    allocator: std.mem.Allocator,
    zls_path: []const u8,
    zig_path: []const u8,
    stderr_behavior: std.process.Child.StdIo,
) (std.process.GetEnvMapError || std.process.Child.SpawnError)!Client {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    try env_map.put("NO_COLOR", "1");

    const argv: []const []const u8 = &.{
        zls_path,
        "--log-file",
        if (builtin.target.os.tag == .windows) "nul" else "/dev/null",
        "--disable-lsp-logs",
    };

    var child_process: std.process.Child = .init(argv, allocator);
    child_process.env_map = &env_map;
    child_process.stdin_behavior = .Pipe;
    child_process.stderr_behavior = stderr_behavior;
    child_process.stdout_behavior = .Pipe;

    try child_process.spawn();
    errdefer _ = child_process.kill() catch @panic("failed to kill ZLS process");

    const text_document_uri = try std.fmt.allocPrint(allocator, "{f}", .{std.Uri{
        .scheme = "untitled",
        .path = .{ .raw = "principal.zig" },
    }});
    errdefer allocator.free(text_document_uri);

    return .{
        .allocator = allocator,
        .child_process = child_process,
        .stdio_transport = undefined, // See `initialize`
        .zig_path = zig_path,
        .text_document_uri = text_document_uri,
    };
}

pub fn wait(client: *Client) std.process.Child.WaitError!void {
    _ = try client.child_process.wait();
}

pub fn kill(client: *Client) void {
    _ = client.child_process.wait() catch @panic("failed to kill ZLS process");
}

pub fn transport(client: *Client) *lsp.Transport {
    return &client.stdio_transport.transport;
}

pub fn initialize(client: *Client) !void {
    client.stdio_transport = .init(&client.transport_read_buffer, client.child_process.stdout.?, client.child_process.stdin.?);

    try client.sendRequest(.{ .string = "pls_init_UwU" }, "initialize", lsp.types.InitializeParams{
        .capabilities = .{},
    });
    try client.sendNotification("initialized", .{});

    var settings: std.json.ObjectMap = .init(client.allocator);
    defer settings.deinit();
    try settings.putNoClobber("skip_std_references", .{ .bool = true }); // references collection into std is very slow
    try settings.putNoClobber("zig_exe_path", .{ .string = client.zig_path });

    try client.sendNotification("workspace/didChangeConfiguration", lsp.types.DidChangeConfigurationParams{
        .settings = .{ .object = settings },
    });

    try client.sendNotification("textDocument/didOpen", lsp.types.DidOpenTextDocumentParams{ .textDocument = .{
        .uri = client.text_document_uri,
        .languageId = "zig",
        .version = 0,
        .text = "",
    } });
}

pub fn shutdown(client: *Client) !void {
    _ = try client.sendNotification("textDocument/didClose", .{
        .textDocument = .{ .uri = client.text_document_uri },
    });

    _ = try client.sendRequest(.{ .string = "pls_deinit_UwU" }, "shutdown", {});
    try client.sendNotification("exit", {});
}

fn sendRequest(
    client: *Client,
    id: lsp.JsonRPCMessage.ID,
    comptime method: []const u8,
    params: lsp.ParamsType(method),
) !void {
    try client.transport().writeRequest(
        client.allocator,
        id,
        method,
        lsp.ParamsType(method),
        params,
        .{ .emit_null_optional_fields = false },
    );
    try utils.waitForResponseToRequest(
        client.allocator,
        client.transport(),
        id,
    );
}

fn sendNotification(
    client: *Client,
    comptime method: []const u8,
    params: lsp.ParamsType(method),
) !void {
    try client.transport().writeNotification(
        client.allocator,
        method,
        lsp.ParamsType(method),
        params,
        .{ .emit_null_optional_fields = false },
    );
}
