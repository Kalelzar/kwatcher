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
    /// The client roles the token carries for the verified audience —
    /// `resource_access.<audience>.roles` (Keycloak's shape; there is no
    /// standard claim for client roles, so that convention is what we
    /// target). Empty when the token carries none.
    roles: []const []const u8 = &.{},

    /// Whether the token carries the client role `name`. Roles are this
    /// deployment's permission strings (e.g. "secret:reveal"); route-level
    /// requirements are declared on `WithAuth` — this is for checks the
    /// route split can't express.
    pub fn hasRole(self: *const Identity, name: []const u8) bool {
        for (self.roles) |r| {
            if (std.mem.eql(u8, r, name)) return true;
        }
        return false;
    }
};

/// Extract `resource_access.<client>.roles` from the raw claim set.
/// Missing levels or non-string entries yield an empty/shorter slice —
/// absence of a role is never an error, it is just "not permitted".
pub fn resourceRoles(
    arena: std.mem.Allocator,
    additional_claims: std.json.Value,
    client: []const u8,
) ![]const []const u8 {
    const root = switch (additional_claims) {
        .object => |o| o,
        else => return &.{},
    };
    const access = root.get("resource_access") orelse return &.{};
    const by_client = switch (access) {
        .object => |o| o.get(client) orelse return &.{},
        else => return &.{},
    };
    const roles = switch (by_client) {
        .object => |o| o.get("roles") orelse return &.{},
        else => return &.{},
    };
    const entries = switch (roles) {
        .array => |a| a.items,
        else => return &.{},
    };

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(arena);
    for (entries) |entry| {
        switch (entry) {
            .string => |s| try out.append(arena, s),
            else => {},
        }
    }
    return try out.toOwnedSlice(arena);
}

test "resourceRoles digs out the Keycloak shape" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"resource_access":{"kwatcher-secret":{"roles":["secret:view","secret:reveal",7]},
        \\ "other-client":{"roles":["nope"]}},"scope":"openid"}
    , .{});

    const roles = try resourceRoles(a, parsed.value, "kwatcher-secret");
    try std.testing.expectEqual(@as(usize, 2), roles.len);
    try std.testing.expectEqualStrings("secret:view", roles[0]);
    try std.testing.expectEqualStrings("secret:reveal", roles[1]);

    var id = Identity{ .roles = roles };
    try std.testing.expect(id.hasRole("secret:reveal"));
    try std.testing.expect(!id.hasRole("nope"));

    try std.testing.expectEqual(@as(usize, 0), (try resourceRoles(a, parsed.value, "unknown")).len);
    try std.testing.expectEqual(@as(usize, 0), (try resourceRoles(a, .null, "kwatcher-secret")).len);
}

// Ref all decls
comptime {
    std.testing.refAllDeclsRecursive(@This());
}
