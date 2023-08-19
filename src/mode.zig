const std = @import("std");

pub const ModeName = std.meta.Tag(Mode);
pub const Mode = union(enum) {
    best_behavior: *@import("modes/BestBehavior.zig"),
    markov: *@import("modes/MarkovMode.zig"),

    pub fn init(
        mode_name: ModeName,
        allocator: std.mem.Allocator,
        arg_it: *std.process.ArgIterator,
        envmap: std.process.EnvMap,
    ) !Mode {
        switch (mode_name) {
            inline else => |m| {
                const Inner = std.meta.Child(std.meta.TagPayload(Mode, m));
                return @unionInit(Mode, @tagName(m), try Inner.init(allocator, arg_it, envmap));
            },
        }
    }

    pub fn deinit(mode: *Mode, allocator: std.mem.Allocator) void {
        switch (mode.*) {
            inline else => |m| m.deinit(allocator),
        }
        mode.* = undefined;
    }

    pub fn gen(mode: *Mode, allocator: std.mem.Allocator) ![]const u8 {
        switch (mode.*) {
            inline else => |m| return try m.gen(allocator),
        }
    }
};
