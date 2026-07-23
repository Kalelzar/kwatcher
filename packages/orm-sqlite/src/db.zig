const std = @import("std");
const zqlite = @import("zsqlite");

/// A connection to a sqlite database. Thin owner over `zqlite.Conn` that pins
/// down the couple of behaviours the ORM relies on: foreign keys enforced per
/// connection, and `u64` round-tripped by bit pattern (see `bindValue` /
/// `readColumn`).
pub const Db = struct {
    conn: zqlite.Conn,

    pub fn open(path: [:0]const u8) !Db {
        const flags = zqlite.OpenFlags.Create |
            zqlite.OpenFlags.ReadWrite |
            zqlite.OpenFlags.EXResCode;
        var conn = zqlite.open(path.ptr, flags) catch return error.OpenFailed;
        errdefer conn.close();
        // FKs are a per-connection opt-in in sqlite; without this the
        // REFERENCES clauses we generate are decorative.
        try conn.execNoArgs("PRAGMA foreign_keys = ON");
        return .{ .conn = conn };
    }

    pub fn close(self: *Db) void {
        self.conn.close();
    }

    /// One statement, no results expected (DDL, INSERT, PRAGMA).
    pub fn exec(self: *Db, sql_text: []const u8) !void {
        try self.conn.exec(sql_text, .{});
    }

    /// Multiple ';'-separated statements (rendered migrations).
    pub fn execAll(self: *Db, sql_text: []const u8) !void {
        var iter = std.mem.splitScalar(u8, sql_text, ';');
        while (iter.next()) |stmt| {
            const trimmed = std.mem.trim(u8, stmt, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            try self.exec(trimmed);
        }
    }

    /// First column of the first row as an integer (COUNT(*)-style checks).
    pub fn scalarInt(self: *Db, sql_text: []const u8) !i64 {
        var row = (try self.conn.row(sql_text, .{})) orelse return error.NoRows;
        defer row.deinit();
        return row.int(0);
    }
};

/// A lazily-prepared, kept-open statement. Query stages hold one of these and
/// step it row by row.
pub const Stmt = zqlite.Stmt;

/// Binds `value` at 0-based parameter `idx`. `u64` is bit-cast to `i64` so the
/// high bit round-trips through sqlite's signed integer storage (sqlite has no
/// unsigned type); everything else defers to zqlite's binder.
fn bindValue(stmt: Stmt, idx: usize, value: anytype) !void {
    const T = @TypeOf(value);
    switch (T) {
        u64 => try stmt.bindValue(@as(i64, @bitCast(value)), idx),
        else => switch (@typeInfo(T)) {
            .optional => if (value) |v| try bindValue(stmt, idx, v) else try stmt.bindValue(null, idx),
            else => try stmt.bindValue(value, idx),
        },
    }
}

/// Reads column `idx` as `T`. Text is duped with `allocator` (caller-owned);
/// `u64` is recovered from sqlite's signed integer by bit pattern.
fn readColumn(comptime T: type, stmt: Stmt, idx: usize, allocator: std.mem.Allocator) !T {
    return switch (T) {
        u64 => @as(u64, @bitCast(stmt.int(idx))),
        i64 => stmt.int(idx),
        i8, i16, i32, u8, u16, u32 => @intCast(stmt.int(idx)),
        bool => stmt.boolean(idx),
        f32 => @floatCast(stmt.float(idx)),
        f64 => stmt.float(idx),
        []const u8, []u8 => try allocator.dupe(u8, stmt.text(idx)),
        else => switch (@typeInfo(T)) {
            .optional => |o| blk: {
                if (stmt.columnType(idx) == .null) break :blk null;
                break :blk try readColumn(o.child, stmt, idx, allocator);
            },
            else => @compileError("Unsupported column type: " ++ @typeName(T)),
        },
    };
}

/// One-shot DML statement (INSERT/UPDATE/DELETE) with our binding
/// conventions (`u64` bit-cast, optionals -> NULL). Prepared, bound,
/// stepped once, finalized.
pub fn execDml(db: *Db, sql_text: []const u8, args: anytype) !void {
    var stmt = db.conn.prepare(sql_text) catch return error.PrepareFailed;
    defer stmt.deinit();
    inline for (args, 0..) |arg, i| try bindValue(stmt, i, arg);
    _ = try stmt.step();
}

/// Shared body of every stage's next(): lazily prepare + bind on first call,
/// then step and materialize one Row (text duped with `allocator`,
/// caller-owned).
pub fn execNext(
    comptime RowT: type,
    sql_text: []const u8,
    stmt_slot: *?Stmt,
    args: anytype,
    db: *Db,
    allocator: std.mem.Allocator,
) !?RowT {
    if (stmt_slot.* == null) {
        var stmt = db.conn.prepare(sql_text) catch return error.PrepareFailed;
        errdefer stmt.deinit();
        inline for (args, 0..) |a, i| try bindValue(stmt, i, a);
        stmt_slot.* = stmt;
    }
    const stmt = stmt_slot.*.?;
    if (try stmt.step()) {
        var row: RowT = undefined;
        inline for (std.meta.fields(RowT), 0..) |f, i| {
            @field(row, f.name) = try readColumn(f.type, stmt, i, allocator);
        }
        return row;
    }
    return null;
}
