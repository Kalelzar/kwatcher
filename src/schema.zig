//! The standard schemas defined for kwatcher clients.
const std = @import("std");

const klib = @import("klib");
const meta = klib.meta;

/// Message options that can be configured from a publishing route (publish/reply)
pub const ConfigurableMessageOptions = struct {
    /// An optional route to which the consumer is expected to respond to.
    reply_to: ?[]const u8 = null,

    /// The correlation id of the message. If left null it will be auto-generated.
    correlation_id: ?[]const u8 = null,

    /// An optional expiration timer for the message.
    expiration: ?u64 = null,
};

/// Message options including non-configurable options defined by the framework.
pub const MessageOptions = meta.MergeStructs(ConfigurableMessageOptions, struct {
    /// The routing key with which to publish the message.
    routing_key: []const u8,

    /// The exchange to which to publish the message.
    exchange: []const u8,

    /// Whether to include the message in recordings.
    norecord: bool,
});

/// A message with configurable options that can be returned from a publishing route.
pub fn Message(comptime SchemaT: type) type {
    return struct {
        /// The body of the message.
        schema: SchemaT,

        /// The configurable options of the message.
        options: ConfigurableMessageOptions,

        /// Prepares the message for sending.
        pub fn prepare(self: *const Message(SchemaT), allocator: std.mem.Allocator) !SendMessage {
            const body = try std.json.stringifyAlloc(allocator, self.schema, .{});
            return .{
                .body = body,
                .options = self.options,
            };
        }
    };
}

/// A message prepared for sending.
pub const SendMessage = struct {
    /// The body of the message.
    body: []const u8,

    /// The options configured for the message including framework-provided options.
    options: MessageOptions,
};

/// A helper for easily creating a valid schema model.
fn SchemaUtils(comptime version: u32, comptime name: []const u8) type {
    return struct {
        /// The version of the schema.
        schema_version: u32 = version,

        /// The name of the schema
        schema_name: []const u8 = name,
    };
}

/// A schema object with a version, name and additional fields.
pub fn Schema(comptime version: u32, comptime name: []const u8, comptime T: type) type {
    return meta.MergeStructs(SchemaUtils(version, name), T);
}

/// The User schema namespace.
pub const User = struct {
    /// Version 1 of the User schema.
    pub const V1 = Schema(
        1,
        "user",
        struct {
            /// The hostname of the machine.
            hostname: []const u8,
            /// The username of the user running the client.
            username: []const u8,
            /// An id that can be used to identify the user. User configurable.
            id: []const u8,
        },
    );
};

/// The Client schema namespace
pub const Client = struct {
    /// Version 1 of the Client schema.
    pub const V1 = Schema(
        1,
        "client",
        struct {
            /// The version of the client.
            version: []const u8,

            /// The name of the client.
            name: []const u8,
        },
    );

    pub const V2 = Schema(
        2,
        "client",
        struct {
            /// The id of the client.
            id: []const u8,

            /// The version of the client.
            version: []const u8,

            /// The name of the client.
            name: []const u8,
        },
    );
};

/// A client-side model for the Client-schema namespace.
/// It follows the latest schema version and has helpers
/// to convert to any other known schema version.
pub const ClientInfo = struct {
    /// The id of the client.
    id: []const u8,

    /// The name of the client.
    name: []const u8,
    /// The version of the client.
    version: []const u8,

    /// Convert to a Client.V1 compatible schema object.
    pub fn v1(self: *const ClientInfo) Client.V1 {
        return .{
            .version = self.version,
            .name = self.name,
        };
    }

    /// Convert to a Client.V2 compatible schema object.
    pub fn v2(self: *const ClientInfo) Client.V2 {
        return .{
            .id = self.id,
            .version = self.version,
            .name = self.name,
        };
    }

    /// Construct from a Client.V1 compatible schema object.
    pub fn fromV1(sch: *const Client.V1, id: []const u8) ClientInfo {
        return .{
            .version = sch.version,
            .name = sch.name,
            .id = id,
        };
    }

    /// Construct from a Client.V2 compatible schema object.
    pub fn fromV2(sch: *const Client.V2) ClientInfo {
        return .{
            .id = sch.id,
            .version = sch.version,
            .name = sch.name,
        };
    }
};

/// A client-side model for the User-schema namespace.
/// It follows the latest schema version and has helpers
/// to convert to any other known schema version.
pub const UserInfo = struct {
    /// The name of the current host.
    hostname: []const u8,
    /// The name of the current user.
    username: []const u8,
    /// An id that can be used to identify the user.
    id: []const u8,

    /// An allocator that owns the user info.
    allocator: std.mem.Allocator,

    /// Initializes a new user with an id override from the user configuration.
    pub fn init(allocator: std.mem.Allocator, id_override: ?[]const u8) !UserInfo {
        const hostname = try klib.host.hostname(allocator);
        const username = try klib.host.username(allocator);

        const id = if (id_override) |id|
            try allocator.dupe(u8, id)
        else
            try std.fmt.allocPrint(allocator, "{s}@{s}", .{ username, hostname });

        return .{
            .hostname = hostname,
            .username = username,
            .id = id,
            .allocator = allocator,
        };
    }

    /// Deinitializes the stored user data.
    pub fn deinit(self: *UserInfo) void {
        self.allocator.free(self.hostname);
        self.allocator.free(self.username);
        self.allocator.free(self.id);
    }

    /// Converts a user info to a User.V1 compatible schema.
    pub fn v1(self: *const UserInfo) User.V1 {
        return .{
            .username = self.username,
            .hostname = self.hostname,
            .id = self.id,
        };
    }

    /// Converts from a User.V1 compatible schema.
    pub fn fromV1(allocator: std.mem.Allocator, sch: *const User.V1) !UserInfo {
        return .{
            .username = try allocator.dupe(u8, sch.username),
            .hostname = try allocator.dupe(u8, sch.hostname),
            .id = try allocator.dupe(u8, sch.id),
            .allocator = allocator,
        };
    }
};

/// The Heartbeat schema namespace.
pub const Heartbeat = struct {
    /// The Heartbeat.V1 schema with a customizable prop schema.
    pub fn V1(Props: type) type {
        return Schema(
            1,
            "heartbeat",
            struct {
                /// The time at the time of publishing
                timestamp: i64,
                /// The name of the event associated with the heartbeat.
                /// See props for more information.
                event: []const u8,
                /// A User.V1 compatible object.
                user: User.V1,
                /// A Client.V1 compatible object.
                client: Client.V1,
                /// A custom schema specific to the event type.
                properties: Props,
            },
        );
    }
};

/// The Metrics schema namespace
pub const Metrics = struct {
    /// The Metrics.V1 schema.
    pub fn V1() type {
        return Schema(
            1,
            "metrics",
            struct {
                /// The time at the time of publishing
                timestamp: i64,

                /// A Client.V1 compatible object.
                client: Client.V1,

                /// A User.V1 compatible object.
                user: User.V1,

                /// The metrics data In plain-text Prometheus format.
                metrics: []const u8,
            },
        );
    }
};
