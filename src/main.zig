const std = @import("std");
const kwatcher = @import("kwatcher");

const P = struct {};

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
            .timestamp = std.time.timestamp(),
        };
    }
};

const EventHandler = struct {
    pub fn heartbeat(timer: kwatcher.server.Timer) !bool {
        return try timer.ready("heartbeat");
    }

    pub fn disabled() bool {
        return false;
    }
};

const ExtraConfig = struct {
    soup: bool,
};

const Deps = struct {};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const deps = Deps{};
    var server = try kwatcher.server.Server(
        "test",
        "0.1.0",
        Deps,
        ExtraConfig,
        TestRoutes,
        EventHandler,
    ).init(
        allocator,
        deps,
    );
    try server.run();
    server.deinit();
}
