const std = @import("std");
const lsp = @import("lsp.zig");
const uri = @import("uri.zig");
const tres = @import("tres.zig");
const utils = @import("utils.zig");
const ChildProcess = std.ChildProcess;

const Fuzzer = @This();

allocator: std.mem.Allocator,
proc: ChildProcess,

zig_version: []const u8,
zls_version: []const u8,

buf: std.ArrayListUnmanaged(u8) = .{},

prng: std.rand.DefaultPrng,
id: usize = 0,

stdin_file: LogFile,
stdout_file: LogFile,
stderr_file: LogFile,

stderr_thread: std.Thread,

args: Args,

/// represents rotating log files
pub const LogFile = struct {
    files: [len]std.fs.File,
    /// the index of the current file and name
    idx: u8 = 0,
    /// saved file names - used for cleanup and re-initialization
    names: [len][]const u8,

    pub const len = 2;
    pub const file_cap = std.mem.page_size * 2;

    /// init idx and names but leaves files undefined
    pub fn init(comptime name_fmt: []const u8, allocator: std.mem.Allocator) !LogFile {
        var result: LogFile = undefined;
        result.idx = 0;
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

        for (result.names) |*name, i| {
            var buf2: [8]u8 = undefined;
            const num = if (i == 0) "" else try std.fmt.bufPrint(&buf2, ".{}", .{i});
            name.* = try allocator.dupe(u8, try std.fmt.bufPrint(&buf, name_fmt, .{num}));
        }

        return result;
    }

    /// create files using previously init names
    pub fn createFiles(lf: *LogFile) !void {
        for (lf.files) |*file, i|
            file.* = try std.fs.cwd().createFile(lf.names[i], .{ .read = true, .truncate = true });
    }
    pub fn currentFile(lf: LogFile) std.fs.File {
        return lf.files[lf.idx];
    }
    pub fn currentName(lf: LogFile) []const u8 {
        return lf.names[lf.idx];
    }
    /// close all files
    pub fn close(lf: *LogFile) void {
        for (lf.files) |f| f.close();
    }
    pub fn nextIdx(idx: u8) u8 {
        return (idx + 1) % len;
    }

    fn writeFile(lf: *LogFile, bytes: []const u8, debug: bool) !void {
        _ = debug;
        const file = lf.currentFile();
        _ = try file.writeAll(bytes);
        if (try file.getEndPos() > file_cap / LogFile.len) {
            lf.idx = LogFile.nextIdx(lf.idx);
            const file2 = lf.currentFile();
            try file2.setEndPos(0);
            try file2.seekTo(0);
        }
    }
};

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
        .stdin_file = try LogFile.init("logs/stdin{s}.log", allocator),
        .stdout_file = try LogFile.init("logs/stdout{s}.log", allocator),
        .stderr_file = try LogFile.init("logs/stderr{s}.log", allocator),
        .stderr_thread = undefined,
        .proc = undefined,
        .prng = std.rand.DefaultPrng.init(seed),
    };
    try fuzzer.reset();
    return fuzzer;
}

pub fn kill(fuzzer: *Fuzzer) void {
    _ = fuzzer.proc.wait() catch |err| {
        std.log.err("{s}", .{@errorName(err)});
    };

    fuzzer.stderr_thread.join();

    // merge must be here after stderr_thread.join() to avoid race
    fuzzer.mergeAndCloseLogs() catch unreachable;
}

pub fn reset(fuzzer: *Fuzzer) !void {
    fuzzer.id = 0;

    fuzzer.proc = std.ChildProcess.init(&.{ fuzzer.args.zls_path, "--enable-debug-log" }, fuzzer.allocator);

    fuzzer.proc.stdin_behavior = .Pipe;
    fuzzer.proc.stderr_behavior = .Pipe;
    fuzzer.proc.stdout_behavior = .Pipe;

    try fuzzer.proc.spawn();

    try std.fs.cwd().makePath("logs");
    try fuzzer.stdin_file.createFiles();
    try fuzzer.stdout_file.createFiles();
    try fuzzer.stderr_file.createFiles();

    var info_buf: [512]u8 = undefined;
    const sub_info_data = try std.fmt.bufPrint(&info_buf, "zig version: {s}\nzls version: {s}\n", .{ fuzzer.zig_version, fuzzer.zls_version });
    try std.fs.cwd().writeFile("logs/info", sub_info_data);

    fuzzer.stderr_thread = try std.Thread.spawn(.{}, readStderr, .{fuzzer});
}

pub fn deinit(fuzzer: *Fuzzer) void {
    _ = fuzzer.proc.wait() catch |err| {
        std.log.err("{s}", .{@errorName(err)});
    };

    fuzzer.buf.deinit(fuzzer.allocator);

    fuzzer.stdin_file.close();
    fuzzer.stderr_file.close();
    fuzzer.stdout_file.close();

    fuzzer.stderr_thread.join();

    fuzzer.allocator.destroy(fuzzer);
}

fn readStderr(fuzzer: *Fuzzer) void {
    var buf: [std.mem.page_size]u8 = undefined;
    while (true) {
        const stderr = fuzzer.proc.stderr orelse break;
        const reader = stderr.reader();
        const amt = reader.read(&buf) catch break;
        fuzzer.stderr_file.writeFile(buf[0..amt], false) catch unreachable;
        if (fuzzer.id % 1000 == 0) std.log.info("heartbeat {}", .{fuzzer.id});
    }
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
    fuzzer.buf.items.len = 0;

    try tres.stringify(
        data,
        .{ .emit_null_optional_fields = false },
        fuzzer.buf.writer(fuzzer.allocator),
    );

    var zls_stdin = fuzzer.proc.stdin.?.writer();
    try zls_stdin.print("Content-Length: {d}\r\n\r\n", .{fuzzer.buf.items.len});
    try zls_stdin.writeAll(fuzzer.buf.items);
    try fuzzer.buf.appendSlice(fuzzer.allocator, "\n\n");

    try fuzzer.stdin_file.writeFile(fuzzer.buf.items, false);
}

pub fn readToBuffer(fuzzer: *Fuzzer) !void {
    const header = try fuzzer.readRequestHeader();
    try fuzzer.buf.ensureTotalCapacity(fuzzer.allocator, header.content_length + 1);
    fuzzer.buf.items.len = header.content_length;
    _ = try fuzzer.proc.stdout.?.reader().readAll(fuzzer.buf.items);
    fuzzer.buf.items.len += 1;
    fuzzer.buf.items[fuzzer.buf.items.len - 1] = '\n';
    try fuzzer.stdout_file.writeFile(fuzzer.buf.items, true);
}

pub fn readAndPrint(fuzzer: *Fuzzer) !void {
    try fuzzer.readToBuffer();
    std.log.info("{s}", .{fuzzer.buf.items});
}

/// copy contents from rotated log files into single file in correct order.
/// also rename the file so that names are always consistent
/// (ie stderr.1.log -> stderr.log).
fn mergeAndCloseLogs(fuzzer: *Fuzzer) !void {
    try fuzzer.mergeAndCloseLog(fuzzer.stdin_file);
    try fuzzer.mergeAndCloseLog(fuzzer.stdout_file);
    try fuzzer.mergeAndCloseLog(fuzzer.stderr_file);
}

fn mergeAndCloseLog(fuzzer: *Fuzzer, log_file: LogFile) !void {
    fuzzer.buf.items.len = 0;
    const startidx = log_file.idx;
    // start with the 'oldest' idx, stop at current
    var idx = LogFile.nextIdx(log_file.idx);
    while (true) : (idx = LogFile.nextIdx(idx)) {
        const file = log_file.files[idx];
        const buf_start = fuzzer.buf.items.len;
        const file_size = try file.getEndPos();
        try fuzzer.buf.ensureUnusedCapacity(fuzzer.allocator, file_size);
        fuzzer.buf.items.len += file_size;
        try file.seekTo(0);
        const amt = try file.readAll(fuzzer.buf.items[buf_start..fuzzer.buf.items.len]);
        std.debug.assert(amt == file_size);
        if (idx == startidx)
            break;
        // done with this 'old' file. close and delete it.
        file.close();
        try std.fs.cwd().deleteFile(log_file.names[idx]);
    }
    // write captured contents to current file
    const file = log_file.currentFile();
    try file.setEndPos(0);
    try file.seekTo(0);
    _ = try file.write(fuzzer.buf.items);
    file.close();
    // rename the log file if necessary
    // not necessary if idx == 0 (same name in this case)
    if (log_file.idx != 0) {
        try std.fs.cwd().rename(log_file.currentName(), log_file.names[0]);
    }
}

pub fn readUntilLastResponse(fuzzer: *Fuzzer, arena: std.mem.Allocator) !void {
    while (true) {
        try fuzzer.readToBuffer();

        var tree = std.json.Parser.init(arena, true);
        const vt = try tree.parse(fuzzer.buf.items);

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
