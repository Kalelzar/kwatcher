//! Emit a runtime-facing projection of each sqlite driver into the generated
//! `manifest.zig`, so the in-app introspection UI can render it.
//!
//! Three surfaces per driver: the table structure (straight off the plain
//! `Driver.schema` IR — never the ORM itself), the named query routes (id,
//! doc comment, call-context element types — the SQL text lives in fn bodies
//! and is not introspectable), and the migration state (committed versions
//! plus the build-time candidate).
//!
//! The emitted Zig is self-contained — it defines its own `Sqlite*` types and
//! a `pub const sqlite_documents` literal, importing nothing — matching the
//! `Http*`/`Cron*`/`Signal*` projections.

const std = @import("std");
const docindex = @import("kw-docindex");

/// Called once for the sqlite kind by the docgen framework, with every driver
/// in the app (we filter to sqlite-kind ourselves). Appends the runtime types
/// + the `sqlite_documents` array to the manifest writer.
pub fn emitRuntime(
    comptime Drivers: []const type,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    doc_index: *const docindex.DocIndex,
    name: []const u8,
    version_str: []const u8,
) !void {
    _ = allocator;

    try writer.writeAll(runtime_types);
    try writer.writeAll("pub const sqlite_documents: []const SqliteDocument = &.{\n");

    inline for (Drivers) |Drv| {
        if (comptime std.mem.eql(u8, @tagName(Drv.kind), "sqlite")) {
            try emitDocument(writer, Drv, doc_index, name, version_str);
        }
    }

    try writer.writeAll("};\n");
}

const runtime_types =
    \\pub const SqliteColumn = struct { name: []const u8, affinity: []const u8, nullable: bool, pk: bool, unique: bool, fk_table: []const u8, fk_column: []const u8, on_delete: []const u8, on_update: []const u8 };
    \\pub const SqliteTable = struct { name: []const u8, columns: []const SqliteColumn };
    \\pub const SqliteParam = struct { field: []const u8, type_name: []const u8 };
    \\pub const SqliteQuery = struct { id: []const u8, summary: []const u8, description: []const u8, params: []const SqliteParam, result: []const u8 };
    \\pub const SqliteMigration = struct { version: []const u8 };
    \\pub const SqliteDocument = struct { key: []const u8, title: []const u8, version: []const u8, tables: []const SqliteTable, queries: []const SqliteQuery, committed: []const SqliteMigration, candidate_up: []const u8, candidate_down: []const u8 };
    \\
;

fn emitDocument(
    w: *std.Io.Writer,
    comptime Drv: type,
    doc_index: *const docindex.DocIndex,
    title: []const u8,
    version: []const u8,
) !void {
    try w.writeAll("    .{ .key = ");
    try emitStr(w, @tagName(Drv.key));
    try w.writeAll(", .title = ");
    try emitStr(w, title);
    try w.writeAll(", .version = ");
    try emitStr(w, version);

    try w.writeAll(", .tables = &.{\n");
    inline for (Drv.schema.tables) |t| {
        try w.writeAll("        .{ .name = ");
        try emitStr(w, t.name);
        try w.writeAll(", .columns = &.{\n");
        inline for (t.columns) |col| {
            try emitColumn(w, col);
        }
        try w.writeAll("        } },\n");
    }
    try w.writeAll("    }, .queries = &.{\n");
    inline for (Drv.Routes) |R| {
        try emitQuery(w, R, doc_index);
    }
    try w.writeAll("    }, .committed = &.{");
    inline for (Drv.committed_migrations) |m| {
        try w.writeAll(" .{ .version = ");
        try emitStr(w, m.version);
        try w.writeAll(" },");
    }
    // Without a MigrationSource the driver auto-migrates and the "candidate"
    // is just the diff against an empty snapshot — noise, not a pending
    // migration. Same rule as the build-time artifact emitter.
    try w.writeAll(" }, .candidate_up = ");
    try emitStr(w, if (comptime Drv.migration_source == null) "" else Drv.candidate_up);
    try w.writeAll(", .candidate_down = ");
    try emitStr(w, if (comptime Drv.migration_source == null) "" else Drv.candidate_down);
    try w.writeAll(" },\n");
}

fn emitColumn(w: *std.Io.Writer, comptime col: anytype) !void {
    try w.writeAll("            .{ .name = ");
    try emitStr(w, col.name);
    try w.writeAll(", .affinity = ");
    try emitStr(w, @tagName(col.affinity));
    try w.print(", .nullable = {}, .pk = {}, .unique = {}", .{ col.nullable, col.pk, col.unique });
    if (col.fk) |fk| {
        try w.writeAll(", .fk_table = ");
        try emitStr(w, fk.table);
        try w.writeAll(", .fk_column = ");
        try emitStr(w, fk.column);
        try w.writeAll(", .on_delete = ");
        try emitStr(w, @tagName(fk.on_delete));
        try w.writeAll(", .on_update = ");
        try emitStr(w, @tagName(fk.on_update));
    } else {
        try w.writeAll(", .fk_table = \"\", .fk_column = \"\", .on_delete = \"\", .on_update = \"\"");
    }
    try w.writeAll(" },\n");
}

fn emitQuery(w: *std.Io.Writer, comptime R: type, doc_index: *const docindex.DocIndex) !void {
    var summary: []const u8 = "";
    var description: []const u8 = "";
    // The index is keyed by the original fn name, not the (renamable) id.
    if (doc_index.declDoc(R.meta.raw)) |doc| {
        summary = firstSentence(doc);
        description = if (doc.len > summary.len) doc else "";
    }

    try w.writeAll("        .{ .id = ");
    try emitStr(w, R.id);
    try w.writeAll(", .summary = ");
    try emitStr(w, summary);
    try w.writeAll(", .description = ");
    try emitStr(w, description);
    try w.writeAll(", .params = &.{");
    inline for (std.meta.fields(R.CallContext), 0..) |f, i| {
        // Call-context elements are positional tuple fields: the form field
        // name is synthesized, only the type is real.
        try w.print(" .{{ .field = \"arg{d}\", .type_name = ", .{i});
        try emitStr(w, @typeName(f.type));
        try w.writeAll(" },");
    }
    try w.writeAll(" }, .result = ");
    try emitStr(w, @typeName(R.Result));
    try w.writeAll(" },\n");
}

/// The first sentence of a doc comment: up to the first sentence-ending period
/// (or the first line break), trimmed. Used as the short `summary`.
fn firstSentence(text: []const u8) []const u8 {
    var end = text.len;
    if (std.mem.indexOfScalar(u8, text, '\n')) |nl| end = nl;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (text[i] == '.') {
            const after = i + 1;
            if (after >= end or text[after] == ' ') {
                end = after;
                break;
            }
        }
    }
    return std.mem.trimRight(u8, text[0..end], " \t");
}

/// Write `s` as a Zig string literal (with surrounding quotes), escaping the
/// bytes that would break out of the literal.
fn emitStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try std.zig.stringEscape(s, w);
    try w.writeByte('"');
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

test "firstSentence stops at the first period" {
    try std.testing.expectEqualStrings(
        "Records a visit.",
        firstSentence("Records a visit. More detail follows."),
    );
}
