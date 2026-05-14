const std = @import("std");
const builtin = @import("builtin");

const utils = @import("utils.zig");
const Fuzzer = @import("Fuzzer.zig");
const Mode = @import("mode.zig").Mode;
const Client = @import("Client.zig");
const lsp = @import("lsp");

pub fn reduce(
    allocator: std.mem.Allocator,
    mode: *Mode,
    config: *const Fuzzer.Config,
    seed: u64,
    progress_node: std.Progress.Node,
) !void {
    var client: Client = try .init(
        allocator,
        config.zls_path,
        config.zig_env.zig_exe,
        .Pipe,
    );
    errdefer _ = client.child_process.kill() catch @panic("failed to kill ZLS process");

    try client.initialize();

    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    var keep_running_stderr: std.atomic.Value(bool) = .init(true);
    const stderr_thread: std.Thread = try .spawn(.{}, readStderr, .{
        allocator,
        client.child_process.stderr.?,
        &stderr,
        &keep_running_stderr,
    });
    defer {
        keep_running_stderr.store(false, .release);
        stderr_thread.join();
    }

    var rand: std.Random.DefaultPrng = .init(seed);
    var text_document: lsp.types.TextDocumentItem = .{
        .uri = client.text_document_uri,
        .languageId = "zig",
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
                allocator,
                "textDocument/didChange",
                lsp.types.DidChangeTextDocumentParams,
                .{
                    .textDocument = .{ .uri = text_document.uri, .version = text_document.version },
                    .contentChanges = &[1]lsp.types.TextDocumentContentChangeEvent{
                        .{ .literal_1 = .{ .text = text_document.text } },
                    },
                },
                .{ .emit_null_optional_fields = false },
            );
        }

        const id, const json_message = try utils.fuzzFeatureRandom(
            client.transport(),
            allocator,
            text_document,
            rand.random(),
        );
        errdefer allocator.free(json_message);

        utils.waitForResponseToRequest(client.allocator, client.transport(), id) catch |err| switch (err) {
            error.EndOfStream => break json_message,
            else => |e| return e,
        };
    } else {
        std.log.err("Could not reproduce!", .{});
        return;
    };
    defer allocator.free(json_message);

    const processed_stderr = if (std.mem.indexOf(u8, stderr.items, "panic:")) |panic_start|
        stderr.items[panic_start..]
    else
        stderr.items;

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

            std.mem.asBytes(&std.time.milliTimestamp()),

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

        var file_writer = std.fs.File.stdout().writer(&.{});
        try file_writer.interface.writeVecAll(&data);
    } else {
        var logs_dir = try std.fs.cwd().makeOpenPath("saved_logs", .{});
        defer logs_dir.close();

        const file_name = std.fmt.hex(seed) ++ ".md";
        const entry_file = try logs_dir.createFile(file_name, .{});
        defer entry_file.close();

        var file_writer = entry_file.writer(&.{});

        var timestamp_buf: [32]u8 = undefined;
        var data = [_][]const u8{
            "timestamp: ",
            try std.fmt.bufPrint(&timestamp_buf, "{d}", .{std.time.milliTimestamp()}),
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
    allocator: std.mem.Allocator,
    stderr: std.fs.File,
    out: *std.ArrayList(u8),
    keep_running: *std.atomic.Value(bool),
) void {
    var buffer: [4096]u8 = undefined;
    while (keep_running.load(.acquire)) {
        const amt = stderr.read(&buffer) catch break;
        out.appendSlice(allocator, buffer[0..amt]) catch break;
    }
}
