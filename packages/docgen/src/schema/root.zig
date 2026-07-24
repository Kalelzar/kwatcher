//! `kw-docschema` — the protocol-agnostic JSON-Schema kernel shared by every docgen
//! backend. It owns the neutral schema model nodes and the Zig-type → schema
//! reflection. OpenAPI (HTTP) and AsyncAPI (AMQP/MQTT/…) both build on these, so
//! they live in the framework package rather than in any single backend.
const std = @import("std");

const schema = @import("schema.zig");

pub const Schema = schema.Schema;
pub const SchemaKind = schema.SchemaKind;
pub const Property = schema.Property;
pub const Components = schema.Components;
pub const SecurityScheme = schema.SecurityScheme;

/// Zig-type → `Schema` reflection (`schemaFor`, `Ctx`, `contentTypeOf`, …).
pub const reflect = @import("reflect.zig");

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

test {
    _ = schema;
    _ = reflect;
}
