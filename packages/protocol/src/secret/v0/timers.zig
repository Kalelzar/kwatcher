const dep = @import("kw-core").deps;

/// Periodically re-broadcast our registration so stores that started (or
/// lost state) after us still learn our key. Registration is idempotent,
/// so the only cost is a small broadcast every five minutes.
pub fn @"secret_announce 0 */5 * * * *"(inj: *dep.DepCtx) !void {
    const scheduler = try inj.require(@import("secret.zig").Scheduler);
    try scheduler.publish(.{ .@"secret-register" = .{} }, .{ .inj = inj });
}
