const std = @import("std");
const kwatcher = @import("kwatcher");

const P = struct {};

pub const AfkStatus = enum {
    Active,
    Inactive,
};

pub const StatusDiff = struct {
    prev: AfkStatus,
    current: AfkStatus,
    timestamp: i64,
};

pub const AfkStatusChangeProperties = kwatcher.schema.Schema(
    1,
    "afk.status-change",
    struct {
        diff: StatusDiff,
    },
);

pub const AfkStatusChange = kwatcher.schema.Heartbeat.V1(AfkStatusChangeProperties);

const TestRoutes = struct {
    pub fn @"PUBLISH:heartbeat amq.direct/heartbeat"(
        user_info: kwatcher.schema.UserInfo,
        client_info: kwatcher.schema.ClientInfo,
    ) kwatcher.schema.Heartbeat.V1(P) {
        return .{
            .event = "TEST",
            .user = user_info.v1(),
            .client = client_info.v1(),
            .properties = .{},
            .timestamp = std.time.microTimestamp(),
        };
    }

    pub fn @"CONSUME amq.direct/afk-status"(change: AfkStatusChange, deps: *SingletonDeps) void {
        std.log.debug(
            "[{}]: Status changed {} -> {}",
            .{ change.timestamp, change.properties.diff.prev, change.properties.diff.current },
        );
        deps.status = change.properties.diff.current;
    }
};

const EventHandler = struct {
    pub fn heartbeat(timer: kwatcher.server.Timer, status: AfkStatus) !bool {
        if (status == .Inactive) return false;
        return try timer.ready("heartbeat");
    }

    pub fn disabled() bool {
        return false;
    }
};

const ExtraConfig = struct {
    soup: bool,
};

const SingletonDeps = struct {
    status: AfkStatus = AfkStatus.Active,
};

const ScopedDeps = struct {};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var deps = SingletonDeps{};
    var server = try kwatcher.server.Server(
        "test",
        "0.1.0",
        SingletonDeps,
        ScopedDeps,
        ExtraConfig,
        TestRoutes,
        EventHandler,
    ).init(
        allocator,
        &deps,
    );
    try server.start();
    server.deinit();
}
