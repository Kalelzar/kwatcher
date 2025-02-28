const std = @import("std");
const kwatcher = @import("kwatcher");

const P = struct {
    e: A,
};

const A = struct {
    i: i32,
};

const E = enum {
    A,
    B,
};

const TestRoutes = struct {
    pub fn @"PUBLISH:heartbeat amq.direct/heartbeat"(
        user_info: kwatcher.schema.UserInfo,
        client_info: kwatcher.schema.ClientInfo,
        a: A,
    ) kwatcher.schema.Heartbeat.V1(P) {
        return .{
            .event = "TEST",
            .user = user_info.v1(),
            .client = client_info.v1(),
            .properties = .{ .e = a },
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

const SingletonDeps = struct {
    pub fn e() !E {
        if (std.time.timestamp() == 0) {
            return error.DUM;
        }
        return .B;
    }
};

const ScopedDeps = struct {
    a: A,
    pub fn construct(self: *ScopedDeps) void {
        self.a = .{ .i = std.crypto.random.int(i32) };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const deps = SingletonDeps{};
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
        deps,
    );
    try server.run();
    server.deinit();
}
