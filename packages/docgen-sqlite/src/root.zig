const std = @import("std");
const docindex = @import("kw-docindex");

/// Write the sqlite driver's schema as build-time artifacts: the rendered
/// DDL (`.sql`) and the serializable schema IR snapshot (`.zon`). The `.sql`
/// is the embeddable "create everything" script; the `.zon` is the diffing
/// input for migration generation (compare a committed snapshot against the
/// freshly generated one).
///
/// The table data comes off the driver type itself (`Driver.schema` /
/// `Driver.schema_sql`, published by kw-sqlite). This backend deliberately
/// does NOT import kw-orm-sqlite: a second module instance in the generator
/// graph would not be marker-identity-compatible with the app's table types.
pub fn docgen(
    comptime Driver: type,
    out_dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    doc_index: *const docindex.DocIndex,
    name: []const u8,
    version: []const u8,
) !void {
    _ = doc_index;

    if (Driver.tables.len == 0) {
        std.log.info("docgen-sqlite: driver '{s}' declares no tables; skipping.", .{
            @tagName(Driver.key),
        });
        return;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sql_name = try std.fmt.allocPrint(a, "sqlite-schema-{s}-{s}-{s}.sql", .{
        name,
        @tagName(Driver.key),
        version,
    });
    std.log.info("docgen-sqlite: writing schema DDL to '{s}'.", .{sql_name});
    {
        var file = try out_dir.createFile(sql_name, .{});
        defer file.close();
        var buf: [4096]u8 = undefined;
        var writer = file.writer(&buf);
        const wi = &writer.interface;
        try wi.writeAll(Driver.schema_sql);
        try wi.flush();
    }

    const zon_name = try std.fmt.allocPrint(a, "sqlite-schema-{s}-{s}-{s}.zon", .{
        name,
        @tagName(Driver.key),
        version,
    });
    std.log.info("docgen-sqlite: writing schema IR snapshot to '{s}'.", .{zon_name});
    {
        var file = try out_dir.createFile(zon_name, .{});
        defer file.close();
        var buf: [4096]u8 = undefined;
        var writer = file.writer(&buf);
        const wi = &writer.interface;
        try std.zon.stringify.serialize(Driver.schema, .{}, wi);
        try wi.writeByte('\n');
        try wi.flush();
    }

    // Candidate migration: only meaningful when the app wired a
    // MigrationSource (otherwise the driver auto-migrates and the diff
    // against an empty snapshot is just noise).
    if (comptime Driver.migration_source == null) return;
    if (Driver.candidate_up.len == 0) {
        std.log.info("docgen-sqlite: schema matches the committed snapshot; no candidate migration.", .{});
        return;
    }
    inline for (.{ .{ "up", Driver.candidate_up }, .{ "down", Driver.candidate_down } }) |pair| {
        const file_name = try std.fmt.allocPrint(a, "sqlite-migration-{s}-{s}-{s}.{s}.sql", .{
            name,
            @tagName(Driver.key),
            version,
            pair[0],
        });
        var file = try out_dir.createFile(file_name, .{});
        defer file.close();
        var buf: [4096]u8 = undefined;
        var writer = file.writer(&buf);
        const wi = &writer.interface;
        try wi.writeAll(pair[1]);
        try wi.flush();
    }
    std.log.info(
        "docgen-sqlite: candidate migration pending for driver '{s}' — make it permanent with `zig build commit-migration -Dmigration-name=<name>`.",
        .{@tagName(Driver.key)},
    );
}

pub const emitRuntime = @import("runtime.zig").emitRuntime;

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
