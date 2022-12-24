const std = @import("std");
const lsp = @import("lsp.zig");
const uri = @import("uri.zig");
const tres = @import("tres.zig");
const utils = @import("utils.zig");
const builtin = @import("builtin");
const ChildProcess = std.ChildProcess;

const Fuzzer = @This();

allocator: std.mem.Allocator,
proc: ChildProcess,

zig_version: []const u8,
zls_version: []const u8,

stdout_buf: std.ArrayListUnmanaged(u8) = .{},
stdin_buf: std.ArrayListUnmanaged(u8) = .{},
log_buf: std.ArrayListUnmanaged(u8) = .{},

prng: std.rand.DefaultPrng,
id: usize = 0,

stderr_file: std.fs.File,
stdout_file: std.fs.File,
stdin_file: std.fs.File,
stderr_thread: std.Thread,

args: Args,

pub const Mode = std.meta.Tag(Args.Base);
pub const Args = struct {
    argsit: std.process.ArgIterator,
    zls_path: []const u8,
    base: Base,

    pub const MarkovArg = enum {
        @"--maxlen",
        @"--cycles-per-gen",
    };
    pub const Markov = struct {
        training_dir: []const u8,
        maxlen: u32 = Defaults.maxlen,
        cycles_per_gen: u32 = Defaults.cycles_per_gen,

        pub const Defaults = struct {
            pub const maxlen = 512;
            pub const cycles_per_gen = 25;
        };
    };

    const Base = union(enum) {
        markov: Markov,
    };

    pub fn format(args: Args, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = try writer.write(args.zls_path);
        _ = try writer.write(" ");
        _ = try writer.write(@tagName(args.base));
        switch (args.base) {
            .markov => |m| {
                try writer.print(" {s} --maxlen {} --cycles-per-gen {}", .{ m.training_dir, m.maxlen, m.cycles_per_gen });
            },
        }
    }

    pub fn deinit(args: *Args) void {
        args.argsit.deinit();
    }
};

pub fn create(
    allocator: std.mem.Allocator,
    args: Args,
    zig_version: []const u8,
    zls_version: []const u8,
) !*Fuzzer {
    var seed: u64 = 0;
    try std.os.getrandom(std.mem.asBytes(&seed));

    var fuzzer = try allocator.create(Fuzzer);

    fuzzer.* = .{
        .allocator = allocator,
        .args = args,
        .zig_version = zig_version,
        .zls_version = zls_version,
        .stdin_file = undefined,
        .stdout_file = undefined,
        .stderr_file = undefined,
        .stderr_thread = undefined,
        .proc = undefined,
        .prng = std.rand.DefaultPrng.init(seed),
    };
    try fuzzer.reset();
    return fuzzer;
}

pub fn reset(fuzzer: *Fuzzer) !void {
    fuzzer.id = 0;

    fuzzer.proc = std.ChildProcess.init(&.{ fuzzer.args.zls_path, "--enable-debug-log" }, fuzzer.allocator);

    fuzzer.proc.stdin_behavior = .Pipe;
    fuzzer.proc.stderr_behavior = .Pipe;
    fuzzer.proc.stdout_behavior = .Pipe;

    try fuzzer.proc.spawn();

    try std.fs.cwd().makePath("logs");

    var info_buf: [512]u8 = undefined;
    const sub_info_data = try std.fmt.bufPrint(&info_buf, "zig version: {s}\nzls version: {s}\n", .{ fuzzer.zig_version, fuzzer.zls_version });
    try std.fs.cwd().writeFile("logs/info", sub_info_data);

    fuzzer.stdin_file = try std.fs.cwd().createFile("logs/stdin.log", .{ .read = true });
    _ = try fuzzer.stdin_file.write(eof_marker);

    fuzzer.stdout_file = try std.fs.cwd().createFile("logs/stdout.log", .{ .read = true });
    _ = try fuzzer.stdout_file.write(eof_marker);

    fuzzer.stderr_file = try std.fs.cwd().createFile("logs/stderr.log", .{ .read = true });
    _ = try fuzzer.stderr_file.write(eof_marker);
    fuzzer.stderr_thread = try std.Thread.spawn(.{}, readStderr, .{fuzzer});
}

pub fn kill(fuzzer: *Fuzzer) !void {
    _ = fuzzer.proc.wait() catch |err| {
        std.log.err("{s}", .{@errorName(err)});
    };

    fuzzer.stderr_thread.join();

    // reorder must be here after stderr_thread.join() and before logs are closed
    try fuzzer.reorderLogs();

    fuzzer.stdin_file.close();
    fuzzer.stderr_file.close();
    fuzzer.stdout_file.close();
}

pub fn deinit(fuzzer: *Fuzzer) void {
    _ = fuzzer.proc.wait() catch |err| {
        std.log.err("{s}", .{@errorName(err)});
    };

    fuzzer.stdout_buf.deinit(fuzzer.allocator);
    fuzzer.stdin_buf.deinit(fuzzer.allocator);
    fuzzer.log_buf.deinit(fuzzer.allocator);

    fuzzer.stderr_thread.join();

    fuzzer.stdin_file.close();
    fuzzer.stderr_file.close();
    fuzzer.stdout_file.close();

    fuzzer.allocator.destroy(fuzzer);
}

const eof_marker = "\n\n--- EOF ---\n\n";
const eof_marker_offset = -@intCast(isize, eof_marker.len);
const file_cap = std.mem.page_size * 2;

/// writes to file in a circular manner.
/// because of this `eof_marker` is used to denote EOF
fn fileWrite(bytes_: []const u8, file: std.fs.File) !void {
    var bytes: []const u8 = bytes_;
    // TODO  this check should be removed once this method is known to work.
    if (builtin.mode == .Debug) {
        // verify the bytes at file.pos match `eof_marker`
        const eof_pos = try file.getPos();
        std.debug.assert(eof_pos >= eof_marker.len);
        var buf: [eof_marker.len]u8 = undefined;
        try file.seekBy(eof_marker_offset);
        _ = try file.read(&buf);
        std.debug.assert(std.mem.eql(u8, eof_marker, &buf));
    }
    try file.seekBy(eof_marker_offset);
    while (bytes.len > 0) {
        var len = @min(file_cap, bytes.len);
        const tail_len = file_cap - try file.getPos();
        if (len > tail_len) {
            const discard = len - tail_len;
            const amt = try file.write(bytes[0..discard]);
            std.debug.assert(amt == discard);
            bytes = bytes[discard..];
            len -= discard;
            try file.seekTo(0);
        }
        const amt = try file.write(bytes[0..len]);
        std.debug.assert(amt == len);
        bytes = bytes[len..];
    }
    _ = try file.write(eof_marker);
}

// needed because files are written to circularly like a ring buffer.
// removes `eof_marker`. reorders file so that it starts after `eof_marker` and
// ends just before it.
fn reorderLog(fuzzer: *Fuzzer, file: std.fs.File) !void {
    fuzzer.log_buf.items.len = 0;
    const file_size = file.getEndPos() catch return;
    try fuzzer.log_buf.ensureTotalCapacity(fuzzer.allocator, file_size);
    fuzzer.log_buf.items.len = file_size;
    try file.seekTo(0);
    const amt = try file.readAll(fuzzer.log_buf.items);
    std.debug.assert(amt == file_size);
    const eof_idx = std.mem.indexOf(u8, fuzzer.log_buf.items, eof_marker) orelse unreachable;
    try file.setEndPos(0);
    try file.seekTo(0);
    _ = try file.writeAll(fuzzer.log_buf.items[eof_idx + eof_marker.len ..]);
    _ = try file.writeAll(fuzzer.log_buf.items[0..eof_idx]);
}

// rewrites log files considering `eof_marker`.
// makes them easier to read. reader doesn't have to search for `eof_marker`.
fn reorderLogs(fuzzer: *Fuzzer) !void {
    try fuzzer.reorderLog(fuzzer.stdin_file);
    try fuzzer.reorderLog(fuzzer.stdout_file);
    try fuzzer.reorderLog(fuzzer.stderr_file);
}

fn readStderr(fuzzer: *Fuzzer) void {
    var buf: [std.mem.page_size]u8 = undefined;
    while (true) {
        const stderr = fuzzer.proc.stderr orelse break;
        const reader = stderr.reader();
        const amt = reader.read(&buf) catch break;
        fileWrite(buf[0..amt], fuzzer.stderr_file) catch unreachable;
        if (fuzzer.id % 1000 == 0) std.log.warn("heartbeat {}", .{fuzzer.id});
    }

    std.log.err("stderr failure", .{});
}

const RequestHeader = struct {
    content_length: usize,
};

pub fn readRequestHeader(fuzzer: *Fuzzer) !RequestHeader {
    const allocator = fuzzer.allocator;
    const reader = fuzzer.proc.stdout.?.reader();

    var r = RequestHeader{
        .content_length = undefined,
    };

    var has_content_length = false;
    while (true) {
        const header = try reader.readUntilDelimiterAlloc(allocator, '\n', 0x100);
        defer allocator.free(header);

        if (header.len == 0 or header[header.len - 1] != '\r') return error.MissingCarriageReturn;
        if (header.len == 1) break;

        const header_name = header[0 .. std.mem.indexOf(u8, header, ": ") orelse return error.MissingColon];
        const header_value = header[header_name.len + 2 .. header.len - 1];

        if (std.mem.eql(u8, header_name, "Content-Length")) {
            if (header_value.len == 0) return error.MissingHeaderValue;
            r.content_length = std.fmt.parseInt(usize, header_value, 10) catch return error.InvalidContentLength;
            has_content_length = true;
        } else if (std.mem.eql(u8, header_name, "Content-Type")) {} else {
            return error.UnknownHeader;
        }
    }
    if (!has_content_length) return error.MissingContentLength;

    return r;
}

pub fn random(fuzzer: *Fuzzer) std.rand.Random {
    return fuzzer.prng.random();
}

pub fn writeJson(fuzzer: *Fuzzer, data: anytype) !void {
    fuzzer.stdin_buf.items.len = 0;

    try tres.stringify(
        data,
        .{ .emit_null_optional_fields = false },
        fuzzer.stdin_buf.writer(fuzzer.allocator),
    );

    var zls_stdin = fuzzer.proc.stdin.?.writer();
    try zls_stdin.print("Content-Length: {d}\r\n\r\n", .{fuzzer.stdin_buf.items.len});
    try zls_stdin.writeAll(fuzzer.stdin_buf.items);

    try fileWrite(fuzzer.stdin_buf.items, fuzzer.stdin_file);
    try fileWrite("\n\n", fuzzer.stdin_file);
}

pub fn readToBuffer(fuzzer: *Fuzzer) !void {
    const header = try fuzzer.readRequestHeader();
    try fuzzer.stdout_buf.ensureTotalCapacity(fuzzer.allocator, header.content_length + 1);
    fuzzer.stdout_buf.items.len = header.content_length;
    _ = try fuzzer.proc.stdout.?.reader().readAll(fuzzer.stdout_buf.items);
    fuzzer.stdout_buf.items.len += 1;
    fuzzer.stdout_buf.items[fuzzer.stdout_buf.items.len - 1] = '\n';

    // TODO figure out why stdout_file ends being 2x file_cap when it should not
    // get longer than file_cap
    try fileWrite(fuzzer.stdout_buf.items, fuzzer.stdout_file);
}

pub fn readAndPrint(fuzzer: *Fuzzer) !void {
    try fuzzer.readToBuffer();
    std.log.info("{s}", .{fuzzer.stdout_buf.items});
}

pub fn readUntilLastResponse(fuzzer: *Fuzzer, arena: std.mem.Allocator) !void {
    while (true) {
        try fuzzer.readToBuffer();

        var tree = std.json.Parser.init(arena, true);
        const vt = try tree.parse(fuzzer.stdout_buf.items);

        if (vt.root.Object.get("method") != null) continue;
        if (vt.root.Object.get("id") != null) break;
    }
}

pub fn initCycle(fuzzer: *Fuzzer) !void {
    var arena = std.heap.ArenaAllocator.init(fuzzer.allocator);
    defer arena.deinit();

    try fuzzer.writeJson(.{
        .jsonrpc = "2.0",
        .id = fuzzer.id,
        .method = "initialize",
        .params = lsp.InitializeParams{
            .capabilities = .{},
        },
    });
    fuzzer.id +%= 1;
    try fuzzer.readUntilLastResponse(arena.allocator());

    try fuzzer.writeJson(.{
        .jsonrpc = "2.0",
        .method = "initialized",
        .params = lsp.InitializedParams{},
    });
}

pub fn open(
    fuzzer: *Fuzzer,
    f_uri: []const u8,
    data: []const u8,
) !void {
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

pub fn change(
    fuzzer: *Fuzzer,
    f_uri: []const u8,
    data: []const u8,
) !void {
    try fuzzer.writeJson(.{
        .jsonrpc = "2.0",
        .method = "textDocument/didChange",
        .params = lsp.DidChangeTextDocumentParams{
            .textDocument = .{
                .uri = f_uri,
                .version = 0,
            },
            .contentChanges = &[1]lsp.TextDocumentContentChangeEvent{.{
                .literal_1 = .{ .text = data },
            }},
        },
    });
}

/// Returns opened file URI; caller owns memory
// not used anywhere
// pub fn openFile(fuzzer: *Fuzzer, path: []const u8) ![]const u8 {
//     // std.debug.print("path {s}\n", .{path});
//     // if (true) @panic("asdf");
//     var file = try std.fs.cwd().openFile(path, .{});
//     defer file.close();

//     const size = (try file.stat()).size;

//     try fuzzer.open_buf.ensureTotalCapacity(fuzzer.allocator, size);
//     fuzzer.open_buf.items.len = size;
//     _ = try file.readAll(fuzzer.open_buf.items);

//     const f_uri = try uri.fromPath(fuzzer.allocator, path);

//     try fuzzer.open(f_uri, fuzzer.open_buf);

//     return f_uri;
// }

// Random feature fuzzing

pub const WhatToFuzz = enum {
    completion,
    definition,
    references,
    signature_help,
    hover,
    semantic,
    document_symbol,
};

pub fn fuzzFeatureRandom(
    fuzzer: *Fuzzer,
    arena: std.mem.Allocator,
    file_uri: []const u8,
    file_data: []const u8,
) !void {
    const rand = fuzzer.random();
    const wtf = rand.enumValue(WhatToFuzz);

    // std.log.info("Fuzzing {s} w/ {s}...", .{ file_uri, @tagName(wtf) });

    switch (wtf) {
        .completion => {
            try fuzzer.writeJson(.{
                .jsonrpc = "2.0",
                .id = fuzzer.id,
                .method = "textDocument/completion",
                .params = lsp.CompletionParams{
                    .textDocument = .{
                        .uri = file_uri,
                    },
                    .position = utils.randomPosition(rand, file_data),
                },
            });

            fuzzer.id +%= 1;
            try fuzzer.readUntilLastResponse(arena);
        },
        .definition => {
            try fuzzer.writeJson(.{
                .jsonrpc = "2.0",
                .id = fuzzer.id,
                .method = "textDocument/definition",
                .params = lsp.DefinitionParams{
                    .textDocument = .{
                        .uri = file_uri,
                    },
                    .position = utils.randomPosition(rand, file_data),
                },
            });

            fuzzer.id +%= 1;
            try fuzzer.readUntilLastResponse(arena);
        },
        .references => {
            try fuzzer.writeJson(.{
                .jsonrpc = "2.0",
                .id = fuzzer.id,
                .method = "textDocument/references",
                .params = lsp.ReferenceParams{
                    .context = .{
                        .includeDeclaration = rand.boolean(),
                    },
                    .textDocument = .{
                        .uri = file_uri,
                    },
                    .position = utils.randomPosition(rand, file_data),
                },
            });

            fuzzer.id +%= 1;
            try fuzzer.readUntilLastResponse(arena);
        },
        .signature_help => {
            try fuzzer.writeJson(.{
                .jsonrpc = "2.0",
                .id = fuzzer.id,
                .method = "textDocument/signatureHelp",
                .params = lsp.SignatureHelpParams{
                    .textDocument = .{
                        .uri = file_uri,
                    },
                    .position = utils.randomPosition(rand, file_data),
                },
            });

            fuzzer.id +%= 1;
            try fuzzer.readUntilLastResponse(arena);
        },
        .hover => {
            try fuzzer.writeJson(.{
                .jsonrpc = "2.0",
                .id = fuzzer.id,
                .method = "textDocument/hover",
                .params = lsp.HoverParams{
                    .textDocument = .{
                        .uri = file_uri,
                    },
                    .position = utils.randomPosition(rand, file_data),
                },
            });

            fuzzer.id +%= 1;
            try fuzzer.readUntilLastResponse(arena);
        },
        .semantic => {
            try fuzzer.writeJson(.{
                .jsonrpc = "2.0",
                .id = fuzzer.id,
                .method = "textDocument/semanticTokens/full",
                .params = lsp.SemanticTokensParams{
                    .textDocument = .{
                        .uri = file_uri,
                    },
                },
            });

            fuzzer.id +%= 1;
            try fuzzer.readUntilLastResponse(arena);
        },
        .document_symbol => {
            try fuzzer.writeJson(.{
                .jsonrpc = "2.0",
                .id = fuzzer.id,
                .method = "textDocument/documentSymbol",
                .params = lsp.DocumentSymbolParams{
                    .textDocument = .{
                        .uri = file_uri,
                    },
                },
            });

            fuzzer.id +%= 1;
            try fuzzer.readUntilLastResponse(arena);
        },
    }
}
