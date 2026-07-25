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

// Column and table shape is expressed with marker structs (PK/FK/Table).
// A struct is one of ours only if it declares a `kind: Kind` decl, so a
// user struct that happens to name a field `kind` is never misread.

pub const Kind = enum {
    table,
    foreign_key,
    primary_key,
    wrapper,
};

/// The marker kind of `T`, or null when `T` is not one of our marker types.
/// The decl's type is checked against `Kind` so a user struct that happens
/// to declare its own `kind` is not misread as a marker.
pub fn markerKind(comptime T: type) ?Kind {
    if (@typeInfo(T) != .@"struct") return null;
    if (!@hasDecl(T, "kind")) return null;
    if (@TypeOf(T.kind) != Kind) return null;
    return T.kind;
}

pub fn isMarker(comptime T: type, comptime k: Kind) bool {
    return (markerKind(T) orelse return false) == k;
}

pub fn assertTable(comptime T: type) void {
    if (comptime !isMarker(T, .table)) {
        @compileError("Expected a table, got " ++ @typeName(T));
    }
}

/// Column properties markers accumulate as they compose. Markers flatten:
/// wrapping another marker grabs its underlying `value` type (no nesting)
/// and copies its properties forward, so `PK(Unique(u64))` and
/// `Unique(PK(u64))` are the same shape.
pub const FkAction = ir.FkAction;
pub const Prop = union(enum) {
    unique,
    on_delete: FkAction,
    on_update: FkAction,
};

/// The property list `T` forwards; empty for unmarked types.
pub fn forwardedProps(comptime T: type) []const Prop {
    if (@typeInfo(T) != .@"struct") return &.{};
    if (!@hasDecl(T, "properties")) return &.{};
    return T.properties;
}

pub fn hasProperty(comptime T: type, comptime p: Prop) bool {
    inline for (comptime forwardedProps(T)) |q| {
        if (std.meta.activeTag(q) == std.meta.activeTag(p)) return true;
    }
    return false;
}

pub const FkActionSlot = enum { on_delete, on_update };

/// The referential action `T`'s marker chain carries for `slot`, if any.
/// Conflicting duplicates are a bug in the schema, not a preference.
pub fn fkActionOf(comptime T: type, comptime slot: FkActionSlot) ?FkAction {
    comptime var found: ?FkAction = null;
    inline for (comptime forwardedProps(T)) |p| {
        const action: ?FkAction = switch (p) {
            .unique => null,
            .on_delete => |a| if (slot == .on_delete) a else null,
            .on_update => |a| if (slot == .on_update) a else null,
        };
        if (action) |a| {
            if (found != null) {
                @compileError("Conflicting " ++ @tagName(slot) ++ " actions in one marker chain.");
            }
            found = a;
        }
    }
    return found;
}

/// Rejects wrapping a marker whose kind already decides the column role:
/// key markers may only wrap property wrappers (Unique), not each other.
fn assertWrappable(comptime marker: []const u8, comptime T: type) void {
    if (markerKind(T)) |k| {
        if (k != .wrapper) {
            @compileError(marker ++ " may only wrap property markers (e.g. Unique), not a ." ++ @tagName(k) ++ " marker.");
        }
    }
}

pub fn PK(comptime T: type) type {
    const V = stripMarker(T);
    _ = ir.affinityOf(V); // reject types that can't back a column
    assertWrappable("PK", T);
    return struct {
        pub const kind: Kind = .primary_key;
        pub const properties = forwardedProps(T);
        value: V,
    };
}

pub fn FK(comptime Ref: type, comptime T: type) type {
    const V = stripMarker(T);
    _ = ir.affinityOf(V);
    assertWrappable("FK", T);
    // Target validation (is-a-table, PK type match) is deferred to fkIr at
    // schema-gen time: touching Ref's fields here would force eager resolution
    // and reintroduce the dependency cycle on mutual references.
    return struct {
        pub const kind: Kind = .foreign_key;
        pub const Target = Ref;
        pub const properties = forwardedProps(T);
        value: V,
    };
}

/// Shared flattening body for property wrappers: strip the operand to its
/// underlying value type, keep its kind (or become a plain `.wrapper`),
/// forward the FK target when present, and prepend `extra` to the
/// forwarded properties.
fn Wrapped(comptime T: type, comptime extra: []const Prop) type {
    const V = stripMarker(T);
    _ = ir.affinityOf(V);
    const props = extra ++ forwardedProps(T);

    if (comptime isMarker(T, .table)) {
        @compileError("Property wrappers wrap columns, not tables.");
    }
    if (comptime isMarker(T, .foreign_key)) {
        // Forward the FK's target so fkIr keeps working on the flattened
        // marker.
        return struct {
            pub const kind: Kind = .foreign_key;
            pub const Target = T.Target;
            pub const properties: []const Prop = props;
            value: V,
        };
    }
    return struct {
        pub const kind: Kind = if (markerKind(T)) |m| m else .wrapper;
        pub const properties: []const Prop = props;
        value: V,
    };
}

pub fn Unique(comptime T: type) type {
    return Wrapped(T, &.{.unique});
}

/// Referential actions only exist on REFERENCES constraints, so these
/// require the wrapped chain to already be a foreign key — which also
/// makes a misplaced action unrepresentable (PK/FK only admit `.wrapper`
/// operands, so an action can never sneak in from the inside).
fn assertFkChain(comptime what: []const u8, comptime T: type) void {
    if (comptime !isMarker(T, .foreign_key)) {
        @compileError(what ++ " requires a foreign-key column (referential actions only exist on REFERENCES constraints); got " ++ @typeName(T));
    }
}

pub fn OnDelete(comptime action: FkAction, comptime T: type) type {
    assertFkChain("OnDelete", T);
    return Wrapped(T, &.{.{ .on_delete = action }});
}

pub fn OnUpdate(comptime action: FkAction, comptime T: type) type {
    assertFkChain("OnUpdate", T);
    return Wrapped(T, &.{.{ .on_update = action }});
}

/// ON DELETE CASCADE — the colloquial "cascade". ON UPDATE stays at
/// sqlite's default; use OnUpdate explicitly for update propagation.
pub fn Cascade(comptime T: type) type {
    return OnDelete(.cascade, T);
}

pub fn Table(comptime table_name: @Type(.enum_literal), comptime T: type) type {
    return struct {
        pub const kind: Kind = .table;
        pub const name = table_name;
        data: T,
    };
}

pub fn PrimaryOf(comptime T: type) []const u8 {
    assertTable(T);
    inline for (std.meta.fields(@FieldType(T, "data"))) |f| {
        if (comptime isMarker(f.type, .primary_key)) return f.name;
    }
    @compileError("Table '" ++ @tagName(T.name) ++ "' has no primary key.");
}

// ==== Shape helpers ================================================
// Marker-aware type surgery shared by the IR reflection and the query
// builder.

/// Strips optional and (non-u8) slice wrappers off a field type.
pub fn Unwrap(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| Unwrap(o.child),
        .pointer => |p| if (p.size == .slice and p.child != u8) Unwrap(p.child) else T,
        else => T,
    };
}

/// True when `T` is a single FK column (possibly optional), as opposed to a
/// slice of FKs.
pub fn isSingularFk(comptime T: type) bool {
    const Bare = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
    return isMarker(Bare, .foreign_key);
}

/// The Zig value type behind a marker (PK/FK), or `T` itself when unmarked.
pub fn stripMarker(comptime T: type) type {
    if (markerKind(T) != null) return @FieldType(T, "value");
    return T;
}

/// The field type of `Target`'s FK back to `Owner`, or null when `Target` has
/// no such column. Only safe at schema-gen time (resolves Target's fields).
pub fn FKFor(comptime Target: type, comptime Owner: type) ?type {
    assertTable(Target);
    inline for (std.meta.fields(@FieldType(Target, "data"))) |f| {
        const Bare = Unwrap(f.type);
        if (comptime (isMarker(Bare, .foreign_key) and Bare.Target == Owner)) {
            return f.type;
        }
    }
    return null;
}

/// All of `Target`'s singular FK column names pointing at `Owner`.
/// Unlike FKFor this ignores slice FKs: only singular FKs can carry a join.
pub fn fkFieldNames(comptime Target: type, comptime Owner: type) []const []const u8 {
    comptime var res: []const []const u8 = &.{};
    inline for (std.meta.fields(@FieldType(Target, "data"))) |f| {
        if (comptime isSingularFk(f.type)) {
            const Bare = if (@typeInfo(f.type) == .optional) @typeInfo(f.type).optional.child else f.type;
            if (comptime Bare.Target == Owner) res = res ++ &[_][]const u8{f.name};
        }
    }
    return res;
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
