const std = @import("std");
const Injector = @import("../utils/injector.zig").Injector;
const cache = @import("cache.zig");

pub fn SetOptions(comptime Data: type) type {
    return union(enum) {
        key: []const u8,
        hot: *const fn (*Injector, *anyopaque) anyerror!Data,
        cold: *const fn (*Injector, *anyopaque) anyerror!Data,
    };
}

pub fn SetBuilder(comptime Data: type, comptime Invariant: anytype) type {
    const Opts = SetOptions(Data);
    return struct {
        opts: []Opts,
        const Self = @This();

        fn extend(comptime self: Self, comptime other: Opts) Self {
            comptime {
                var opts: [self.opts.len + 1]Opts = undefined;
                for (self.opts, 0..) |o, i| {
                    opts[i] = o;
                }
                opts[self.opts.len] = other;
                return .{
                    .opts = &opts,
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

        pub fn hot(comptime self: Self, comptime f: anytype) Self {
            return self.extend(.{ .hot = handler(f) });
        }

        pub fn hotRaw(comptime self: Self, comptime f: anytype) Self {
            return self.extend(.{ .hot = f });
        }

        pub fn cold(comptime self: Self, comptime f: anytype) Self {
            return self.extend(.{ .cold = handler(f) });
        }

        fn TypeFor(comptime self: Self) type {
            var has_cold = false;
            var has_hot = false;
            var has_key = false;

            comptime {
                for (self.opts) |opts| {
                    switch (opts) {
                        .key => has_key = true,
                        .cold => has_cold = true,
                        .hot => has_hot = true,
                    }
                }

                if (!has_key) {
                    @compileError("A cache always needs a key!");
                }

                return cache.HotCold(Data);
            }
        }

        pub fn build(comptime self: Self) TypeFor(self) {
            var cache_config = std.mem.zeroInit(TypeFor(self), .{});
            inline for (self.opts) |o| {
                @field(cache_config, @tagName(std.meta.activeTag(o))) = @field(o, @tagName(std.meta.activeTag(o)));
            }
            return cache_config;
        }
    };
}
