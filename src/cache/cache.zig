const std = @import("std");
const Injector = @import("../utils/injector.zig").Injector;
const metrics = @import("../utils/metrics.zig");

pub const SetBuilder = @import("set_builder.zig").SetBuilder;
pub const EvictionStrategy = @import("set_builder.zig").EvictionStrategy;
pub const Residency = @import("set_builder.zig").Residency;
pub const Expiration = @import("set_builder.zig").Expiration;
pub const HotCold = @import("hotcold.zig").HotCold;
pub const context = @import("context.zig");
pub const eviction = @import("eviction.zig");
pub const Tiered = @import("tiered_cache.zig").TieredCache;

pub fn Cache(comptime Data: type) type {
    return struct {
        config: HotCold(Data),
        inj: *Injector,

        pub fn get(self: @This(), invariant: anytype) !Data {
            const start = std.time.microTimestamp();
            defer {
                const time = std.time.microTimestamp() - start;
                metrics.latency(self.config.action_name, time) catch {};
            }
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

        pub fn push(self: @This(), data: Data, invariant: anytype) !?Data {
            const arg: *anyopaque = @constCast(&invariant);
            if (self.config.push) |h| {
                @branchHint(.likely);
                return @call(.auto, h, .{ self.inj, data, arg });
            } else {
                @branchHint(.cold);
                return error.ReadOnly;
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
            // FIXME: Do not require the contexts twice.
            inline for (0..Context.len) |i| {
                var ctx = try inj.require(*(Context[i]));
                if (try ctx.get(&hash)) |r| {
                    try metrics.cacheHit(config.key, Context[i].id);
                    inline for (0..i) |j| {
                        var other_context = try inj.require(*(Context[j]));
                        switch (@typeInfo(Data)) {
                            inline .@"struct" => {
                                if (comptime @hasDecl(Data, "dupe")) {
                                    try other_context.put(&hash, try Data.dupe(other_context.allocator, &r));
                                } else {
                                    try other_context.put(&hash, r);
                                }
                            },
                            else => try other_context.put(&hash, r),
                        }
                        try metrics.cacheGrow(config.key, Context[j].id);
                    }
                    return r;
                }
                try metrics.cacheMiss(config.key, Context[i].id);
            }

            if (config.cold) |c| {
                const data = try @call(.auto, c, .{ inj, invariant });
                inline for (0..Context.len) |i| {
                    var ctx = try inj.require(*(Context[i]));
                    try ctx.put(&hash, data);
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

pub fn autoPushWithContexts(
    comptime Data: type,
    comptime Invariant: anytype,
    comptime Context: anytype,
) *const fn (*Injector, Data, *anyopaque) anyerror!?Data {
    const H = struct {
        pub fn push(inj: *Injector, data: Data, invariant: *anyopaque) anyerror!?Data {
            var hasher = std.crypto.hash.Blake3.init(.{ .key = null });
            const in: *std.meta.Tuple(&Invariant) = @ptrCast(@alignCast(invariant));
            std.hash.autoHashStrat(&hasher, in.*, .DeepRecursive);
            var hashBytes: [32]u8 = undefined;
            hasher.final(&hashBytes);
            const hash = std.fmt.bytesToHex(&hashBytes, .upper);

            const config = try inj.require(HotCold(Data));
            inline for (0..Context.len) |i| {
                var ctx = try inj.require(*(Context[i]));
                try ctx.put(&hash, data);
                try metrics.cacheGrow(config.key, Context[i].id);
            }

            // NOTE: Reserved for future expansion.
            // `Put' may return any evicted members in a future implementation.
            return null;
        }
    };

    return &H.push;
}
