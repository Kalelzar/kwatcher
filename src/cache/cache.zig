const std = @import("std");
const dep = @import("../dep.zig");
const metrics = @import("../utils/metrics.zig");
const build_config = @import("build_config");

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
        inj: *dep.DepCtx,

        pub fn get(self: @This(), invariant: anytype) !Data {
            const start = if (comptime build_config.enable_metrics) std.time.microTimestamp() else 0;
            defer {
                if (comptime build_config.enable_metrics) {
                    const time = std.time.microTimestamp() - start;
                    metrics.latency(self.config.action_name, time) catch {};
                }
            }
            const ptr: *@TypeOf(invariant) = @constCast(&invariant);
            const arg: *anyopaque = @ptrCast(@alignCast(ptr));
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

fn TupleTToV(comptime Context: anytype) type {
    var val: [Context.len]type = undefined;
    for (0..Context.len) |i| {
        val[i] = ?*Context[i];
    }

    return std.meta.Tuple(&val);
}

fn splatNull(comptime Context: anytype) TupleTToV(Context) {
    var tuple: TupleTToV(Context) = undefined;
    for (0..Context.len) |i| {
        tuple[i] = null;
    }
    return tuple;
}

fn hashingStrategy(comptime Invariant: anytype, comptime off: usize, in: std.meta.Tuple(&Invariant)) u64 {
    if (comptime off == 0) {
        const actual = comptime blk: {
            var actual: u64 = 0;
            for (0..Invariant.len) |i| {
                actual += @bitSizeOf(Invariant[i]);
            }
            break :blk actual;
        };

        const is_oversized = comptime actual > 64;
        const is_a_simple_type = comptime blk: {
            for (0..Invariant.len) |i| {
                const ti = @typeInfo(Invariant[i]);
                switch (ti) {
                    .@"struct" => |s| {
                        switch (s.layout) {
                            .@"packed" => {},
                            else => break :blk false,
                        }
                    },
                    // Trivially convertable to an integral value
                    .@"enum", .int, .bool, .float => {},
                    .@"anyframe",
                    .@"fn",
                    .@"opaque",
                    .@"union", // FIXME: This might be convertable if all of the fields are simple?
                    .comptime_float,
                    .comptime_int,
                    .error_set,
                    .error_union,
                    .enum_literal,
                    .frame,
                    .noreturn,
                    .void,
                    .undefined,
                    .null,
                    .type,
                    .vector,
                    .optional,
                    .array, // FIXME: Technically we can do this so long as the array type is simple as well but this can be an optimization for later
                    .pointer, // FIXME: See above. Here however we can also choose to interpret the pointer as it's address since that is already easily convertable to a u64/u32. Is that what we *want* though?
                    => break :blk false,
                }
            }
            break :blk true;
        };

        if (comptime is_oversized or !is_a_simple_type) {
            // We can't fast path this invariant so we fallback to a proper hash. Sadge.
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, in.*, .DeepRecursive);
            return hasher.final();
        }
    }

    if (comptime Invariant[off] == u64 or (Invariant[off] == usize and @bitSizeOf(usize) == 64)) {
        return in[off];
    } else if (comptime Invariant[off] == u32 or (Invariant[off] == usize and @bitSizeOf(usize) == 32)) {
        if (comptime Invariant.len - off == 1) {
            return @intCast(in[off]);
        } else {
            // Store the current u32 in the higher 4 bytes and we can try to fit the rest of the invariant in the remaining 4.
            // We know that we CAN fit what remains here
            const low = @as(u64, @intCast(in[off]));
            const high = hashingStrategy(Invariant, off + 1, in) << 32;
            return high | low;
        }
    } else if (comptime Invariant[off] == u16) {
        if (comptime Invariant.len - off == 1) {
            return @intCast(in[off]);
        } else {
            // Store the current u16 in the higher 2 bytes and we can try to fit the rest of the invariant in the remaining 6.
            // We know that we CAN fit what remains here.
            const low = @as(u64, @intCast(in[off]));
            const high = hashingStrategy(Invariant, off + 1, in) << 16;
            return high | low;
        }
    } else if (comptime Invariant[off] == u8) {
        if (comptime Invariant.len - off == 1) {
            return @intCast(in[off]);
        } else {
            // Store the current u8 in the highest byte and we can try to fit the rest of the invariant in the remaining 7.
            // We know that we CAN fit what remains here.
            const low = @as(u64, @intCast(in[off]));
            const high = hashingStrategy(Invariant, off + 1, in) << 8;
            return high | low;
        }
    } else if (comptime Invariant[off] == u1) {
        if (comptime Invariant.len - off == 1) {
            return @intCast(in[off]);
        } else {
            // Store the current u1 in the highest byte and we can try to fit the rest of the invariant in the remaining.
            // We know that we CAN fit what remains here.
            const low = @as(u64, @intCast(in[off]));
            const high = hashingStrategy(Invariant, off + 1, in) << 1;
            return high | low;
        }
    } else {
        @compileError("Type '" ++ @typeName(Invariant[off]) ++ "' is missing an invariant hash fast path.");
    }
}

pub fn autoCacheWithContexts(
    comptime Data: type,
    comptime Invariant: anytype,
    comptime Context: anytype,
) *const fn (*dep.DepCtx, *anyopaque) anyerror!Data {
    const H = struct {
        pub fn get(inj: *dep.DepCtx, invariant: *anyopaque) anyerror!Data {
            const C = struct {
                var config: ?HotCold(Data) = null;
                var contexts: TupleTToV(Context) = splatNull(Context);
            };

            const config = C.config orelse blk: {
                @branchHint(.cold);
                C.config = try inj.require(HotCold(Data));
                break :blk C.config.?;
            };

            const hash: u64 = blk: {
                const in: *std.meta.Tuple(&Invariant) = @ptrCast(@alignCast(invariant));
                break :blk hashingStrategy(Invariant, 0, in.*);
            };

            // FIXME: Do not require the contexts twice.
            inline for (0..Context.len) |i| {
                var ctx = C.contexts[i] orelse blk: {
                    @branchHint(.cold);
                    C.contexts[i] = try inj.require(*(Context[i]));
                    break :blk C.contexts[i].?;
                };

                if (try ctx.get(hash)) |r| {
                    if (comptime build_config.enable_metrics) {
                        try metrics.cacheHit(config.key, Context[i].id);
                    }
                    inline for (0..i) |j| {
                        var other_context = C.contexts[j] orelse blk: {
                            @branchHint(.cold);
                            C.contexts[j] = try inj.require(*(Context[j]));
                            break :blk C.contexts[j].?;
                        };
                        switch (@typeInfo(Data)) {
                            inline .@"struct" => {
                                if (comptime @hasDecl(Data, "dupe")) {
                                    try other_context.put(hash, try Data.dupe(other_context.allocator, &r));
                                } else {
                                    try other_context.put(hash, r);
                                }
                            },
                            else => try other_context.put(hash, r),
                        }
                        if (comptime build_config.enable_metrics) {
                            try metrics.cacheGrow(config.key, Context[j].id);
                        }
                    }
                    return r;
                }
                if (comptime build_config.enable_metrics) {
                    try metrics.cacheMiss(config.key, Context[i].id);
                }
            }

            if (config.cold) |c| {
                const data = try @call(.auto, c, .{ inj, invariant });
                inline for (0..Context.len) |i| {
                    var ctx = C.contexts[i] orelse blk: {
                        @branchHint(.cold);
                        C.contexts[i] = try inj.require(*(Context[i]));
                        break :blk C.contexts[i].?;
                    };
                    try ctx.put(hash, data);
                    if (comptime build_config.enable_metrics) {
                        try metrics.cacheGrow(config.key, Context[i].id);
                    }
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
) *const fn (*dep.DepCtx, Data, *anyopaque) anyerror!?Data {
    const H = struct {
        pub fn push(inj: *dep.DepCtx, data: Data, invariant: *anyopaque) anyerror!?Data {
            const C = struct {
                var config: ?HotCold(Data) = null;
                var contexts: TupleTToV(Context) = splatNull(Context);
            };

            const config = C.config orelse blk: {
                @branchHint(.cold);
                C.config = try inj.require(HotCold(Data));
                break :blk C.config.?;
            };

            const hash: u64 = blk: {
                const in: *std.meta.Tuple(&Invariant) = @ptrCast(@alignCast(invariant));
                break :blk hashingStrategy(Invariant, 0, in.*);
            };

            inline for (0..Context.len) |i| {
                var ctx = C.contexts[i] orelse blk: {
                    @branchHint(.cold);
                    C.contexts[i] = try inj.require(*(Context[i]));
                    break :blk C.contexts[i].?;
                };
                try ctx.put(hash, data);
                if (comptime build_config.enable_metrics) {
                    try metrics.cacheGrow(config.key, Context[i].id);
                }
            }

            // NOTE: Reserved for future expansion.
            // `Put' may return any evicted members in a future implementation.
            return null;
        }
    };

    return &H.push;
}
