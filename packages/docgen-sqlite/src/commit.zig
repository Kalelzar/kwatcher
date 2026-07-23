//! kw-sqlite-commit: promote the generated candidate migration to a
//! committed one. Scans the docgen output directory for the candidate pair
//! (`sqlite-migration-*.up.sql` / `.down.sql`) and the schema snapshot
//! (`sqlite-schema-*.zon`), copies the pair into the app's migrations
//! directory as `NNNN.<name>.{up,down}.sql` (NNNN = max existing + 1), and
//! overwrites `<migrations>/schema.zon` with the fresh snapshot — after
//! which the next build diffs to empty and the runner promotes the applied
//! candidate row in place.
//!
//! Usage: kw-sqlite-commit <docs_dir> <migrations_dir> <name>

const std = @import("std");

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("kw-sqlite-commit: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const args = try std.process.argsAlloc(a);
    if (args.len != 4) fail("usage: kw-sqlite-commit <docs_dir> <migrations_dir> <name>", .{});
    const docs_path = args[1];
    const migrations_path = args[2];
    const name = args[3];

    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
            fail("migration name '{s}' may only contain [A-Za-z0-9_-]", .{name});
        }
    }

    var docs = std.fs.cwd().openDir(docs_path, .{ .iterate = true }) catch
        fail("cannot open docs directory '{s}' — run the build first", .{docs_path});
    defer docs.close();

    // Find the candidate pair and the snapshot. Exactly one candidate
    // (one sqlite driver with pending changes) is supported for now.
    var up_name: ?[]const u8 = null;
    var snapshot_name: ?[]const u8 = null;
    var it = docs.iterate();
    while (try it.next()) |f| {
        if (f.kind != .file) continue;
        if (std.mem.startsWith(u8, f.name, "sqlite-migration-") and std.mem.endsWith(u8, f.name, ".up.sql")) {
            if (up_name != null) fail("multiple candidate migrations in '{s}'; commit them one driver at a time", .{docs_path});
            up_name = try a.dupe(u8, f.name);
        } else if (std.mem.startsWith(u8, f.name, "sqlite-schema-") and std.mem.endsWith(u8, f.name, ".zon")) {
            if (snapshot_name != null) fail("multiple schema snapshots in '{s}'; cannot pick one", .{docs_path});
            snapshot_name = try a.dupe(u8, f.name);
        }
    }
    const up_file = up_name orelse
        fail("no candidate migration found in '{s}' — either the schema matches the committed snapshot or the build hasn't run", .{docs_path});
    const snapshot_file = snapshot_name orelse
        fail("no schema snapshot found in '{s}'", .{docs_path});
    const down_file = try std.fmt.allocPrint(a, "{s}.down.sql", .{up_file[0 .. up_file.len - ".up.sql".len]});

    const up = try docs.readFileAlloc(a, up_file, 1024 * 1024);
    const down = docs.readFileAlloc(a, down_file, 1024 * 1024) catch
        fail("candidate '{s}' has no matching down file '{s}'", .{ up_file, down_file });
    const snapshot = try docs.readFileAlloc(a, snapshot_file, 1024 * 1024);

    std.fs.cwd().makePath(migrations_path) catch
        fail("cannot create migrations directory '{s}'", .{migrations_path});
    var migrations = try std.fs.cwd().openDir(migrations_path, .{ .iterate = true });
    defer migrations.close();

    var max: u32 = 0;
    var mit = migrations.iterate();
    while (try mit.next()) |f| {
        if (f.kind != .file or !std.mem.endsWith(u8, f.name, ".up.sql")) continue;
        const dot = std.mem.indexOfScalar(u8, f.name, '.') orelse continue;
        const n = std.fmt.parseInt(u32, f.name[0..dot], 10) catch continue;
        if (n > max) max = n;
    }

    const up_out = try std.fmt.allocPrint(a, "{d:0>4}.{s}.up.sql", .{ max + 1, name });
    const down_out = try std.fmt.allocPrint(a, "{d:0>4}.{s}.down.sql", .{ max + 1, name });

    try migrations.writeFile(.{ .sub_path = up_out, .data = up });
    try migrations.writeFile(.{ .sub_path = down_out, .data = down });
    try migrations.writeFile(.{ .sub_path = "schema.zon", .data = snapshot });

    std.debug.print(
        "kw-sqlite-commit: committed '{s}' + '{s}' and updated '{s}/schema.zon'.\n",
        .{ up_out, down_out, migrations_path },
    );
}
