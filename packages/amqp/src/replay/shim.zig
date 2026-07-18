const std = @import("std");
const dep = @import("kw-core").deps;

/// Type-erased handle for queueing an amqp replay pass. Framework code
/// (e.g. exported cron routes) can require this without naming the
/// app-assembled scheduler type. Deliberately separate from
/// `AmqpSchedulerShim`: replay is independent of the publish routes that
/// shim is parameterized over.
pub const ReplayShim = struct {
    pub const ReplayExtra = struct { inj: ?*dep.DepCtx = null };

    _replayFn: *const fn (*anyopaque, ReplayExtra) anyerror!void,
    _ctx: *anyopaque,

    pub fn replay(self: @This(), extra: ReplayExtra) !void {
        return self._replayFn(self._ctx, extra);
    }
};

/// Adapts the real amqp Scheduler's `replay` to the type-erased shim.
pub fn ReplayBridge(comptime RealScheduler: type) type {
    return struct {
        real: RealScheduler,

        fn replayImpl(ctx: *anyopaque, extra: ReplayShim.ReplayExtra) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.real.replay(.{ .inj = extra.inj });
        }

        pub fn toShim(self: *@This()) ReplayShim {
            return .{ ._replayFn = &replayImpl, ._ctx = @ptrCast(self) };
        }
    };
}

/// DI factory wrapper that lazily creates a `ReplayBridge` on first
/// request. The factory method depends on `RealScheduler`, which the DI
/// system resolves from the `SchedulerCtx.schedulerFac` registered by the
/// Server in `bind()`.
pub fn ReplayShimCtx(comptime RealScheduler: type) type {
    const BridgeType = ReplayBridge(RealScheduler);
    return struct {
        bridge: ?BridgeType = null,

        pub fn replayShimFac(self: *@This(), real_sched: RealScheduler) ReplayShim {
            if (self.bridge == null) {
                self.bridge = .{ .real = real_sched };
            }
            return self.bridge.?.toShim();
        }
    };
}

// Ref all decls — the bridge/ctx generics are instantiated concretely by
// `defaultFor` against the app-assembled scheduler.
comptime {
    std.testing.refAllDecls(@This());
}
