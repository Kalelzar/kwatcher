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
