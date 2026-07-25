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
