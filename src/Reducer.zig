const std = @import("std");
const builtin = @import("builtin");

const utils = @import("utils.zig");
const Fuzzer = @import("Fuzzer.zig");
const Mode = @import("mode.zig").Mode;
const Client = @import("Client.zig");
const lsp = @import("lsp");

pub fn reduce(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    mode: *Mode,
    config: *const Fuzzer.Config,
    seed: u64,
    progress_node: std.Progress.Node,
) !void {
    var client: Client = try .init(
        io,
        allocator,
        environ_map,
        config.zls_path,
        config.zig_env.zig_exe,
        .pipe,
    );
    errdefer client.child_process.kill(io);

    try client.initialize();

    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    var stderr_task = try io.concurrent(readStderr, .{
        io,
        allocator,
        client.child_process.stderr.?,
        &stderr,
    });
    defer stderr_task.cancel(io);

    var rand: std.Random.DefaultPrng = .init(seed);
    var text_document: lsp.types.TextDocument = .{
        .uri = client.text_document_uri,
        .languageId = .{ .custom_value = "zig" },
        .version = 0,
        .text = "",
    };

    var cycle: usize = 0;
    const json_message: []const u8 = while (true) : (cycle += 1) {
        progress_node.completeOne();
        if (cycle % config.cycles_per_gen == 0) {
            while (true) {
                var new_text = try mode.gen(allocator, rand.random());
                defer allocator.free(new_text);
                if (std.unicode.utf8ValidateSlice(new_text)) {
                    std.mem.swap([]const u8, &text_document.text, &new_text);
                    break;
                }
            }

            text_document.version += 1;
            try client.transport().writeNotification(
                io,
                allocator,
                "textDocument/didChange",
                lsp.types.TextDocument.DidChangeParams,
                .{
                    .textDocument = .{ .uri = text_document.uri, .version = text_document.version },
                    .contentChanges = &[1]lsp.types.TextDocument.ContentChangeEvent{
                        .{ .text_document_content_change_whole_document = .{ .text = text_document.text } },
                    },
                },
                .{ .emit_null_optional_fields = false },
            );
        }

        const id, const json_message = try utils.fuzzFeatureRandom(
            io,
            allocator,
            client.transport(),
            text_document,
            rand.random(),
        );
        errdefer allocator.free(json_message);

        utils.waitForResponseToRequest(io, allocator, client.transport(), id) catch |err| switch (err) {
            error.EndOfStream => break json_message,
            else => |e| return e,
        };
    } else {
        std.log.err("Could not reproduce!", .{});
        return;
    };
    defer allocator.free(json_message);

    stderr_task.await(io);

    const processed_stderr = if (std.mem.find(u8, stderr.items, "panic:")) |panic_start|
        stderr.items[panic_start..]
    else
        stderr.items;

    const now: std.Io.Timestamp = .now(io, .awake);

    if (config.rpc) {
        var data = [_][]const u8{
            std.mem.asBytes(&@as(u32, @intCast(
                8 +
                    1 + config.zig_env.version.len +
                    1 + config.zls_version.len +
                    4 + text_document.text.len +
                    2 + json_message.len +
                    2 + processed_stderr.len,
            ))),

            std.mem.asBytes(&now.toMilliseconds()),

            std.mem.asBytes(&@as(u8, @intCast(config.zig_env.version.len))),
            config.zig_env.version,

            std.mem.asBytes(&@as(u8, @intCast(config.zls_version.len))),
            config.zls_version,

            std.mem.asBytes(&@as(u32, @intCast(text_document.text.len))),
            text_document.text,

            std.mem.asBytes(&@as(u16, @intCast(json_message.len))),
            json_message,

            std.mem.asBytes(&@as(u16, @intCast(processed_stderr.len))),
            processed_stderr,
        };

        var file_writer = std.Io.File.stdout().writer(io, &.{});
        try file_writer.interface.writeVecAll(&data);
    } else {
        var logs_dir = try std.Io.Dir.cwd().createDirPathOpen(io, "saved_logs", .{});
        defer logs_dir.close(io);

        var file_name_buffer: [16 + ".md".len]u8 = undefined;
        const file_name = std.mem.print(&file_name_buffer, "{x}.md", .{seed}) catch unreachable;
        std.debug.assert(file_name.len == file_name_buffer.len);
        const entry_file = try logs_dir.createFile(io, file_name, .{});
        defer entry_file.close(io);

        var file_writer = entry_file.writer(io, &.{});

        var timestamp_buf: [32]u8 = undefined;
        var data = [_][]const u8{
            "timestamp: ",
            try std.mem.print(&timestamp_buf, "{d}", .{now}),
            "\n",
            "zig version: ",
            config.zig_env.version,
            "\nzls version: ",
            config.zls_version,
            "\n\n",
            "principal:\n```zig\n",
            text_document.text,
            "\n```\n\n",
            "message:\n```json\n",
            json_message,
            "\n```\n\n",
            "stderr:\n```\n",
            processed_stderr,
            "\n```\n",
        };
        try file_writer.interface.writeVecAll(&data);
    }
}

fn readStderr(
    io: std.Io,
    allocator: std.mem.Allocator,
    stderr: std.Io.File,
    out: *std.ArrayList(u8),
) void {
    var buffer: [4096]u8 = undefined;
    var reader = stderr.reader(io, &buffer);
    reader.interface.appendRemaining(allocator, out, .unlimited) catch |err| switch (err) {
        error.OutOfMemory, error.ReadFailed, error.StreamTooLong => return,
    };
}
