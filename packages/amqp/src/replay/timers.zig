const std = @import("std");
const dep = @import("kw-core").deps;

const ReplayShim = @import("shim.zig").ReplayShim;

/// Cron routes that fire an amqp replay pass every 15 minutes. Register on
/// the app's cron driver:
/// `.routes(cron.From(MyRoutes) ++ cron.From(amqp.Replay))`.
/// The handler only needs the `ReplayShim` that `amqp.defaultFor` registers.
pub const Replay = struct {
    pub fn @"amqp_replay 0 */15 * * * *"(inj: *dep.DepCtx) !void {
        const scheduler = try inj.require(ReplayShim);
        try scheduler.replay(.{ .inj = inj });
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
