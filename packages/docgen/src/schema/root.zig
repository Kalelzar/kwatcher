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
