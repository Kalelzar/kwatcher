//! `kw-docgen--signal` — the build-time signal docgen backend.
//!
//! There is no on-disk document standard worth emitting for signal handlers, so
//! `docgen` is a no-op; the real product is the runtime projection `runtime.zig`
//! appends to the generated `manifest.zig` for the in-app introspection UI.

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
    std.log.info("Skipping on-disk docgen for {s} driver: '{s}'.", .{
        @tagName(Driver.kind),
        @tagName(Driver.key),
    });
}

pub const emitRuntime = @import("runtime.zig").emitRuntime;

comptime {
    std.testing.refAllDecls(@This());
}
