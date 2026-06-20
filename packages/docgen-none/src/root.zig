const std = @import("std");
const docindex = @import("kw-docindex");

pub fn docgen(
    comptime Driver: type,
    out_dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    doc_index: *const docindex.DocIndex,
    name: []const u8,
    version: []const u8,
) !void {
    _ = out_dir;
    _ = allocator;
    _ = doc_index;
    _ = name;
    _ = version;
    std.log.info("Skipping docgen for {s} driver: '{s}'.", .{
        @tagName(Driver.kind),
        @tagName(Driver.key),
    });
}
