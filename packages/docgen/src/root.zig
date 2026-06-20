const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");

pub const generator = if (build_config.module_only) @import("modgen.zig") else @import("docgen.zig");

pub fn main() !void {
    if (comptime builtin.mode == .Debug) {
        var gpa = std.heap.GeneralPurposeAllocator(.{
            .stack_trace_frames = 10,
        }).init;
        const allocator = gpa.allocator();
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();
        _ = args.next();

        generator.generate(allocator, args.next() orelse return error.NoOutput) catch |e| {
            std.log.err("Application error: {}", .{e});
        };
        _ = gpa.detectLeaks();
    } else {
        const allocator = std.heap.smp_allocator;
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();
        _ = args.next();
        try generator.generate(allocator, args.next() orelse return error.NoOutput);
    }
}

comptime {
    std.testing.refAllDecls(@This());
}
