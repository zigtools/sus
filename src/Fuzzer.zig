const std = @import("std");
const builtin = @import("builtin");

const utils = @import("utils.zig");
const lsp = @import("lsp");
const Mode = @import("mode.zig").Mode;
const ModeName = @import("mode.zig").ModeName;
const Client = @import("Client.zig");

const Fuzzer = @This();

// if you add or change config options, update the usage in main.zig then
// run `zig build run -- --help` and paste the contents into the README
pub const Config = struct {
    rpc: bool,
    seed: ?u64,
    zls_path: []const u8,
    mode_name: ModeName,
    cycles_per_gen: u32,

    zig_env_arena: std.heap.ArenaAllocator.State,
    zig_env: ZigEnv,
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
        self.zig_env_arena.promote(allocator).deinit();
        allocator.free(self.zls_path);
        allocator.free(self.zls_version);
        self.* = undefined;
    }
};

io: std.Io,
allocator: std.mem.Allocator,
mode: *Mode,
config: *const Config,
seed: u64,

cycle: usize = 0,
client: Client,
rand: std.Random.DefaultPrng,
pending_request_ids: std.AutoArrayHashMapUnmanaged(i64, void) = .empty,
text_document: lsp.types.TextDocument,

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    mode: *Mode,
    config: *const Config,
) !Fuzzer {
    var client: Client = try .init(
        io,
        allocator,
        environ_map,
        config.zls_path,
        config.zig_env.zig_exe,
        if (config.seed != null) .inherit else .ignore,
    );
    errdefer client.child_process.kill(io);

    const rng_impl: std.Random.IoSource = .{ .io = io };
    const rng = rng_impl.interface();

    const seed = config.seed orelse rng.int(u64);

    var pending_request_ids: std.AutoArrayHashMapUnmanaged(i64, void) = .empty;
    try pending_request_ids.ensureTotalCapacity(allocator, config.cycles_per_gen);
    errdefer pending_request_ids.deinit(allocator);

    return .{
        .io = io,
        .allocator = allocator,
        .mode = mode,
        .config = config,
        .seed = seed,

        .client = client,
        .rand = .init(seed),
        .pending_request_ids = pending_request_ids,
        .text_document = .{
            .uri = client.text_document_uri,
            .languageId = .{ .custom_value = "zig" },
            .version = 0,
            .text = "",
        },
    };
}

pub fn deinit(fuzzer: *Fuzzer) void {
    fuzzer.pending_request_ids.deinit(fuzzer.allocator);
    fuzzer.allocator.free(fuzzer.text_document.uri);
    fuzzer.allocator.free(fuzzer.text_document.text);
    fuzzer.* = undefined;
}

pub fn fuzz(fuzzer: *Fuzzer) (lsp.Transport.WriteError || lsp.Transport.ReadError || std.json.ParseError(std.json.Scanner) || error{OutOfMemory})!void {
    fuzzer.cycle += 1;

    if (fuzzer.cycle % fuzzer.config.cycles_per_gen == 0) {
        try utils.waitForResponseToRequests(
            fuzzer.io,
            fuzzer.allocator,
            &fuzzer.client.stdio_transport.transport,
            &fuzzer.pending_request_ids,
        );

        while (true) {
            var new_text = try fuzzer.mode.gen(fuzzer.allocator, fuzzer.rand.random());
            defer fuzzer.allocator.free(new_text);
            if (std.unicode.utf8ValidateSlice(new_text)) {
                std.mem.swap([]const u8, &fuzzer.text_document.text, &new_text);
                break;
            }
        }

        fuzzer.text_document.version += 1;
        try fuzzer.client.transport().writeNotification(
            fuzzer.io,
            fuzzer.allocator,
            "textDocument/didChange",
            lsp.types.TextDocument.DidChangeParams,
            .{
                .textDocument = .{ .uri = fuzzer.text_document.uri, .version = fuzzer.text_document.version },
                .contentChanges = &[1]lsp.types.TextDocument.ContentChangeEvent{
                    .{ .text_document_content_change_whole_document = .{ .text = fuzzer.text_document.text } },
                },
            },
            .{ .emit_null_optional_fields = false },
        );
    }

    const id, const json_message = try utils.fuzzFeatureRandom(
        fuzzer.io,
        fuzzer.allocator,
        fuzzer.client.transport(),
        fuzzer.text_document,
        fuzzer.rand.random(),
    );
    defer fuzzer.allocator.free(json_message);
    try fuzzer.pending_request_ids.putNoClobber(fuzzer.allocator, id.number, {}); // clobber is statistically improbable
}
