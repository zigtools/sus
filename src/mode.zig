const std = @import("std");

pub const ModeName = std.meta.Tag(Mode);
pub const Mode = union(enum) {
    best_behavior: *@import("modes/BestBehavior.zig"),
    markov: *@import("modes/MarkovMode.zig"),

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        mode_name: ModeName,
        progress: std.Progress.Node,
        arg_it: *std.process.Args.Iterator,
        envmap: *const std.process.Environ.Map,
    ) !Mode {
        switch (mode_name) {
            inline else => |m| {
                return @unionInit(Mode, @tagName(m), try .init(io, allocator, progress, arg_it, envmap));
            },
        }
    }

    pub fn deinit(mode: *Mode, allocator: std.mem.Allocator) void {
        switch (mode.*) {
            inline else => |m| m.deinit(allocator),
        }
        mode.* = undefined;
    }

    pub fn gen(mode: *const Mode, allocator: std.mem.Allocator, random: std.Random) ![]const u8 {
        switch (mode.*) {
            inline else => |m| return try m.gen(allocator, random),
        }
    }
};
