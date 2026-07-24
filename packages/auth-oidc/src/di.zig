//! DI wiring for the auth package.
//!
//! `extension(config_path, scheme_name)` is a `.with(...)`-compatible hub
//! extension (same shape as kw-runtime's `default.config`) that registers:
//! - the `Settings` section of the application config (lazy, via Resolver),
//! - the process-wide `AuthState` (static),
//! - the per-request `AuthCtx` (scoped) carrying the verified `Identity`,
//! - an `http.security.AuthSchemes` registry for the introspection UI.
const std = @import("std");
const core = @import("kw-core");
const http = @import("kw-http");

const dep = core.deps;
const Resolver = core.resolver.Resolver;

const state_mod = @import("state.zig");
const Settings = @import("settings.zig").Settings;

pub fn extension(comptime config_path: []const u8, comptime scheme_name: []const u8) type {
    return struct {
        pub fn apply(
            dephub: anytype,
            comptime category: anytype,
            allocator: std.mem.Allocator,
            comptime Config: type,
        ) Return(category, Config, @TypeOf(dephub)) {
            const H = struct {
                var state_ctx: state_mod.AuthStateCtx = .{};
                var settings_ctx: ResolvedSettings(Config, config_path, scheme_name) = .{};
            };
            H.state_ctx.state.alloc = allocator;
            return dephub
                .static(category, &H.settings_ctx)
                .static(category, &H.state_ctx)
                .scoped(category, state_mod.AuthCtx);
        }

        pub fn Return(comptime category: anytype, comptime Config: type, comptime DH: type) type {
            return DH
                .Static(category, *ResolvedSettings(Config, config_path, scheme_name))
                .Static(category, *state_mod.AuthStateCtx)
                .Scoped(category, state_mod.AuthCtx);
        }
    };
}

/// Registers only the runtime scheme facts (settings resolver + the
/// `http.security.AuthSchemes` registry) — for mounts that need to *know
/// about* the auth setup, like the introspection UI's Auth tab, without
/// enforcing anything. Enforcement mounts use `extension`.
pub fn schemes(comptime config_path: []const u8, comptime scheme_name: []const u8) type {
    return struct {
        pub fn apply(
            dephub: anytype,
            comptime category: anytype,
            allocator: std.mem.Allocator,
            comptime Config: type,
        ) Return(category, Config, @TypeOf(dephub)) {
            _ = allocator;
            const H = struct {
                var settings_ctx: ResolvedSettings(Config, config_path, scheme_name) = .{};
            };
            return dephub.static(category, &H.settings_ctx);
        }

        pub fn Return(comptime category: anytype, comptime Config: type, comptime DH: type) type {
            return DH.Static(category, *ResolvedSettings(Config, config_path, scheme_name));
        }
    };
}

pub fn ResolvedSettings(comptime Config: type, comptime config_path: []const u8, comptime scheme_name: []const u8) type {
    if (Resolver(Config).resolveType(config_path) != Settings) {
        @compileError(
            "Config mismatch: '" ++ config_path ++ "' does not resolve to kw-auth-oidc Settings in " ++ @typeName(Config),
        );
    }

    return struct {
        pub fn authSettings(inj: *dep.DepCtx, conf: *Config) !*Settings {
            return Resolver(Config).resolveRef(inj, config_path, conf);
        }

        pub fn authSchemes(settings: *Settings) http.security.AuthSchemes {
            const H = struct {
                var schemes: [1]http.security.RuntimeScheme = undefined;
            };
            H.schemes[0] = .{
                .name = scheme_name,
                .well_known = settings.well_known,
            };
            return .{ .schemes = &H.schemes };
        }
    };
}

// Ref all decls — extension/ResolvedSettings are generic over the app
// config; instantiated in root.zig's comptime block.
comptime {
    std.testing.refAllDecls(@This());
}
