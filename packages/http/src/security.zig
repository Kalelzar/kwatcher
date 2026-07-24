//! Security metadata for HTTP routes.
//!
//! Two halves, deliberately split by *when* the information exists:
//!
//! - `SecurityRequirement` is comptime: an auth middleware attaches it to a
//!   route via `RouteBase.wrapWith`, and docgen reads it back with
//!   `RouteBase.getMeta` to emit OpenAPI `security` / `securitySchemes`.
//!   It must therefore never carry runtime configuration.
//! - `RuntimeScheme` / `AuthSchemes` are runtime: an auth package registers
//!   an `AuthSchemes` in DI so the introspection UI can discover the OIDC
//!   provider (well-known URL, public client id) and offer a real login.
//!
//! Both live in kw-http so that auth packages and docgen backends can share
//! them without depending on each other.
const std = @import("std");

/// What flavor of scheme a requirement describes. Maps onto OpenAPI
/// `securitySchemes` types; only bearer exists today.
pub const SchemeKind = enum {
    http_bearer,
};

/// Comptime marker attached to a route by an auth middleware.
pub const SecurityRequirement = struct {
    /// Scheme name — the key used in OpenAPI `securitySchemes` and to look
    /// up the matching `RuntimeScheme` at runtime.
    scheme: []const u8,
    kind: SchemeKind = .http_bearer,
    scopes: []const []const u8 = &.{},
};

/// Runtime description of a configured auth scheme — facts about the auth
/// setup only; UI concerns (login clients) live in `LoginClients`.
pub const RuntimeScheme = struct {
    /// Matches `SecurityRequirement.scheme`.
    name: []const u8,
    /// OIDC discovery document URL.
    well_known: []const u8,
};

/// DI-registered registry of configured schemes. Consumers (introspection
/// UI) should treat a missing registration as "no auth configured".
pub const AuthSchemes = struct {
    schemes: []const RuntimeScheme = &.{},

    pub fn find(self: *const AuthSchemes, name: []const u8) ?RuntimeScheme {
        for (self.schemes) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }
};

/// A public OIDC client the introspection UI may use for an
/// authorization-code + PKCE login against a scheme. Registered separately
/// from `AuthSchemes` — auth enforcement never needs it, only the UI does.
pub const LoginClient = struct {
    /// Matches `RuntimeScheme.name`.
    scheme: []const u8,
    client_id: []const u8,
};

/// DI-registered registry of UI login clients. Absent (or empty) simply
/// means no login buttons — token paste still works.
pub const LoginClients = struct {
    clients: []const LoginClient = &.{},

    pub fn find(self: *const LoginClients, scheme: []const u8) ?[]const u8 {
        for (self.clients) |c| {
            if (std.mem.eql(u8, c.scheme, scheme)) return c.client_id;
        }
        return null;
    }
};

/// DI carrier for `LoginClients` — register an instance of *this* as the
/// static. The hub scans a registered context's pub fns as factories, so
/// registering a `LoginClients` directly would put `find`'s parameters into
/// the dependency graph; the field registration here is what makes
/// `LoginClients` requireable.
pub const LoginClientsCtx = struct {
    clients: LoginClients = .{},
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

test "AuthSchemes.find" {
    const schemes = AuthSchemes{ .schemes = &.{
        .{ .name = "bearer", .well_known = "https://idp.example/.well-known/openid-configuration" },
    } };
    try std.testing.expect(schemes.find("bearer") != null);
    try std.testing.expect(schemes.find("basic") == null);
}

test "LoginClients.find" {
    const clients = LoginClients{ .clients = &.{
        .{ .scheme = "bearer", .client_id = "kw-introspect" },
    } };
    try std.testing.expectEqualStrings("kw-introspect", clients.find("bearer").?);
    try std.testing.expect(clients.find("basic") == null);
}
