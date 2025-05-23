const std = @import("std");

const klib = @import("klib");
const meta = klib.meta;

pub const ConfigurableMessageOptions = struct {
    reply_to: ?[]const u8 = null,
    correlation_id: ?[]const u8 = null,
    expiration: ?u64 = null,
};

pub const MessageOptions = meta.MergeStructs(ConfigurableMessageOptions, struct {
    routing_key: []const u8,
    exchange: []const u8,
});

pub fn Message(comptime SchemaT: type) type {
    return struct {
        schema: SchemaT,
        options: ConfigurableMessageOptions,

        pub fn prepare(self: *const Message(SchemaT), allocator: std.mem.Allocator) !SendMessage {
            const body = try std.json.stringifyAlloc(allocator, self.schema, .{});
            return .{
                .body = body,
                .options = self.options,
            };
        }
    };
}

pub const SendMessage = struct {
    body: []const u8,
    options: MessageOptions,
};

fn SchemaUtils(comptime version: u32, comptime name: []const u8) type {
    return struct {
        schema_version: u32 = version,
        schema_name: []const u8 = name,
    };
}

pub fn Schema(comptime version: u32, comptime name: []const u8, comptime T: type) type {
    return meta.MergeStructs(SchemaUtils(version, name), T);
}

pub const User = struct {
    pub const V1 = Schema(
        1,
        "user",
        struct {
            hostname: []const u8,
            username: []const u8,
            id: []const u8,
        },
    );
};

pub const Client = struct {
    pub const V1 = Schema(
        1,
        "client",
        struct {
            version: []const u8,
            name: []const u8,
        },
    );
};

pub const ClientInfo = struct {
    name: []const u8,
    version: []const u8,

    pub fn v1(self: *const ClientInfo) Client.V1 {
        return .{
            .version = self.version,
            .name = self.name,
        };
    }

    pub fn fromV1(sch: *const Client.V1) ClientInfo {
        return .{
            .version = sch.version,
            .name = sch.name,
        };
    }
};

pub const UserInfo = struct {
    hostname: []const u8,
    username: []const u8,
    id: []const u8,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id_override: ?[]const u8) UserInfo {
        return .{
            .hostname = "localhost",
            .username = "Kalelzar",
            .id = id_override orelse "kalelzar",
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const UserInfo) void {
        _ = self;
    }

    pub fn v1(self: *const UserInfo) User.V1 {
        return .{
            .username = self.username,
            .hostname = self.hostname,
            .id = self.id,
        };
    }

    pub fn fromV1(allocator: std.mem.Allocator, sch: *const User.V1) UserInfo {
        return .{
            .username = sch.username,
            .hostname = sch.hostname,
            .id = sch.id,
            .allocator = allocator,
        };
    }
};

pub const Heartbeat = struct {
    pub fn V1(Props: type) type {
        return Schema(
            1,
            "heartbeat",
            struct {
                timestamp: i64,
                event: []const u8,
                user: User.V1,
                client: Client.V1,
                properties: Props,
            },
        );
    }
};

pub const Metrics = struct {
    pub fn V1() type {
        return Schema(
            1,
            "metrics",
            struct {
                timestamp: i64,
                client: Client.V1,
                user: User.V1,
                metrics: []const u8, // In Prometheus format.
            },
        );
    }
};
