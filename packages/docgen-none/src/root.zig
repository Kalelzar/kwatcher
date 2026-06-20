const std = @import("std");

pub fn docgen(comptime Driver: type, out_dir: std.fs.Dir, allocator: std.mem.Allocator) !void {
    _ = out_dir;
    _ = allocator;
    std.log.info("Skipping docgen for {s} driver: '{s}'.", .{
        @tagName(Driver.kind),
        @tagName(Driver.key),
    });
}
