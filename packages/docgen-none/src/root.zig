const std = @import("std");
const docindex = @import("kw-docindex");

pub fn docgen(
    comptime Driver: type,
    out_dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    doc_index: *const docindex.DocIndex,
) !void {
    _ = out_dir;
    _ = allocator;
    _ = doc_index;
    std.log.info("Skipping docgen for {s} driver: '{s}'.", .{
        @tagName(Driver.kind),
        @tagName(Driver.key),
    });
}
