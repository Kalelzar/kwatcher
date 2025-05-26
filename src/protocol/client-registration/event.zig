const Timer = @import("../../timer.zig");
const ClientRegistry = @import("registry.zig");

pub fn announce(timer: Timer, cr: *ClientRegistry) !bool {
    return cr.state != .registered and try timer.ready("announce");
}

pub fn heartbeat(timer: Timer, cr: *ClientRegistry) !bool {
    return cr.state == .registered and try timer.ready("heartbeat");
}
