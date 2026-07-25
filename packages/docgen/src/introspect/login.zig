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

//! The introspection UI's own login: `/_introspect/login`.
//!
//! Distinct from the Auth tab, which manages tokens for the *inspected
//! application's* Try-it requests. This flow authenticates the operator to
//! the UI itself; the resulting bearer token is stored under
//! `kw:introspect:token` and attached to every htmx request by the `_head`
//! hook (and to the Try-it render calls).
//!
//! Same stateless PKCE mechanics as the Auth tab flow (verifier + state in a
//! short-lived HttpOnly cookie, server-side code exchange), with its own
//! cookie and callback so the two flows never interfere. Everything about
//! the UI's scheme (name, well-known URL, login client) comes from the
//! dedicated `security.UiAuth` registry — deliberately separate from
//! `AuthSchemes`/`LoginClients`, which describe the *inspected app's*
//! schemes and feed the Auth tab.

const std = @import("std");
const core = @import("kw-core");
const http = @import("kw-http");
const auth = @import("auth.zig");
const security = @import("security.zig");

const ui_pkce_cookie = "kw_introspect_ui_pkce";

fn uiAuthOf(depctx: *core.deps.DepCtx) ?security.UiAuth {
    const ua = depctx.require(security.UiAuth) catch return null;
    if (ua.scheme.well_known.len == 0) return null;
    return ua;
}

const LoginCard = struct {
    scheme: []const u8,
    has_login: bool,
    configured: bool,
};

const CallbackResult = struct {
    token: []const u8,
    err: []const u8,
};

/// Templated routes (core prefix). All open: they are what an
/// unauthenticated operator must reach to become authenticated.
pub fn Pages(comptime Docs: type) type {
    _ = Docs;
    return struct {
        pub fn @"GET _introspect/login @introspectLogin"(
            _: http.data.Request(null),
        ) http.data.Html(struct { title: []const u8 }, &.{200}) {
            return .{ .value = .{ .ok = .{ .title = "Login" } } };
        }

        /// The login card fragment. Open on purpose — it must render before
        /// any UI token exists (it *is* the way to get one).
        pub fn @"GET _introspect/login/card @introspectLoginCard"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
            },
            depctx: *core.deps.DepCtx,
        ) http.data.Html(LoginCard, &.{200}) {
            _ = body;
            const ua = uiAuthOf(depctx) orelse
                return .{ .value = .{ .ok = .{ .scheme = "", .has_login = false, .configured = false } } };
            return .{ .value = .{ .ok = .{
                .scheme = ua.scheme.name,
                .has_login = ua.client_id != null,
                .configured = true,
            } } };
        }

        pub fn @"GET _introspect/login/callback @introspectLoginCallback"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                // OAuth says to ignore unrecognized authorization-response
                // params, but the framework rejects undeclared query params —
                // so the extras Keycloak sends are declared (and unused).
                query: struct {
                    code: []const u8 = "",
                    state: []const u8 = "",
                    @"error": []const u8 = "",
                    error_description: []const u8 = "",
                    session_state: []const u8 = "",
                    iss: []const u8 = "",
                },
            },
            depctx: *core.deps.DepCtx,
            persistent: std.mem.Allocator,
        ) !http.data.Html(CallbackResult, &.{200}) {
            // Same memory discipline as the Auth tab callback: the pooled
            // request allocator is a 4KiB bump block, so HTTP fetches run off
            // the persistent allocator and response strings land in httpz's
            // response arena.
            const a = body.response.arena;
            body.response.header("Set-Cookie", ui_pkce_cookie ++ "=; Path=/_introspect/login; Max-Age=0");

            if (body.query.@"error".len != 0) {
                const err = if (body.query.error_description.len != 0)
                    body.query.error_description
                else
                    body.query.@"error";
                return failure(err);
            }
            if (body.query.code.len == 0) {
                return failure("The provider sent no authorization code.");
            }

            const cookies = body.request.header("cookie") orelse "";
            const pkce = auth.cookieValue(cookies, ui_pkce_cookie) orelse
                return failure("Login session expired — start the login again.");
            const dot = std.mem.indexOfScalar(u8, pkce, '.') orelse
                return failure("Malformed login session cookie.");
            const state = pkce[0..dot];
            const verifier = pkce[dot + 1 ..];
            if (!std.mem.eql(u8, state, body.query.state)) {
                return failure("State mismatch — start the login again.");
            }

            const ua = uiAuthOf(depctx) orelse
                return failure("The UI auth scheme is not configured.");
            const client_id = ua.client_id orelse
                return failure("The UI auth scheme has no login client configured.");

            const endpoints = auth.fetchEndpoints(persistent, a, ua.scheme.well_known) catch
                return failure("Could not reach the provider's discovery document.");
            const token_endpoint = endpoints.token_endpoint orelse
                return failure("The provider advertises no token endpoint.");

            // Must match the redirect_uri sent by the start route exactly.
            const redirect_uri = try selfCallbackUri(a, body.request);

            var form: std.Io.Writer.Allocating = .init(a);
            try form.writer.writeAll("grant_type=authorization_code&code=");
            try auth.percentEncode(&form.writer, body.query.code);
            try form.writer.writeAll("&redirect_uri=");
            try auth.percentEncode(&form.writer, redirect_uri);
            try form.writer.writeAll("&client_id=");
            try auth.percentEncode(&form.writer, client_id);
            try form.writer.writeAll("&code_verifier=");
            try auth.percentEncode(&form.writer, verifier);

            const token = auth.exchangeCode(persistent, a, token_endpoint, form.written()) catch
                return failure("The token exchange failed.");
            const access_token = token.access_token orelse
                return failure(token.error_description orelse token.@"error" orelse "The provider returned no access token.");

            return .{ .value = .{ .ok = .{ .token = access_token, .err = "" } } };
        }

        fn failure(err: []const u8) http.data.Html(CallbackResult, &.{200}) {
            return .{ .value = .{ .ok = .{ .token = "", .err = err } } };
        }
    };
}

/// Raw (untemplated) route: the 302 that starts the provider login. Kept out
/// of the template pipeline because its useful output is a redirect.
pub fn Start(comptime Docs: type) type {
    _ = Docs;
    return struct {
        pub fn @"GET _introspect/login/start"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
            },
            depctx: *core.deps.DepCtx,
            persistent: std.mem.Allocator,
        ) !http.data.InternalFile("text/html") {
            const a = body.response.arena;

            const ua = uiAuthOf(depctx) orelse return bad(body.response, "The UI auth scheme is not configured.");
            const client_id = ua.client_id orelse
                return bad(body.response, "The UI auth scheme has no login client configured.");

            const endpoints = auth.fetchEndpoints(persistent, a, ua.scheme.well_known) catch
                return bad(body.response, "Could not reach the provider's discovery document.");
            const authorization_endpoint = endpoints.authorization_endpoint orelse
                return bad(body.response, "The provider advertises no authorization endpoint.");

            // PKCE (S256) + CSRF state, both carried in a short-lived cookie.
            var verifier_bytes: [32]u8 = undefined;
            std.crypto.random.bytes(&verifier_bytes);
            var verifier_buf: [43]u8 = undefined;
            const verifier = std.base64.url_safe_no_pad.Encoder.encode(&verifier_buf, &verifier_bytes);

            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
            var challenge_buf: [43]u8 = undefined;
            const challenge = std.base64.url_safe_no_pad.Encoder.encode(&challenge_buf, &digest);

            var state_bytes: [16]u8 = undefined;
            std.crypto.random.bytes(&state_bytes);
            var state_buf: [22]u8 = undefined;
            const state = std.base64.url_safe_no_pad.Encoder.encode(&state_buf, &state_bytes);

            const cookie = try std.fmt.allocPrint(
                a,
                ui_pkce_cookie ++ "={s}.{s}; Path=/_introspect/login; Max-Age=300; HttpOnly; SameSite=Lax",
                .{ state, verifier },
            );
            body.response.header("Set-Cookie", cookie);

            const redirect_uri = try selfCallbackUri(a, body.request);

            var url: std.Io.Writer.Allocating = .init(a);
            try url.writer.writeAll(authorization_endpoint);
            try url.writer.writeAll(if (std.mem.indexOfScalar(u8, authorization_endpoint, '?') == null) "?" else "&");
            try url.writer.writeAll("response_type=code&scope=openid&code_challenge_method=S256&client_id=");
            try auth.percentEncode(&url.writer, client_id);
            try url.writer.writeAll("&redirect_uri=");
            try auth.percentEncode(&url.writer, redirect_uri);
            try url.writer.writeAll("&state=");
            try url.writer.print("{s}", .{state});
            try url.writer.writeAll("&code_challenge=");
            try url.writer.print("{s}", .{challenge});

            body.response.status = 302;
            body.response.header("Location", url.written());
            return .{ .value = "" };
        }

        fn bad(res: *http.Response, msg: []const u8) http.data.InternalFile("text/html") {
            res.status = 404;
            return .{ .value = msg };
        }
    };
}

/// The absolute callback URI on this mount, from the request's Host header.
/// Plain http — the UI is a dev tool.
fn selfCallbackUri(a: std.mem.Allocator, request: *http.Request) ![]const u8 {
    const host = request.header("host") orelse "localhost";
    return std.fmt.allocPrint(a, "http://{s}/_introspect/login/callback", .{host});
}

// Ref all decls — the route containers are generic over Docs/scheme;
// instantiated by consumers through MountWith.
comptime {
    std.testing.refAllDecls(@This());
}
