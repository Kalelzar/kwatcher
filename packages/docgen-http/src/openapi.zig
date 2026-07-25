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
const model = @import("model.zig");
const version = @import("version.zig");
const v3_2_0 = @import("emit/v3_2_0.zig");

pub const OpenApiVersion = version.OpenApiVersion;
pub const Document = model.Document;

/// Serialize a neutral document to the requested OpenAPI version.
///
/// The version is threaded through here rather than assumed: each `OpenApiVersion`
/// maps to its own emitter. Adding a target is a new arm in this switch plus a new
/// `emit/<v>.zig` — nothing upstream of this changes.
pub fn serialize(doc: Document, writer: *std.Io.Writer) !void {
    switch (doc.openapi_version) {
        .v3_2_0 => try v3_2_0.serialize(doc, writer),
    }
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
