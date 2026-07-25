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
const docindex = @import("kw-docindex");
const model = @import("schema.zig");

/// Shared state for a single document build: the arena schemas are allocated from,
/// the component registry named structs are deduplicated into, and an optional
/// doc-comment index consulted for type/field descriptions.
pub const Ctx = struct {
    allocator: std.mem.Allocator,
    components: *model.Components,
    doc_index: ?*const docindex.DocIndex = null,
};

/// The content type a payload type explicitly declares via `pub const ContentType`,
/// or `null` if it doesn't. The `Json` helper declares one; most types don't.
pub fn declaredContentType(comptime T: type) ?[]const u8 {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            if (@hasDecl(T, "ContentType")) return T.ContentType;
        },
        else => {},
    }
    return null;
}

/// The content type a payload type advertises, or the framework default.
///
/// A result/body type may declare `pub const ContentType: []const u8` to override
/// it (the `Json` helper does). Everything else defaults to `application/json`,
/// which is the HTTP framework's default behavior.
pub fn contentTypeOf(comptime T: type) []const u8 {
    return declaredContentType(T) orelse "application/json";
}

/// Map a Zig type to a neutral `model.Schema`.
///
/// Named structs are registered once in `ctx.components` and returned as a `$ref`;
/// anonymous/inline structs are inlined. Recursion is guarded by inserting a
/// placeholder before descending into a named struct's fields.
pub fn schemaFor(comptime T: type, ctx: *Ctx) std.mem.Allocator.Error!model.Schema {
    switch (@typeInfo(T)) {
        .bool => return .{ .kind = .boolean },

        .int => |info| return .{
            .kind = .integer,
            .format = if (info.bits > 32) "int64" else "int32",
            .minimum = if (info.signedness == .unsigned) 0 else null,
        },
        .comptime_int => return .{ .kind = .integer },

        .float => |info| return .{
            .kind = .number,
            .format = if (info.bits > 32) "double" else "float",
        },
        .comptime_float => return .{ .kind = .number },

        .optional => |info| {
            var inner = try schemaFor(info.child, ctx);
            inner.nullable = true;
            return inner;
        },

        .@"enum" => |info| {
            const values = comptime blk: {
                var v: [info.fields.len][]const u8 = undefined;
                for (info.fields, 0..) |f, i| v[i] = f.name;
                const frozen = v;
                break :blk &frozen;
            };
            return .{ .kind = .@"enum", .enum_values = values };
        },

        .error_set => return .{ .kind = .string },

        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child == u8) return .{ .kind = .string };
                const items = try ctx.allocator.create(model.Schema);
                items.* = try schemaFor(info.child, ctx);
                return .{ .kind = .array, .items = items };
            },
            // A single-item pointer is transparent for documentation purposes.
            .one => return try schemaFor(info.child, ctx),
            else => return .{ .kind = .empty },
        },

        .array => |info| {
            if (info.child == u8) return .{ .kind = .string };
            const items = try ctx.allocator.create(model.Schema);
            items.* = try schemaFor(info.child, ctx);
            return .{ .kind = .array, .items = items, .max_items = info.len };
        },

        .@"struct" => return try structSchema(T, ctx),

        .@"union" => |info| {
            const variants = try ctx.allocator.alloc(model.Schema, info.fields.len);
            inline for (info.fields, 0..) |f, i| {
                variants[i] = try schemaFor(f.type, ctx);
            }
            return .{ .kind = .one_of, .one_of = variants };
        },

        .void => return .{ .kind = .empty },

        // anyerror, anyopaque, and anything else we can't describe.
        else => return .{ .kind = .empty },
    }
}

fn structSchema(comptime T: type, ctx: *Ctx) std.mem.Allocator.Error!model.Schema {
    if (componentNameFor(T, ctx)) |name| {
        const ref = try std.fmt.allocPrint(ctx.allocator, "#/components/schemas/{s}", .{name});
        // Already registered (or registering) — just reference it.
        if (ctx.components.schemas.contains(name)) return .{ .kind = .ref, .ref = ref };
        // Reserve the slot before recursing so self-referential types terminate.
        try ctx.components.schemas.put(ctx.allocator, name, .{ .kind = .object });
        const built = try objectSchema(T, ctx);
        try ctx.components.schemas.put(ctx.allocator, name, built);
        return .{ .kind = .ref, .ref = ref };
    }

    // Anonymous/inline struct: emit the object schema directly.
    return try objectSchema(T, ctx);
}

/// The component name for a struct, or null when it should be inlined.
///
/// A concrete `schema.Schema(ver, name, …)` is named after its `(name, version)` —
/// `"client"`/2 → `Client.V2`, `"afk.status-change"`/1 → `Afk.StatusChange.V1`. We only
/// do this for schemas the doc index actually collected (a `const = Schema(...)` decl);
/// a *generic* schema like `Heartbeat.V1(Props)` shares one `(name, version)` across
/// distinct `Props`, so it is left inline to avoid a component collision. Everything else
/// (HTTP/OpenAPI bare types) keeps the comptime `@typeName`-derived name.
fn componentNameFor(comptime T: type, ctx: *Ctx) ?[]const u8 {
    if (comptime schemaIdentity(T)) |id| {
        if (ctx.doc_index) |idx| {
            if (idx.hasSchema(id.name, id.version)) return comptime schemaComponentName(id);
        }
    }
    return comptime componentName(T);
}

fn objectSchema(comptime T: type, ctx: *Ctx) std.mem.Allocator.Error!model.Schema {
    const info = @typeInfo(T).@"struct";
    // A `schema.Schema(ver, name, …)` carries its `(name, version)` as comptime field
    // defaults — a stable identity both reflection and the doc index see, immune to the
    // `@typeName` ambiguity that defeats merged/anonymous types. Prefer it; otherwise
    // fall back to the bare-decl-name + field-set heuristic (the `@typeName` last
    // component, generated/absent for anonymous structs). See docKey.
    const id = comptime schemaIdentity(T);
    const name = comptime docKey(@typeName(T));
    const names = comptime fieldNames(T);

    const props = try ctx.allocator.alloc(model.Property, info.fields.len);
    inline for (info.fields, 0..) |f, i| {
        props[i] = .{
            .name = f.name,
            .schema = try schemaFor(f.type, ctx),
            .description = fieldDescription(ctx.doc_index, id, name, f.name, names),
        };
    }

    comptime var required_count = 0;
    inline for (info.fields) |f| {
        if (comptime isRequired(f)) required_count += 1;
    }
    const required = try ctx.allocator.alloc([]const u8, required_count);
    var ri: usize = 0;
    inline for (info.fields) |f| {
        if (comptime isRequired(f)) {
            required[ri] = f.name;
            ri += 1;
        }
    }

    return .{
        .kind = .object,
        .properties = props,
        .required = required,
        .description = typeDescription(ctx.doc_index, id, name, names),
    };
}

/// A `schema.Schema(...)` envelope's identity: the comptime defaults of its
/// `schema_name`/`schema_version` fields. Null for any other struct, so non-schema
/// types keep using the bare-name lookup.
const SchemaIdentity = struct { name: []const u8, version: u32 };

fn schemaIdentity(comptime T: type) ?SchemaIdentity {
    const info = @typeInfo(T);
    if (info != .@"struct") return null;
    comptime var name: ?[]const u8 = null;
    comptime var version: ?u32 = null;
    inline for (info.@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "schema_name") and f.type == []const u8) {
            if (f.default_value_ptr) |p| name = @as(*const []const u8, @ptrCast(@alignCast(p))).*;
        }
        if (comptime std.mem.eql(u8, f.name, "schema_version") and f.type == u32) {
            if (f.default_value_ptr) |p| version = @as(*const u32, @ptrCast(@alignCast(p))).*;
        }
    }
    if (name) |n| if (version) |v| return .{ .name = n, .version = v };
    return null;
}

/// The component name for a schema identity: each `.`-segment of the wire name is
/// PascalCased (splitting on `-`/`_` too), then `.V<version>` is appended.
/// `client.announce`/1 → `Client.Announce.V1`; `afk`/1 → `Afk.V1`.
fn schemaComponentName(comptime id: SchemaIdentity) []const u8 {
    comptime {
        var out: []const u8 = "";
        var it = std.mem.splitScalar(u8, id.name, '.');
        var first = true;
        while (it.next()) |seg| {
            if (!first) out = out ++ ".";
            out = out ++ pascalWord(seg);
            first = false;
        }
        return out ++ std.fmt.comptimePrint(".V{d}", .{id.version});
    }
}

/// `status-change` → `StatusChange`: uppercase each word, dropping `-`/`_`/space.
fn pascalWord(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var upper = true;
        for (s) |c| {
            if (c == '-' or c == '_' or c == ' ') {
                upper = true;
                continue;
            }
            out = out ++ &[_]u8{if (upper) std.ascii.toUpper(c) else c};
            upper = false;
        }
        return out;
    }
}

/// A schema's type doc: by `(name, version)` when it is a `Schema(...)` envelope, else
/// by bare decl name + field set.
fn typeDescription(idx: ?*const docindex.DocIndex, comptime id: ?SchemaIdentity, comptime name: []const u8, comptime names: []const []const u8) ?[]const u8 {
    const i = idx orelse return null;
    if (comptime id) |x| return i.schemaDoc(x.name, x.version);
    return i.typeDoc(name, names);
}

/// A field's doc, resolved the same way as `typeDescription`.
fn fieldDescription(idx: ?*const docindex.DocIndex, comptime id: ?SchemaIdentity, comptime name: []const u8, comptime field: []const u8, comptime names: []const []const u8) ?[]const u8 {
    const i = idx orelse return null;
    if (comptime id) |x| return i.schemaFieldDoc(x.name, x.version, field);
    return i.fieldDoc(name, field, names);
}

/// The bare declaration name — the last dot-component of a `@typeName`, which is how
/// the doc index keys types. `http.response.ProblemDetails` → `ProblemDetails`.
///
/// NOTE: this is heuristic. Mapping a reflected type to its source documentation by
/// name (disambiguated by field set) can mis-resolve when two distinct types share a
/// name and field shape. Doing it exactly needs import-graph name resolution (find
/// the actual decl each route handler/param/return points at) rather than reflection
/// + name matching — a worthwhile but much larger change.
fn docKey(comptime fqn: []const u8) []const u8 {
    return comptime lastSegment(fqn);
}

/// The reflected struct's field names, as a comptime slice — used to disambiguate
/// doc-index entries that collide on file-stem.
fn fieldNames(comptime T: type) []const []const u8 {
    const fields = @typeInfo(T).@"struct".fields;
    comptime var names: [fields.len][]const u8 = undefined;
    inline for (fields, 0..) |f, i| names[i] = f.name;
    const frozen = names;
    return &frozen;
}

/// A field is required when it has no default value and is not itself optional.
fn isRequired(comptime f: std.builtin.Type.StructField) bool {
    if (f.default_value_ptr != null) return false;
    return @typeInfo(f.type) != .optional;
}

/// Returns a sanitized component name for a struct that should be registered as a
/// reusable component, or `null` when the struct is anonymous/inline and should be
/// emitted in place.
fn componentName(comptime T: type) ?[]const u8 {
    const seg = comptime lastSegment(@typeName(T));
    const anon_markers = [_][]const u8{ "__struct_", "__union_", "__enum_", "__anon", "__opaque_" };
    inline for (anon_markers) |m| {
        if (comptime std.mem.indexOf(u8, seg, m) != null) return null;
    }
    return comptime sanitize(seg);
}

/// The bare declaration identifier inside a `@typeName`: the final dot-component with
/// any trailing generic-instantiation punctuation removed. A generic type's name ends
/// in the closing tokens of the call — `MergeStructs(..,pkg.ClientHeartbeat)` yields
/// the segment `ClientHeartbeat)`, which trims to `ClientHeartbeat`. Keeping this in
/// one place means the component key (`componentName`) and the doc-lookup key
/// (`docKey`) agree, so a documented type still matches its index entry.
fn lastSegment(comptime full: []const u8) []const u8 {
    const idx = comptime std.mem.lastIndexOfScalar(u8, full, '.');
    const seg = if (idx) |i| full[i + 1 ..] else full;
    return comptime std.mem.trimRight(u8, seg, ")] ");
}

/// Replace any character outside the OpenAPI component-key set with '_'.
fn sanitize(comptime s: []const u8) []const u8 {
    comptime {
        var out: [s.len]u8 = undefined;
        for (s, 0..) |c, i| {
            out[i] = switch (c) {
                'A'...'Z', 'a'...'z', '0'...'9', '.', '-', '_' => c,
                else => '_',
            };
        }
        const frozen = out;
        return &frozen;
    }
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

test "primitives map to expected kinds" {
    var components: model.Components = .{};
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .components = &components };
    defer components.schemas.deinit(std.testing.allocator);

    try std.testing.expectEqual(model.SchemaKind.boolean, (try schemaFor(bool, &ctx)).kind);
    try std.testing.expectEqual(model.SchemaKind.string, (try schemaFor([]const u8, &ctx)).kind);
    try std.testing.expectEqual(model.SchemaKind.integer, (try schemaFor(u64, &ctx)).kind);
    try std.testing.expectEqualStrings("int64", (try schemaFor(u64, &ctx)).format.?);
    try std.testing.expectEqual(@as(?i64, 0), (try schemaFor(u32, &ctx)).minimum);
    try std.testing.expectEqual(model.SchemaKind.number, (try schemaFor(f64, &ctx)).kind);

    const opt = try schemaFor(?u8, &ctx);
    try std.testing.expect(opt.nullable);
    try std.testing.expectEqual(model.SchemaKind.integer, opt.kind);
}

test "named struct registers a component and returns a ref" {
    const User = struct { id: u64, nickname: ?[]const u8 = null };
    var components: model.Components = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: Ctx = .{ .allocator = arena.allocator(), .components = &components };
    defer components.schemas.deinit(arena.allocator());

    const s = try schemaFor(User, &ctx);
    try std.testing.expectEqual(model.SchemaKind.ref, s.kind);
    try std.testing.expect(components.schemas.count() == 1);

    const registered = components.schemas.values()[0];
    try std.testing.expectEqual(model.SchemaKind.object, registered.kind);
    try std.testing.expectEqual(@as(usize, 2), registered.properties.len);
    // `id` is required, `nickname` (optional w/ default) is not.
    try std.testing.expectEqual(@as(usize, 1), registered.required.len);
    try std.testing.expectEqualStrings("id", registered.required[0]);
}

test "anonymous struct is inlined" {
    var components: model.Components = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: Ctx = .{ .allocator = arena.allocator(), .components = &components };
    defer components.schemas.deinit(arena.allocator());

    const s = try schemaFor(struct { name: []const u8 }, &ctx);
    try std.testing.expectEqual(model.SchemaKind.object, s.kind);
    try std.testing.expectEqual(@as(usize, 0), components.schemas.count());
}

test "schema and field descriptions come from the doc index" {
    const HeartbeatMessage = struct { timestamp: u64, count: u64 };

    // Populate the index directly under this type's exact `@typeName`, sidestepping
    // file-stem FQN matching (a test-local struct has no real source file).
    var index: docindex.DocIndex = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer index.deinit();
    const ia = index.arena.allocator();
    var entries: std.ArrayListUnmanaged(docindex.TypeEntry) = .empty;
    try entries.append(ia, .{
        .doc = "A heartbeat payload.",
        .field_names = &.{ "timestamp", "count" },
        .field_docs = &.{.{ .name = "timestamp", .doc = "Unix timestamp in seconds." }},
    });
    try index.types.put(ia, comptime docKey(@typeName(HeartbeatMessage)), entries);

    var components: model.Components = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: Ctx = .{ .allocator = arena.allocator(), .components = &components, .doc_index = &index };
    defer components.schemas.deinit(arena.allocator());

    _ = try schemaFor(HeartbeatMessage, &ctx);
    const registered = components.schemas.get("HeartbeatMessage").?;
    try std.testing.expectEqualStrings("A heartbeat payload.", registered.description.?);
    // `timestamp` is documented; `count` is not.
    for (registered.properties) |p| {
        if (std.mem.eql(u8, p.name, "timestamp")) {
            try std.testing.expectEqualStrings("Unix timestamp in seconds.", p.description.?);
        } else {
            try std.testing.expect(p.description == null);
        }
    }
}

test "ContentType decl overrides default" {
    const Custom = struct {
        pub const ContentType = "application/problem+json";
        x: u8,
    };
    try std.testing.expectEqualStrings("application/problem+json", contentTypeOf(Custom));
    try std.testing.expectEqualStrings("application/json", contentTypeOf(struct { x: u8 }));
}
