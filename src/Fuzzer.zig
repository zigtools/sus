const std = @import("std");
const utils = @import("utils.zig");
const lsp = @import("lsp.zig");
const ChildProcess = std.ChildProcess;
const Mode = @import("mode.zig").Mode;
const ModeName = @import("mode.zig").ModeName;
const Header = @import("Header.zig");
const Reducer = @import("Reducer.zig");

const Fuzzer = @This();

// note: if you add or change config options, update the usage in main.zig then
// run `zig build run -- --help` and paste the contents into the README
pub const Config = struct {
    rpc: bool,
    zls_path: []const u8,
    mode_name: ModeName,
    cycles_per_gen: u32,

    zig_env: std.json.Parsed(ZigEnv),
    zls_version: []const u8,

    pub const Defaults = struct {
        pub const rpc = false;
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

pub const SentMessage = struct {
    id: i64,
    start: u32,
    end: u32,
};

allocator: std.mem.Allocator,
progress_node: *std.Progress.Node,
mode: *Mode,
config: Config,
env_map: *const std.process.EnvMap,
rand: std.rand.DefaultPrng,
cycle: usize = 0,

zls_process: ChildProcess,
id: i64 = 0,

buffered_reader: std.io.BufferedReader(4096, std.fs.File.Reader),
read_buffer: std.ArrayListUnmanaged(u8) = .{},

sent_data: std.ArrayListUnmanaged(u8) = .{},
sent_messages: std.ArrayListUnmanaged(SentMessage) = .{},
sent_ids: std.AutoArrayHashMapUnmanaged(i64, void) = .{},

principal_file_source: []const u8 = "",
principal_file_uri: []const u8,

pub fn create(
    allocator: std.mem.Allocator,
    progress: *std.Progress,
    mode: *Mode,
    config: Config,
    env_map: *const std.process.EnvMap,
    principal_file_uri: []const u8,
) !*Fuzzer {
    const fuzzer = try allocator.create(Fuzzer);
    errdefer allocator.destroy(fuzzer);

    var seed: u64 = 0;
    try std.os.getrandom(std.mem.asBytes(&seed));

    var zls_process = std.ChildProcess.init(&.{ config.zls_path, "--enable-debug-log" }, allocator);
    zls_process.env_map = env_map;
    zls_process.stdin_behavior = .Pipe;
    zls_process.stderr_behavior = .Ignore;
    zls_process.stdout_behavior = .Pipe;

    try zls_process.spawn();
    errdefer _ = zls_process.kill() catch @panic("failed to kill zls process");

    var sent_ids = std.AutoArrayHashMapUnmanaged(i64, void){};
    try sent_ids.ensureTotalCapacity(allocator, config.cycles_per_gen);

    fuzzer.* = .{
        .allocator = allocator,
        .progress_node = progress.start("fuzzer", 0),
        .mode = mode,
        .config = config,
        .env_map = env_map,
        .rand = std.rand.DefaultPrng.init(seed),
        .zls_process = zls_process,
        .buffered_reader = std.io.bufferedReader(zls_process.stdout.?.reader()),
        .sent_ids = sent_ids,
        .principal_file_uri = principal_file_uri,
    };

    return fuzzer;
}

pub fn wait(fuzzer: *Fuzzer) void {
    _ = fuzzer.zls_process.wait() catch |err| {
        std.log.err("failed to await zls process: {}", .{err});
    };
}

pub fn destroy(fuzzer: *Fuzzer) void {
    const allocator = fuzzer.allocator;

    fuzzer.read_buffer.deinit(allocator);

    fuzzer.sent_data.deinit(allocator);
    fuzzer.sent_messages.deinit(allocator);
    fuzzer.sent_ids.deinit(allocator);

    allocator.free(fuzzer.principal_file_source);

    fuzzer.* = undefined;
    allocator.destroy(fuzzer);
}

pub fn random(fuzzer: *Fuzzer) std.rand.Random {
    return fuzzer.rand.random();
}

pub fn initCycle(fuzzer: *Fuzzer) !void {
    fuzzer.progress_node.activate();

    try fuzzer.sendRequest("initialize", lsp.InitializeParams{
        .capabilities = .{},
    });
    try fuzzer.sendNotification("initialized", .{});

    var settings = std.json.ObjectMap.init(fuzzer.allocator);
    defer settings.deinit();
    try settings.putNoClobber("skip_std_references", .{ .bool = true }); // references collection into std is very slow
    try settings.putNoClobber("zig_exe_path", .{ .string = fuzzer.config.zig_env.value.zig_exe });

    try fuzzer.sendNotification("workspace/didChangeConfiguration", lsp.DidChangeConfigurationParams{
        .settings = .{ .object = settings },
    });

    try fuzzer.sendNotification("textDocument/didOpen", lsp.DidOpenTextDocumentParams{ .textDocument = .{
        .uri = fuzzer.principal_file_uri,
        .languageId = .{ .custom_value = "zig" },
        .version = @intCast(fuzzer.cycle),
        .text = fuzzer.principal_file_source,
    } });
}

pub fn closeCycle(fuzzer: *Fuzzer) !void {
    fuzzer.progress_node.end();

    _ = try fuzzer.sendNotification("textDocument/didClose", .{
        .textDocument = .{ .uri = fuzzer.principal_file_uri },
    });

    _ = try fuzzer.sendRequest("shutdown", {});
    try fuzzer.sendNotification("exit", {});
}

pub fn reduce(fuzzer: *Fuzzer) !void {
    std.log.info("Reducing...", .{});

    var reducer = Reducer.fromFuzzer(fuzzer);
    defer reducer.deinit();

    try reducer.reduce();
}

pub fn fuzz(fuzzer: *Fuzzer) !void {
    fuzzer.progress_node.setCompletedItems(fuzzer.cycle);
    fuzzer.cycle += 1;

    if (fuzzer.cycle % fuzzer.config.cycles_per_gen == 0) {
        // detch from cycle count to prevent pipe fillage on windows
        try utils.waitForResponseToRequests(
            fuzzer.allocator,
            fuzzer.buffered_reader.reader(),
            &fuzzer.read_buffer,
            &fuzzer.sent_ids,
        );

        // var arena_allocator = std.heap.ArenaAllocator.init(fuzzer.allocator);
        // defer arena_allocator.deinit();
        // const arena = arena_allocator.allocator();
        // _ = arena; // autofix

        while (true) {
            fuzzer.allocator.free(fuzzer.principal_file_source);
            fuzzer.principal_file_source = try fuzzer.mode.gen(fuzzer.allocator);
            if (std.unicode.utf8ValidateSlice(fuzzer.principal_file_source)) break;
        }

        fuzzer.sent_data.items.len = 0;
        fuzzer.sent_messages.items.len = 0;
        fuzzer.sent_ids.clearRetainingCapacity();

        try fuzzer.sendNotification("textDocument/didChange", lsp.DidChangeTextDocumentParams{
            .textDocument = .{ .uri = fuzzer.principal_file_uri, .version = @intCast(fuzzer.cycle) },
            .contentChanges = &[1]lsp.TextDocumentContentChangeEvent{
                .{ .TextDocumentContentChangeWholeDocument = .{ .text = fuzzer.principal_file_source } },
            },
        });
    }

    try fuzzer.fuzzFeatureRandom(fuzzer.principal_file_uri, fuzzer.principal_file_source);
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

pub fn fuzzFeatureRandom(
    fuzzer: *Fuzzer,
    file_uri: []const u8,
    file_data: []const u8,
) !void {
    const rand = fuzzer.random();
    const wtf = rand.enumValue(WhatToFuzz);

    switch (wtf) {
        .completion => try fuzzer.sendRequest(
            "textDocument/completion",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
        ),
        .declaration => try fuzzer.sendRequest(
            "textDocument/declaration",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
        ),
        .definition => try fuzzer.sendRequest(
            "textDocument/definition",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
        ),
        .type_definition => try fuzzer.sendRequest(
            "textDocument/typeDefinition",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
        ),
        .implementation => try fuzzer.sendRequest(
            "textDocument/implementation",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
        ),
        .references => try fuzzer.sendRequest(
            "textDocument/references",
            .{
                .context = .{ .includeDeclaration = rand.boolean() },
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
        ),
        .signature_help => try fuzzer.sendRequest(
            "textDocument/signatureHelp",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
        ),
        .hover => try fuzzer.sendRequest(
            "textDocument/hover",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
        ),
        .semantic => try fuzzer.sendRequest(
            "textDocument/semanticTokens/full",
            .{ .textDocument = .{ .uri = file_uri } },
        ),
        .document_symbol => try fuzzer.sendRequest(
            "textDocument/documentSymbol",
            .{ .textDocument = .{ .uri = file_uri } },
        ),
        .folding_range => {
            _ = try fuzzer.sendRequest(
                "textDocument/foldingRange",
                .{ .textDocument = .{ .uri = file_uri } },
            );
        },
        .formatting => try fuzzer.sendRequest(
            "textDocument/formatting",
            .{
                .textDocument = .{ .uri = file_uri },
                .options = .{
                    .tabSize = 4,
                    .insertSpaces = true,
                },
            },
        ),
        .document_highlight => try fuzzer.sendRequest(
            "textDocument/documentHighlight",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
            },
        ),
        .inlay_hint => try fuzzer.sendRequest(
            "textDocument/inlayHint",
            .{
                .textDocument = .{ .uri = file_uri },
                .range = utils.randomRange(rand, file_data),
            },
        ),
        .rename => try fuzzer.sendRequest(
            "textDocument/rename",
            .{
                .textDocument = .{ .uri = file_uri },
                .position = utils.randomPosition(rand, file_data),
                .newName = "helloWorld",
            },
        ),
    }
}

fn sendRequest(fuzzer: *Fuzzer, comptime method: []const u8, params: utils.Params(method)) !void {
    const start = fuzzer.sent_data.items.len;

    const request_id = fuzzer.id;

    try utils.stringifyRequest(
        fuzzer.sent_data.writer(fuzzer.allocator),
        &fuzzer.id,
        method,
        params,
    );

    try utils.send(
        fuzzer.zls_process.stdin.?,
        fuzzer.sent_data.items[start..],
    );

    try fuzzer.sent_messages.append(fuzzer.allocator, .{
        .id = request_id,
        .start = @intCast(start),
        .end = @intCast(fuzzer.sent_data.items.len),
    });

    fuzzer.sent_ids.putAssumeCapacityNoClobber(request_id, void{});

    // try utils.waitForResponseToRequest(
    //     fuzzer.allocator,
    //     fuzzer.buffered_reader.reader(),
    //     &fuzzer.read_buffer,
    //     request_id,
    // );
}

fn sendNotification(fuzzer: *Fuzzer, comptime method: []const u8, params: utils.Params(method)) !void {
    const start = fuzzer.sent_data.items.len;

    try utils.stringifyNotification(
        fuzzer.sent_data.writer(fuzzer.allocator),
        method,
        params,
    );

    return utils.send(
        fuzzer.zls_process.stdin.?,
        fuzzer.sent_data.items[start..],
    );
}
