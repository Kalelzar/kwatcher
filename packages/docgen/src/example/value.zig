const std = @import("std");

/// A neutral, content-type-independent sample value produced by the synthesizer.
/// Serializers (one per content type) walk this tree to emit bytes, so the same
/// synthesized example can be rendered as multiple content types
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    array: []const Value,
    object: []const Field,

    pub const Field = struct {
        name: []const u8,
        value: Value,
    };
};
