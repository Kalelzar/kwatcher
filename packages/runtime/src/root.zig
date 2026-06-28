// kwatcher: the runtime engine. Generic over the driver set, which the consumer
// assembles. Nothing depends on this package — it is a peer leaf of the drivers.

pub const server = @import("server.zig");
pub const default = @import("default.zig");

/// Driver-agnostic middleware shipped with the runtime. (HTTP-specific
/// middleware like CORS lives in the http package.)
pub const middleware = struct {
    pub const latency = @import("latency.zig").WithLatency;
    pub const Latency = @import("latency.zig");
    pub const enable_if = @import("middleware/enable.zig").EnableIf;
};

comptime {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
