const cache = @import("cache.zig");

pub fn TieredCache(comptime Data: type, comptime Invariant: anytype, comptime Tiers: anytype) cache.SetBuilder(Data, Invariant) {
    return cache.SetBuilder(Data, Invariant)
        .new()
        .hotRaw(cache.autoCacheWithContexts(Data, Invariant, Tiers));
}
