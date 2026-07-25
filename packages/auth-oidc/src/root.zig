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

//! kw-auth-oidc — OIDC bearer-token authentication for kwatcher HTTP routes.
//!
//! An OIDC *resource server*: verifies `Authorization: Bearer <jwt>` against
//! the provider's JWKS (discovered via `.well-known`), validates the claims,
//! and exposes the verified `Identity` to downstream handlers through DI.
//! There is no login/session flow here.
//!
//! Usage sketch:
//! ```zig
//! const auth = @import("kw-auth-oidc");
//! // Route list: only wrapped routes require (and document) auth.
//! const routes = auth.WithAuth(http.From(Secured, Ctx), .{}) ++ http.From(Public, Ctx);
//! // DI: register settings ("auth" section of the app config), state, and
//! // the per-request identity under the http driver's key.
//! const hub = base_hub.with(.my_http_driver, auth.extension("auth", "bearer"), alloc);
//! // Handler:
//! pub fn @"GET /me @me"(ctx: Ctx, identity: auth.Identity) Me { ... }
//! ```
const std = @import("std");
const http = @import("kw-http");

pub const jwk = @import("jwk.zig");
pub const jwt = @import("jwt.zig");
pub const discovery = @import("discovery.zig");

pub const Settings = @import("settings.zig").Settings;
pub const Identity = @import("identity.zig").Identity;
pub const AuthState = @import("state.zig").AuthState;
pub const AuthStateCtx = @import("state.zig").AuthStateCtx;
pub const AuthCtx = @import("state.zig").AuthCtx;

pub const WithAuth = @import("middleware.zig").WithAuth;
pub const Opts = @import("middleware.zig").Opts;
pub const stripBearer = @import("middleware.zig").stripBearer;

pub const extension = @import("di.zig").extension;
pub const ResolvedSettings = @import("di.zig").ResolvedSettings;

// Ref all decls — non-recursive at the root (pub re-exports); each sub-file
// carries its own block. Generics are instantiated below against a real
// route so the wrapper bodies get analyzed.
comptime {
    std.testing.refAllDecls(@This());

    const Context = struct { request_id: u64 = 0 };
    const Rs = struct {
        pub fn @"GET /secured @refSecured"(ctx: struct {
            request: *http.Request,
            response: *http.Response,
        }, identity: Identity) []const u8 {
            _ = ctx;
            _ = identity;
            return "";
        }
    };

    const Rts = http.From(Rs, Context);
    const secured = WithAuth(Rts, .{ .scopes = &.{"profile"} });
    if (secured.len != Rts.len) @compileError("BUG: WithAuth changed route count");

    const R = secured[0];
    const req = R.getMeta(http.security.SecurityRequirement) orelse
        @compileError("BUG: WithAuth did not attach a SecurityRequirement");
    if (!std.mem.eql(u8, req.scheme, "bearer")) @compileError("BUG: wrong scheme name");
    if (req.kind != .http_bearer) @compileError("BUG: wrong scheme kind");

    // Force analysis of the wrapper call body.
    for (secured) |CR| {
        _ = &CR.call;
    }

    // DI extension: instantiate against a representative app config.
    const Config = struct { auth: Settings };
    _ = extension("auth");
    const RS = ResolvedSettings(Config, "auth");
    _ = &RS.authSettings;
}
