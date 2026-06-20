const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");

pub const generator = if (build_config.module_only) @import("modgen.zig") else @import("docgen.zig");

pub fn main() !void {
    if (comptime builtin.mode == .Debug) {
        var gpa = std.heap.GeneralPurposeAllocator(.{
            .stack_trace_frames = 10,
        }).init;
        // Registered first so it runs last — after args/roots are freed below —
        // otherwise leak detection sees them still live.
        defer _ = gpa.detectLeaks();
        const allocator = gpa.allocator();
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();
        _ = args.next();

        const out_dir = args.next() orelse return error.NoOutput;
        var roots: std.ArrayListUnmanaged([]const u8) = .empty;
        defer roots.deinit(allocator);
        while (args.next()) |arg| try roots.append(allocator, arg);

        generator.generate(allocator, out_dir, roots.items) catch |e| {
            std.log.err("Application error: {}", .{e});
        };
    } else {
        const allocator = std.heap.smp_allocator;
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();
        _ = args.next();

        const out_dir = args.next() orelse return error.NoOutput;
        var roots: std.ArrayListUnmanaged([]const u8) = .empty;
        defer roots.deinit(allocator);
        while (args.next()) |arg| try roots.append(allocator, arg);

        try generator.generate(allocator, out_dir, roots.items);
    }
}

comptime {
    std.testing.refAllDecls(@This());
}
