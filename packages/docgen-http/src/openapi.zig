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
