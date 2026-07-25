const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");

pub const generator = @import("docgen.zig");

pub fn juicyMain(allocator: std.mem.Allocator) !void {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    const out_dir = args.next() orelse return error.NoOutput;
    var roots: std.ArrayListUnmanaged([]const u8) = .empty;
    defer roots.deinit(allocator);
    while (args.next()) |arg| try roots.append(allocator, arg);

    try generator.generate(allocator, out_dir, roots.items);
}

pub fn main() !void {
    if (comptime builtin.mode == .Debug) {
        var gpa = std.heap.GeneralPurposeAllocator(.{
            .stack_trace_frames = 10,
        }).init;
        const allocator = gpa.allocator();
        juicyMain(allocator) catch |e| {
            std.log.err("Application error: {}", .{e});
        };
        _ = gpa.detectLeaks();
    } else {
        const allocator = std.heap.smp_allocator;

        try juicyMain(allocator);
    }
}

comptime {
    std.testing.refAllDecls(@This());
}
