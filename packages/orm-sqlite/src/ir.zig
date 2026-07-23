const std = @import("std");
const model = @import("model.zig");

// Plain serializable data: no types, no comptime-only constructs. The
// reflection walk (types -> IR) lives below it; SQL rendering (generator.zig)
// and the future migration differ are pure functions over this.

pub const Affinity = enum { integer, real, text };

/// sqlite's referential actions (clauses of the REFERENCES constraint).
pub const FkAction = enum { no_action, restrict, set_null, set_default, cascade };

pub const FkIr = struct {
    table: []const u8,
    column: []const u8,
    on_delete: FkAction = .no_action,
    on_update: FkAction = .no_action,
};

pub const ColumnIr = struct {
    name: []const u8,
    affinity: Affinity,
    nullable: bool = false,
    pk: bool = false,
    unique: bool = false,
    fk: ?FkIr = null,
};

pub const TableIr = struct {
    name: []const u8,
    columns: []const ColumnIr,
};

pub const Schema = struct {
    /// IR format version, not schema version.
    version: u32 = 1,
    tables: []const TableIr,
};

// ==== Reflection: types -> IR ======================================

pub fn affinityOf(comptime T: type) Affinity {
    return switch (T) {
        []const u8, []u8 => .text,
        i8, i16, i32, i64, u8, u16, u32, u64 => .integer,
        f32, f64 => .real,
        bool => .integer,
        else => @compileError("Unsupported column type: " ++ @typeName(T)),
    };
}

/// Checks the FK's stored type against its target's PK and returns its IR.
/// Only safe at schema-gen time (resolves Target's fields).
fn fkIr(comptime F: type) FkIr {
    const Target = F.Target;
    const pk_name = model.PrimaryOf(Target);
    const PkValue = @FieldType(@FieldType(@FieldType(Target, "data"), pk_name), "value");
    if (@FieldType(F, "value") != PkValue) {
        @compileError(std.fmt.comptimePrint(
            "Foreign key type mismatch: expected '{s}' to match table '{s}''s primary key type '{s}'",
            .{ @typeName(@FieldType(F, "value")), @tagName(Target.name), @typeName(PkValue) },
        ));
    }
    return .{
        .table = @tagName(Target.name),
        .column = pk_name,
        .on_delete = model.fkActionOf(F, .on_delete) orelse .no_action,
        .on_update = model.fkActionOf(F, .on_update) orelse .no_action,
    };
}

/// Column IR before nullability is applied, or null when the field is a pure
/// relation (reverse side of a one-to-many) and has no column of its own.
/// `Owner` is the table the field belongs to.
fn baseColumnIr(comptime fname: []const u8, comptime T: type, comptime Owner: type) ?ColumnIr {
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (model.markerKind(T)) |k| {
                const aff = affinityOf(@FieldType(T, "value"));
                const uniq = model.hasProperty(T, .unique);
                return switch (k) {
                    .table => @compileError("You can't embed another table directly. Use a FK instead."),
                    .foreign_key => .{ .name = fname, .affinity = aff, .fk = fkIr(T), .unique = uniq },
                    .primary_key => .{ .name = fname, .affinity = aff, .pk = true, .unique = uniq },
                    .wrapper => .{ .name = fname, .affinity = aff, .unique = uniq },
                };
            }
            return .{ .name = fname, .affinity = affinityOf(T) };
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("Cannot store pointers in a table.");
            if (p.child == u8) return .{ .name = fname, .affinity = .text };
            if (model.markerKind(p.child)) |m| {
                switch (m) {
                    .primary_key, .table, .wrapper => @compileError("Nonsensical structure: slice of " ++ @typeName(p.child)),
                    .foreign_key => {
                        _ = fkIr(p.child); // the FK itself must still be coherent
                        const Inverse = model.FKFor(p.child.Target, Owner) orelse
                            @compileError("Many-to-One and Many-to-Many relationships require that both tables have a proper foreign key");
                        if (comptime model.isSingularFk(Inverse)) {
                            // Reverse side of a one-to-many: the child table
                            // holds the column, nothing to emit here.
                            return null;
                        }
                        // TODO(later): both sides are slices -> junction table.
                        @compileError("Many-to-many relationships need a junction table (not implemented yet).");
                    },
                }
            }
            return baseColumnIr(fname, p.child, Owner);
        },
        .int, .float, .bool => return .{ .name = fname, .affinity = affinityOf(T) },
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    }
}

fn columnIr(comptime fname: []const u8, comptime T: type, comptime Owner: type) ?ColumnIr {
    const ti = @typeInfo(T);
    if (ti == .optional) {
        const Child = ti.optional.child;
        if (comptime model.isMarker(Child, .primary_key)) {
            @compileError("A primary key cannot be optional.");
        }
        comptime var col = baseColumnIr(fname, Child, Owner) orelse return null;
        col.nullable = true;
        return col;
    }
    return baseColumnIr(fname, T, Owner);
}

pub fn TableIrOf(comptime Tbl: type) TableIr {
    model.assertTable(Tbl);

    const fields = std.meta.fields(@FieldType(Tbl, "data"));
    if (comptime fields.len == 0) {
        @compileError("Table '" ++ @tagName(Tbl.name) ++ "' has no columns.");
    }

    comptime var cols: []const ColumnIr = &.{};
    inline for (fields) |f| {
        // Relation-only fields (reverse side of a one-to-many) have no column.
        if (comptime columnIr(f.name, f.type, Tbl)) |col| {
            cols = cols ++ &[_]ColumnIr{col};
        }
    }
    if (comptime cols.len == 0) {
        @compileError("Table '" ++ @tagName(Tbl.name) ++ "' has no columns.");
    }
    return .{ .name = @tagName(Tbl.name), .columns = cols };
}

pub fn SchemaIr(comptime tables: anytype) Schema {
    comptime var tbls: []const TableIr = &.{};
    inline for (tables) |T| {
        tbls = tbls ++ &[_]TableIr{TableIrOf(T)};
    }
    return .{ .tables = tbls };
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
