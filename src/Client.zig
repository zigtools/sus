const std = @import("std");
const builtin = @import("builtin");

const utils = @import("utils.zig");
const lsp = @import("lsp");

const Client = @This();

io: std.Io,
allocator: std.mem.Allocator,
child_process: std.process.Child,
transport_read_buffer: [256]u8 = undefined,
stdio_transport: lsp.Transport.Stdio,
text_document_uri: []const u8,
zig_path: []const u8,

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    zls_path: []const u8,
    zig_path: []const u8,
    stderr_behavior: std.process.SpawnOptions.StdIo,
) (std.process.SpawnError)!Client {
    var env_map = try environ_map.clone(allocator);
    defer env_map.deinit();

    try env_map.put("NO_COLOR", "1");

    const argv: []const []const u8 = &.{
        zls_path,
        "--log-file",
        if (builtin.target.os.tag == .windows) "nul" else "/dev/null",
        "--disable-lsp-logs",
    };

    var child_process = try std.process.spawn(io, .{
        .environ_map = &env_map,
        .argv = argv,
        .stdin = .pipe,
        .stderr = stderr_behavior,
        .stdout = .pipe,
    });
    errdefer child_process.kill(io);

    const text_document_uri = try std.fmt.allocPrint(allocator, "{f}", .{std.Uri{
        .scheme = "untitled",
        .path = .{ .raw = "principal.zig" },
    }});
    errdefer allocator.free(text_document_uri);

    return .{
        .io = io,
        .allocator = allocator,
        .child_process = child_process,
        .stdio_transport = undefined, // See `initialize`
        .zig_path = zig_path,
        .text_document_uri = text_document_uri,
    };
}

pub fn wait(client: *Client) std.process.Child.WaitError!void {
    _ = try client.child_process.wait(client.io);
}

pub fn kill(client: *Client) void {
    client.child_process.kill(client.io);
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

    var settings: std.json.ObjectMap = .empty;
    defer settings.deinit(client.allocator);
    try settings.putNoClobber(client.allocator, "skip_std_references", .{ .bool = true }); // references collection into std is very slow
    try settings.putNoClobber(client.allocator, "zig_exe_path", .{ .string = client.zig_path });

    try client.sendNotification("workspace/didChangeConfiguration", lsp.types.workspace.configuration.did_change.Params{
        .settings = .{ .object = settings },
    });

    try client.sendNotification("textDocument/didOpen", lsp.types.TextDocument.DidOpenParams{ .textDocument = .{
        .uri = client.text_document_uri,
        .languageId = .{ .custom_value = "zig" },
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
        client.io,
        client.allocator,
        id,
        method,
        lsp.ParamsType(method),
        params,
        .{ .emit_null_optional_fields = false },
    );
    try utils.waitForResponseToRequest(
        client.io,
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
        client.io,
        client.allocator,
        method,
        lsp.ParamsType(method),
        params,
        .{ .emit_null_optional_fields = false },
    );
}
