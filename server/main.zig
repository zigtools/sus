const std = @import("std");
const sqlite = @import("sqlite");
const Request = std.http.Server.Request;
const Response = std.http.Server.Response;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var server = std.http.Server.init(allocator, .{});
    try server.listen(try std.net.Address.parseIp("127.0.0.1", 1313));

    var database = try Database.init(.{
        .mode = sqlite.Db.Mode{ .File = "db.db" },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    var router = Router{
        .allocator = allocator,
        .server = &server,
        .database = &database,
    };

    while (true) {
        router.accept() catch |err| {
            std.log.err("{s}", .{@errorName(err)});
            if (@errorReturnTrace()) |ert|
                std.debug.dumpStackTrace(ert.*);
            continue;
        };
    }
}

pub const Database = struct {
    db: sqlite.Db,

    pub const Entry = struct {
        owner_name: []const u8,
        repo_name: []const u8,
        branch_name: []const u8,
        commit_hash: []const u8,
        bucket_object: []const u8,
        zig_version: []const u8,
        zls_version: []const u8,
        summary: []const u8,
    };

    pub fn init(options: sqlite.InitOptions) !Database {
        var db = try sqlite.Db.init(options);

        var diags = sqlite.Diagnostics{};
        db.execMulti(@embedFile("sql/migrations/001_init.sql"), .{
            .diags = &diags,
        }) catch |err| {
            std.log.err("ERR {s}", .{diags});
            return err;
        };

        return .{
            .db = db,
        };
    }

    pub fn addEntry(database: *Database, entry: Entry) !void {
        const repo_id = try database.db.one(u64,
            \\SELECT repo_id FROM repos WHERE owner_name=? AND repo_name=?;
        , .{}, .{
            .owner_name = entry.owner_name,
            .repo_name = entry.repo_name,
        }) orelse (try database.db.one(u64,
            \\INSERT INTO repos (
            \\    owner_name,
            \\    repo_name
            \\) VALUES (
            \\    ?,
            \\    ?
            \\) RETURNING repo_id;
        , .{}, .{
            .owner_name = entry.owner_name,
            .repo_name = entry.repo_name,
        })).?;

        const branch_id = try database.db.one(u64,
            \\SELECT branch_id FROM branches WHERE branch_name=? AND repo_id=?;
        , .{}, .{
            .branch_name = entry.branch_name,
            .repo_id = repo_id,
        }) orelse (try database.db.one(u64,
            \\INSERT INTO branches (
            \\    branch_name,
            \\    repo_id
            \\) VALUES (
            \\    ?,
            \\    ?
            \\) RETURNING branch_id;
        , .{}, .{
            .branch_name = entry.branch_name,
            .repo_id = repo_id,
        })).?;

        const commit_id = try database.db.one(u64,
            \\SELECT commit_id FROM commits WHERE commit_hash=? AND branch_id=?;
        , .{}, .{
            .commit_hash = entry.commit_hash,
            .branch_id = branch_id,
        }) orelse (try database.db.one(u64,
            \\INSERT INTO commits (
            \\    commit_hash,
            \\    branch_id
            \\) VALUES (
            \\    ?,
            \\    ?
            \\) RETURNING commit_id;
        , .{}, .{
            .commit_hash = entry.commit_hash,
            .branch_id = branch_id,
        })).?;

        const entry_set_id = try database.db.one(u64,
            \\SELECT entry_set_id FROM entry_sets WHERE summary=?;
        , .{}, .{
            .summary = entry.summary,
        }) orelse (try database.db.one(u64,
            \\INSERT INTO entry_sets (
            \\    summary
            \\) VALUES (
            \\    ?
            \\) RETURNING entry_set_id;
        , .{}, .{
            .summary = entry.summary,
        })).?;

        try database.db.exec(
            \\INSERT INTO entries (
            \\    bucket_object,
            \\    zig_version,
            \\    zls_version,
            \\    commit_id,
            \\    entry_set_id
            \\) VALUES (
            \\    ?,
            \\    ?,
            \\    ?,
            \\    ?,
            \\    ?
            \\);
        , .{}, .{
            .bucket_object = entry.bucket_object,
            .zig_version = entry.zig_version,
            .zls_version = entry.zls_version,
            .commit_id = commit_id,
            .entry_set_id = entry_set_id,
        });
    }
};

test Database {
    var database = try Database.init(.{
        .mode = sqlite.Db.Mode.Memory,
        .open_flags = .{ .write = true },
    });

    try database.addEntry(.{
        .owner_name = "zigtools",
        .repo_name = "zls",
        .branch_name = "main",
        .commit_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .bucket_object = "bucketobject0",
        .zig_version = "version0",
        .zls_version = "version0",
        .summary = "some sort of panic",
    });

    try database.addEntry(.{
        .owner_name = "zigtools",
        .repo_name = "zls",
        .branch_name = "main",
        .commit_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .bucket_object = "bucketobject0",
        .zig_version = "version0",
        .zls_version = "version0",
        .summary = "some sort of panic!",
    });
}

pub const Router = struct {
    allocator: std.mem.Allocator,
    server: *std.http.Server,
    database: *Database,

    const Part = union(enum) {
        string: []const u8,
    };
    const RouteHandler = *const fn (router: *Router, req: *Request, res: *Response) anyerror!void;
    const Route = struct {
        parts: []const Part,
        handler: RouteHandler,
    };

    const routes = [_]Route{
        .{
            .parts = &.{
                .{ .string = "/" },
            },
            .handler = &index,
        },
    };

    pub fn accept(router: *Router) !void {
        var res = try router.server.accept(.{ .allocator = router.allocator });
        var req = &res.request;

        defer res.deinit();

        while (res.reset() != .closing) {
            try res.wait();

            var path = if (std.Uri.parse(req.target)) |uri|
                uri.path
            else |_|
                req.target;

            std.log.info("{s} {s}", .{ @tagName(req.method), path });

            rit: for (routes) |route| {
                var i: usize = 0;
                for (route.parts) |part| {
                    switch (part) {
                        .string => |str| {
                            if (std.mem.eql(u8, path[i..str.len], str)) {
                                i += str.len;
                            } else {
                                continue :rit;
                            }
                        },
                    }
                }

                if (i == path.len) {
                    try route.handler(router, req, &res);
                    return;
                }
            }

            std.log.info("NOT FOUND", .{});
            try router.notFound(req, &res);
        }
    }

    pub fn notFound(router: *Router, req: *Request, res: *Response) !void {
        _ = router;

        while (true) {
            const byte = res.reader().readByte() catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            _ = byte;
        }

        res.transfer_encoding = .chunked;
        try res.do();

        res.status = .not_found;
        try res.headers.append("Content-Type", "text/plain");
        try res.writer().print("404 Not Found: {s}", .{req.target});

        try res.finish();
    }

    pub fn index(router: *Router, req: *Request, res: *Response) anyerror!void {
        const allocator = router.allocator;

        const body = try res.reader().readAllAlloc(allocator, 8192);
        defer allocator.free(body);

        res.transfer_encoding = .chunked;
        try res.do();

        try res.headers.append("Content-Type", "text/plain");

        for (req.headers.list.items) |header| {
            try res.writer().print("{s}: {s}\n", .{ header.name, header.value });
        }

        try res.finish();
    }
};
