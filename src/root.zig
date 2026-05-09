// root
pub const schema = @import("schema.zig");
pub const mem = @import("mem/mem.zig");
pub const server = @import("server.zig");
pub const deps = @import("dep.zig");
pub const cache = @import("cache/cache.zig");
pub const event = @import("event.zig");
pub const DriverRegistry = @import("driver.zig").Drivers;
pub const default = @import("default.zig");

// client
pub const Client = @import("client/client.zig");
pub const AmqpClient = @import("client/amqp_client.zig");
pub const LoggingClient = @import("client/logging_client.zig");
pub const CircuitBreakerClient = @import("client/circuit_breaker_client.zig");

// protocol
pub const protocol = @import("protocol/protocol.zig");

// utils
pub const config = @import("utils/config.zig");
pub const metrics = @import("utils/metrics.zig");
pub const InternFmtCache = @import("utils/intern_fmt_cache.zig");
pub const meta = @import("utils/meta.zig");
pub const shared = @import("utils/shared.zig");
pub const queue = @import("utils/queue.zig");
pub const resolver = @import("utils/resolver.zig");

// v2
pub const cron = @import("v2/cron.zig");
pub const amqp = @import("v2/amqp.zig");

pub const http = @import("v2/http.zig");

pub const middleware = struct {
    pub const latency = @import("middleware/latency.zig").WithLatency;
    pub const cors = @import("middleware/cors.zig").WithCors;
    pub const Cors = @import("middleware/cors.zig");
};

comptime {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
