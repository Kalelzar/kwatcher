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

//! DI wiring for the auth package.
//!
//! `extension(config_path)` is a `.with(...)`-compatible hub extension (same
//! shape as kw-runtime's `default.config`) that registers what token
//! *enforcement* needs:
//! - the `Settings` section of the application config (lazy, via Resolver),
//! - the process-wide `AuthState` (static),
//! - the per-request `AuthCtx` (scoped) carrying the verified `Identity`.
//!
//! Discovery registries for UIs live in kw-introspect (`security.*`) and
//! are deliberately NOT registered here: the app owns them, because one
//! scope may know about several schemes while enforcing only one.
const std = @import("std");
const core = @import("kw-core");

const dep = core.deps;
const Resolver = core.resolver.Resolver;

const state_mod = @import("state.zig");
const Settings = @import("settings.zig").Settings;

pub fn extension(comptime config_path: []const u8) type {
    return struct {
        pub fn apply(
            dephub: anytype,
            comptime category: anytype,
            allocator: std.mem.Allocator,
            comptime Config: type,
        ) Return(category, Config, @TypeOf(dephub)) {
            const H = struct {
                var state_ctx: state_mod.AuthStateCtx = .{};
                var settings_ctx: ResolvedSettings(Config, config_path) = .{};
            };
            H.state_ctx.state.alloc = allocator;
            return dephub
                .static(category, &H.settings_ctx)
                .static(category, &H.state_ctx)
                .scoped(category, state_mod.AuthCtx);
        }

        pub fn Return(comptime category: anytype, comptime Config: type, comptime DH: type) type {
            return DH
                .Static(category, *ResolvedSettings(Config, config_path))
                .Static(category, *state_mod.AuthStateCtx)
                .Scoped(category, state_mod.AuthCtx);
        }
    };
}

pub fn ResolvedSettings(comptime Config: type, comptime config_path: []const u8) type {
    if (Resolver(Config).resolveType(config_path) != Settings) {
        @compileError(
            "Config mismatch: '" ++ config_path ++ "' does not resolve to kw-auth-oidc Settings in " ++ @typeName(Config),
        );
    }

    return struct {
        pub fn authSettings(inj: *dep.DepCtx, conf: *Config) !*Settings {
            return Resolver(Config).resolveRef(inj, config_path, conf);
        }
    };
}

// Ref all decls — extension/ResolvedSettings are generic over the app
// config; instantiated in root.zig's comptime block.
comptime {
    std.testing.refAllDecls(@This());
}
