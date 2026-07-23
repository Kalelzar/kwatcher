const std = @import("std");
const ir = @import("ir.zig");

// Rendering: IR -> DDL. Pure functions over IR data; no type information.
// The migration differ will reuse these to render rebuilt tables.

fn affinitySql(comptime a: ir.Affinity) []const u8 {
    return switch (a) {
        .integer => "INTEGER",
        .real => "REAL",
        .text => "TEXT",
    };
}

pub fn renderColumn(comptime col: ir.ColumnIr) []const u8 {
    comptime var res: []const u8 = col.name ++ " " ++ affinitySql(col.affinity);
    if (col.pk) res = res ++ " PRIMARY KEY";
    if (col.unique) res = res ++ " UNIQUE";
    if (col.fk) |fk| res = res ++ " REFERENCES " ++ fk.table ++ "(" ++ fk.column ++ ")";
    if (!col.nullable) res = res ++ " NOT NULL";
    return res;
}

pub fn renderTable(comptime t: ir.TableIr) []const u8 {
    comptime var res: []const u8 = "CREATE TABLE IF NOT EXISTS " ++ t.name ++ "(";
    for (t.columns, 0..) |col, i| {
        if (i != 0) res = res ++ ",";
        res = res ++ renderColumn(col);
    }
    return res ++ ")";
}

pub fn TableGen(comptime Tbl: type) []const u8 {
    return comptime renderTable(ir.TableIrOf(Tbl));
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
