const std = @import("std");
const lsp = @import("zig-lsp");
const utils = @import("utils.zig");
const lsp_types = lsp.types;
const ChildProcess = std.ChildProcess;
const Mode = @import("mode.zig").Mode;
const ModeName = @import("mode.zig").ModeName;

const Fuzzer = @This();

pub const Connection = lsp.Connection(std.fs.File.Reader, std.fs.File.Writer, Fuzzer);

// note: if you add or change config options, update the usage in main.zig then
// run `zig build run -- --help` and paste the contents into the README
pub const Config = struct {
    output_as_dir: bool,
    zls_path: []const u8,
    mode_name: ModeName,
    cycles_per_gen: u32,

    zig_env: std.json.Parsed(ZigEnv),
    zls_version: []const u8,

    pub const Defaults = struct {
        pub const output_as_dir = false;
        pub const cycles_per_gen: u32 = 25;
    };

    pub const ZigEnv = struct {
        zig_exe: []const u8,
        lib_dir: []const u8,
        std_dir: []const u8,
        // global_cache_dir: []const u8,
        version: []const u8,
        // target: []const u8,
    };

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        self.zig_env.deinit();
        allocator.free(self.zls_path);
        allocator.free(self.zls_version);
        self.* = undefined;
    }
};

allocator: std.mem.Allocator,
connection: Connection,
progress_node: *std.Progress.Node,
mode: *Mode,
config: Config,
rand: std.rand.DefaultPrng,
cycle: usize = 0,

zls_process: ChildProcess,
stderr_thread_keep_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
stderr_thread: std.Thread,

stdin_output: std.ArrayListUnmanaged(u8) = .{},
stdout_output: std.ArrayListUnmanaged(u8) = .{},
stderr_output: std.ArrayListUnmanaged(u8) = .{},
principal_file_source: []const u8 = "",
principal_file_uri: []const u8,

pub fn create(
    allocator: std.mem.Allocator,
    progress: *std.Progress,
    mode: *Mode,
    config: Config,
) !*Fuzzer {
    var fuzzer = try allocator.create(Fuzzer);
    errdefer allocator.destroy(fuzzer);

    var seed: u64 = 0;
    try std.os.getrandom(std.mem.asBytes(&seed));

    const cwd_path = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd_path);

    const principal_file_path = try std.fs.path.join(allocator, &.{ cwd_path, "tmp", "principal.zig" });
    defer allocator.free(principal_file_path);

    const principal_file_uri = try std.fmt.allocPrint(allocator, "{+/}", .{std.Uri{
        .scheme = "file",
        .user = null,
        .password = null,
        .host = null,
        .port = null,
        .path = principal_file_path,
        .query = null,
        .fragment = null,
    }});
    errdefer allocator.free(principal_file_uri);

    var env_map = try allocator.create(std.process.EnvMap);
    env_map.* = std.process.getEnvMap(allocator) catch std.process.EnvMap.init(allocator);
    try env_map.put("NO_COLOR", "");

    defer {
        env_map.deinit();
        allocator.destroy(env_map);
    }

    var zls_process = std.ChildProcess.init(&.{ config.zls_path, "--enable-debug-log" }, allocator);
    zls_process.env_map = env_map;
    zls_process.stdin_behavior = .Pipe;
    zls_process.stderr_behavior = .Pipe;
    zls_process.stdout_behavior = .Pipe;

    try zls_process.spawn();
    errdefer _ = zls_process.kill() catch @panic("failed to kill zls process");

    fuzzer.* = .{
        .allocator = allocator,
        .connection = undefined, // set below
        .progress_node = progress.start("fuzzer", 0),
        .mode = mode,
        .config = config,
        .rand = std.rand.DefaultPrng.init(seed),
        .zls_process = zls_process,
        .stderr_thread = undefined, // set below
        .principal_file_uri = principal_file_uri,
    };

    fuzzer.connection = Connection.init(
        allocator,
        zls_process.stdout.?.reader(),
        zls_process.stdin.?.writer(),
        fuzzer,
    );

    fuzzer.stderr_thread = try std.Thread.spawn(.{}, readStderr, .{fuzzer});

    return fuzzer;
}

pub fn wait(fuzzer: *Fuzzer) void {
    fuzzer.stderr_thread_keep_running.store(false, .Release);
    fuzzer.stderr_thread.join();

    _ = fuzzer.zls_process.wait() catch |err| {
        std.log.err("failed to await zls process: {}", .{err});
    };
}

pub fn destroy(fuzzer: *Fuzzer) void {
    const allocator = fuzzer.allocator;

    fuzzer.stdin_output.deinit(allocator);
    fuzzer.stdout_output.deinit(allocator);
    fuzzer.stderr_output.deinit(allocator);

    allocator.free(fuzzer.principal_file_source);
    allocator.free(fuzzer.principal_file_uri);

    fuzzer.connection.write_buffer.deinit(fuzzer.connection.allocator);
    fuzzer.connection.callback_map.deinit(fuzzer.connection.allocator);

    fuzzer.* = undefined;
    allocator.destroy(fuzzer);
}

fn readStderr(fuzzer: *Fuzzer) void {
    var buffer: [std.mem.page_size]u8 = undefined;
    while (fuzzer.stderr_thread_keep_running.load(.Acquire)) {
        const stderr = fuzzer.zls_process.stderr.?;
        const amt = stderr.reader().read(&buffer) catch break;
        fuzzer.stderr_output.appendSlice(fuzzer.allocator, buffer[0..amt]) catch break;
    }
}

pub fn random(fuzzer: *Fuzzer) std.rand.Random {
    return fuzzer.rand.random();
}

pub fn initCycle(fuzzer: *Fuzzer) !void {
    fuzzer.progress_node.activate();

    var arena = std.heap.ArenaAllocator.init(fuzzer.allocator);
    defer arena.deinit();

    _ = try fuzzer.connection.requestSync(arena.allocator(), "initialize", lsp_types.InitializeParams{
        .capabilities = .{},
    });
    try fuzzer.connection.notify("initialized", .{});

    var settings = std.json.ObjectMap.init(fuzzer.allocator);
    defer settings.deinit();
    try settings.putNoClobber("skip_std_references", .{ .bool = true }); // references collection into std is very slow
    try settings.putNoClobber("zig_exe_path", .{ .string = fuzzer.config.zig_env.value.zig_exe });

    try fuzzer.connection.notify("workspace/didChangeConfiguration", lsp_types.DidChangeConfigurationParams{
        .settings = .{ .object = settings },
    });

    try fuzzer.connection.notify("textDocument/didOpen", lsp_types.DidOpenTextDocumentParams{ .textDocument = .{
        .uri = fuzzer.principal_file_uri,
        .languageId = "zig",
        .version = @intCast(fuzzer.cycle),
        .text = fuzzer.principal_file_source,
    } });
}

pub fn closeCycle(fuzzer: *Fuzzer) !void {
    fuzzer.progress_node.end();

    var arena = std.heap.ArenaAllocator.init(fuzzer.allocator);
    defer arena.deinit();

    _ = try fuzzer.connection.notify("textDocument/didClose", .{
        .textDocument = .{ .uri = fuzzer.principal_file_uri },
    });

    _ = try fuzzer.connection.requestSync(arena.allocator(), "shutdown", {});
    try fuzzer.connection.notify("exit", {});
}

pub fn fuzz(fuzzer: *Fuzzer) !void {
    fuzzer.progress_node.setCompletedItems(fuzzer.cycle);
    fuzzer.cycle += 1;

    if (fuzzer.cycle % fuzzer.config.cycles_per_gen == 0) {
        var arena_allocator = std.heap.ArenaAllocator.init(fuzzer.allocator);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        while (fuzzer.connection.callback_map.count() != 0) {
            _ = arena_allocator.reset(.retain_capacity);
            try fuzzer.connection.acceptUntilResponse(arena);
        }

        while (true) {
            fuzzer.allocator.free(fuzzer.principal_file_source);
            fuzzer.principal_file_source = try fuzzer.mode.gen(fuzzer.allocator);
            if (std.unicode.utf8ValidateSlice(fuzzer.principal_file_source)) break;
        }

        try fuzzer.connection.notify("textDocument/didChange", lsp_types.DidChangeTextDocumentParams{
            .textDocument = .{ .uri = fuzzer.principal_file_uri, .version = @intCast(fuzzer.cycle) },
            .contentChanges = &[1]lsp_types.TextDocumentContentChangeEvent{
                .{ .literal_1 = .{ .text = fuzzer.principal_file_source } },
            },
        });
    }
    try fuzzer.fuzzFeatureRandom(fuzzer.principal_file_uri, fuzzer.principal_file_source);
}

pub fn logPrincipal(fuzzer: *Fuzzer) !void {
    var bytes: [32]u8 = undefined;
    fuzzer.random().bytes(&bytes);

    try std.fs.cwd().makePath("saved_logs");

    const log_entry_path = try std.fmt.allocPrint(fuzzer.allocator, "saved_logs/{d}", .{std.fmt.fmtSliceHexLower(&bytes)});
    defer fuzzer.allocator.free(log_entry_path);

    if (fuzzer.config.output_as_dir) {
        try std.fs.cwd().makeDir(log_entry_path);

        var entry_dir = try std.fs.cwd().openDir(log_entry_path, .{});
        defer entry_dir.close();

        const principal_file = try entry_dir.createFile("principal.zig", .{});
        defer principal_file.close();

        try principal_file.writeAll(fuzzer.principal_file_source);

        for (
            [_]std.ArrayListUnmanaged(u8){ fuzzer.stdin_output, fuzzer.stdout_output, fuzzer.stderr_output },
            [_][]const u8{ "stdin.log", "stdout.log", "stderr.log" },
        ) |output, path| {
            const output_file = try entry_dir.createFile(path, .{});
            defer output_file.close();

            try output_file.writeAll(output.items);
        }
    } else {
        const entry_file = try std.fs.cwd().createFile(log_entry_path, .{});
        defer entry_file.close();

        var iovecs: [13]std.os.iovec_const = undefined;

        for ([_][]const u8{
            std.mem.asBytes(&std.time.milliTimestamp()),

            std.mem.asBytes(&@as(u8, @intCast(fuzzer.config.zig_env.value.version.len))),
            fuzzer.config.zig_env.value.version,

            std.mem.asBytes(&@as(u8, @intCast(fuzzer.config.zls_version.len))),
            fuzzer.config.zls_version,

            std.mem.asBytes(&@as(u32, @intCast(fuzzer.principal_file_source.len))),
            fuzzer.principal_file_source,

            std.mem.asBytes(&@as(u32, @intCast(fuzzer.stdin_output.items.len))),
            fuzzer.stdin_output.items,

            std.mem.asBytes(&@as(u32, @intCast(fuzzer.stdout_output.items.len))),
            fuzzer.stdout_output.items,

            std.mem.asBytes(&@as(u32, @intCast(fuzzer.stderr_output.items.len))),
            fuzzer.stderr_output.items,
        }, 0..) |val, i| {
            iovecs[i] = .{
                .iov_base = val.ptr,
                .iov_len = val.len,
            };
        }

        try entry_file.writevAll(&iovecs);
    }
}

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

fn requestCallback(comptime method: []const u8) lsp.RequestCallback(Connection, method) {
    const Context = struct {
        pub fn res(_: *Connection, _: lsp.Result(method)) !void {}

        pub fn err(_: *Connection, resperr: lsp_types.ResponseError) !void {
            return switch (resperr.code) {
                @intFromEnum(lsp_types.ErrorCodes.ParseError) => error.ParseError,
                @intFromEnum(lsp_types.ErrorCodes.InvalidRequest) => error.InvalidRequest,
                @intFromEnum(lsp_types.ErrorCodes.MethodNotFound) => error.MethodNotFound,
                @intFromEnum(lsp_types.ErrorCodes.InvalidParams) => error.InvalidParams,
                @intFromEnum(lsp_types.ErrorCodes.InternalError) => error.InternalError,
                @intFromEnum(lsp_types.ErrorCodes.ServerNotInitialized) => error.ServerNotInitialized,
                @intFromEnum(lsp_types.ErrorCodes.UnknownErrorCode) => error.UnknownErrorCode,
                else => error.InternalError,
            };
        }
    };
    return .{
        .onResponse = &Context.res,
        .onError = &Context.err,
    };
}

pub fn fuzzFeatureRandom(
    fuzzer: *Fuzzer,
    file_uri: []const u8,
    file_data: []const u8,
) !void {
    const rand = fuzzer.random();
    const wtf = rand.enumValue(WhatToFuzz);

    switch (wtf) {
        .completion => try fuzzer.connection.request(
            "textDocument/completion",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
            requestCallback("textDocument/completion"),
        ),
        .declaration => try fuzzer.connection.request(
            "textDocument/declaration",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
            requestCallback("textDocument/declaration"),
        ),
        .definition => try fuzzer.connection.request(
            "textDocument/definition",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
            requestCallback("textDocument/definition"),
        ),
        .type_definition => try fuzzer.connection.request(
            "textDocument/typeDefinition",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
            requestCallback("textDocument/typeDefinition"),
        ),
        .implementation => try fuzzer.connection.request(
            "textDocument/implementation",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
            requestCallback("textDocument/implementation"),
        ),
        .references => try fuzzer.connection.request(
            "textDocument/references",
            .{
                .context = .{ .includeDeclaration = rand.boolean() },
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
            requestCallback("textDocument/references"),
        ),
        .signature_help => try fuzzer.connection.request(
            "textDocument/signatureHelp",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
            requestCallback("textDocument/signatureHelp"),
        ),
        .hover => try fuzzer.connection.request(
            "textDocument/hover",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
            requestCallback("textDocument/hover"),
        ),
        .semantic => try fuzzer.connection.request(
            "textDocument/semanticTokens/full",
            .{ .textDocument = .{ .uri = file_uri } },
            requestCallback("textDocument/semanticTokens/full"),
        ),
        .document_symbol => try fuzzer.connection.request(
            "textDocument/documentSymbol",
            .{ .textDocument = .{ .uri = file_uri } },
            requestCallback("textDocument/documentSymbol"),
        ),
        .folding_range => {
            _ = try fuzzer.connection.request(
                "textDocument/foldingRange",
                .{ .textDocument = .{ .uri = file_uri } },
                requestCallback("textDocument/foldingRange"),
            );
        },
        .formatting => try fuzzer.connection.request(
            "textDocument/formatting",
            .{
                .textDocument = .{ .uri = file_uri },
                .options = .{
                    .tabSize = 4,
                    .insertSpaces = true,
                },
            },
            requestCallback("textDocument/formatting"),
        ),
        .document_highlight => try fuzzer.connection.request(
            "textDocument/documentHighlight",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
            requestCallback("textDocument/documentHighlight"),
        ),
        .inlay_hint => try fuzzer.connection.request(
            "textDocument/inlayHint",
            .{
                .textDocument = .{ .uri = file_uri },
                .range = utils.randomRange(rand, file_data),
            },
            requestCallback("textDocument/inlayHint"),
        ),
        // TODO: Nest positions properly to avoid crash
        // .selection_range => {
        //     var positions: [16]lsp_types.Position = undefined;
        //     for (positions) |*pos| {
        //         pos.* = utils.randomPosition(rand, file_data);
        //     }
        //     try fuzzer.connection.request(
        //         "textDocument/selectionRange",
        //         .{
        //             .textDocument = .{ .uri = file_uri },
        //             .positions = &positions,
        //         },
        //         requestCallback("textDocument/selectionRange"),
        //     );
        // },
        .rename => try fuzzer.connection.request(
            "textDocument/rename",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
                .newName = "helloWorld",
            },
            requestCallback("textDocument/rename"),
        ),
    }
}

// Handlers

pub fn @"window/logMessage"(_: *Connection, params: lsp.Params("window/logMessage")) !void {
    switch (params.type) {
        .Error => std.log.err("logMessage: {s}", .{params.message}),
        .Warning => std.log.warn("logMessage: {s}", .{params.message}),
        .Info => std.log.info("logMessage: {s}", .{params.message}),
        .Log => std.log.debug("logMessage: {s}", .{params.message}),
    }
}

pub fn @"window/showMessage"(_: *Connection, params: lsp.Params("window/showMessage")) !void {
    switch (params.type) {
        .Error => std.log.err("showMessage: {s}", .{params.message}),
        .Warning => std.log.warn("showMessage: {s}", .{params.message}),
        .Info => std.log.info("showMessage: {s}", .{params.message}),
        .Log => std.log.debug("showMessage: {s}", .{params.message}),
    }
}

pub fn @"textDocument/publishDiagnostics"(_: *Connection, _: lsp.Params("textDocument/publishDiagnostics")) !void {}
pub fn @"workspace/semanticTokens/refresh"(_: *Connection, _: lsp.types.RequestId, _: lsp.Params("workspace/semanticTokens/refresh")) !void {}

pub fn dataRecv(
    conn: *Connection,
    data: []const u8,
) !void {
    const fuzzer: *Fuzzer = conn.context;
    try fuzzer.stdout_output.ensureUnusedCapacity(fuzzer.allocator, data.len + 1);
    fuzzer.stdout_output.appendSliceAssumeCapacity(data);
    fuzzer.stdout_output.appendAssumeCapacity('\n');
}

pub fn dataSend(
    conn: *Connection,
    data: []const u8,
) !void {
    const fuzzer: *Fuzzer = conn.context;
    try fuzzer.stdin_output.ensureUnusedCapacity(fuzzer.allocator, data.len + 1);
    fuzzer.stdin_output.appendSliceAssumeCapacity(data);
    fuzzer.stdin_output.appendAssumeCapacity('\n');
}
