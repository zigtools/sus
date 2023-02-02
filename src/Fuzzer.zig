const std = @import("std");
const lsp = @import("zig-lsp");
const uri = @import("uri.zig");
const utils = @import("utils.zig");
const lsp_types = lsp.types;
const ChildProcess = std.ChildProcess;

const Fuzzer = @This();

pub const Connection = lsp.Connection(std.fs.File.Reader, std.fs.File.Writer, Fuzzer);

allocator: std.mem.Allocator,
connection: Connection,
proc: ChildProcess,

zig_version: []const u8,
zls_version: []const u8,

buf: std.ArrayListUnmanaged(u8) = .{},

prng: std.rand.DefaultPrng,

stdin_file: LogFile,
stdout_file: LogFile,
stderr_file: LogFile,

stderr_thread: std.Thread,

args: Args,

pub const LogFile = struct {
    const Compressor = std.compress.deflate.Compressor(std.fs.File.Writer);

    allocator: std.mem.Allocator,
    path: []const u8,

    loaded: bool = false,
    file: std.fs.File,
    compressor: Compressor,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !LogFile {
        var lf = LogFile{
            .allocator = allocator,
            .path = path,

            .file = undefined,
            .compressor = undefined,
        };
        return lf;
    }

    pub fn reset(log_file: *LogFile) !void {
        if (log_file.loaded) {
            log_file.close();
        }
        log_file.file = try std.fs.cwd().createFile(log_file.path, .{});
        log_file.compressor = try std.compress.deflate.compressor(log_file.allocator, log_file.file.writer(), .{});
        log_file.loaded = true;
    }

    pub fn close(log_file: *LogFile) void {
        if (!log_file.loaded) @panic("Double close");
        log_file.compressor.close() catch @panic("Flush failure");
        log_file.file.close();
        log_file.loaded = false;
        log_file.compressor.deinit();
    }

    pub fn writer(log_file: *LogFile) Compressor.Writer {
        return log_file.compressor.writer();
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
        .connection = undefined,
        .args = args,
        .zig_version = zig_version,
        .zls_version = zls_version,
        .stdin_file = try LogFile.init(allocator, "logs/stdin.log"),
        .stdout_file = try LogFile.init(allocator, "logs/stdout.log"),
        .stderr_file = try LogFile.init(allocator, "logs/stderr.log"),
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
    fuzzer.stdin_file.close();
    fuzzer.stdout_file.close();
    fuzzer.stderr_file.close();
}

pub fn reset(fuzzer: *Fuzzer) !void {
    fuzzer.proc = std.ChildProcess.init(&.{ fuzzer.args.zls_path, "--enable-debug-log" }, fuzzer.allocator);

    fuzzer.proc.stdin_behavior = .Pipe;
    fuzzer.proc.stderr_behavior = .Pipe;
    fuzzer.proc.stdout_behavior = .Pipe;

    try fuzzer.proc.spawn();

    try std.fs.cwd().makePath("logs");
    try fuzzer.stdin_file.reset();
    try fuzzer.stdout_file.reset();
    try fuzzer.stderr_file.reset();

    var info_buf: [512]u8 = undefined;
    const sub_info_data = try std.fmt.bufPrint(&info_buf, "zig version: {s}\nzls version: {s}\n", .{ fuzzer.zig_version, fuzzer.zls_version });
    try std.fs.cwd().writeFile("logs/info", sub_info_data);

    fuzzer.connection = Connection.init(fuzzer.allocator, fuzzer.proc.stdout.?.reader(), fuzzer.proc.stdin.?.writer(), fuzzer);

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
        fuzzer.stderr_file.writer().writeAll(buf[0..amt]) catch unreachable;
        if (fuzzer.connection.id % 1000 == 0) std.log.info("heartbeat {}", .{fuzzer.connection.id});
    }
}

const RequestHeader = struct {
    content_length: usize,
};

pub fn random(fuzzer: *Fuzzer) std.rand.Random {
    return fuzzer.prng.random();
}

pub fn closeFiles(fuzzer: *Fuzzer) void {
    fuzzer.stdin_file.close();
    fuzzer.stderr_file.close();
    fuzzer.stdout_file.close();
}

pub fn initCycle(fuzzer: *Fuzzer) !void {
    var arena = std.heap.ArenaAllocator.init(fuzzer.allocator);
    defer arena.deinit();

    _ = try fuzzer.connection.requestSync(arena.allocator(), "initialize", .{
        .capabilities = .{},
    });
    try fuzzer.connection.notify("initialized", .{});
}

pub fn open(
    fuzzer: *Fuzzer,
    f_uri: []const u8,
    data: []const u8,
) !void {
    try fuzzer.connection.notify("textDocument/didOpen", .{
        .textDocument = .{
            .uri = f_uri,
            .languageId = "zig",
            .version = 0,
            .text = data,
        },
    });
}

pub fn change(
    fuzzer: *Fuzzer,
    f_uri: []const u8,
    data: []const u8,
) !void {
    try fuzzer.connection.notify("textDocument/didChange", .{
        .textDocument = .{
            .uri = f_uri,
            .version = 0,
        },
        .contentChanges = &[1]lsp_types.TextDocumentContentChangeEvent{
            .{
                .literal_1 = .{ .text = data },
            },
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
    declaration,
    definition,
    type_definition,
    implementation,
    references,
    signature_help,
    hover,
    semantic,
    document_symbol,
    folding_range,
    formatting,
    document_highlight,
    inlay_hint,
    // selection_range,
    rename,
};

pub fn fuzzFeatureRandom(
    fuzzer: *Fuzzer,
    arena: std.mem.Allocator,
    file_uri: []const u8,
    file_data: []const u8,
) !void {
    const rand = fuzzer.random();
    const wtf = rand.enumValue(WhatToFuzz);

    switch (wtf) {
        .completion => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/completion", .{
                .textDocument = .{
                    .uri = file_uri,
                },
                .position = utils.randomPosition(rand, file_data),
            });
        },
        .declaration => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/declaration", .{
                .textDocument = .{
                    .uri = file_uri,
                },
                .position = utils.randomPosition(rand, file_data),
            });
        },
        .definition => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/definition", .{
                .textDocument = .{
                    .uri = file_uri,
                },
                .position = utils.randomPosition(rand, file_data),
            });
        },
        .type_definition => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/typeDefinition", .{
                .textDocument = .{
                    .uri = file_uri,
                },
                .position = utils.randomPosition(rand, file_data),
            });
        },
        .implementation => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/implementation", .{
                .textDocument = .{
                    .uri = file_uri,
                },
                .position = utils.randomPosition(rand, file_data),
            });
        },
        .references => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/references", .{
                .context = .{
                    .includeDeclaration = rand.boolean(),
                },
                .textDocument = .{
                    .uri = file_uri,
                },
                .position = utils.randomPosition(rand, file_data),
            });
        },
        .signature_help => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/signatureHelp", .{
                .textDocument = .{
                    .uri = file_uri,
                },
                .position = utils.randomPosition(rand, file_data),
            });
        },
        .hover => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/hover", .{
                .textDocument = .{
                    .uri = file_uri,
                },
                .position = utils.randomPosition(rand, file_data),
            });
        },
        .semantic => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/semanticTokens/full", .{
                .textDocument = .{
                    .uri = file_uri,
                },
            });
        },
        .document_symbol => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/documentSymbol", .{
                .textDocument = .{
                    .uri = file_uri,
                },
            });
        },
        .folding_range => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/foldingRange", .{
                .textDocument = .{
                    .uri = file_uri,
                },
            });
        },
        .formatting => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/formatting", .{
                .textDocument = .{
                    .uri = file_uri,
                },
                .options = .{
                    .tabSize = 4,
                    .insertSpaces = true,
                },
            });
        },
        .document_highlight => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/documentHighlight", .{
                .textDocument = .{
                    .uri = file_uri,
                },
                .position = utils.randomPosition(rand, file_data),
            });
        },
        .inlay_hint => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/inlayHint", .{
                .textDocument = .{
                    .uri = file_uri,
                },
                .range = utils.randomRange(rand, file_data),
            });
        },
        // TODO: Nest positions properly to avoid crash
        // .selection_range => {
        //     var positions: [16]lsp_types.Position = undefined;
        //     for (positions) |*pos| {
        //         pos.* = utils.randomPosition(rand, file_data);
        //     }
        //     _ = try fuzzer.connection.requestSync(arena, "textDocument/selectionRange", .{
        //         .textDocument = .{
        //             .uri = file_uri,
        //         },
        //         .positions = &positions,
        //     });
        // },
        .rename => {
            _ = try fuzzer.connection.requestSync(arena, "textDocument/rename", .{
                .textDocument = .{
                    .uri = file_uri,
                },
                .position = utils.randomPosition(rand, file_data),
                .newName = "helloWorld",
            });
        },
    }
}

// Handlers

pub fn @"window/logMessage"(_: *Connection, params: lsp.Params("window/logMessage")) !void {
    // std.log.info("log message: ", .{params.})
    switch (params.type) {
        .Error => std.log.warn("logMessage err: {s}", .{params.message}),
        .Warning => std.log.warn("logMessage warn: {s}", .{params.message}),
        .Info => std.log.warn("logMessage info: {s}", .{params.message}),
        .Log => std.log.warn("logMessage log: {s}", .{params.message}),
    }
}
pub fn @"textDocument/publishDiagnostics"(_: *Connection, _: lsp.Params("textDocument/publishDiagnostics")) !void {}

pub fn dataRecv(
    conn: *Connection,
    data: []const u8,
) !void {
    const fuzzer = conn.context;
    const writer = fuzzer.stdout_file.writer();
    try writer.writeAll(data);
    try writer.writeAll("\n");
}

pub fn dataSend(
    conn: *Connection,
    data: []const u8,
) !void {
    const fuzzer = conn.context;
    const writer = fuzzer.stdin_file.writer();
    try writer.writeAll(data);
    try writer.writeAll("\n");
}
