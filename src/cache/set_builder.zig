const std = @import("std");
const Injector = @import("../utils/injector.zig").Injector;
const cache = @import("cache.zig");

pub const EvictionStrategy = enum {
    none,
    lru,
};

pub const Residency = union(enum) {
    count: usize,
    bytes: usize,
    unlimited: void,
};

pub fn SetOptions(comptime Data: type) type {
    return union(enum) {
        key: []const u8,
        hot: *const fn (*Injector, *anyopaque) anyerror!Data,
        cold: *const fn (*Injector, *anyopaque) anyerror!Data,
        push: *const fn (*Injector, Data, *anyopaque) anyerror!?Data,
        eviction: EvictionStrategy,
        residency: Residency,
    };
}

pub fn SetBuilder(comptime Data: type, comptime Invariant: anytype) type {
    const Opts = SetOptions(Data);
    return struct {
        opts: []Opts,
        const Self = @This();

        fn extend(comptime self: Self, comptime other: Opts) Self {
            comptime {
                const opts = blk: {
                    var opts: [self.opts.len + 1]Opts = undefined;
                    for (self.opts, 0..) |o, i| {
                        opts[i] = o;
                    }
                    opts[self.opts.len] = other;
                    break :blk opts;
                };
                return .{
                    .opts = @constCast(&opts),
                };
            }
        }

        pub fn new() Self {
            return comptime .{
                .opts = &.{},
            };
        }

        pub fn key(comptime self: Self, comptime k: anytype) Self {
            return self.extend(.{ .key = @tagName(k) });
        }

        fn handler(comptime f: anytype) *const fn (*Injector, *anyopaque) anyerror!Data {
            const H = struct {
                pub fn handle(
                    inj: *Injector,
                    invariant: *anyopaque,
                ) anyerror!Data {
                    const in: *std.meta.Tuple(&Invariant) = @ptrCast(@alignCast(@constCast(invariant)));

                    return inj.call_first(f, in.*);
                }
            };

            return &H.handle;
        }

        fn pushHandler(comptime f: anytype) *const fn (*Injector, Data, *anyopaque) anyerror!?Data {
            const H = struct {
                pub fn handle(
                    inj: *Injector,
                    data: Data,
                    invariant: *anyopaque,
                ) anyerror!Data {
                    const types = comptime blk: {
                        const in_ti = @typeInfo(@TypeOf(Invariant)).@"struct";
                        var types: [in_ti.fields.len + 1]type = undefined;
                        types[0] = Data;
                        for (in_ti.fields, 1..) |field, i| {
                            types[i] = field.type;
                        }
                        break :blk &types;
                    };

                    const in: *std.meta.Tuple(&Invariant) = @ptrCast(@alignCast(@constCast(invariant)));
                    const args: std.meta.Tuple(types) = undefined;
                    args[0] = data;
                    inline for (1..args.len) |i| {
                        args[i] = in[i - 1];
                    }

                    return inj.call_first(f, args);
                }
            };

            return &H.handle;
        }

        pub fn find(comptime self: Self, comptime keyName: anytype) ?@FieldType(SetOptions(Data), @tagName(keyName)) {
            inline for (self.opts) |o| {
                if (comptime std.meta.activeTag(o) == keyName) {
                    return @field(o, @tagName(keyName));
                }
            }
            return null;
        }

        pub fn hot(comptime self: Self, comptime f: anytype) Self {
            return self.extend(.{ .hot = handler(f) });
        }

        pub fn hotRaw(comptime self: Self, comptime f: anytype) Self {
            return self.extend(.{ .hot = f });
        }

        pub fn cold(comptime self: Self, comptime f: anytype) Self {
            return self.extend(.{ .cold = handler(f) });
        }

        pub fn push(comptime self: Self, comptime f: anytype) Self {
            return self.extend(.{ .push = pushHandler(f) });
        }

        pub fn pushRaw(comptime self: Self, comptime f: anytype) Self {
            return self.extend(.{ .push = f });
        }

        pub fn evict(comptime self: Self, comptime e: EvictionStrategy) Self {
            return self.extend(.{ .eviction = e });
        }

        pub fn residency(comptime self: Self, comptime r: Residency) Self {
            return self.extend(.{ .residency = r });
        }

        pub fn TypeFor(comptime self: Self) type {
            var has_cold = false;
            var has_hot = false;
            var has_key = false;
            var has_push = false;
            var eviction = EvictionStrategy.none;
            var resident = Residency{ .unlimited = {} };

            comptime {
                for (self.opts) |opts| {
                    switch (opts) {
                        .key => has_key = true,
                        .cold => has_cold = true,
                        .hot => has_hot = true,
                        .push => has_push = true,
                        .eviction => |e| eviction = e,
                        .residency => |r| resident = r,
                    }
                }

                if (!has_key) {
                    @compileError("A cache always needs a key!");
                }

                return switch (eviction) {
                    .none => cache.HotCold(Data),
                    .lru => cache.HotColdLru(Data),
                };
            }
        }

        pub fn interface(comptime self: Self) type {
            return TypeFor(self);
        }

        pub fn build(comptime self: Self) TypeFor(self) {
            var cache_config = std.mem.zeroInit(TypeFor(self), .{});
            inline for (self.opts) |o| {
                if (comptime @hasField(@TypeOf(cache_config), @tagName(std.meta.activeTag(o)))) {
                    @field(cache_config, @tagName(std.meta.activeTag(o))) = @field(o, @tagName(std.meta.activeTag(o)));
                }
            }
            cache_config.action_name = "cache " ++ cache_config.key;
            return cache_config;
        }
    };
}
