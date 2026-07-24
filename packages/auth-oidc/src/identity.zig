const std = @import("std");
const jwt = @import("jwt.zig");

/// The verified user identity, populated by the auth middleware before the
/// wrapped handler runs. Handlers receive it as an ordinary dependency
/// argument (`identity: Identity` or `identity: *const Identity`).
///
/// All slices point into the request's scoped arena — valid for the request,
/// never to be retained past it.
pub const Identity = struct {
    claims: jwt.Claims = .{},
    header: jwt.JWTHeader = .{},
    /// Full claim set as raw JSON for claims not modeled in `jwt.Claims`.
    additional_claims: std.json.Value = .null,
    /// The compact-form token (without `Bearer ` prefix), for pass-through
    /// to downstream services.
    token: []const u8 = "",
};

// Ref all decls
comptime {
    std.testing.refAllDeclsRecursive(@This());
}
