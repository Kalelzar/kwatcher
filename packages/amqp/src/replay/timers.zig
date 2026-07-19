const std = @import("std");
const dep = @import("kw-core").deps;

const ReplayShim = @import("shim.zig").ReplayShim;

pub const Replay = struct {
    /// Schedule a replay of any recorded amqp messages.
    /// The scheduled event is a noop if the broker is unreachable.
    pub fn @"amqp_replay 0 */15 * * * *"(inj: *dep.DepCtx) !void {
        const scheduler = try inj.require(ReplayShim);
        try scheduler.replay(.{ .inj = inj });
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
