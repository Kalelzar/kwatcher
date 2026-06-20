const std = @import("std");

pub fn docgen(comptime Driver: type, out_dir: std.fs.Dir, allocator: std.mem.Allocator) !void {
    _ = out_dir;
    _ = allocator;
    // TODO: emit OpenAPI document for the HTTP driver.
    std.log.info("TODO: docgen for {s} driver: '{s}'.", .{ @tagName(Driver.kind), @tagName(Driver.key) });
}
