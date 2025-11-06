const std = @import("std");
const Injector = @import("../utils/injector.zig").Injector;
const metrics = @import("../utils/metrics.zig");

pub const SetBuilder = @import("set_builder.zig").SetBuilder;
pub const HotCold = @import("hotcold.zig").HotCold;
pub const Memory = @import("memory_cache.zig").Memory;
pub const MemoryContext = @import("memory_cache.zig").MemoryContext;
pub const File = @import("file_cache.zig").File;
pub const FileContext = @import("file_cache.zig").FileContext;
pub const Tiered = @import("tiered_cache.zig").TieredCache;

pub fn Cache(comptime Data: type) type {
    return struct {
        config: HotCold(Data),
        inj: *Injector,

        pub fn get(self: @This(), invariant: anytype) !Data {
            const arg: *anyopaque = @constCast(&invariant);
            if (self.config.hot) |h| {
                @branchHint(.likely);
                return @call(.auto, h, .{ self.inj, arg });
            } else if (self.config.cold) |c| {
                @branchHint(.unlikely);
                return @call(.auto, c, .{ self.inj, arg });
            } else {
                @branchHint(.cold);
                return error.NullCacheCalled;
            }
        }
    };
}

pub fn autoCacheWithContexts(
    comptime Data: type,
    comptime Invariant: anytype,
    comptime Context: anytype,
) *const fn (*Injector, *anyopaque) anyerror!Data {
    const H = struct {
        pub fn get(inj: *Injector, invariant: *anyopaque) anyerror!Data {
            var hasher = std.crypto.hash.Blake3.init(.{ .key = null });
            const in: *std.meta.Tuple(&Invariant) = @ptrCast(@alignCast(invariant));
            std.hash.autoHashStrat(&hasher, in.*, .DeepRecursive);
            var hashBytes: [32]u8 = undefined;
            hasher.final(&hashBytes);
            const hash = std.fmt.bytesToHex(&hashBytes, .upper);

            const config = try inj.require(HotCold(Data));
            // FIXME: Do ot reguire the contexts twice.
            inline for (0..Context.len) |i| {
                var context = try inj.require(*(Context[i]));
                if (try context.get(&hash)) |r| {
                    try metrics.cacheHit(config.key, Context[i].id);
                    inline for (0..i) |j| {
                        var other_context = try inj.require(*(Context[j]));
                        try other_context.put(&hash, try Data.dupe(other_context.allocator, &r));
                        try metrics.cacheGrow(config.key, Context[j].id);
                    }
                    return r;
                }
                try metrics.cacheMiss(config.key, Context[i].id);
            }

            if (config.cold) |c| {
                const data = try @call(.auto, c, .{ inj, invariant });
                inline for (0..Context.len) |i| {
                    var context = try inj.require(*(Context[i]));
                    try context.put(&hash, data);
                    try metrics.cacheGrow(config.key, Context[i].id);
                }

                return data;
            } else {
                return error.CacheMiss;
            }
        }
    };

    return &H.get;
}
