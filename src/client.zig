const std = @import("std");
const log = std.log.scoped(.kwatcher);

const amqp = @import("zamqp");
const uuid = @import("uuid");

const schema = @import("schema.zig");
const config = @import("config.zig");

pub const Channel = struct {
    queue: []const u8,
    route: []const u8,
    exchange: []const u8,
    channel: amqp.Channel,

    pub fn bind(self: *Channel) !void {
        const queue_response = try self.channel.queue_declare(amqp.bytes_t.init(self.queue), .{
            .passive = false,
            .durable = true,
            .exclusive = false,
            .auto_delete = false,
            .arguments = amqp.table_t.empty(),
        });

        const route_bytes = amqp.bytes_t.init(self.route);
        const exchange_bytes = amqp.bytes_t.init(self.exchange);
        try self.channel.queue_bind(
            queue_response.queue,
            exchange_bytes,
            route_bytes,
            amqp.table_t.empty(),
        );
    }

    pub fn publish(self: *Channel, message: schema.SendMessage) !void {
        const cid = uuid.v7.new();
        const urn = uuid.urn.serialize(cid);

        const props = amqp.BasicProperties.init(.{
            .correlation_id = amqp.bytes_t.init(&urn),
            .content_type = amqp.bytes_t.init("application/json"),
            .delivery_mode = 2,
            .reply_to = amqp.bytes_t.init(message.options.queue),
        });
        const route = amqp.bytes_t.init(message.options.routing_key);
        const exchange = amqp.bytes_t.init(message.options.exchange);

        log.info(
            "[{s}] Publishing message to '{?s}':\n\t{s}",
            .{
                &urn,
                message.options.queue,
                message.body,
            },
        );

        try self.channel.basic_publish(
            exchange,
            route,
            amqp.bytes_t.init(message.body),
            props,
            .{
                .mandatory = true,
                .immediate = false, // Not supported by RabbitMQ
            },
        );
    }
};

pub const AmqpClient = struct {
    connection: amqp.Connection,
    socket: amqp.TcpSocket,
    channels: std.StringHashMap(Channel),
    next: u16 = 1,

    pub fn init(allocator: std.mem.Allocator, config_file: config.BaseConfig) !AmqpClient {
        errdefer log.err("Failed to initialize", .{});
        const channel_map = std.StringHashMap(Channel).init(allocator);

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

        return .{
            .connection = connection,
            .socket = socket,
            .channels = channel_map,
        };
    }

    pub fn openChannel(self: *AmqpClient, exchange: []const u8, queue: []const u8) !void {
        var amqp_channel = amqp.Channel{
            .connection = self.connection,
            .number = self.next,
        };
        self.next += 1;
        _ = try amqp_channel.open();
        log.debug("Opened channel '[{}] {s}/{s}'", .{ self.next - 1, exchange, queue });

        var channel = Channel{
            .channel = amqp_channel,
            .exchange = exchange,
            .queue = queue,
            .route = "default",
        };

        try channel.bind();

        try self.channels.put(queue, channel);
    }

    pub fn getChannel(self: *const AmqpClient, queue: []const u8) !*Channel {
        return self.channels.getPtr(queue) orelse error.NotFound;
    }

    pub fn deinit(self: *const AmqpClient) void {
        log.info("Closing connection", .{});
        disposeConnection(@constCast(&self.connection));
    }

    fn disposeConnection(connection: *amqp.Connection) void {
        connection.destroy() catch |err| {
            log.err("Could not close connection: {}", .{err});
        };
    }
};
