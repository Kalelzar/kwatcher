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

const ctx = @import("dep/ctx.zig");
pub const StaticBinder = ctx.StaticBinder;
pub const Resolved = ctx.Resolved;
pub const TidHashContext = ctx.TidHashContext;
pub const TidArrayHashContext = ctx.TidArrayHashContext;
pub const DepCtx = ctx.DepCtx;
pub const Cache = ctx.Cache;

pub const Analyser = @import("dep/analyser.zig").Analyser;

const map = @import("dep/map.zig");
pub const DCategory = map.DCategory;
pub const DepMap = map.DepMap;

pub const DepHub = @import("dep/hub.zig").DepHub;

const scope_mod = @import("dep/scope.zig");
pub const Scope = scope_mod.Scope;
pub const scope = scope_mod.scope;

const container = @import("dep/container.zig");
pub const DependencyLifetimes = container.DependencyLifetimes;
pub const DependencyContainer = container.DependencyContainer;

// Ref all decls — non-recursive: the DI types (DepCtx/DepHub/DependencyContainer)
// are deeply nested generics that explode under refAllDeclsRecursive; they're
// exercised concretely by the driver/runtime builds.
comptime {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
