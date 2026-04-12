const dep = @import("../../dep.zig");

pub fn @"client_live */5 * * * * *"(inj: *dep.DepCtx) !void {
    const scheduler = try inj.require(@import("client_registration.zig").Scheduler);
    try scheduler.publish(.{ .@"client-heartbeat" = .{} }, .{ .inj = inj });
}
