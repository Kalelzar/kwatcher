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

/// The OpenAPI document version we serialize to.
///
/// The whole generator is built so that adding a new target is a new enum field
/// here plus a new arm in `openapi.serialize` (and a matching `emit/<v>.zig`).
/// Extraction and reflection are version-neutral and never need to change.
pub const OpenApiVersion = enum {
    v3_2_0,

    /// The dotted version string as it appears in the `openapi` field of the document.
    pub fn toString(self: OpenApiVersion) []const u8 {
        return switch (self) {
            .v3_2_0 => "3.2.0",
        };
    }
};

pub const ParseError = error{UnsupportedOpenApiVersion};

/// Parse a dotted version string (e.g. "3.2.0") into an `OpenApiVersion`.
/// Returns `error.UnsupportedOpenApiVersion` for anything we don't emit yet,
/// so passing `-Dopenapi_version=3.1.0` fails loudly rather than silently
/// producing a 3.2.0 document.
pub fn parse(text: []const u8) ParseError!OpenApiVersion {
    inline for (@typeInfo(OpenApiVersion).@"enum".fields) |field| {
        const candidate: OpenApiVersion = @enumFromInt(field.value);
        if (std.mem.eql(u8, text, candidate.toString())) return candidate;
    }
    return error.UnsupportedOpenApiVersion;
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

test "round trips every supported version" {
    inline for (@typeInfo(OpenApiVersion).@"enum".fields) |field| {
        const v: OpenApiVersion = @enumFromInt(field.value);
        try std.testing.expectEqual(v, try parse(v.toString()));
    }
}

test "rejects unsupported versions" {
    try std.testing.expectError(error.UnsupportedOpenApiVersion, parse("3.1.0"));
    try std.testing.expectError(error.UnsupportedOpenApiVersion, parse("nonsense"));
}
