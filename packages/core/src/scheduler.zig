const std = @import("std");
const event = @import("event.zig");
const MPMCQueue = @import("utils/queue.zig").StaticStrict;
const dep = @import("dep.zig");

pub const Internal = struct {
    pub const key = .internal;
    pub const kind = .internal;
    pub const jobs = 0;
    pub const Dependencies: []const type = &.{};
    pub const EventType = event.Base;
    pub const EventValues = event.BaseValues;

    pub fn Yield(comptime ET: type, comptime EV: type) type {
        const E = comptime event.Event(ET, EV);
        return struct {
            const Self = @This();
            queue: ?*MPMCQueue(E) = null,
            should_run: bool = true,

            pub fn init() @This() {
                return .{};
            }

            pub const Scheduler = struct {
                parent: *Self,

                pub fn shutdown(self: @This(), extra: struct { inj: ?*dep.DepCtx = null }) !void {
                    if (!@atomicLoad(bool, &self.parent.should_run, .acquire)) return;

                    const value = @unionInit(
                        EV,
                        @tagName(key),
                        .{
                            .shutdown = .{},
                        },
                    );

                    var ev = E{
                        .event_data = value,
                        .event_type = .shutdown,
                    };

                    if (extra.inj) |inj| {
                        const p = try inj.require(event.Properties);
                        if (p.correlation_id.isUnset()) {
                            std.log.err("scheduling a shutdown from a handler without a correlation id (bug)", .{});
                        }
                        ev.properties.correlation_id = p.correlation_id;
                    }

                    if (@cmpxchgStrong(bool, &self.parent.should_run, true, false, .seq_cst, .acquire)) |_| {
                        return;
                    }

                    _ = self.parent.queue.?.push(ev);
                }
            };

            pub fn scheduler(self: *@This()) Scheduler {
                return .{
                    .parent = self,
                };
            }

            pub fn stop(self: *@This()) void {
                _ = self;
            }

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                _ = self;
                _ = allocator;
            }

            pub fn accepts(e: ET) bool {
                const v = @intFromEnum(e);

                const bounds = comptime blk: {
                    var min: u12 = std.math.maxInt(u12);
                    var max: u12 = std.math.minInt(u12);
                    for (@typeInfo(event.Base).@"enum".fields) |f| {
                        if (min > f.value) min = f.value;
                        if (max < f.value) max = f.value;
                    }

                    break :blk .{ .min = min, .max = max };
                };

                if (v >= bounds.min and v <= bounds.max) {
                    const base_e: event.Base = @enumFromInt(v);
                    switch (base_e) {
                        .noop, .shutdown, .shutdownImminent => false,
                        else => false,
                    }
                }

                return false;
            }

            pub fn watch(
                self: *@This(),
                wg: *std.Thread.WaitGroup,
                pool: *std.Thread.Pool,
                arc: anytype,
            ) anyerror!void {
                _ = self;
                _ = wg;
                _ = pool;
                arc.deinit();
                return;
            }

            pub fn bind(self: *@This(), queue: *MPMCQueue(E)) void {
                self.queue = queue;
            }
        };
    }
};

/// Type-erased handle to the internal driver's scheduler.
///
/// The real `Internal.Yield(ET, EV).Scheduler` is parameterized by the full
/// event union — a type only known in the end-user's program once the driver
/// set is assembled. Framework packages (e.g. pre-built runtime routes) cannot
/// name it, so they depend on this fixed vtable instead. Unlike the AMQP shim,
/// the internal scheduler's inputs carry no route-derived data, so a plain
/// function pointer suffices — no per-route union mapping.
pub const InternalSchedulerShim = struct {
    pub const ShutdownExtra = struct { inj: ?*dep.DepCtx = null };

    _shutdownFn: *const fn (*anyopaque, ShutdownExtra) anyerror!void,
    _ctx: *anyopaque,

    pub fn shutdown(self: @This(), extra: ShutdownExtra) !void {
        return self._shutdownFn(self._ctx, extra);
    }
};

/// Adapts a concrete internal `Scheduler` to the type-erased
/// `InternalSchedulerShim` vtable.
pub fn SchedulerBridge(comptime RealScheduler: type) type {
    return struct {
        real: RealScheduler,

        fn shutdownImpl(ctx: *anyopaque, extra: InternalSchedulerShim.ShutdownExtra) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.real.shutdown(.{ .inj = extra.inj });
        }

        pub fn toShim(self: *@This()) InternalSchedulerShim {
            return .{ ._shutdownFn = &shutdownImpl, ._ctx = @ptrCast(self) };
        }
    };
}

/// DI factory wrapper that lazily builds a `SchedulerBridge` on first request.
/// `shimSchedulerFac` depends on the concrete `RealScheduler`, which the DI
/// system resolves from the `SchedulerCtx` the Server registers in `bind()`.
pub fn BridgeShimCtx(comptime RealScheduler: type) type {
    const BridgeType = SchedulerBridge(RealScheduler);
    return struct {
        bridge: ?BridgeType = null,

        pub fn shimSchedulerFac(self: *@This(), real_sched: RealScheduler) InternalSchedulerShim {
            if (self.bridge == null) {
                self.bridge = .{ .real = real_sched };
            }
            return self.bridge.?.toShim();
        }
    };
}
