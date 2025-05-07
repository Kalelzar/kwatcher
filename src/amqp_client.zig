const std = @import("std");
const log = std.log.scoped(.kwatcher);

const amqp = @import("zamqp");
const uuid = @import("uuid");

const schema = @import("schema.zig");
const config = @import("config.zig");
const metrics = @import("metrics.zig");
const Client = @import("client.zig");
const Channel = @import("channel.zig");

const AmqpClient = @This();

pub const AmqpChannel = struct {
    queue: []const u8,
    route: []const u8,
    exchange: []const u8,
    achannel: amqp.Channel,

    fn bind(ptr: *anyopaque) !void {
        const self: *AmqpChannel = @ptrCast(@alignCast(ptr));
        const queue_response = try self.achannel.queue_declare(amqp.bytes_t.init(self.queue), .{
            .passive = false,
            .durable = true,
            .exclusive = false,
            .auto_delete = false,
            .arguments = amqp.table_t.empty(),
        });

        const route_bytes = amqp.bytes_t.init(self.route);
        const exchange_bytes = amqp.bytes_t.init(self.exchange);
        try self.achannel.queue_bind(
            queue_response.queue,
            exchange_bytes,
            route_bytes,
            amqp.table_t.empty(),
        );
    }

    fn publish(ptr: *anyopaque, message: schema.SendMessage) !void {
        const self: *AmqpChannel = @ptrCast(@alignCast(ptr));
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

        try self.achannel.basic_publish(
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

    fn configureQoS(self: *AmqpChannel) !void {
        try self.achannel.basic_qos(0, 200, false); // RabbitMQ does not support prefetch_size!=0
    }

    fn configureConsume(ptr: *anyopaque) !void {
        const self: *AmqpChannel = @ptrCast(@alignCast(ptr));
        try self.configureQoS();
        _ = try self.achannel.basic_consume(
            amqp.bytes_t.init(self.queue),
            .{
                .no_local = false,
                .no_ack = false,
                .exclusive = false,
                .consumer_tag = amqp.bytes_t.init(self.queue),
            },
        );
    }

    fn ack(ptr: *anyopaque, delivery_tag: u64) !void {
        const self: *AmqpChannel = @ptrCast(@alignCast(ptr));
        return self.achannel.basic_ack(delivery_tag, false);
    }

    fn reject(ptr: *anyopaque, delivery_tag: u64, requeue: bool) !void {
        const self: *AmqpChannel = @ptrCast(@alignCast(ptr));
        return self.achannel.basic_reject(delivery_tag, requeue);
    }

    pub fn channel(self: *AmqpChannel) Channel {
        return .{
            .ptr = self,
            .vtable = &.{
                .bind = bind,
                .configureConsume = configureConsume,
                .publish = publish,
                .ack = ack,
                .reject = reject,
            },
        };
    }
};

connection: amqp.Connection,
socket: amqp.TcpSocket,
channels: std.StringHashMap(AmqpChannel),
next: u16 = 1,

pub fn init(allocator: std.mem.Allocator, config_file: config.BaseConfig, name: []const u8) !AmqpClient {
    return connect_inner(allocator, config_file, name);
}

pub fn connect(ptr: *anyopaque, allocator: std.mem.Allocator, config_file: config.BaseConfig, name: []const u8) !void {
    var self: *AmqpClient = @ptrCast(@alignCast(ptr));
    const temp = try connect_inner(allocator, config_file, name);
    self.channels = temp.channels;
    self.socket = temp.socket;
    self.connection = temp.connection;
}

fn connect_inner(allocator: std.mem.Allocator, config_file: config.BaseConfig, name: []const u8) !AmqpClient {
    errdefer log.err("Failed to initialize", .{});
    const channel_map = std.StringHashMap(AmqpChannel).init(allocator);

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
        .socket = socket,
        .channels = channel_map,
        .connection = connection,
    };
}

pub fn openChannel(ptr: *anyopaque, exchange: []const u8, queue: []const u8, route: []const u8) !void {
    var self: *AmqpClient = @ptrCast(@alignCast(ptr));
    if (self.channels.contains(queue)) return;

    var amqp_channel = amqp.Channel{
        .connection = self.connection,
        .number = self.next,
    };
    self.next += 1;
    _ = try amqp_channel.open();
    log.info("Opened channel '[{}] {s}/{s}'", .{ self.next - 1, exchange, queue });

    var channel = AmqpChannel{
        .achannel = amqp_channel,
        .exchange = exchange,
        .queue = queue,
        .route = route,
    };

    try channel.channel().bind();

    try self.channels.put(queue, channel);
    try metrics.addChannel();
    try metrics.addQueue();
}

pub fn consume(ptr: *anyopaque, alloc: std.mem.Allocator, timeout: i64) !?Client.Response {
    var self: *AmqpClient = @ptrCast(@alignCast(ptr));
    var timeval = std.c.timeval{
        .sec = 0,
        .usec = @truncate(timeout),
    };
    var envelope = self.connection.consume_message(&timeval, 0) catch |e| switch (e) {
        error.Timeout => return null,
        else => |le| return le,
    };
    defer envelope.destroy();
    return .{
        .channel = envelope.channel,
        .consumer_tag = try alloc.dupe(u8, envelope.consumer_tag.slice() orelse unreachable),
        .queue = try alloc.dupe(u8, envelope.message.properties.get(.reply_to).?.slice() orelse unreachable),
        .delivery_tag = envelope.delivery_tag,
        .exchange = try alloc.dupe(u8, envelope.exchange.slice() orelse unreachable),
        .routing_key = try alloc.dupe(u8, envelope.routing_key.slice() orelse unreachable),
        .redelivered = envelope.redelivered != 0,
        .message = .{
            .basic_properties = envelope.message.properties,
            .body = try alloc.dupe(u8, envelope.message.body.slice() orelse unreachable),
        },
    };
}

pub fn reset(ptr: *anyopaque) void {
    var self: *AmqpClient = @ptrCast(@alignCast(ptr));
    self.connection.maybe_release_buffers();
}

pub fn getChannel(ptr: *anyopaque, queue: []const u8) !Channel {
    const self: *AmqpClient = @ptrCast(@alignCast(ptr));
    if (self.channels.getPtr(queue)) |chptr| {
        return chptr.channel();
    } else return error.NotFound;
}

pub fn deinit(ptr: *anyopaque) void {
    var self: *AmqpClient = @ptrCast(@alignCast(ptr));
    log.info("Closing connection", .{});
    self.channels.deinit();
    disposeConnection(&self.connection);
}

fn disposeConnection(connection: *amqp.Connection) void {
    connection.destroy() catch |err| {
        log.err("Could not close connection: {}", .{err});
    };
}

pub fn client(self: *AmqpClient) Client {
    return .{
        .vtable = &.{
            .connect = connect,
            .openChannel = openChannel,
            .consume = consume,
            .reset = reset,
            .getChannel = getChannel,
            .deinit = deinit,
        },
        .ptr = self,
    };
}
