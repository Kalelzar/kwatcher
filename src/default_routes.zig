const std = @import("std");
const schema = @import("schema.zig");

pub fn @"publish:metrics amq.direct/metrics"(
    user_info: schema.UserInfo,
    client_info: schema.ClientInfo,
) schema.Metrics.V1() {
    return .{
        .timestamp = std.time.microTimestamp(),
        .user = user_info.v1(),
        .client = client_info.v1(),
        .metrics = "", // TODO: Collect actual metrics. I know. Shocking.
    };
}
