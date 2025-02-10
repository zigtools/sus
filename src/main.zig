const std = @import("std");
const builtin = @import("builtin");
const Fuzzer = @import("Fuzzer.zig");
const Mode = @import("mode.zig").Mode;
const ModeName = @import("mode.zig").ModeName;

fn loadEnv(allocator: std.mem.Allocator) !std.process.EnvMap {
    var envmap: std.process.EnvMap = std.process.getEnvMap(allocator) catch std.process.EnvMap.init(allocator);
    errdefer envmap.deinit();

    const env_content = std.fs.cwd().readFileAlloc(allocator, ".env", std.math.maxInt(usize)) catch |e| switch (e) {
        error.FileNotFound => return envmap,
        else => return e,
    };
    defer allocator.free(env_content);

    var line_it = std.mem.splitAny(u8, env_content, "\n\r");
    while (line_it.next()) |line| {
        if (std.mem.indexOfScalar(u8, line, '=')) |equal_sign_index| {
            const key = line[0..equal_sign_index];
            const val = line[equal_sign_index + 1 ..];
            try envmap.put(key, val);
        } else {
            try envmap.put(line, "");
        }
    }
    return envmap;
}

fn initConfig(allocator: std.mem.Allocator, env_map: std.process.EnvMap, arg_it: *std.process.ArgIterator) !Fuzzer.Config {
    _ = arg_it.skip();

    var maybe_zls_path: ?[]const u8 = blk: {
        if (env_map.get("zls_path")) |path| {
            break :blk try allocator.dupe(u8, path);
        }
        break :blk findInPath(allocator, env_map, "zls");
    };
    errdefer if (maybe_zls_path) |path| allocator.free(path);

    var maybe_zig_path: ?[]const u8 = blk: {
        if (env_map.get("zig_path")) |path| {
            break :blk try allocator.dupe(u8, path);
        }
        break :blk findInPath(allocator, env_map, "zig");
    };
    defer if (maybe_zig_path) |path| allocator.free(path);

    var rpc =
        if (env_map.get("rpc")) |str|
        if (std.mem.eql(u8, str, "false"))
            false
        else if (std.mem.eql(u8, str, "true"))
            true
        else blk: {
            std.log.warn("expected boolean (true|false) in env option 'rpc' but got '{s}'", .{str});
            break :blk Fuzzer.Config.Defaults.rpc;
        }
    else
        Fuzzer.Config.Defaults.rpc;

    var mode_name: ?ModeName = blk: {
        if (env_map.get("mode")) |mode_name| {
            if (std.meta.stringToEnum(ModeName, mode_name)) |mode| {
                break :blk mode;
            } else {
                std.log.warn(
                    "expected mode name (one of {s}) in env option 'mode' but got '{s}'",
                    .{ std.meta.fieldNames(ModeName).*, mode_name },
                );
            }
        }
        break :blk null;
    };

    var cycles_per_gen: u32 = blk: {
        if (env_map.get("cycles_per_gen")) |str| {
            if (std.fmt.parseUnsigned(u32, str, 10)) |cpg| {
                break :blk cpg;
            } else |err| {
                std.log.warn("expected unsigned integer in env option 'cycles_per_gen' but got '{s}': {}", .{ str, err });
            }
        }
        break :blk Fuzzer.Config.Defaults.cycles_per_gen;
    };

    var num_args: usize = 0;
    while (arg_it.next()) |arg| : (num_args += 1) {
        if (std.mem.eql(u8, arg, "--")) break; // all argument after '--' are mode specific arguments

        if (std.mem.eql(u8, arg, "--help")) {
            try std.io.getStdOut().writeAll(usage);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--rpc")) {
            rpc = true;
        } else if (std.mem.eql(u8, arg, "--zls-path")) {
            if (maybe_zls_path) |path| {
                allocator.free(path);
                maybe_zls_path = null;
            }
            maybe_zls_path = try allocator.dupe(u8, arg_it.next() orelse fatal("expected file path after --zls-path", .{}));
        } else if (std.mem.eql(u8, arg, "--zig-path")) {
            if (maybe_zig_path) |path| {
                allocator.free(path);
                maybe_zig_path = null;
            }
            maybe_zig_path = try allocator.dupe(u8, arg_it.next() orelse fatal("expected file path after --zig-path", .{}));
        } else if (std.mem.eql(u8, arg, "--mode")) {
            const mode_arg = arg_it.next() orelse fatal("expected mode parameter after --mode", .{});
            mode_name = std.meta.stringToEnum(ModeName, mode_arg) orelse fatal("unknown mode: {s}", .{mode_arg});
        } else if (std.mem.eql(u8, arg, "--cycles-per-gen")) {
            const next_arg = arg_it.next() orelse fatal("expected unsigned integer after --cycles-per-gen", .{});
            cycles_per_gen = std.fmt.parseUnsigned(u32, next_arg, 10) catch fatal("invalid unsigned integer '{s}'", .{next_arg});
        } else {
            fatalWithUsage("unknown parameter: {s}", .{arg});
        }
    }

    if (num_args == 0 and (maybe_zls_path == null or mode_name == null)) {
        try std.io.getStdErr().writeAll(usage);
        std.process.exit(1);
    }

    const zls_path = maybe_zls_path orelse fatalWithUsage("ZLS was not found in PATH. Please specify --zls-path instead", .{});
    const zig_path = maybe_zig_path orelse fatalWithUsage("Zig was not found in PATH. Please specify --zig-path instead", .{});
    const mode = mode_name orelse fatalWithUsage("must specify --mode", .{});

    const zls_version = blk: {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ zls_path, "--version" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code != 0) fatal("command '{s} --version' exited with non zero exit code: {d}", .{ zls_path, code }),
            else => fatal("command '{s} --version' exited abnormally: {s}", .{ zls_path, @tagName(result.term) }),
        }

        break :blk try allocator.dupe(u8, std.mem.trim(u8, result.stdout, &std.ascii.whitespace));
    };
    errdefer allocator.free(zls_version);

    const zig_env = blk: {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ zig_path, "env" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code != 0) fatal("command '{s} --version' exited with non zero exit code: {d}", .{ zls_path, code }),
            else => fatal("command '{s} --version' exited abnormally: {s}", .{ zls_path, @tagName(result.term) }),
        }

        var scanner = std.json.Scanner.initCompleteInput(allocator, result.stdout);
        defer scanner.deinit();

        var diagnostics: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&diagnostics);

        break :blk std.json.parseFromTokenSource(Fuzzer.Config.ZigEnv, allocator, &scanner, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.err(
                \\command '{s} env' did not respond with valid json
                \\stdout:
                \\{s}
                \\stderr:
                \\{s}
                \\On Line {d}, Column {d}: {}
            , .{ zig_path, result.stdout, result.stderr, diagnostics.getLine(), diagnostics.getColumn(), err });
            std.process.exit(1);
        };
    };
    errdefer zig_env.deinit();

    return .{
        .rpc = rpc,
        .zls_path = zls_path,
        .mode_name = mode,
        .cycles_per_gen = cycles_per_gen,

        .zig_env = zig_env,
        .zls_version = zls_version,
    };
}

// if you change this text, run `zig build run -- --help` and paste the contents into the README
const usage = std.fmt.comptimePrint(
    \\sus - ZLS fuzzing tooling
    \\
    \\Usage:   sus [options] --mode [mode] -- <mode specific arguments>
    \\
    \\Example: sus --mode markov        -- --training-dir  /path/to/folder/containing/zig/files/
    \\         sus --mode best_behavior -- --source_dir   ~/path/to/folder/containing/zig/files/
    \\
    \\General Options:
    \\  --help                Print this help and exit
    \\  --mode [mode]         Specify fuzzing mode - one of {s}
    \\  --rpc                 Use RPC mode (default: {})
    \\  --zls-path [path]     Specify path to ZLS executable (default: Search in PATH)
    \\  --zig-path [path]     Specify path to Zig executable (default: Search in PATH)
    \\  --cycles-per-gen      How many times to fuzz a random feature before regenerating a new file. (default: {d})
    \\
    \\For a listing of mode specific options, use 'sus --mode [mode] -- --help'.
    \\For a listing of build options, use 'zig build --help'.
    \\
, .{
    std.meta.fieldNames(ModeName).*,
    Fuzzer.Config.Defaults.rpc,
    Fuzzer.Config.Defaults.cycles_per_gen,
});

fn fatalWithUsage(comptime format: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writeAll(usage) catch {};
    std.log.err(format, args);
    std.process.exit(1);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.process.exit(1);
}

pub fn findInPath(allocator: std.mem.Allocator, env_map: std.process.EnvMap, sub_path: []const u8) ?[]const u8 {
    const env_path = env_map.get("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, env_path, std.fs.path.delimiter);
    while (it.next()) |path| {
        const full_path = std.fs.path.join(allocator, &[_][]const u8{ path, sub_path }) catch continue;

        if (!std.fs.path.isAbsolute(full_path)) {
            allocator.free(full_path);
            continue;
        }
        std.fs.accessAbsolute(full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };

        return full_path;
    }
    return null;
}

pub fn main() !void {
    var general_purpose_allocator: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = general_purpose_allocator.deinit();
    const gpa = general_purpose_allocator.allocator();

    var env_map: std.process.EnvMap = loadEnv(gpa) catch std.process.EnvMap.init(gpa);
    defer env_map.deinit();

    var arg_it = try std.process.ArgIterator.initWithAllocator(gpa);
    defer arg_it.deinit();

    var config = try initConfig(gpa, env_map, &arg_it);
    defer config.deinit(gpa);

    var progress = std.Progress.start(.{});
    defer progress.end();

    std.debug.print(
        \\zig-version:    {s}
        \\zls-version:    {s}
        \\zig-path:       {s}
        \\zls-path:       {s}
        \\mode:           {s}
        \\cycles-per-gen: {d}
        \\
    , .{
        config.zig_env.value.version,
        config.zls_version,
        config.zig_env.value.zig_exe,
        config.zls_path,
        @tagName(config.mode_name),
        config.cycles_per_gen,
    });

    var mode = try Mode.init(config.mode_name, gpa, progress, &arg_it, env_map);
    defer mode.deinit(gpa);

    const cwd_path = try std.process.getCwdAlloc(gpa);
    defer gpa.free(cwd_path);

    const principal_file_path = try std.fs.path.join(gpa, &.{ cwd_path, "tmp", "principal.zig" });
    defer gpa.free(principal_file_path);

    const principal_file_uri = try std.fmt.allocPrint(gpa, "{}", .{std.Uri{
        .scheme = "file",
        .path = .{ .raw = principal_file_path },
    }});
    defer gpa.free(principal_file_uri);

    while (true) {
        var fuzzer = try Fuzzer.create(
            gpa,
            progress,
            &mode,
            config,
            principal_file_uri,
        );
        errdefer {
            fuzzer.wait();
            fuzzer.destroy();
        }
        fuzzer.progress_node.setEstimatedTotalItems(100_000);
        try fuzzer.initCycle();

        while (true) {
            if (fuzzer.cycle >= 100_000) {
                std.debug.print("Fuzzer running too long with no result... restarting\n", .{});

                try fuzzer.closeCycle();
                fuzzer.wait();
                fuzzer.destroy();
                break;
            }

            fuzzer.fuzz() catch {
                std.debug.print("Reducing...\n", .{});

                fuzzer.wait();
                try fuzzer.reduce();
                fuzzer.destroy();

                std.debug.print("Restarting fuzzer...\n", .{});

                break;
            };
        }
    }
}
