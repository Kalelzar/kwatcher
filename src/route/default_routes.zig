const std = @import("std");

const schema = @import("../schema.zig");
const mem = @import("../mem.zig");

const metrics = @import("../utils/metrics.zig");

pub fn @"publish!:metrics amq.direct/metrics"(
    user_info: schema.UserInfo,
    client_info: schema.ClientInfo,
    arena: *mem.InternalArena,
) !schema.Metrics.V1() {
    return metrics.v1(arena.allocator(), client_info.v1(), user_info.v1());
}
