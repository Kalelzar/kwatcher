//! Runtime auth registries for the introspection UI. These live here — NOT
//! in kw-http — because they exist purely for the UI: the Auth tab lists the
//! inspected application's schemes for Try-it logins, and the UI's own login
//! page reads its dedicated scheme. Build-time route security metadata
//! (`SecurityRequirement`) stays in kw-http, where docgen reads it.
//!
//! Each registry has a `*Ctx` DI carrier: the hub scans a registered
//! context's pub fns as factories, so registering a registry (with its
//! `find` method) directly would poison the dependency graph — the carrier's
//! field registration is what makes the registry type requireable.
const std = @import("std");

/// Runtime description of a configured auth scheme — facts about the
/// inspected application's auth setup.
pub const RuntimeScheme = struct {
    /// Matches the comptime `SecurityRequirement.scheme` on protected routes.
    name: []const u8,
    /// OIDC discovery document URL.
    well_known: []const u8,
};

/// The inspected application's schemes, as listed by the Auth tab. The UI's
/// own scheme lives in `UiAuth`, never here. A missing registration reads as
/// "no auth configured".
pub const AuthSchemes = struct {
    schemes: []const RuntimeScheme = &.{},

    pub fn find(self: *const AuthSchemes, name: []const u8) ?RuntimeScheme {
        for (self.schemes) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }
};

/// DI carrier for `AuthSchemes`.
pub const AuthSchemesCtx = struct {
    schemes: AuthSchemes = .{},
};

/// A public OIDC client the Auth tab may use for an authorization-code +
/// PKCE Try-it login against a scheme.
pub const LoginClient = struct {
    /// Matches `RuntimeScheme.name`.
    scheme: []const u8,
    client_id: []const u8,
};

/// Per-scheme Try-it login clients. Absent (or empty) simply means no login
/// buttons — token paste still works.
pub const LoginClients = struct {
    clients: []const LoginClient = &.{},

    pub fn find(self: *const LoginClients, scheme: []const u8) ?[]const u8 {
        for (self.clients) |c| {
            if (std.mem.eql(u8, c.scheme, scheme)) return c.client_id;
        }
        return null;
    }
};

/// DI carrier for `LoginClients`.
pub const LoginClientsCtx = struct {
    clients: LoginClients = .{},
};

/// The introspection UI's own auth scheme + login client — deliberately
/// separate from `AuthSchemes`/`LoginClients` so it never shows up in the
/// Auth tab.
pub const UiAuth = struct {
    scheme: RuntimeScheme = .{ .name = "", .well_known = "" },
    /// Public client for the UI's `/_introspect/login` button; null leaves
    /// token paste as the only way in.
    client_id: ?[]const u8 = null,
};

/// DI carrier for `UiAuth`.
pub const UiAuthCtx = struct {
    ui: UiAuth = .{},
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
