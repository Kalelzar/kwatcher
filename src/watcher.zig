const std = @import("std");
const c = std.c;
const json = std.json;
const log = std.log.scoped(.kwatcher);
const amqp = @import("zamqp");

pub const schema = @import("schema.zig");
pub const config = @import("config.zig");
pub const meta = @import("meta.zig");

pub const MessageFactory = struct {
    arena: std.heap.ArenaAllocator,
    persist: std.mem.Allocator,

    name: []const u8,
    client_info: schema.ClientInfo,
    user_info: schema.UserInfo,
    index: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, client_info: schema.ClientInfo, user_info: schema.UserInfo, name: []const u8) !MessageFactory {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();

        const owned_user_info = schema.UserInfo{
            .username = try alloc.dupe(u8, user_info.username),
            .hostname = try alloc.dupe(u8, user_info.hostname),
            .id = try alloc.dupe(u8, user_info.id),
            .allocator = alloc,
        };

        return .{
            .arena = arena,
            .name = name,
            .client_info = client_info,
            .user_info = owned_user_info,
            .persist = alloc,
        };
    }

    pub fn allocator(self: *MessageFactory) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn nextHeartbeat(self: *MessageFactory, comptime Props: type, props: Props) !schema.SendMessage {
        const Schema = schema.Heartbeat.V1(Props);
        const SchemaMessage = schema.Message(Schema);
        const alloc = self.allocator();
        const correlation_id = try self.nextCorrelationId("schema.heartbeat.v1");
        const timestamp = std.time.timestamp();

        const suffix = "/heartbeat";
        const event = try self.allocator().alloc(u8, self.name.len + suffix.len);
        @memcpy(event.ptr, self.name);
        @memcpy(event.ptr + self.name.len, suffix);

        const message: SchemaMessage = .{
            .options = .{
                .queue = "heartbeat",
                .exchange = "amq.direct",
                .routing_key = "heartbeat.consumer",
                .correlation_id = correlation_id,
            },
            .schema = .{
                .timestamp = timestamp,
                .event = event,
                .user = self.user_info.v1(),
                .client = self.client_info.v1(),
                .properties = props,
            },
        };

        return message.prepare(alloc);
    }

    fn nextCorrelationId(self: *MessageFactory, schemaName: []const u8) ![]const u8 {
        const alloc = self.allocator();
        const id = self.index;
        const correlation_id = try std.fmt.allocPrint(
            alloc,
            "{s}-{d:0>5}",
            .{ schemaName, id },
        );
        self.index += 1;
        return correlation_id;
    }

    pub fn deinit(self: *MessageFactory) void {
        self.arena.deinit();
        self.persist.free(self.user_info.hostname);
        self.persist.free(self.user_info.username);
        self.persist.free(self.user_info.id);
    }

    pub fn reset(self: *MessageFactory) void {
        _ = self.arena.reset(std.heap.ArenaAllocator.ResetMode.retain_capacity);
    }
};

pub fn WatcherClient(comptime Config: type) type {
    return struct {
        connection: amqp.Connection,
        socket: amqp.TcpSocket,
        channel: amqp.Channel,
        default_timeout: c.timeval,

        config_file: Config,
        client_info: schema.ClientInfo,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, config_file: Config, client_info: schema.ClientInfo) !WatcherClient(Config) {
            errdefer log.err("Failed to initialize", .{});
            var connection = try amqp.Connection.new();
            errdefer disposeConnection(&connection);

            var timeout = config_file.config.timeout.toTimeval();
            var socket = try amqp.TcpSocket.new(&connection);

            const host = try allocator.dupeZ(u8, config_file.server.host);
            defer allocator.free(host);
            const password = try allocator.dupeZ(u8, config_file.credentials.password);
            defer allocator.free(password);
            const username = try allocator.dupeZ(u8, config_file.credentials.username);
            defer allocator.free(username);

            try socket.open(host, config_file.server.port, &timeout);

            connection.login(
                "/",
                amqp.Connection.SaslAuth{
                    .plain = .{
                        .username = username,
                        .password = password,
                    },
                },
                .{
                    .heartbeat = 5,
                },
            ) catch |err| switch (err) {
                error.ConnectionClosed => {
                    log.err("Failed to login with the given credentials.", .{});
                    return error.AuthFailure;
                },
                else => |leftover| return leftover,
            };

            var channel = amqp.Channel{
                .connection = connection,
                .number = 1,
            };
            const channel_response = try channel.open();
            log.debug("Opened channel '{?s}'", .{channel_response.*.channel_id.slice()});

            return .{
                .allocator = allocator,
                .connection = connection,
                .socket = socket,
                .default_timeout = timeout,
                .channel = channel,
                .config_file = config_file,
                .client_info = client_info,
            };
        }

        pub fn registerQueue(self: *WatcherClient(Config), queue: []const u8, exchange: []const u8, route: []const u8) !void {
            const queue_response = try self.channel.queue_declare(asBytes(queue), .{
                .passive = false,
                .durable = true,
                .exclusive = false,
                .auto_delete = false,
                .arguments = amqp.table_t.empty(),
            });

            const route_bytes = asBytes(route);
            const exchange_bytes = asBytes(exchange);
            try self.channel.queue_bind(
                queue_response.queue,
                exchange_bytes,
                route_bytes,
                amqp.table_t.empty(),
            );
        }

        pub fn deinit(self: *WatcherClient(Config)) void {
            self.info("Closing connection", .{});
            disposeConnection(&self.connection);
        }

        pub fn factory(self: *WatcherClient(Config), name: []const u8) !MessageFactory {
            const user_info = schema.UserInfo.init(self.allocator, self.config_file.user.id);
            defer user_info.deinit();

            const message_factory = MessageFactory.init(self.allocator, self.client_info, user_info, name);
            return message_factory;
        }

        fn send(self: *WatcherClient(Config), message: schema.SendMessage) !void {
            const props = amqp.BasicProperties.init(.{
                .correlation_id = asBytes(message.options.correlation_id),
                .content_type = asBytes("application/json"),
                .delivery_mode = 2,
                .reply_to = asBytes(message.options.queue),
            });
            const route = amqp.bytes_t.init(message.options.routing_key);
            const exchange = amqp.bytes_t.init(message.options.exchange);

            self.info(
                "[{s}] Publishing message to '{?s}':\n\t{s}",
                .{
                    message.options.correlation_id,
                    message.options.queue,
                    message.body,
                },
            );

            try self.channel.basic_publish(
                exchange,
                route,
                asBytes(message.body),
                props,
                .{
                    .mandatory = true,
                    .immediate = false, // Not supported by RabbitMQ
                },
            );
        }

        pub fn heartbeat(self: *WatcherClient(Config), body: schema.SendMessage) !void {
            try self.send(body);
        }

        fn asBytes(str: []const u8) amqp.bytes_t {
            return amqp.bytes_t.init(str);
        }

        fn disposeConnection(connection: *amqp.Connection) void {
            connection.destroy() catch |err| {
                log.err("Could not close connection: {}", .{err});
            };
        }

        fn info(self: *const WatcherClient(Config), comptime format: []const u8, args: anytype) void {
            if (self.config_file.config.debug) {
                log.info(format, args);
            }
        }
    };
}
