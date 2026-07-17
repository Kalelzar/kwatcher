const std = @import("std");
const DepCtx = @import("ctx.zig").DepCtx;

/// Owns one scoped dependency context: compile → prepare → actualize on init,
/// deactualize → reset on deinit. Cheap enough to build per worker thread,
/// which gives every watch worker its own context (and e.g. its own pooled
/// client lease) instead of sharing one actualized context across threads.
pub fn Scope(comptime Hub: type, comptime key: anytype) type {
    return struct {
        ctx: DepCtx,
        allocator: std.mem.Allocator,

        pub fn init(hub: *Hub, allocator: std.mem.Allocator) !@This() {
            var ctx = try hub.compile(key, .scoped, allocator);
            {
                // reset() indexes ctx.value per ContextStack entry, so it is
                // only legal once prepare() has populated the slice; until
                // then the cache is the only owned resource.
                errdefer ctx.cache.deinit(allocator);
                try hub.prepare(&ctx, key, .scoped, allocator);
            }
            errdefer Hub.reset(&ctx, key, .scoped, allocator);
            try hub.actualize(key, .scoped, &ctx);
            return .{ .ctx = ctx, .allocator = allocator };
        }

        pub fn deinit(self: *@This()) void {
            Hub.deactualize(&self.ctx, key, .scoped);
            Hub.reset(&self.ctx, key, .scoped, self.allocator);
        }
    };
}

/// Type-inferring convenience: `var sc = try dep.scope(deps, key, alloc);`
/// where `deps` is a pointer to the hub.
pub fn scope(hub: anytype, comptime key: anytype, allocator: std.mem.Allocator) !Scope(@TypeOf(hub.*), key) {
    return Scope(@TypeOf(hub.*), key).init(hub, allocator);
}

// Ref all decls — Scope is a generic over a concrete hub type; it is
// instantiated concretely by the driver watch loops.
comptime {
    std.testing.refAllDecls(@This());
}
