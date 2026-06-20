const std = @import("std");

/// Protocol-agnostic JSON-Schema model nodes shared by every docgen backend.
///
/// Both OpenAPI (HTTP) and AsyncAPI (AMQP/MQTT/…) describe payloads with JSON
/// Schema, so these nodes — and the reflection in `reflect.zig` that produces
/// them — live here, in the framework package, rather than in any single backend.
///
/// Each emitter reads only the fields relevant to a node's `kind` and decides how
/// to project them (e.g. how `nullable` is represented). Nothing here is specific
/// to a spec version or a wire protocol.
pub const Components = struct {
    /// Component name -> schema, referenced as `#/components/schemas/<name>`.
    schemas: std.StringArrayHashMapUnmanaged(Schema) = .empty,
};

pub const Property = struct {
    name: []const u8,
    schema: Schema,
    /// From the field's `///` doc comment, when available.
    description: ?[]const u8 = null,
};

pub const SchemaKind = enum {
    object,
    array,
    string,
    integer,
    number,
    boolean,
    @"enum",
    one_of,
    ref,
    /// No constraints at all (`{}`) — used as a fallback for types we can't describe.
    empty,
};

/// A neutral superset schema node. Emitters read only the fields relevant to the
/// active `kind`. `nullable` is stored neutrally; each emitter chooses how to
/// represent it (3.0's `nullable: true` vs 3.1+/3.2's `type: [..., "null"]`).
pub const Schema = struct {
    kind: SchemaKind,
    nullable: bool = false,

    /// From the type's `///` doc comment, when available (set for named types).
    description: ?[]const u8 = null,

    /// JSON Schema `format` hint (e.g. "int64", "double") when known.
    format: ?[]const u8 = null,

    // kind == .object
    properties: []const Property = &.{},
    required: []const []const u8 = &.{},

    // kind == .array
    items: ?*const Schema = null,
    max_items: ?u64 = null,

    // kind == .enum
    enum_values: []const []const u8 = &.{},

    // kind == .one_of
    one_of: []const Schema = &.{},

    // kind == .ref ("#/components/schemas/<ref>")
    ref: ?[]const u8 = null,

    // numeric bounds, when known
    minimum: ?i64 = null,
    maximum: ?i64 = null,
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
