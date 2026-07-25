// This file is part of the kwatcher project.
//
// Copyright (C) 2025-2026 Borislav Atanasov
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, version 3 of the License only.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.

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

fn actionSql(a: ir.FkAction) []const u8 {
    return switch (a) {
        .no_action => "NO ACTION",
        .restrict => "RESTRICT",
        .set_null => "SET NULL",
        .set_default => "SET DEFAULT",
        .cascade => "CASCADE",
    };
}

pub fn renderColumn(comptime col: ir.ColumnIr) []const u8 {
    comptime var res: []const u8 = col.name ++ " " ++ affinitySql(col.affinity);
    if (col.pk) res = res ++ " PRIMARY KEY";
    if (col.unique) res = res ++ " UNIQUE";
    if (col.fk) |fk| {
        res = res ++ " REFERENCES " ++ fk.table ++ "(" ++ fk.column ++ ")";
        if (fk.on_delete != .no_action) res = res ++ " ON DELETE " ++ actionSql(fk.on_delete);
        if (fk.on_update != .no_action) res = res ++ " ON UPDATE " ++ actionSql(fk.on_update);
    }
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
