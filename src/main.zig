const std = @import("std");
const builtin = @import("builtin");
const Fuzzer = @import("Fuzzer.zig");
const Mode = @import("mode.zig").Mode;
const ModeName = @import("mode.zig").ModeName;

pub const std_options = struct {
    pub const log_level = std.log.Level.info;

    pub fn logFn(
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        _ = scope;
        if (@intFromEnum(level) > @intFromEnum(log_level)) return;

        const level_txt = comptime level.asText();

        std.debug.print("{d} | {s}: ", .{ std.time.milliTimestamp(), level_txt });
        std.debug.print(format ++ "\n", args);
    }
};

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

fn parseArgs(allocator: std.mem.Allocator, env_map: std.process.EnvMap, arg_it: *std.process.ArgIterator) !Fuzzer.Config {
    _ = arg_it.next() orelse @panic("");

    var zls_path: ?[]const u8 = blk: {
        if (env_map.get("zls_path")) |path| {
            break :blk try allocator.dupe(u8, path);
        }
        break :blk findInPath(allocator, env_map, "zls");
    };
    errdefer if (zls_path) |path| allocator.free(path);

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

    var deflate: bool = if (env_map.get("deflate")) |str| blk: {
        if (std.mem.eql(u8, str, "true")) break :blk true;
        if (std.mem.eql(u8, str, "false")) break :blk false;
        std.log.warn("expected boolean in env option 'deflate' but got '{s}'", .{str});
        break :blk false;
    } else false;

    var cycles_per_gen: u32 = blk: {
        if (env_map.get("cycles_per_gen")) |str| {
            if (std.fmt.parseUnsigned(u32, str, 10)) |cpg| {
                break :blk cpg;
            } else |err| {
                std.log.warn("expected integer in env option 'cycles_per_gen' but got '{s}': {}", .{ str, err });
            }
        }
        break :blk Fuzzer.Config.Defaults.cycles_per_gen;
    };

    var num_args: usize = 0;
    while (arg_it.next()) |arg| : (num_args += 1) {
        if (std.mem.eql(u8, arg, "--")) break;

        if (std.mem.eql(u8, arg, "--help")) {
            try std.io.getStdErr().writeAll(usage);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--zls-path")) {
            zls_path = arg_it.next() orelse fatal("expected file path after --zls-path", .{});
        } else if (std.mem.eql(u8, arg, "--mode")) {
            const mode_arg = arg_it.next() orelse fatal("expected mode parameter after --mode", .{});
            mode_name = std.meta.stringToEnum(ModeName, mode_arg) orelse fatal("unknown mode: {s}", .{mode_arg});
        } else if (std.mem.eql(u8, arg, "--deflate")) {
            deflate = true;
        } else if (std.mem.eql(u8, arg, "--cycles-per-gen")) {
            const next_arg = arg_it.next() orelse fatal("expected integer after --cycles-per-gen", .{});
            cycles_per_gen = std.fmt.parseUnsigned(u32, next_arg, 10) catch fatal("invalid integer '{s}'", .{next_arg});
        } else {
            fatalWithUsage("unknown parameter: {s}", .{arg});
        }
    }

    if (num_args == 0 and (zls_path == null or mode_name == null)) {
        try std.io.getStdErr().writeAll(usage);
        std.process.exit(1);
    }

    // make sure required parameters weren't skipped
    if (zls_path == null) {
        fatalWithUsage("must specify --zls-path", .{});
    } else if (mode_name == null) {
        fatalWithUsage("must specify --mode", .{});
    }

    return .{
        .zls_path = zls_path.?,
        .mode_name = mode_name.?,
        .cycles_per_gen = cycles_per_gen,
        .deflate = deflate,
    };
}

// note: if you change this text don't forget to run `zig build run --help`
// and paste the contents into the README
const usage =
    std.fmt.comptimePrint(
    \\sus - zls fuzzing tooling
    \\
    \\Usage:  sus [options] --mode [mode] -- <mode specific arguments>
    \\        sus [options] --mode [mode] -- <mode specific arguments>
    \\
    \\General Options:
    \\  --help                Print this help and exit
    \\  --zls-path [path]     Specify path to ZLS executable
    \\  --mode [mode]         Specify fuzzing mode - one of {s}
    \\  --deflate             Compress log files with DEFLATE
    \\  --cycles-per-gen      How many times to fuzz a random feature before regenerating a new file. (default: {d})
    \\
    \\For a listing of mode specific options, use 'sus --mode [mode] -- --help'.
    \\For a listing of build options, use 'zig build --help'.
    \\
, .{
    std.meta.fieldNames(ModeName).*,
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

const stack_trace_frames: usize = switch (builtin.mode) {
    .Debug => 16,
    else => 0,
};

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = stack_trace_frames,
    }){};
    defer _ = general_purpose_allocator.deinit();
    const gpa = general_purpose_allocator.allocator();

    const stderr = std.io.getStdErr().writer();

    var env_map: std.process.EnvMap = loadEnv(gpa) catch std.process.EnvMap.init(gpa);
    defer env_map.deinit();

    var arg_it = try std.process.ArgIterator.initWithAllocator(gpa);
    defer arg_it.deinit();

    var config = try parseArgs(gpa, env_map, &arg_it);
    defer config.deinit(gpa);

    const zls_version = blk: {
        const vers = try std.ChildProcess.exec(.{
            .allocator = gpa,
            .argv = &.{ config.zls_path, "--version" },
        });
        defer gpa.free(vers.stdout);
        defer gpa.free(vers.stderr);
        break :blk try gpa.dupe(u8, std.mem.trim(u8, vers.stdout, &std.ascii.whitespace));
    };
    defer gpa.free(zls_version);

    try stderr.print(
        \\zig_version:    {s}
        \\zls_version:    {s}
        \\zls_path:       {s}
        \\mode:           {s}
        \\deflate:        {}
        \\cycles-per-gen: {d}
        \\
    , .{ builtin.zig_version_string, zls_version, config.zls_path, @tagName(config.mode_name), config.deflate, config.cycles_per_gen });

    var mode = try Mode.init(config.mode_name, gpa, &arg_it, env_map);
    defer mode.deinit(gpa);

    while (true) {
        var fuzzer = try Fuzzer.create(gpa, &mode, config);
        errdefer {
            fuzzer.wait();
            fuzzer.destroy();
        }
        try fuzzer.initCycle();

        while (true) {
            if (fuzzer.cycle % 1000 == 0) {
                std.log.info("heartbeat {d}", .{fuzzer.cycle});
            }

            if (fuzzer.cycle >= 100_000) {
                std.log.info("Fuzzer running too long with no result... restarting", .{});

                try fuzzer.closeCycle();
                fuzzer.wait();
                fuzzer.destroy();
                break;
            }

            fuzzer.fuzz() catch {
                std.log.info("Restarting fuzzer...", .{});

                fuzzer.wait();
                fuzzer.logPrincipal() catch {
                    std.log.err("failed to log principal", .{});
                };
                fuzzer.destroy();
                break;
            };
        }
    }
}
