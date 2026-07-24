//! `WithAuth` — comptime route-list transform enforcing OIDC bearer auth.
//!
//! Wrapping is declaring: each wrapped route also carries a
//! `http.security.SecurityRequirement` metadata entry (via `wrapWith`), so
//! OpenAPI/introspection see exactly the routes that are actually enforced.
const std = @import("std");
const klib = @import("klib");
const core = @import("kw-core");
const http = @import("kw-http");

const dep = core.deps;
const EventPropertiesEx = core.event.ExtendedProperties;

const jwt = @import("jwt.zig");
const state_mod = @import("state.zig");
const Settings = @import("settings.zig").Settings;
const Identity = @import("identity.zig").Identity;

pub const Opts = struct {
    /// Scheme name used in OpenAPI `securitySchemes` and matched against the
    /// runtime `AuthSchemes` registry (see `di.extension`).
    scheme: []const u8 = "bearer",
    scopes: []const []const u8 = &.{},
};

/// Strip a case-insensitive `Bearer ` prefix. Null when the header does not
/// carry a bearer token at all.
pub fn stripBearer(header: []const u8) ?[]const u8 {
    const prefix = "Bearer ";
    if (header.len <= prefix.len) return null;
    if (!std.ascii.startsWithIgnoreCase(header, prefix)) return null;
    return std.mem.trimLeft(u8, header[prefix.len..], " ");
}

pub fn WithAuth(comptime routes: []const type, comptime opts: Opts) []const type {
    if (comptime routes.len == 0) return routes;

    var nroutes: [routes.len]type = undefined;
    inline for (routes, 0..) |R, i| {
        nroutes[i] = R.wrapWith(WrapRouteHandlers.create, http.security.SecurityRequirement{
            .scheme = opts.scheme,
            .kind = .http_bearer,
            .scopes = opts.scopes,
        });
    }

    return &nroutes;
}

const WrapRouteHandlers = struct {
    pub fn create(comptime HandlerFac: anytype) type {
        return struct {
            pub fn make(comptime Base: type) type {
                const Handler = HandlerFac(Base);
                return struct {
                    pub const CallContext = Handler.CallContext;

                    pub const Dependencies = Handler.Dependencies ++ .{
                        *Settings,
                        *state_mod.AuthState,
                        *state_mod.AuthCtx,
                    };

                    pub fn call(
                        inj: *dep.DepCtx,
                        ctx: CallContext,
                        evprop: EventPropertiesEx,
                    ) klib.meta.Return(Handler.call) {
                        const req = ctx.request;
                        const res = ctx.response;

                        const raw_header = req.header("authorization") orelse
                            return fail(res, null);
                        const token = stripBearer(raw_header) orelse
                            return fail(res, "invalid_request");

                        const settings = try inj.require(*Settings);
                        const state = try inj.require(*state_mod.AuthState);
                        const auth_ctx = try inj.require(*state_mod.AuthCtx);

                        // The pooled request allocator is a single 4KiB bump
                        // block — not enough for JWT parsing. Parse into a
                        // dedicated arena on the scoped ctx instead; the hub
                        // deconstructs it after the response is written.
                        const persistent = state.alloc orelse return error.NotInitialized;
                        auth_ctx.arena = std.heap.ArenaAllocator.init(persistent);
                        const arena = auth_ctx.arena.?.allocator();

                        var keyset = try state.keys(settings, .{});
                        const parsed = jwt.parse(arena, token, &keyset) catch |e| switch (e) {
                            // Unknown kid may just mean the provider rotated
                            // its keys since we cached them: refresh once.
                            error.InvalidKid => blk: {
                                keyset = try state.keys(settings, .{ .force = true });
                                break :blk jwt.parse(arena, token, &keyset) catch
                                    return fail(res, "invalid_token");
                            },
                            error.OutOfMemory => return error.OutOfMemory,
                            else => return fail(res, "invalid_token"),
                        };

                        const wk = try state.discoveryData(settings);
                        jwt.validate(&parsed.claims, .{
                            .now = std.time.timestamp(),
                            .issuer = wk.issuer,
                            .audience = settings.audience,
                        }) catch return fail(res, "invalid_token");

                        auth_ctx.identity = .{
                            .claims = parsed.claims,
                            .header = parsed.header,
                            .additional_claims = parsed.additional_claims,
                            .token = token,
                        };

                        return @call(.auto, Handler.call, .{ inj, ctx, evprop });
                    }

                    /// RFC 6750 challenge; the response body/status is
                    /// rendered by the error handler's Unauthorized mapping.
                    fn fail(res: anytype, comptime code: ?[]const u8) klib.meta.Return(Handler.call) {
                        const challenge = if (code) |c|
                            "Bearer error=\"" ++ c ++ "\""
                        else
                            "Bearer";
                        res.header("WWW-Authenticate", challenge);
                        return error.Unauthorized;
                    }

                    pub inline fn name(inj: *dep.DepCtx) ![]const u8 {
                        return @call(.auto, Handler.name, .{inj});
                    }
                };
            }
        };
    }
};

// Ref all decls — WithAuth/WrapRouteHandlers are generic; instantiated in
// root.zig's comptime block against a real route.
comptime {
    std.testing.refAllDecls(@This());
}

test "stripBearer" {
    try std.testing.expectEqualStrings("tok", stripBearer("Bearer tok").?);
    try std.testing.expectEqualStrings("tok", stripBearer("bearer tok").?);
    try std.testing.expectEqualStrings("tok", stripBearer("BEARER  tok").?);
    try std.testing.expect(stripBearer("Basic dXNlcjpwdw==") == null);
    try std.testing.expect(stripBearer("Bearer") == null);
    try std.testing.expect(stripBearer("") == null);
    try std.testing.expect(stripBearer("Bearertok") == null);
}
