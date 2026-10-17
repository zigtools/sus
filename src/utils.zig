const std = @import("std");
const lsp = @import("lsp");

pub fn randomPosition(random: std.Random, data: []const u8) lsp.types.Position {
    // TODO: Consider offsets
    var index = random.uintAtMost(usize, data.len);
    while (index != 0 and index < data.len and !isFirstUtf8Byte(data[index])) index -= 1;
    return lsp.offsets.indexToPosition(data, index, .@"utf-16");
}

pub fn randomRange(random: std.Random, data: []const u8) lsp.types.Range {
    // TODO: Consider offsets
    var loc: lsp.offsets.Loc = .{
        .start = random.uintAtMost(usize, data.len),
        .end = random.uintAtMost(usize, data.len),
    };
    while (loc.start != 0 and loc.start < data.len and !isFirstUtf8Byte(data[loc.start])) loc.start -= 1;
    while (loc.end != 0 and loc.end < data.len and !isFirstUtf8Byte(data[loc.end])) loc.end -= 1;
    if (loc.start > loc.end) std.mem.swap(usize, &loc.start, &loc.end);

    return lsp.offsets.locToRange(data, loc, .@"utf-16");
}

fn isFirstUtf8Byte(byte: u8) bool {
    return byte & 0b11000000 != 0b10000000;
}

pub fn waitForResponseToRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    id: lsp.JsonRPCMessage.ID,
) !void {
    while (true) {
        const json_message = try transport.readJsonMessage(io, allocator);
        defer allocator.free(json_message);

        const result = try std.json.parseFromSlice(
            struct { id: ?lsp.JsonRPCMessage.ID = null },
            allocator,
            json_message,
            .{
                .ignore_unknown_fields = true,
            },
        );

        defer result.deinit();

        if (result.value.id) |received_id| {
            if (received_id.eql(id)) {
                return;
            }
        }
    }
}

pub fn waitForResponseToRequests(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    ids: *std.array_hash_map.Auto(i64, void),
) !void {
    while (ids.count() != 0) {
        const json_message = try transport.readJsonMessage(io, allocator);
        defer allocator.free(json_message);

        const result = try std.json.parseFromSlice(
            struct { id: ?lsp.JsonRPCMessage.ID = null },
            allocator,
            json_message,
            .{
                .ignore_unknown_fields = true,
            },
        );
        defer result.deinit();

        if (result.value.id) |received_id| {
            if (received_id != .number) continue;
            std.debug.assert(ids.swapRemove(received_id.number));
        }
    }
}

const WhatToFuzz = enum {
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
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: ?*lsp.Transport,
    text_document: lsp.types.TextDocument,
    random: std.Random,
) (lsp.Transport.WriteError || error{OutOfMemory})!struct { lsp.JsonRPCMessage.ID, []u8 } {
    const id: lsp.JsonRPCMessage.ID = .{ .number = random.int(i64) };

    switch (random.enumValue(WhatToFuzz)) {
        inline else => |method| {
            const Params = switch (method) {
                .@"textDocument/completion",
                .@"textDocument/declaration",
                .@"textDocument/definition",
                .@"textDocument/typeDefinition",
                .@"textDocument/implementation",
                .@"textDocument/signatureHelp",
                .@"textDocument/hover",
                .@"textDocument/documentHighlight",
                => lsp.types.declaration.Params,

                .@"textDocument/semanticTokens/full",
                .@"textDocument/documentSymbol",
                .@"textDocument/foldingRange",
                => lsp.types.semantic_tokens.Params,

                .@"textDocument/inlayHint",
                .@"textDocument/references",
                .@"textDocument/formatting",
                .@"textDocument/rename",
                => lsp.ParamsType(@tagName(method)),
            };
            const params: Params = createRandomRequestParams(Params, random, text_document);

            if (transport) |t| {
                const request: lsp.TypedJsonRPCRequest(Params) = .{
                    .id = id,
                    .method = @tagName(method),
                    .params = params,
                };
                const json_message = try std.json.Stringify.valueAlloc(allocator, request, .{ .emit_null_optional_fields = false });
                errdefer allocator.free(json_message);

                try t.writeJsonMessage(io, json_message);
                return .{ id, json_message };
            }
            return .{ id, "" };
        },
    }
}

fn createRandomRequestParams(
    comptime Params: type,
    random: std.Random,
    text_document: lsp.types.TextDocument,
) Params {
    return switch (Params) {
        lsp.types.declaration.Params => .{
            .textDocument = .{ .uri = text_document.uri },
            .position = randomPosition(random, text_document.text),
        },
        lsp.types.semantic_tokens.Params => .{
            .textDocument = .{ .uri = text_document.uri },
        },
        lsp.types.InlayHint.Params => .{
            .textDocument = .{ .uri = text_document.uri },
            .range = randomRange(random, text_document.text),
        },
        lsp.types.reference.Params => .{
            .context = .{ .includeDeclaration = random.boolean() },
            .textDocument = .{ .uri = text_document.uri },
            .position = randomPosition(random, text_document.text),
        },
        lsp.types.document_formatting.Params => .{
            .textDocument = .{ .uri = text_document.uri },
            .options = .{ .tabSize = 4, .insertSpaces = true },
        },
        lsp.types.rename.Params => .{
            .textDocument = .{ .uri = text_document.uri },
            .position = randomPosition(random, text_document.text),
            .newName = "helloWorld",
        },
        else => comptime unreachable,
    };
}
