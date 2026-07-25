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

                /// Pushes a prebuilt composed event onto the server queue.
                /// The event was fully built earlier (correlation stamped at
                /// build time by callLater/publishLater); nothing is
                /// re-stamped here. Returns error.WouldBlock if the queue
                /// stays full for ~1ms — the event is by value, so the
                /// caller loses nothing on failure.
                pub fn enqueue(self: @This(), ev: E) !void {
                    _ = try self.parent.queue.?.tryPush(ev, std.time.ns_per_ms);
                }

                /// Type-erased variant for callers holding a heap-allocated
                /// `*E` as `*anyopaque`. ALWAYS consumes the pointer: on
                /// success the event is copied onto the queue; on a full
                /// queue it is warned and dropped. Either way
                /// `extra.allocator` — the allocator that created the
                /// pointer, in practice the persistent app allocator —
                /// frees it.
                pub fn enqueueIndirect(
                    self: @This(),
                    ptr: *anyopaque,
                    extra: struct { allocator: std.mem.Allocator },
                ) void {
                    const ev: *E = @ptrCast(@alignCast(ptr));
                    defer extra.allocator.destroy(ev);
                    _ = self.parent.queue.?.tryPush(ev.*, std.time.ns_per_ms) catch {
                        std.log.warn("Event queue full; pending event dropped.", .{});
                    };
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
                deps: anytype,
                allocator: std.mem.Allocator,
            ) anyerror!void {
                _ = self;
                _ = wg;
                _ = pool;
                _ = deps;
                _ = allocator;
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
    pub const EnqueueExtra = struct { allocator: std.mem.Allocator };

    _shutdownFn: *const fn (*anyopaque, ShutdownExtra) anyerror!void,
    _enqueueIndirectFn: *const fn (*anyopaque, *anyopaque, EnqueueExtra) void,
    _ctx: *anyopaque,

    pub fn shutdown(self: @This(), extra: ShutdownExtra) !void {
        return self._shutdownFn(self._ctx, extra);
    }

    /// Copies the pointed-to composed event onto the server queue and
    /// frees the pointer with `extra.allocator`; on a full queue the
    /// event is warned and dropped, but the pointer is still freed.
    pub fn enqueueIndirect(self: @This(), ptr: *anyopaque, extra: EnqueueExtra) void {
        return self._enqueueIndirectFn(self._ctx, ptr, extra);
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

        fn enqueueIndirectImpl(
            ctx: *anyopaque,
            ptr: *anyopaque,
            extra: InternalSchedulerShim.EnqueueExtra,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.real.enqueueIndirect(ptr, .{ .allocator = extra.allocator });
        }

        pub fn toShim(self: *@This()) InternalSchedulerShim {
            return .{
                ._shutdownFn = &shutdownImpl,
                ._enqueueIndirectFn = &enqueueIndirectImpl,
                ._ctx = @ptrCast(self),
            };
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

// Mirrors the app-side composition (driver.zig EventValues()): the internal
// driver's events sit under an `internal` union arm keyed by driver key,
// which `shutdown`'s @unionInit relies on.
const TestEV = union(enum) { internal: event.BaseValues };
const TestYield = Internal.Yield(event.Base, TestEV);
const TestE = event.Event(event.Base, TestEV);

fn testQueue(buffer: []TestE, occupancy: []u1) MPMCQueue(TestE) {
    return MPMCQueue(TestE).init(buffer, occupancy);
}

test "enqueue pushes a prebuilt event as-is" {
    var buf: [2]TestE = undefined;
    var occ: [2]u1 = undefined;
    var q = testQueue(&buf, &occ);
    var yield = TestYield.init();
    yield.bind(&q);

    var ev = TestE{ .event_type = .noop, .event_data = .{ .internal = .{ .noop = .{} } } };
    ev.properties.attempts = 3;
    try yield.scheduler().enqueue(ev);

    try std.testing.expectEqual(ev, q.pop());
    try std.testing.expect(q.empty());
}

test "enqueue on a full queue returns WouldBlock" {
    var buf: [2]TestE = undefined;
    var occ: [2]u1 = undefined;
    var q = testQueue(&buf, &occ);
    var yield = TestYield.init();
    yield.bind(&q);

    const ev = TestE{ .event_type = .noop, .event_data = .{ .internal = .{ .noop = .{} } } };
    try yield.scheduler().enqueue(ev);
    try yield.scheduler().enqueue(ev);
    try std.testing.expectError(error.WouldBlock, yield.scheduler().enqueue(ev));
}

test "enqueueIndirect consumes the pointer and pushes a copy" {
    var buf: [2]TestE = undefined;
    var occ: [2]u1 = undefined;
    var q = testQueue(&buf, &occ);
    var yield = TestYield.init();
    yield.bind(&q);

    const ptr = try std.testing.allocator.create(TestE);
    ptr.* = .{ .event_type = .shutdownImminent, .event_data = .{ .internal = .{ .shutdownImminent = .{} } } };
    const expected = ptr.*;

    yield.scheduler().enqueueIndirect(@ptrCast(ptr), .{ .allocator = std.testing.allocator });

    // std.testing.allocator's leak check proves the pointer was freed.
    try std.testing.expectEqual(expected, q.pop());
    try std.testing.expect(q.empty());
}

test "enqueueIndirect on a full queue drops the event but still frees" {
    var buf: [2]TestE = undefined;
    var occ: [2]u1 = undefined;
    var q = testQueue(&buf, &occ);
    var yield = TestYield.init();
    yield.bind(&q);

    const filler = TestE{ .event_type = .noop, .event_data = .{ .internal = .{ .noop = .{} } } };
    try yield.scheduler().enqueue(filler);
    try yield.scheduler().enqueue(filler);

    const ptr = try std.testing.allocator.create(TestE);
    ptr.* = .{ .event_type = .shutdown, .event_data = .{ .internal = .{ .shutdown = .{} } } };
    yield.scheduler().enqueueIndirect(@ptrCast(ptr), .{ .allocator = std.testing.allocator });

    try std.testing.expectEqual(filler, q.pop());
    try std.testing.expectEqual(filler, q.pop());
    try std.testing.expect(q.empty());
}

test "shim enqueueIndirect routes through the bridge" {
    var buf: [2]TestE = undefined;
    var occ: [2]u1 = undefined;
    var q = testQueue(&buf, &occ);
    var yield = TestYield.init();
    yield.bind(&q);

    var bridge = SchedulerBridge(TestYield.Scheduler){ .real = yield.scheduler() };
    const shim = bridge.toShim();

    const ptr = try std.testing.allocator.create(TestE);
    ptr.* = .{ .event_type = .noop, .event_data = .{ .internal = .{ .noop = .{} } } };
    const expected = ptr.*;

    shim.enqueueIndirect(@ptrCast(ptr), .{ .allocator = std.testing.allocator });

    try std.testing.expectEqual(expected, q.pop());
    try std.testing.expect(q.empty());
}
