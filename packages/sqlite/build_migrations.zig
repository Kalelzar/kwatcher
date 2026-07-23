//! Build-time wiring for an app's sqlite migrations (kalpack's
//! `embedMigrations` in spirit, adapted to the candidate workflow):
//!
//!  - `"kw-sqlite--snapshot"`: zon module with the committed schema IR
//!    (`<dir>/schema.zon`), or an empty schema when the file doesn't exist
//!    yet (first run: the whole schema becomes the candidate).
//!  - `"kw-sqlite--migrations"`: generated source embedding every committed
//!    `NNNN.<name>.up.sql` / `.down.sql` pair, sorted by filename.
//!
//! Call `wire` on every copy of the app module (the installed target AND the
//! host docgen entrypoint) so both graphs stay identical.

const std = @import("std");

pub fn wire(b: *std.Build, app: *std.Build.Module, migrations_dir: []const u8) void {
    const wf = b.addWriteFiles();

    const snapshot: std.Build.LazyPath = blk: {
        const rel = b.pathJoin(&.{ migrations_dir, "schema.zon" });
        if (b.build_root.handle.access(rel, .{})) |_| {
            break :blk b.path(rel);
        } else |_| {
            break :blk wf.add("schema.zon", ".{ .version = 1, .tables = .{} }\n");
        }
    };
    app.addAnonymousImport("kw-sqlite--snapshot", .{ .root_source_file = snapshot });

    app.addAnonymousImport("kw-sqlite--migrations", .{
        .root_source_file = wf.add("kw_sqlite_migrations.zig", generateEmbedded(b, migrations_dir)),
    });
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn generateEmbedded(b: *std.Build, migrations_dir: []const u8) []const u8 {
    const a = b.allocator;
    var src = std.ArrayList(u8){};
    src.appendSlice(a,
        \\pub const Migration = struct {
        \\    version: []const u8,
        \\    up: []const u8,
        \\    down: []const u8,
        \\};
        \\pub const all = [_]Migration{
        \\
    ) catch @panic("OOM");

    var names = std.ArrayList([]const u8){};
    collect: {
        var dir = b.build_root.handle.openDir(migrations_dir, .{ .iterate = true }) catch break :collect;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch @panic("failed to iterate the migrations directory")) |f| {
            if (f.kind == .file and std.mem.endsWith(u8, f.name, ".up.sql")) {
                names.append(a, a.dupe(u8, f.name) catch @panic("OOM")) catch @panic("OOM");
            }
        }
    }
    std.sort.heap([]const u8, names.items, {}, lessThan);

    for (names.items) |name| {
        const base = name[0 .. name.len - ".up.sql".len];
        const up = readMigration(b, migrations_dir, name);
        const down = readMigration(b, migrations_dir, b.fmt("{s}.down.sql", .{base}));
        src.appendSlice(a, "    .{ .version = \"") catch @panic("OOM");
        appendEscaped(b, &src, base);
        src.appendSlice(a, "\", .up = \"") catch @panic("OOM");
        appendEscaped(b, &src, up);
        src.appendSlice(a, "\", .down = \"") catch @panic("OOM");
        appendEscaped(b, &src, down);
        src.appendSlice(a, "\" },\n") catch @panic("OOM");
    }

    src.appendSlice(a, "};\n") catch @panic("OOM");
    return src.items;
}

fn readMigration(b: *std.Build, migrations_dir: []const u8, name: []const u8) []const u8 {
    const rel = b.pathJoin(&.{ migrations_dir, name });
    return b.build_root.handle.readFileAlloc(b.allocator, rel, 1024 * 1024) catch
        @panic(b.fmt("failed to read migration file '{s}' (every .up.sql needs a matching .down.sql)", .{rel}));
}

fn appendEscaped(b: *std.Build, src: *std.ArrayList(u8), s: []const u8) void {
    const a = b.allocator;
    for (s) |c| {
        switch (c) {
            '\\' => src.appendSlice(a, "\\\\") catch @panic("OOM"),
            '"' => src.appendSlice(a, "\\\"") catch @panic("OOM"),
            '\n' => src.appendSlice(a, "\\n") catch @panic("OOM"),
            '\r' => src.appendSlice(a, "\\r") catch @panic("OOM"),
            '\t' => src.appendSlice(a, "\\t") catch @panic("OOM"),
            else => if (std.ascii.isPrint(c))
                src.append(a, c) catch @panic("OOM")
            else
                src.appendSlice(a, b.fmt("\\x{x:0>2}", .{c})) catch @panic("OOM"),
        }
    }
}
