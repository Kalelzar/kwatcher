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
    clientInfo: schema.ClientInfo,
    userInfo: schema.UserInfo,
    index: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, clientInfo: schema.ClientInfo, userInfo: schema.UserInfo, name: []const u8) !MessageFactory {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();

        const ownedUserInfo = schema.UserInfo{
            .username = try alloc.dupe(u8, userInfo.username),
            .hostname = try alloc.dupe(u8, userInfo.hostname),
            .id = try alloc.dupe(u8, userInfo.id),
            .allocator = alloc,
        };

        return .{
            .arena = arena,
            .name = name,
            .clientInfo = clientInfo,
            .userInfo = ownedUserInfo,
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
        const correlationId = try self.nextCorrelationId("schema.heartbeat.v1");
        const timestamp = std.time.timestamp();

        const suffix = "/heartbeat";
        const event = try self.allocator().alloc(u8, self.name.len + suffix.len);
        @memcpy(event.ptr, self.name);
        @memcpy(event.ptr + self.name.len, suffix);

        const message: SchemaMessage = .{
            .options = .{
                .queue = "heartbeat",
                .exchange = "amq.direct",
                .routingKey = "heartbeat.consumer",
                .correlationId = correlationId,
            },
            .schema = .{
                .timestamp = timestamp,
                .event = event,
                .user = self.userInfo.v1(),
                .client = self.clientInfo.v1(),
                .properties = props,
            },
        };

        return message.prepare(alloc);
    }

    fn nextCorrelationId(self: *MessageFactory, schemaName: []const u8) ![]const u8 {
        const alloc = self.allocator();
        const id = self.index;
        const correlationId = try std.fmt.allocPrint(
            alloc,
            "{s}-{d:0>5}",
            .{ schemaName, id },
        );
        self.index += 1;
        return correlationId;
    }

    pub fn deinit(self: *MessageFactory) void {
        self.arena.deinit();
        self.persist.free(self.userInfo.hostname);
        self.persist.free(self.userInfo.username);
        self.persist.free(self.userInfo.id);
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
        defaultTimeout: c.timeval,

        configFile: Config,
        clientInfo: schema.ClientInfo,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, configFile: Config, clientInfo: schema.ClientInfo) !WatcherClient(Config) {
            errdefer log.err("Failed to initialize", .{});
            var connection = try amqp.Connection.new();
            errdefer disposeConnection(&connection);

            var timeout = configFile.config.timeout.toTimeval();
            var socket = try amqp.TcpSocket.new(&connection);

            const host = try allocator.dupeZ(u8, configFile.server.host);
            defer allocator.free(host);
            const password = try allocator.dupeZ(u8, configFile.credentials.password);
            defer allocator.free(password);
            const username = try allocator.dupeZ(u8, configFile.credentials.username);
            defer allocator.free(username);

            try socket.open(host, configFile.server.port, &timeout);

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
            const channelResponse = try channel.open();
            log.debug("Opened channel '{?s}'", .{channelResponse.*.channel_id.slice()});

            return .{
                .allocator = allocator,
                .connection = connection,
                .socket = socket,
                .defaultTimeout = timeout,
                .channel = channel,
                .configFile = configFile,
                .clientInfo = clientInfo,
            };
        }

        pub fn registerQueue(self: *WatcherClient(Config), queue: []const u8, exchange: []const u8, route: []const u8) !void {
            const queueResponse = try self.channel.queue_declare(asBytes(queue), .{
                .passive = false,
                .durable = true,
                .exclusive = false,
                .auto_delete = false,
                .arguments = amqp.table_t.empty(),
            });

            const routeB = asBytes(route);
            const exchangeB = asBytes(exchange);
            try self.channel.queue_bind(
                queueResponse.queue,
                exchangeB,
                routeB,
                amqp.table_t.empty(),
            );
        }

        pub fn deinit(self: *WatcherClient(Config)) void {
            self.info("Closing connection", .{});
            disposeConnection(&self.connection);
        }

        pub fn factory(self: *WatcherClient(Config), name: []const u8) !MessageFactory {
            const userInfo = schema.UserInfo.init(self.allocator, self.configFile.user.id);
            defer userInfo.deinit();

            const messageFactory = MessageFactory.init(self.allocator, self.clientInfo, userInfo, name);
            return messageFactory;
        }

        fn send(self: *WatcherClient(Config), message: schema.SendMessage) !void {
            const props = amqp.BasicProperties.init(.{
                .correlation_id = asBytes(message.options.correlationId),
                .content_type = asBytes("application/json"),
                .delivery_mode = 2,
                .reply_to = asBytes(message.options.queue),
            });
            const route = amqp.bytes_t.init(message.options.routingKey);
            const exchange = amqp.bytes_t.init(message.options.exchange);

            self.info(
                "[{s}] Publishing message to '{?s}':\n\t{s}",
                .{
                    message.options.correlationId,
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
            if (self.configFile.config.debug) {
                log.info(format, args);
            }
        }
    };
}
