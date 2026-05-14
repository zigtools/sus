const std = @import("std");
const builtin = @import("builtin");
const Fuzzer = @import("Fuzzer.zig");
const Mode = @import("mode.zig").Mode;
const ModeName = @import("mode.zig").ModeName;

fn loadEnv(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) std.Io.Dir.ReadFileAllocError!std.process.Environ.Map {
    var envmap: std.process.Environ.Map = try environ_map.clone(allocator);
    errdefer envmap.deinit();

    const env_content = std.Io.Dir.cwd().readFileAlloc(io, ".env", allocator, .limited(1024 * 1024)) catch |e| switch (e) {
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

fn initConfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    arg_it: *std.process.Args.Iterator,
) !Fuzzer.Config {
    _ = arg_it.skip();

    var maybe_zls_path: ?[]const u8 = blk: {
        if (env_map.get("zls_path")) |path| {
            break :blk try allocator.dupe(u8, path);
        }
        break :blk try findInPath(io, allocator, env_map, "zls");
    };
    errdefer if (maybe_zls_path) |path| allocator.free(path);

    var maybe_zig_path: ?[]const u8 = blk: {
        if (env_map.get("zig_path")) |path| {
            break :blk try allocator.dupe(u8, path);
        }
        break :blk try findInPath(io, allocator, env_map, "zig");
    };
    defer if (maybe_zig_path) |path| allocator.free(path);

    var rpc =
        if (env_map.get("rpc")) |str| if (std.mem.eql(u8, str, "false"))
            false
        else if (std.mem.eql(u8, str, "true"))
            true
        else blk: {
            std.log.warn("expected boolean (true|false) in env option 'rpc' but got '{s}'", .{str});
            break :blk Fuzzer.Config.Defaults.rpc;
        } else Fuzzer.Config.Defaults.rpc;

    var seed: ?u64 = null; // Cannot be set through env_map

    var mode_name: ?ModeName = blk: {
        if (env_map.get("mode")) |mode_name| {
            if (std.meta.stringToEnum(ModeName, mode_name)) |mode| {
                break :blk mode;
            } else {
                std.log.warn(
                    "expected mode name (one of {f}) in env option 'mode' but got '{s}'",
                    .{ std.json.fmt(std.meta.fieldNames(ModeName).*, .{}), mode_name },
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
            try std.Io.File.stdout().writeStreamingAll(io, usage);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--rpc")) {
            rpc = true;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            const next_arg = arg_it.next() orelse fatal("expected number after --seed", .{});
            seed = std.fmt.parseUnsigned(u64, next_arg, 10) catch fatal("invalid unsigned integer '{s}'", .{next_arg});
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
        std.Io.File.stderr().writeStreamingAll(io, usage) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => {},
        };
        std.process.exit(1);
    }

    const zls_path = maybe_zls_path orelse fatalWithUsage("ZLS was not found in PATH. Please specify --zls-path instead", .{});
    const zig_path = maybe_zig_path orelse fatalWithUsage("Zig was not found in PATH. Please specify --zig-path instead", .{});
    const mode = mode_name orelse fatalWithUsage("must specify --mode", .{});

    const zls_version = blk: {
        const result = std.process.run(allocator, io, .{
            .argv = &.{ zls_path, "--version" },
        }) catch |err| {
            fatal("Failed to run '{s} --version' command: {}", .{ zls_path, err });
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) fatal("command '{s} --version' exited with non zero exit code: {d}", .{ zls_path, code }),
            else => fatal("command '{s} --version' exited abnormally: {s}", .{ zls_path, @tagName(result.term) }),
        }

        break :blk try allocator.dupe(u8, std.mem.trim(u8, result.stdout, &std.ascii.whitespace));
    };
    errdefer allocator.free(zls_version);

    var zig_env_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer zig_env_arena.deinit();

    const zig_env: Fuzzer.Config.ZigEnv = blk: {
        const result = std.process.run(allocator, io, .{
            .argv = &.{ zig_path, "env" },
        }) catch |err| {
            fatal("failed to run '{s} env' command: {}", .{ zig_path, err });
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) fatal("command '{s} env' exited with non zero exit code: {d}", .{ zig_path, code }),
            else => fatal("command '{s} env' exited abnormally: {s}", .{ zig_path, @tagName(result.term) }),
        }

        if (std.mem.startsWith(u8, result.stdout, "{")) {
            var scanner: std.json.Scanner = .initCompleteInput(allocator, result.stdout);
            defer scanner.deinit();

            var diagnostics: std.json.Diagnostics = .{};
            scanner.enableDiagnostics(&diagnostics);

            break :blk std.json.parseFromTokenSourceLeaky(
                Fuzzer.Config.ZigEnv,
                zig_env_arena.allocator(),
                &scanner,
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            ) catch |err| {
                fatal(
                    \\command '{s} env' did not respond with valid json or zon
                    \\stdout:
                    \\{s}
                    \\stderr:
                    \\{s}
                    \\On Line {d}, Column {d}: {}
                , .{ zig_path, result.stdout, result.stderr, diagnostics.getLine(), diagnostics.getColumn(), err });
            };
        } else {
            const stdout = try allocator.dupeZ(u8, result.stdout);
            defer allocator.free(stdout);

            var diagnostics: std.zon.parse.Diagnostics = .{};
            break :blk std.zon.parse.fromSliceAlloc(
                Fuzzer.Config.ZigEnv,
                zig_env_arena.allocator(),
                stdout,
                &diagnostics,
                .{ .ignore_unknown_fields = true },
            ) catch {
                fatal(
                    \\command '{s} env' did not respond with valid json or zon
                    \\stdout:
                    \\{s}
                    \\stderr:
                    \\{s}
                    \\{f}
                , .{ zig_path, result.stdout, result.stderr, diagnostics });
            };
        }
    };

    return .{
        .rpc = rpc,
        .seed = seed,
        .zls_path = zls_path,
        .mode_name = mode,
        .cycles_per_gen = cycles_per_gen,

        .zig_env_arena = zig_env_arena.state,
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
    \\  --mode [mode]         Specify fuzzing mode - one of {f}
    \\  --seed [number]       Fuzz a specific seed to reproduce a crash
    \\  --rpc                 Use RPC mode (default: {})
    \\  --zls-path [path]     Specify path to ZLS executable (default: Search in PATH)
    \\  --zig-path [path]     Specify path to Zig executable (default: Search in PATH)
    \\  --cycles-per-gen      How many times to fuzz a random feature before regenerating a new file. (default: {d})
    \\
    \\For a listing of mode specific options, use 'sus --mode [mode] -- --help'.
    \\For a listing of build options, use 'zig build --help'.
    \\
, .{
    std.json.fmt(std.meta.fieldNames(ModeName).*, .{}),
    Fuzzer.Config.Defaults.rpc,
    Fuzzer.Config.Defaults.cycles_per_gen,
});

fn fatalWithUsage(comptime format: []const u8, args: anytype) noreturn {
    const stderr = std.debug.lockStderr(&.{}).terminal();
    defer std.debug.unlockStderr();
    stderr.writer.writeAll(usage) catch {};
    std.log.err(format, args);
    std.process.exit(1);
}

const fatal = std.process.fatal;

fn findInPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    cmd: []const u8,
) error{ Canceled, OutOfMemory }!?[]const u8 {
    const is_windows = builtin.target.os.tag == .windows;

    const env_path = environ_map.get("PATH") orelse return null;
    const env_path_ext = if (is_windows) environ_map.get("PATHEXT") orelse return null;

    var filename_buffer: std.ArrayList(u8) = .empty;
    defer filename_buffer.deinit(allocator);

    var path_it = std.mem.tokenizeScalar(u8, env_path, std.Io.Dir.path.delimiter);
    var ext_it = if (is_windows) std.mem.tokenizeScalar(u8, env_path_ext, std.Io.Dir.path.delimiter);

    while (path_it.next()) |path| : (if (is_windows) ext_it.reset()) {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.FileNotFound => continue,
            else => |e| {
                std.log.warn("failed to open entry in PATH '{s}': {}", .{ path, e });
                continue;
            },
        };
        defer dir.close(io);

        var cont = true;
        while (cont) : (cont = is_windows) {
            const filename = if (!is_windows) cmd else filename: {
                const ext = ext_it.next() orelse break;

                filename_buffer.clearRetainingCapacity();
                try filename_buffer.ensureTotalCapacity(allocator, cmd.len + ext.len);
                filename_buffer.appendSliceAssumeCapacity(cmd);
                filename_buffer.appendSliceAssumeCapacity(ext);

                break :filename filename_buffer.items;
            };

            const stat = dir.statFile(io, filename, .{}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.FileNotFound => continue,
                else => |e| {
                    std.log.warn("failed to access entry in PATH '{f}': {}", .{ std.Io.Dir.path.fmtJoin(&.{ path, filename }), e });
                    continue;
                },
            };

            if (stat.kind == .directory) {
                std.log.warn("ignoring entry in PATH '{f}' because it is a directory", .{std.Io.Dir.path.fmtJoin(&.{ path, filename })});
                continue;
            }

            return try std.Io.Dir.path.join(allocator, &.{ path, filename });
        }
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var env_map: std.process.Environ.Map = loadEnv(io, gpa, init.environ_map) catch .init(gpa);
    defer env_map.deinit();

    var arg_it = init.minimal.args.iterate();
    defer arg_it.deinit();

    var config = try initConfig(io, gpa, &env_map, &arg_it);
    defer config.deinit(gpa);

    var progress = std.Progress.start(io, .{});
    defer progress.end();

    std.debug.print(
        \\zig-version:    {s}
        \\zls-version:    {s}
        \\zig-path:       {s}
        \\zls-path:       {s}
        \\mode:           {s}
        \\seed:           {?d}
        \\cycles-per-gen: {d}
        \\
    , .{
        config.zig_env.version,
        config.zls_version,
        config.zig_env.zig_exe,
        config.zls_path,
        @tagName(config.mode_name),
        config.seed,
        config.cycles_per_gen,
    });

    var mode: Mode = try .init(io, gpa, config.mode_name, progress, &arg_it, &env_map);
    defer mode.deinit(gpa);

    while (true) {
        const progress_node = progress.start("fuzzing", 100_000);
        defer progress_node.end();

        var fuzzer: Fuzzer = try .init(io, gpa, init.environ_map, &mode, &config);
        defer fuzzer.deinit();
        errdefer fuzzer.client.kill();

        fuzzer.client.initialize() catch |err| {
            std.log.err("Failed to initalize LSP Client: {}", .{err});
            return err;
        };

        while (fuzzer.cycle < 100_000) {
            if (fuzzer.fuzz()) {
                progress_node.completeOne();
            } else |err| {
                try fuzzer.client.wait();
                std.log.info("Reducing {} [seed={d}]...", .{ err, fuzzer.seed });
                // if (config.seed != null) return;

                const progress_node_reduce = progress_node.start("reducing", fuzzer.cycle);
                defer progress_node_reduce.end();
                try @import("Reducer.zig").reduce(
                    io,
                    gpa,
                    init.environ_map,
                    &mode,
                    &config,
                    fuzzer.seed,
                    progress_node_reduce,
                );
                break;
            }
        } else {
            if (config.seed != null) {
                std.log.info("Fuzzer running too long with no result. restarting...", .{});
            }

            fuzzer.client.shutdown() catch |err| {
                std.log.err("Failed to shutdown LSP Client: {}", .{err});
                return err;
            };
            try fuzzer.client.wait();
            if (config.seed != null) return;
        }
    }
}
