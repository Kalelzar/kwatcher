const std = @import("std");
const log = std.log.scoped(.kwatcher);

const amqp = @import("zamqp");
const uuid = @import("uuid");

const schema = @import("schema.zig");
const config = @import("config.zig");
const metrics = @import("metrics.zig");

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

    pub fn configureQoS(self: *Channel) !void {
        try self.channel.basic_qos(0, 200, false); // RabbitMQ does not support prefetch_size!=0
    }

    pub fn configureConsume(self: *Channel) !void {
        try self.configureQoS();
        _ = try self.channel.basic_consume(
            amqp.bytes_t.init(self.queue),
            .{
                .no_local = false,
                .no_ack = false,
                .exclusive = false,
                .consumer_tag = amqp.bytes_t.init(self.queue),
            },
        );
    }

    pub fn ack(self: *Channel, delivery_tag: u64) !void {
        return self.channel.basic_ack(delivery_tag, false);
    }

    pub fn reject(self: *Channel, delivery_tag: u64, requeue: bool) !void {
        return self.channel.basic_reject(delivery_tag, requeue);
    }
};

pub const Response = struct {
    routing_key: []const u8,
    exchange: []const u8,
    queue: []const u8,

    consumer_tag: []const u8,
    delivery_tag: u64,
    channel: u16,
    redelivered: bool,
    message: struct {
        basic_properties: amqp.BasicProperties,
        body: []const u8,
    },
};

pub const AmqpClient = struct {
    connection: amqp.Connection,
    socket: amqp.TcpSocket,
    channels: std.StringHashMap(Channel),
    next: u16 = 1,

    pub fn init(allocator: std.mem.Allocator, config_file: config.BaseConfig, name: []const u8) !AmqpClient {
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
        var buf = try allocator.alloc(amqp.table_entry_t, 1);
        defer allocator.free(buf);
        buf[0] = .{
            .key = amqp.bytes_t.init("connection_name"),
            .value = .{ .kind = amqp.AMQP_FIELD_KIND_BYTES, .value = .{ .bytes = amqp.bytes_t.init(name) } },
        };
        const table = amqp.table_t{
            .entries = buf.ptr,
            .num_entries = 1,
        };

        connection.login_with_properties(
            "/",
            amqp.Connection.SaslAuth{
                .plain = .{
                    .username = username,
                    .password = password,
                },
            },
            .{
                .heartbeat = config_file.server.heartbeat,
                .properties = &table,
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

    pub fn openChannel(self: *AmqpClient, exchange: []const u8, queue: []const u8, route: []const u8) !void {
        if (self.channels.contains(queue)) return;

        var amqp_channel = amqp.Channel{
            .connection = self.connection,
            .number = self.next,
        };
        self.next += 1;
        _ = try amqp_channel.open();
        log.info("Opened channel '[{}] {s}/{s}'", .{ self.next - 1, exchange, queue });

        var channel = Channel{
            .channel = amqp_channel,
            .exchange = exchange,
            .queue = queue,
            .route = route,
        };

        try channel.bind();

        try self.channels.put(queue, channel);
        try metrics.addChannel();
        try metrics.addQueue();
    }

    pub fn consume(self: *AmqpClient, timeout: i64) !?Response {
        var timeval = std.c.timeval{
            .sec = 0,
            .usec = @truncate(timeout),
        };
        const envelope = self.connection.consume_message(&timeval, 0) catch |e| switch (e) {
            error.Timeout => return null,
            else => |le| return le,
        };
        return .{
            .channel = envelope.channel,
            .consumer_tag = envelope.consumer_tag.slice() orelse unreachable,
            .queue = envelope.message.properties.get(.reply_to).?.slice() orelse unreachable,
            .delivery_tag = envelope.delivery_tag,
            .exchange = envelope.exchange.slice() orelse unreachable,
            .routing_key = envelope.routing_key.slice() orelse unreachable,
            .redelivered = envelope.redelivered != 0,
            .message = .{
                .basic_properties = envelope.message.properties,
                .body = envelope.message.body.slice() orelse unreachable,
            },
        };
    }

    pub fn reset(self: *AmqpClient) void {
        self.connection.maybe_release_buffers();
    }

    pub fn getChannel(self: *const AmqpClient, queue: []const u8) !*Channel {
        return self.channels.getPtr(queue) orelse error.NotFound;
    }

    pub fn deinit(self: *const AmqpClient) void {
        log.info("Closing connection", .{});
        // This should probably not accept const but oh well.
        // We can close our eyes for now. @constCast my beloved.
        disposeConnection(@constCast(&self.connection));
    }

    fn disposeConnection(connection: *amqp.Connection) void {
        connection.destroy() catch |err| {
            log.err("Could not close connection: {}", .{err});
        };
    }
};
