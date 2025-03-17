const std = @import("std");
const utils = @import("utils.zig");
const lsp = @import("lsp");
const Mode = @import("mode.zig").Mode;
const ModeName = @import("mode.zig").ModeName;
const Reducer = @import("Reducer.zig");

const Fuzzer = @This();

// if you add or change config options, update the usage in main.zig then
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
progress_node: std.Progress.Node,
mode: *Mode,
config: Config,
rand: std.Random.DefaultPrng,
cycle: usize = 0,

zls_process: std.process.Child,
id: i64 = 0,

transport: lsp.TransportOverStdio,

sent_data: std.ArrayListUnmanaged(u8) = .{},
sent_messages: std.ArrayListUnmanaged(SentMessage) = .{},
sent_ids: std.AutoArrayHashMapUnmanaged(i64, void) = .{},

principal_file_source: []const u8 = "",
principal_file_uri: []const u8,

pub fn create(
    allocator: std.mem.Allocator,
    progress: std.Progress.Node,
    mode: *Mode,
    config: Config,
    principal_file_uri: []const u8,
) !*Fuzzer {
    const fuzzer = try allocator.create(Fuzzer);
    errdefer allocator.destroy(fuzzer);

    const seed = std.crypto.random.int(u64);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    try env_map.put("NO_COLOR", "1");

    const zls_cli_revamp_version = comptime std.SemanticVersion.parse("0.14.0-50+3354fdc") catch unreachable;
    const zls_version = try std.SemanticVersion.parse(config.zls_version);

    const argv: []const []const u8 = if (zls_version.order(zls_cli_revamp_version) == .lt)
        &.{ config.zls_path, "--enable-debug-log" }
    else
        &.{ config.zls_path, "--log-level", "debug" };

    var zls_process = std.process.Child.init(argv, allocator);
    zls_process.env_map = &env_map;
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
        .rand = std.Random.DefaultPrng.init(seed),
        .zls_process = zls_process,
        .transport = lsp.TransportOverStdio.init(zls_process.stdout.?, zls_process.stdin.?),
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

    fuzzer.sent_data.deinit(allocator);
    fuzzer.sent_messages.deinit(allocator);
    fuzzer.sent_ids.deinit(allocator);

    allocator.free(fuzzer.principal_file_source);

    fuzzer.* = undefined;
    allocator.destroy(fuzzer);
}

pub fn random(fuzzer: *Fuzzer) std.Random {
    return fuzzer.rand.random();
}

pub fn initCycle(fuzzer: *Fuzzer) !void {
    try fuzzer.sendRequest("initialize", lsp.types.InitializeParams{
        .capabilities = .{},
    });
    try fuzzer.sendNotification("initialized", .{});

    var settings = std.json.ObjectMap.init(fuzzer.allocator);
    defer settings.deinit();
    try settings.putNoClobber("skip_std_references", .{ .bool = true }); // references collection into std is very slow
    try settings.putNoClobber("zig_exe_path", .{ .string = fuzzer.config.zig_env.value.zig_exe });

    try fuzzer.sendNotification("workspace/didChangeConfiguration", lsp.types.DidChangeConfigurationParams{
        .settings = .{ .object = settings },
    });

    try fuzzer.sendNotification("textDocument/didOpen", lsp.types.DidOpenTextDocumentParams{ .textDocument = .{
        .uri = fuzzer.principal_file_uri,
        .languageId = "zig",
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
    var reducer = Reducer.fromFuzzer(fuzzer);
    defer reducer.deinit();

    try reducer.reduce();
}

pub fn fuzz(fuzzer: *Fuzzer) !void {
    fuzzer.cycle += 1;

    if (fuzzer.cycle % fuzzer.config.cycles_per_gen == 0) {
        // detch from cycle count to prevent pipe fillage on windows
        try utils.waitForResponseToRequests(
            fuzzer.allocator,
            &fuzzer.transport,
            &fuzzer.sent_ids,
        );

        while (true) {
            fuzzer.allocator.free(fuzzer.principal_file_source);
            fuzzer.principal_file_source = try fuzzer.mode.gen(fuzzer.allocator);
            if (std.unicode.utf8ValidateSlice(fuzzer.principal_file_source)) break;
        }

        fuzzer.sent_data.clearRetainingCapacity();
        fuzzer.sent_messages.clearRetainingCapacity();
        std.debug.assert(fuzzer.sent_ids.count() == 0);

        try fuzzer.sendNotification("textDocument/didChange", lsp.types.DidChangeTextDocumentParams{
            .textDocument = .{ .uri = fuzzer.principal_file_uri, .version = @intCast(fuzzer.cycle) },
            .contentChanges = &[1]lsp.types.TextDocumentContentChangeEvent{
                .{ .literal_1 = .{ .text = fuzzer.principal_file_source } },
            },
        });
    }

    try fuzzer.fuzzFeatureRandom(fuzzer.principal_file_uri, fuzzer.principal_file_source);
    fuzzer.progress_node.completeOne();
}

pub const WhatToFuzz = enum {
    @"textDocument/completion",
    @"textDocument/declaration",
    @"textDocument/definition",
    @"textDocument/typeDefinition",
    @"textDocument/implementation",
    @"textDocument/references",
    @"textDocument/signatureHelp",
    @"textDocument/hover",
    @"textDocument/semanticTokens/full",
    @"textDocument/documentSymbol",
    @"textDocument/foldingRange",
    @"textDocument/formatting",
    @"textDocument/documentHighlight",
    @"textDocument/inlayHint",
    // @"textDocument/selectionRange",
    @"textDocument/rename",
};

pub fn fuzzFeatureRandom(
    fuzzer: *Fuzzer,
    file_uri: []const u8,
    file_data: []const u8,
) (lsp.AnyTransport.WriteError || error{OutOfMemory})!void {
    const rand = fuzzer.random();
    const wtf = rand.enumValue(WhatToFuzz);

    switch (wtf) {
        inline .@"textDocument/completion",
        .@"textDocument/declaration",
        .@"textDocument/definition",
        .@"textDocument/typeDefinition",
        .@"textDocument/implementation",
        .@"textDocument/signatureHelp",
        .@"textDocument/hover",
        .@"textDocument/documentHighlight",
        => |method| try fuzzer.sendRequest(@tagName(method), .{
            .textDocument = .{ .uri = file_uri },
            .position = utils.randomPosition(rand, file_data),
        }),

        inline .@"textDocument/semanticTokens/full",
        .@"textDocument/documentSymbol",
        .@"textDocument/foldingRange",
        => |method| try fuzzer.sendRequest(
            @tagName(method),
            .{ .textDocument = .{ .uri = file_uri } },
        ),

        .@"textDocument/inlayHint" => try fuzzer.sendRequest("textDocument/inlayHint", .{
            .textDocument = .{ .uri = file_uri },
            .range = utils.randomRange(rand, file_data),
        }),
        .@"textDocument/references" => try fuzzer.sendRequest("textDocument/references", .{
            .context = .{ .includeDeclaration = rand.boolean() },
            .textDocument = .{ .uri = file_uri },
            .position = utils.randomPosition(rand, file_data),
        }),
        .@"textDocument/formatting" => try fuzzer.sendRequest("textDocument/formatting", .{
            .textDocument = .{ .uri = file_uri },
            .options = .{
                .tabSize = 4,
                .insertSpaces = true,
            },
        }),
        .@"textDocument/rename" => try fuzzer.sendRequest("textDocument/rename", .{
            .textDocument = .{ .uri = file_uri },
            .position = utils.randomPosition(rand, file_data),
            .newName = "helloWorld",
        }),
    }
}

fn sendRequest(fuzzer: *Fuzzer, comptime method: []const u8, params: lsp.ParamsType(method)) (lsp.AnyTransport.WriteError || error{OutOfMemory})!void {
    defer fuzzer.id += 1;

    const request: lsp.TypedJsonRPCRequest(lsp.ParamsType(method)) = .{
        .id = .{ .number = fuzzer.id },
        .method = method,
        .params = params,
    };

    const start = fuzzer.sent_data.items.len;
    try std.json.stringify(request, .{ .emit_null_optional_fields = false }, fuzzer.sent_data.writer(fuzzer.allocator));
    try fuzzer.transport.writeJsonMessage(fuzzer.sent_data.items[start..]);

    try fuzzer.sent_messages.append(fuzzer.allocator, .{
        .id = fuzzer.id,
        .start = @intCast(start),
        .end = @intCast(fuzzer.sent_data.items.len),
    });

    fuzzer.sent_ids.putAssumeCapacityNoClobber(fuzzer.id, {});
}

fn sendNotification(fuzzer: *Fuzzer, comptime method: []const u8, params: lsp.ParamsType(method)) (lsp.AnyTransport.WriteError || error{OutOfMemory})!void {
    const notification: lsp.TypedJsonRPCNotification(lsp.ParamsType(method)) = .{
        .method = method,
        .params = params,
    };

    const start = fuzzer.sent_data.items.len;
    try std.json.stringify(notification, .{ .emit_null_optional_fields = false }, fuzzer.sent_data.writer(fuzzer.allocator));
    try fuzzer.transport.writeJsonMessage(fuzzer.sent_data.items[start..]);
}
