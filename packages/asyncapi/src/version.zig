const std = @import("std");

/// The AsyncAPI document version we serialize to.
///
/// As with the OpenAPI generator, adding a new target is a new enum field here plus
/// a new arm in `asyncapi.serialize` (and a matching `emit/<v>.zig`). The neutral
/// model, route extraction, and schema reflection are version-neutral and never
/// need to change.
pub const AsyncApiVersion = enum {
    v3_0_0,

    /// The dotted version string as it appears in the `asyncapi` field of the document.
    pub fn toString(self: AsyncApiVersion) []const u8 {
        return switch (self) {
            .v3_0_0 => "3.0.0",
        };
    }
};

pub const ParseError = error{UnsupportedAsyncApiVersion};

/// Parse a dotted version string (e.g. "3.0.0") into an `AsyncApiVersion`.
/// Returns `error.UnsupportedAsyncApiVersion` for anything we don't emit yet, so
/// passing `-Dasyncapi_version=2.6.0` fails loudly rather than silently producing
/// a 3.0.0 document.
pub fn parse(text: []const u8) ParseError!AsyncApiVersion {
    inline for (@typeInfo(AsyncApiVersion).@"enum".fields) |field| {
        const candidate: AsyncApiVersion = @enumFromInt(field.value);
        if (std.mem.eql(u8, text, candidate.toString())) return candidate;
    }
    return error.UnsupportedAsyncApiVersion;
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

test "round trips every supported version" {
    inline for (@typeInfo(AsyncApiVersion).@"enum".fields) |field| {
        const v: AsyncApiVersion = @enumFromInt(field.value);
        try std.testing.expectEqual(v, try parse(v.toString()));
    }
}

test "rejects unsupported versions" {
    try std.testing.expectError(error.UnsupportedAsyncApiVersion, parse("2.6.0"));
    try std.testing.expectError(error.UnsupportedAsyncApiVersion, parse("nonsense"));
}
