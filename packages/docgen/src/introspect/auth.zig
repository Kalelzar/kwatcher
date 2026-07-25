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

//! The Auth tab: lists the app's configured auth schemes (the runtime
//! `security.AuthSchemes` registry, registered by the app) and drives a real OIDC authorization-code + PKCE login so
//! tokens land in the browser's sessionStorage without hand-pasting.
//!
//! Layering: this module never imports an auth package — everything it needs
//! is the kw-http registry type, the provider's discovery document, and
//! `std.http.Client`. The registry is body-required through the DepCtx so an
//! app without any auth package still renders (an empty tab), rather than
//! failing dependency analysis.
//!
//! The login flow is stateless on the server: the PKCE verifier and the
//! `state` nonce travel in a short-lived HttpOnly cookie, and the code is
//! exchanged server-side (no provider CORS involvement); the resulting
//! access token is handed to the page, which stores it under
//! `kw:auth:token:<scheme>` for the Try-it forms.

const std = @import("std");
const core = @import("kw-core");
const http = @import("kw-http");
const security = @import("security.zig");

const pkce_cookie = "kw_introspect_pkce";

const SchemeEntry = struct {
    name: []const u8,
    well_known: []const u8,
    has_login: bool,
};

const AuthView = struct {
    schemes: []const SchemeEntry,
};

const CallbackResult = struct {
    scheme: []const u8,
    token: []const u8,
    err: []const u8,
};

pub fn schemesOf(depctx: *core.deps.DepCtx) ?security.AuthSchemes {
    return depctx.require(security.AuthSchemes) catch null;
}

/// The UI login-client registry is registered by the app only when it wants
/// login buttons; absent just means paste-only.
pub fn loginClientsOf(depctx: *core.deps.DepCtx) security.LoginClients {
    return depctx.require(security.LoginClients) catch .{};
}

/// Templated routes that must stay outside auth protection (core prefix):
/// the tab's shell page and the provider callback — both are browser
/// navigations, which can never carry an Authorization header.
pub fn Shell(comptime Docs: type) type {
    _ = Docs;
    return struct {
        /// The static page shell. The scheme list arrives as an htmx
        /// fragment (`@introspectAuthSchemes`) — the shell's markup lives in
        /// a `@partial head` slot, and zmpl slots cannot host `@zig` blocks
        /// (or multi-line braced scripts); fragments have no such limits.
        pub fn @"GET _introspect/auth @introspectAuth"(
            _: http.data.Request(null),
        ) http.data.Html(struct { title: []const u8 }, &.{200}) {
            return .{ .value = .{ .ok = .{ .title = "Auth" } } };
        }

        pub fn @"GET _introspect/auth/{scheme}/callback @introspectAuthCallback"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { scheme: []const u8 },
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
            // The pooled request allocator is a 4KiB bump block: HTTP fetches
            // run off the persistent allocator (freed before returning) and
            // anything the response keeps lands in httpz's response arena.
            const a = body.response.arena;
            // The cookie is single-use either way.
            body.response.header("Set-Cookie", pkce_cookie ++ "=; Path=/_introspect/auth; Max-Age=0");

            if (body.query.@"error".len != 0) {
                const err = if (body.query.error_description.len != 0)
                    body.query.error_description
                else
                    body.query.@"error";
                return failure(body.captures.scheme, err);
            }
            if (body.query.code.len == 0) {
                return failure(body.captures.scheme, "The provider sent no authorization code.");
            }

            const cookies = body.request.header("cookie") orelse "";
            const pkce = cookieValue(cookies, pkce_cookie) orelse
                return failure(body.captures.scheme, "Login session expired — start the login again.");
            const dot = std.mem.indexOfScalar(u8, pkce, '.') orelse
                return failure(body.captures.scheme, "Malformed login session cookie.");
            const state = pkce[0..dot];
            const verifier = pkce[dot + 1 ..];
            if (!std.mem.eql(u8, state, body.query.state)) {
                return failure(body.captures.scheme, "State mismatch — start the login again.");
            }

            const schemes = schemesOf(depctx) orelse
                return failure(body.captures.scheme, "No auth schemes are configured.");
            const scheme = schemes.find(body.captures.scheme) orelse
                return failure(body.captures.scheme, "Unknown auth scheme.");
            const client_id = loginClientsOf(depctx).find(scheme.name) orelse
                return failure(body.captures.scheme, "This scheme has no login client configured.");

            const endpoints = fetchEndpoints(persistent, a, scheme.well_known) catch
                return failure(body.captures.scheme, "Could not reach the provider's discovery document.");
            const token_endpoint = endpoints.token_endpoint orelse
                return failure(body.captures.scheme, "The provider advertises no token endpoint.");

            // Must match the redirect_uri sent by the login route exactly.
            const redirect_uri = try selfCallbackUri(a, body.request, body.captures.scheme);

            var form: std.Io.Writer.Allocating = .init(a);
            try form.writer.writeAll("grant_type=authorization_code&code=");
            try percentEncode(&form.writer, body.query.code);
            try form.writer.writeAll("&redirect_uri=");
            try percentEncode(&form.writer, redirect_uri);
            try form.writer.writeAll("&client_id=");
            try percentEncode(&form.writer, client_id);
            try form.writer.writeAll("&code_verifier=");
            try percentEncode(&form.writer, verifier);

            const token = exchangeCode(persistent, a, token_endpoint, form.written()) catch
                return failure(body.captures.scheme, "The token exchange failed.");
            const access_token = token.access_token orelse
                return failure(body.captures.scheme, token.error_description orelse token.@"error" orelse "The provider returned no access token.");

            return .{ .value = .{ .ok = .{
                .scheme = body.captures.scheme,
                .token = access_token,
                .err = "",
            } } };
        }

        fn failure(scheme: []const u8, err: []const u8) http.data.Html(CallbackResult, &.{200}) {
            return .{ .value = .{ .ok = .{ .scheme = scheme, .token = "", .err = err } } };
        }
    };
}

/// Templated inner routes (core prefix) — data fragments, safe to put behind
/// UI auth: the shell's htmx calls carry the UI bearer token.
pub fn Inner(comptime Docs: type) type {
    _ = Docs;
    return struct {
        pub fn @"GET _introspect/auth/schemes @introspectAuthSchemes"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
            },
            depctx: *core.deps.DepCtx,
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(AuthView, &.{200}) {
            _ = body;
            const schemes = schemesOf(depctx) orelse
                return .{ .value = .{ .ok = .{ .schemes = &.{} } } };
            const clients = loginClientsOf(depctx);

            const entries = try allocator.value.alloc(SchemeEntry, schemes.schemes.len);
            for (schemes.schemes, 0..) |s, i| {
                entries[i] = .{
                    .name = s.name,
                    .well_known = s.well_known,
                    .has_login = clients.find(s.name) != null,
                };
            }
            return .{ .value = .{ .ok = .{ .schemes = entries } } };
        }
    };
}

/// Raw (untemplated) routes: the login redirect. Kept out of the template
/// pipeline because its useful output is a 302, not a page.
pub fn Login(comptime Docs: type) type {
    _ = Docs;
    return struct {
        pub fn @"GET _introspect/auth/{scheme}/login"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { scheme: []const u8 },
            },
            depctx: *core.deps.DepCtx,
            persistent: std.mem.Allocator,
        ) !http.data.InternalFile("text/html") {
            // See the callback route for why the scoped allocator is avoided.
            const a = body.response.arena;

            const schemes = schemesOf(depctx) orelse return bad(body.response, "No auth schemes are configured.");
            const scheme = schemes.find(body.captures.scheme) orelse return bad(body.response, "Unknown auth scheme.");
            const client_id = loginClientsOf(depctx).find(scheme.name) orelse return bad(body.response, "This scheme has no login client configured.");

            const endpoints = fetchEndpoints(persistent, a, scheme.well_known) catch
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
                pkce_cookie ++ "={s}.{s}; Path=/_introspect/auth; Max-Age=300; HttpOnly; SameSite=Lax",
                .{ state, verifier },
            );
            body.response.header("Set-Cookie", cookie);

            const redirect_uri = try selfCallbackUri(a, body.request, body.captures.scheme);

            var url: std.Io.Writer.Allocating = .init(a);
            try url.writer.writeAll(authorization_endpoint);
            try url.writer.writeAll(if (std.mem.indexOfScalar(u8, authorization_endpoint, '?') == null) "?" else "&");
            try url.writer.writeAll("response_type=code&scope=openid&code_challenge_method=S256&client_id=");
            try percentEncode(&url.writer, client_id);
            try url.writer.writeAll("&redirect_uri=");
            try percentEncode(&url.writer, redirect_uri);
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

/// The absolute callback URI for `scheme` on this mount, from the request's
/// Host header. The introspection UI is served over plain http (it is a dev
/// tool on a private mount), so the scheme is fixed.
fn selfCallbackUri(a: std.mem.Allocator, request: *http.Request, scheme: []const u8) ![]const u8 {
    const host = request.header("host") orelse "localhost";
    return std.fmt.allocPrint(a, "http://{s}/_introspect/auth/{s}/callback", .{ host, scheme });
}

pub const Endpoints = struct {
    authorization_endpoint: ?[]const u8 = null,
    token_endpoint: ?[]const u8 = null,
};

/// Fetch the two endpoints we need from the OIDC discovery document. No
/// caching: logins are rare, and statelessness keeps this module trivial.
/// Network work runs on `gpa` and is fully released; the returned strings
/// are duped into `out`.
pub fn fetchEndpoints(gpa: std.mem.Allocator, out: std.mem.Allocator, well_known: []const u8) !Endpoints {
    var client = std.http.Client{ .allocator = gpa };
    defer client.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = well_known },
        .keep_alive = false,
        .response_writer = &w.writer,
    });
    if (result.status != .ok) return error.BadRequest;

    const parsed = try std.json.parseFromSlice(Endpoints, gpa, w.written(), .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .authorization_endpoint = if (parsed.value.authorization_endpoint) |s| try out.dupe(u8, s) else null,
        .token_endpoint = if (parsed.value.token_endpoint) |s| try out.dupe(u8, s) else null,
    };
}

pub const TokenResponse = struct {
    access_token: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    error_description: ?[]const u8 = null,
};

/// Exchange an authorization code at the provider's token endpoint
/// (public client + PKCE — no client secret involved). Same allocator
/// discipline as `fetchEndpoints`.
pub fn exchangeCode(gpa: std.mem.Allocator, out: std.mem.Allocator, token_endpoint: []const u8, form: []const u8) !TokenResponse {
    var client = std.http.Client{ .allocator = gpa };
    defer client.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = token_endpoint },
        .method = .POST,
        .payload = form,
        .keep_alive = false,
        .response_writer = &w.writer,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
    });
    // Providers return token errors with a 400 + JSON body; parse either way.
    _ = result;

    const parsed = try std.json.parseFromSlice(TokenResponse, gpa, w.written(), .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .access_token = if (parsed.value.access_token) |s| try out.dupe(u8, s) else null,
        .@"error" = if (parsed.value.@"error") |s| try out.dupe(u8, s) else null,
        .error_description = if (parsed.value.error_description) |s| try out.dupe(u8, s) else null,
    };
}

/// RFC 3986 percent-encoding, everything but the unreserved set.
pub fn percentEncode(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(c),
            else => try w.print("%{X:0>2}", .{c}),
        }
    }
}

pub fn cookieValue(cookies: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, cookies, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len > name.len + 1 and
            std.mem.startsWith(u8, trimmed, name) and
            trimmed[name.len] == '=')
        {
            return trimmed[name.len + 1 ..];
        }
    }
    return null;
}

// Ref all decls — the route containers are generic over Docs; instantiated
// by any consumer through assemble/coreRoutes.
comptime {
    std.testing.refAllDecls(@This());
}

test "cookieValue" {
    try std.testing.expectEqualStrings("s.v", cookieValue("a=1; kw_introspect_pkce=s.v; b=2", pkce_cookie).?);
    try std.testing.expectEqualStrings("s.v", cookieValue("kw_introspect_pkce=s.v", pkce_cookie).?);
    try std.testing.expect(cookieValue("kw_introspect_pkce2=s.v", pkce_cookie) == null);
    try std.testing.expect(cookieValue("", pkce_cookie) == null);
}

test "percentEncode" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try percentEncode(&w, "a b/c~d");
    try std.testing.expectEqualStrings("a%20b%2Fc~d", w.buffered());
}
