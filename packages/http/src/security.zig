//! Security metadata for HTTP routes.
//!
//! `SecurityRequirement` is comptime route metadata: an auth middleware
//! attaches it to a route via `RouteBase.wrapWith`, and docgen reads it back
//! with `RouteBase.getMeta` to emit OpenAPI `security` / `securitySchemes`.
//! It must never carry runtime configuration.
//!
//! Runtime auth discovery (scheme registries, login clients) is an
//! introspection-UI concern and lives in kw-introspect, not here.
const std = @import("std");

/// What flavor of scheme a requirement describes. Maps onto OpenAPI
/// `securitySchemes` types; only bearer exists today.
pub const SchemeKind = enum {
    http_bearer,
};

/// Comptime marker attached to a route by an auth middleware.
pub const SecurityRequirement = struct {
    /// Scheme name — the key used in OpenAPI `securitySchemes`.
    scheme: []const u8,
    kind: SchemeKind = .http_bearer,
    scopes: []const []const u8 = &.{},
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
