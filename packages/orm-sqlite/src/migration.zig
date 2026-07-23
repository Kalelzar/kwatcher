//! Migration differ: IR x IR -> ops -> up/down SQL.
//!
//! Everything here is comptime: schemas are diffed at build time and the
//! rendered SQL is embedded in the executable. sqlite's ALTER TABLE is
//! tiny: ADD COLUMN (no PK, NOT NULL needs a default, no NOT NULL FK) and
//! DROP COLUMN (not PK, not FK-constrained). Everything else goes through
//! the rebuild recipe (shadow table, copy, drop, rename). The runner is
//! expected to wrap a migration in a transaction and, around rebuilds,
//! PRAGMA foreign_keys=OFF.

const std = @import("std");
const ir = @import("ir.zig");
const generator = @import("generator.zig");

pub const MigrationOp = union(enum) {
    create_table: ir.TableIr,
    drop_table: ir.TableIr, // full IR so down can recreate the shape
    add_column: struct { table: []const u8, column: ir.ColumnIr },
    drop_column: struct { table: []const u8, column: ir.ColumnIr },
    rebuild: struct { old: ir.TableIr, new: ir.TableIr },
};

pub const Direction = enum { up, down };

fn findTable(comptime s: ir.Schema, comptime name: []const u8) ?ir.TableIr {
    for (s.tables) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn findColumn(comptime t: ir.TableIr, comptime name: []const u8) ?ir.ColumnIr {
    for (t.columns) |col| {
        if (std.mem.eql(u8, col.name, name)) return col;
    }
    return null;
}

fn fkEql(comptime a: ?ir.FkIr, comptime b: ?ir.FkIr) bool {
    const av = a orelse return b == null;
    const bv = b orelse return false;
    return std.mem.eql(u8, av.table, bv.table) and
        std.mem.eql(u8, av.column, bv.column) and
        av.on_delete == bv.on_delete and
        av.on_update == bv.on_update;
}

fn columnEql(comptime a: ir.ColumnIr, comptime b: ir.ColumnIr) bool {
    return std.mem.eql(u8, a.name, b.name) and
        a.affinity == b.affinity and
        a.nullable == b.nullable and
        a.pk == b.pk and
        a.unique == b.unique and
        fkEql(a.fk, b.fk);
}

/// Cheap ALTERs only work on plain data columns; PK, FK and UNIQUE columns
/// always force a rebuild (ADD COLUMN can't carry PRIMARY KEY/UNIQUE, DROP
/// COLUMN can't remove constrained columns).
fn alterable(comptime col: ir.ColumnIr) bool {
    return !col.pk and col.fk == null and !col.unique;
}

/// Backfill value for a NOT NULL column that has no source data.
fn zeroDefault(comptime a: ir.Affinity) []const u8 {
    return switch (a) {
        .integer => "0",
        .real => "0.0",
        .text => "''",
    };
}

/// Column order is ignored: our SQL always names columns explicitly.
/// Renames are undecidable from a diff and come out as drop+add (lossy);
/// an explicit annotation can upgrade that later.
pub fn diff(comptime old: ir.Schema, comptime new: ir.Schema) []const MigrationOp {
    // The nested table/column scans multiply fast against a real snapshot;
    // the default 1000-branch quota only survives near-empty schemas.
    @setEvalBranchQuota(100_000);
    comptime var ops: []const MigrationOp = &.{};

    for (new.tables) |nt| {
        const ot = findTable(old, nt.name) orelse {
            ops = ops ++ &[_]MigrationOp{.{ .create_table = nt }};
            continue;
        };
        comptime var needs_rebuild = false;
        for (nt.columns) |nc| {
            if (findColumn(ot, nc.name)) |oc| {
                if (!columnEql(oc, nc)) needs_rebuild = true;
            } else if (!alterable(nc)) {
                needs_rebuild = true;
            }
        }
        for (ot.columns) |oc| {
            if (findColumn(nt, oc.name) == null and !alterable(oc)) needs_rebuild = true;
        }
        if (needs_rebuild) {
            ops = ops ++ &[_]MigrationOp{.{ .rebuild = .{ .old = ot, .new = nt } }};
            continue;
        }
        for (nt.columns) |nc| {
            if (findColumn(ot, nc.name) == null) {
                ops = ops ++ &[_]MigrationOp{.{ .add_column = .{ .table = nt.name, .column = nc } }};
            }
        }
        for (ot.columns) |oc| {
            if (findColumn(nt, oc.name) == null) {
                ops = ops ++ &[_]MigrationOp{.{ .drop_column = .{ .table = nt.name, .column = oc } }};
            }
        }
    }
    for (old.tables) |ot| {
        if (findTable(new, ot.name) == null) {
            ops = ops ++ &[_]MigrationOp{.{ .drop_table = ot }};
        }
    }
    return ops;
}

fn renderAddColumn(comptime table: []const u8, comptime col: ir.ColumnIr) []const u8 {
    comptime var res: []const u8 = "ALTER TABLE " ++ table ++ " ADD COLUMN " ++ generator.renderColumn(col);
    // sqlite backfills existing rows from the default; NOT NULL without
    // one is rejected outright.
    if (!col.nullable) res = res ++ " DEFAULT " ++ zeroDefault(col.affinity);
    return res ++ ";\n";
}

/// The general table-change recipe: shadow table in the target shape, copy
/// the column intersection over, swap. Columns missing a source get NULL
/// (nullable) or a zero default; NOT NULL targets fed from nullable sources
/// go through COALESCE so the copy can't violate the constraint.
fn renderRebuild(comptime from: ir.TableIr, comptime to: ir.TableIr) []const u8 {
    comptime var res: []const u8 = "CREATE TABLE _mig_" ++ to.name ++ "(";
    for (to.columns, 0..) |col, i| {
        if (i != 0) res = res ++ ",";
        res = res ++ generator.renderColumn(col);
    }
    res = res ++ ");\nINSERT INTO _mig_" ++ to.name ++ " (";
    for (to.columns, 0..) |col, i| {
        if (i != 0) res = res ++ ",";
        res = res ++ col.name;
    }
    res = res ++ ") SELECT ";
    for (to.columns, 0..) |col, i| {
        if (i != 0) res = res ++ ",";
        if (findColumn(from, col.name)) |src| {
            if (!col.nullable and src.nullable) {
                res = res ++ "COALESCE(" ++ col.name ++ "," ++ zeroDefault(col.affinity) ++ ")";
            } else {
                res = res ++ col.name;
            }
        } else if (col.nullable) {
            res = res ++ "NULL";
        } else {
            res = res ++ zeroDefault(col.affinity);
        }
    }
    res = res ++ " FROM " ++ from.name ++ ";\n";
    res = res ++ "DROP TABLE " ++ from.name ++ ";\n";
    res = res ++ "ALTER TABLE _mig_" ++ to.name ++ " RENAME TO " ++ to.name ++ ";\n";
    return res;
}

pub fn renderUp(comptime op: MigrationOp) []const u8 {
    return switch (op) {
        .create_table => |t| generator.renderTable(t) ++ ";\n",
        .drop_table => |t| "DROP TABLE " ++ t.name ++ ";\n",
        .add_column => |a| renderAddColumn(a.table, a.column),
        .drop_column => |d| "ALTER TABLE " ++ d.table ++ " DROP COLUMN " ++ d.column.name ++ ";\n",
        .rebuild => |r| renderRebuild(r.old, r.new),
    };
}

pub fn renderDown(comptime op: MigrationOp) []const u8 {
    return switch (op) {
        .create_table => |t| "DROP TABLE " ++ t.name ++ ";\n",
        .drop_table => |t| generator.renderTable(t) ++ ";\n",
        .add_column => |a| "ALTER TABLE " ++ a.table ++ " DROP COLUMN " ++ a.column.name ++ ";\n",
        .drop_column => |d| renderAddColumn(d.table, d.column),
        .rebuild => |r| renderRebuild(r.new, r.old),
    };
}

/// Down migrations run the inverse ops in reverse order.
pub fn renderMigration(comptime ops: []const MigrationOp, comptime direction: Direction) []const u8 {
    @setEvalBranchQuota(100_000);
    comptime var res: []const u8 = "";
    switch (direction) {
        .up => for (ops) |op| {
            res = res ++ renderUp(op);
        },
        .down => {
            var i = ops.len;
            while (i > 0) {
                i -= 1;
                res = res ++ renderDown(ops[i]);
            }
        },
    }
    return res;
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
