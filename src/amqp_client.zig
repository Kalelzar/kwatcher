const std = @import("std");
const log = std.log.scoped(.amqp_client);

const amqp = @import("zamqp");
const uuid = @import("uuid");

const schema = @import("schema.zig");
const config = @import("config.zig");
const metrics = @import("metrics.zig");
const Client = @import("client.zig");

/// A client for receiving and sending messages over the Advanced Message Queue Protocol (0_9_1)
const AmqpClient = @This();

/// Errors related to state.
pub const StateError = error{ InvalidState, StateCorrupted };

/// Errors related to authorization
pub const AuthError = error{AuthFailed};

/// Errors related to memory and allocations.
pub const MemError = std.mem.Allocator.Error;

/// Errors related to AMQP
pub const AmqpError = amqp.Error;

/// The possible states of the client
pub const State = enum {
    connected, //< A client that is connected
    disconnected, //< A client that isn't connected.
    invalid, //< A client in an invalid state.
};

/// Data related to the active connection.
const Connection = struct {
    this: amqp.Connection,
    socket: amqp.TcpSocket,
    channels: std.StringHashMapUnmanaged(amqp.Channel),
    counter: u16 = 1,

    /// While the underlying AMQP library is not thread-safe
    /// this client allows multiple threads to access the same client
    /// by synchronizing their access. Ideally you would just use a new connection per thread.
    lock: std.Thread.Mutex = .{},

    /// Initializes a new amqp connection.
    /// @borrow name
    /// @borrow configuration
    /// @borrow allocator
    pub fn init(allocator: std.mem.Allocator, configuration: config.BaseConfig, name: []const u8) (MemError || AuthError || AmqpError)!Connection {
        log.info("Initializing client .{s}", .{name});
        const channel_map = std.StringHashMapUnmanaged(amqp.Channel){};

        // Setup
        var timeout = configuration.config.timeout.toTimeval();
        const host = try allocator.dupeZ(u8, configuration.server.host);
        defer allocator.free(host);
        const password = try allocator.dupeZ(u8, configuration.credentials.password);
        defer allocator.free(password);
        const username = try allocator.dupeZ(u8, configuration.credentials.username);
        defer allocator.free(username);

        var buf = try allocator.alloc(amqp.table_entry_t, 1);
        defer allocator.free(buf);

        buf[0] = .{
            .key = amqp.bytes_t.init("connection_name"),
            .value = .{
                .kind = amqp.AMQP_FIELD_KIND_BYTES,
                .value = .{
                    .bytes = amqp.bytes_t.init(name),
                },
            },
        };

        const table = amqp.table_t{
            .entries = buf.ptr,
            .num_entries = 1,
        };

        // Open the connection
        log.debug("Opening connection", .{});
        var connection = try open();
        errdefer close(&connection);

        // Open the socket
        log.debug("Opening socket", .{});
        var socket = try amqp.TcpSocket.new(&connection);
        try socket.open(host, configuration.server.port, &timeout);

        // Authenticate
        log.debug("Authenticating...", .{});
        connection.login_with_properties(
            "/",
            amqp.Connection.SaslAuth{
                .plain = .{
                    .username = username,
                    .password = password,
                },
            },
            .{
                .heartbeat = configuration.server.heartbeat,
                .properties = &table,
            },
        ) catch |err| switch (err) {
            error.ConnectionClosed => {
                log.err("Failed to login with the given credentials.", .{});
                return error.AuthFailed;
            },
            else => |leftover| return leftover,
        };

        return .{
            .channels = channel_map,
            .socket = socket,
            .this = connection,
        };
    }

    /// Open a new amqp connection.
    /// @note This allocates memory outside of zig allocator space (via C malloc)
    //        Each open() MUST have a matching close()!
    fn open() error{OutOfMemory}!amqp.Connection {
        return amqp.Connection.new();
    }

    fn close(conn: *amqp.Connection) void {
        conn.close(.REPLY_SUCCESS) catch |e| {
            log.warn("Received an error '{}' while closing amqp connection.", .{e});
        };
        conn.destroy() catch |e| {
            log.warn("Received an error '{}' while destroying amqp connection.", .{e});
        };
    }

    pub fn openChannel(self: *Connection, allocator: std.mem.Allocator, channel_name: []const u8) !void {
        // We lock before the lookup to avoid a race condition where two threads attempt to create a channel
        // with the same name simultainously.
        self.lock.lock();
        defer self.lock.unlock();
        if (self.channels.contains(channel_name)) return;

        log.debug("Opening channel: {s} = {}", .{ channel_name, self.counter });
        var amqp_channel = amqp.Channel{
            .connection = self.this,
            .number = self.counter,
        };

        _ = try amqp_channel.open();
        log.info("Opened channel: {s} = {}", .{ channel_name, self.counter });
        self.counter += 1;

        try amqp_channel.basic_qos(0, 200, false);

        log.debug("Configured prefetch for {s}.", .{channel_name});

        try self.channels.put(allocator, channel_name, amqp_channel);
        try metrics.addChannel();
    }

    pub fn closeChannel(self: *Connection, channel_name: []const u8) !void {
        // We lock before the lookup to avoid a race condition where two threads attempt to create a channel
        // with the same name simultainously.
        self.lock.lock();
        defer self.lock.unlock();
        if (self.channels.fetchRemove(channel_name)) |entry| {
            try entry.value.close(.REPLY_SUCCESS);
        }
    }

    pub fn declareQueue(
        self: *Connection,
        queue: ?[]const u8,
        extra: struct {
            passive: bool = false,
            durable: bool = false,
            exclusive: bool = false,
            auto_delete: bool = false,
            arguments: amqp.table_t = amqp.table_t.empty(),
        },
    ) ![]const u8 {
        self.lock.lock();
        defer self.lock.unlock();

        const rpc_channel = self.channels.get("__rpc") orelse return error.StateCorrupted;

        const queue_bytes = if (queue) |q| amqp.bytes_t.init(q) else amqp.bytes_t.empty();

        const response = try rpc_channel.queue_declare(queue_bytes, .{
            .passive = extra.passive,
            .durable = extra.durable,
            .exclusive = extra.exclusive,
            .auto_delete = extra.auto_delete,
            .arguments = extra.arguments,
        });

        return response.queue.slice() orelse unreachable;
    }

    pub fn bind(
        self: *Connection,
        queue: []const u8,
        route: []const u8,
        exchange: []const u8,
        opts: Client.ChannelOpts,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const rpc_channel = self.channels.get(opts.channel_name orelse "__consume") orelse return error.StateCorrupted;

        const queue_bytes = amqp.bytes_t.init(queue);
        const route_bytes = amqp.bytes_t.init(route);
        const exchange_bytes = amqp.bytes_t.init(exchange);

        try rpc_channel.queue_bind(
            queue_bytes,
            exchange_bytes,
            route_bytes,
            amqp.table_t.empty(),
        );

        _ = try rpc_channel.basic_consume(queue_bytes, .{
            .no_local = false,
            .no_ack = false,
            .exclusive = false,
            .consumer_tag = route_bytes,
        });
    }

    pub fn publish(
        self: *Connection,
        body: []const u8,
        exchange: []const u8,
        routing_key: []const u8,
        props: amqp.BasicProperties,
        opts: Client.ChannelOpts,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const route_bytes = amqp.bytes_t.init(routing_key);
        const exchange_bytes = amqp.bytes_t.init(exchange);
        const body_bytes = amqp.bytes_t.init(body);

        const rpc_channel = self.channels.get(opts.channel_name orelse "__publish") orelse return error.StateCorrupted;

        try rpc_channel.basic_publish(
            exchange_bytes,
            route_bytes,
            body_bytes,
            props,
            .{ .mandatory = true, .immediate = false },
        );
    }

    pub fn consume(self: *Connection, timeout: i64) !?Client.Response {
        self.lock.lock();
        defer self.lock.unlock();
        var timeval = std.c.timeval{
            .sec = 0,
            .usec = @truncate(timeout),
        };
        var envelope = self.this.consume_message(&timeval, 0) catch |e| switch (e) {
            error.Timeout => return null,
            else => |le| return le,
        };

        const response: Client.Response = .{
            .consumer_tag = envelope.consumer_tag.slice() orelse unreachable,
            .delivery_tag = envelope.delivery_tag,
            .exchange = envelope.exchange.slice() orelse unreachable,
            .routing_key = envelope.routing_key.slice() orelse unreachable,
            .redelivered = envelope.redelivered != 0,
            .message = .{
                .basic_properties = envelope.message.properties,
                .body = envelope.message.body.slice() orelse unreachable,
            },
            // We pass the envelope up so that our user can .destroy() it when they no longer need it
            .envelope = envelope,
        };

        log.info(
            "[{}] Consumed a message on {s} from {s}/{s}:\n\t{s}",
            .{
                response.delivery_tag,
                response.consumer_tag,
                response.exchange,
                response.routing_key,
                response.message.body,
            },
        );

        return response;
    }

    pub fn reset(self: *Connection) void {
        self.this.maybe_release_buffers();
    }

    pub fn ack(
        self: *Connection,
        delivery_tag: u64,
        opts: Client.ChannelOpts,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();
        const rpc_channel = self.channels.get(opts.channel_name orelse "__consume") orelse return error.StateCorrupted;
        try rpc_channel.basic_ack(delivery_tag, false);
    }

    pub fn reject(
        self: *Connection,
        delivery_tag: u64,
        requeue: bool,
        opts: Client.ChannelOpts,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();
        const rpc_channel = self.channels.get(opts.channel_name orelse "__consume") orelse return error.StateCorrupted;
        try rpc_channel.basic_reject(delivery_tag, requeue);
    }

    pub fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        self.lock.lock();
        defer self.lock.unlock();

        var channelIt = self.channels.iterator();

        while (channelIt.next()) |channel| {
            channel.value_ptr.close(.REPLY_SUCCESS) catch |e| {
                log.warn("Failed to close channel '{s}' with error {}.", .{ channel.key_ptr.*, e });
            };
        }

        self.channels.deinit(allocator);

        close(&self.this);
    }
};

/// The current state of the client.
state: State,

/// The user configuration applied to the client.
configuration: config.BaseConfig,

/// An allocator used to allocate internal resources for the lifetime of the client.
/// @lifetime The allocator needs to outlive the client.
allocator: std.mem.Allocator,

/// The name of this client.
/// @lifetime From client initialization to client deinitialization.
/// @ownership `AmqpClient` instance
name: []const u8,

/// The current connection or null if disconnected.
connection: ?*Connection = null,

/// The client lock.
mutex: std.Thread.Mutex.Recursive = .init,

/// Ensure that the current state matches the provided state or fail with `StateErrror.InvalidState`
fn ensureState(self: *AmqpClient, state: State) StateError!void {
    if (self.state != state) return StateError.InvalidState;
}

/// Initializes a new empty client in a disconnected state.
/// @borrow allocator
/// @borrow configuration
/// @own name
pub fn init(allocator: std.mem.Allocator, configuration: config.BaseConfig, name: []const u8) MemError!AmqpClient {
    const own_name = try allocator.dupe(u8, name);
    return .{
        .allocator = allocator,
        .configuration = configuration,
        .name = own_name,
        .state = .disconnected,
    };
}

pub fn deinit(self: *AmqpClient) void {
    self.allocator.free(self.name);
    if (self.connection) |conn| {
        conn.deinit(self.allocator);
        self.connection = null;
    }
    self.state = .invalid;
}

pub fn reset(ptr: *anyopaque) void {
    const self = getSelf(ptr);
    if (self.connection) |conn| {
        conn.reset();
    }
}

pub fn connect(ptr: *anyopaque) !void {
    var self = getSelf(ptr);
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.ensureState(.disconnected);

    if (self.connection) |existing| {
        log.warn("Cleaning up existing connection! Client '{s}' state is invalid.", .{self.name});
        existing.deinit(self.allocator);
        self.allocator.destroy(existing);
    }

    const cptr = try self.allocator.create(Connection);
    errdefer self.allocator.destroy(cptr);
    cptr.* = try Connection.init(self.allocator, self.configuration, self.name);
    self.connection = cptr;
    self.state = .connected;

    openChannel(self, "__rpc") catch |e| try self.handleDisconnect(e, cptr);
    openChannel(self, "__publish") catch |e| try self.handleDisconnect(e, cptr);
    openChannel(self, "__consume") catch |e| try self.handleDisconnect(e, cptr);
}

fn ensureConnected(self: *AmqpClient) StateError!*Connection {
    try self.ensureState(.connected);
    return self.connection orelse error.StateCorrupted;
}

pub fn disconnect(ptr: *anyopaque) StateError!void {
    var self = getSelf(ptr);
    self.mutex.lock();
    defer self.mutex.unlock();
    var conn = try self.ensureConnected();

    conn.deinit(self.allocator);
    self.connection = null;
    self.state = .disconnected;
}

pub fn openChannel(ptr: *anyopaque, name: []const u8) !void {
    var self = getSelf(ptr);
    var conn = try self.ensureConnected();
    conn.openChannel(self.allocator, name) catch |e| try self.handleDisconnect(e, conn);
}

pub fn closeChannel(ptr: *anyopaque, name: []const u8) !void {
    var self = getSelf(ptr);
    var conn = try self.ensureConnected();

    conn.closeChannel(name) catch |e| try self.handleDisconnect(e, conn);
}

pub fn declareEphemeralQueue(ptr: *anyopaque) ![]const u8 {
    var self = getSelf(ptr);
    var conn = try self.ensureConnected();

    return conn.declareQueue(null, .{
        .passive = false,
        .durable = false,
        .exclusive = true,
        .auto_delete = true,
        .arguments = amqp.table_t.empty(),
    }) catch |e| {
        try self.handleDisconnect(e, conn);
        unreachable;
    };
}

pub fn declareDurableQueue(ptr: *anyopaque, queue: []const u8) ![]const u8 {
    var self = getSelf(ptr);
    var conn = try self.ensureConnected();

    return conn.declareQueue(queue, .{
        .passive = false,
        .durable = true,
        .exclusive = false,
        .auto_delete = false,
        .arguments = amqp.table_t.empty(),
    }) catch |e| {
        try self.handleDisconnect(e, conn);
        unreachable;
    };
}

pub fn bind(
    ptr: *anyopaque,
    queue: ?[]const u8,
    route: []const u8,
    exchange: []const u8,
    opts: Client.ChannelOpts,
) !void {
    var self = getSelf(ptr);
    var conn = try self.ensureConnected();

    const declared_queue =
        if (queue) |q|
            try declareDurableQueue(self, q)
        else
            try declareEphemeralQueue(self);

    conn.bind(
        declared_queue,
        route,
        exchange,
        opts,
    ) catch |e| try self.handleDisconnect(e, conn);

    log.info("Binding {s}/{s} to queue {s} on channel {s}.", .{
        exchange,
        route,
        declared_queue,
        opts.channel_name orelse "__consume",
    });
}

pub fn consume(ptr: *anyopaque, timeout: i64) !?Client.Response {
    var self = getSelf(ptr);
    var conn = try self.ensureConnected();

    return conn.consume(timeout) catch |e| {
        try self.handleDisconnect(e, conn);
        unreachable;
    };
}

pub fn ack(
    ptr: *anyopaque,
    delivery_tag: u64,
    opts: Client.ChannelOpts,
) !void {
    var self = getSelf(ptr);
    var conn = try self.ensureConnected();
    conn.ack(delivery_tag, opts) catch |e| try self.handleDisconnect(e, conn);
    log.info("[{}] Acknowledging message", .{delivery_tag});
}

pub fn reject(
    ptr: *anyopaque,
    delivery_tag: u64,
    requeue: bool,
    opts: Client.ChannelOpts,
) !void {
    var self = getSelf(ptr);
    var conn = try self.ensureConnected();
    conn.reject(
        delivery_tag,
        requeue,
        opts,
    ) catch |e| try self.handleDisconnect(e, conn);
    log.info("[{}] Rejecting message", .{delivery_tag});
}

pub fn publish(
    ptr: *anyopaque,
    message: schema.SendMessage,
    opts: Client.ChannelOpts,
) !void {
    var self = getSelf(ptr);
    var conn = try self.ensureConnected();

    const correlation_id = amqp.bytes_t.init(message.options.correlation_id orelse &uuid.urn.serialize(uuid.v7.new()));

    // There might be value in allowing the user to alter this.
    const content_type = amqp.bytes_t.init("application/json");

    var props = amqp.BasicProperties.init(.{
        .correlation_id = correlation_id,
        .content_type = content_type,
        .delivery_mode = 2,
    });

    if (message.options.reply_to) |r| {
        props.set(.reply_to, amqp.bytes_t.init(r));
    }

    conn.publish(
        message.body,
        message.options.exchange,
        message.options.routing_key,
        props,
        opts,
    ) catch |e| try self.handleDisconnect(e, conn);

    log.info(
        "[{s}] Publishing to {s}/{s}:\n\t{s}",
        .{
            correlation_id.slice().?,
            message.options.exchange,
            message.options.routing_key,
            message.body,
        },
    );
}

fn handleDisconnect(self: *AmqpClient, err: anyerror, conn: *Connection) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    return switch (err) {
        error.ConnectionClosed, error.SocketClosed, error.SocketError, error.HostnameResolutionFailed => {
            log.err("Client '{s}' was disconnected with error: {}.", .{ self.name, err });
            conn.deinit(self.allocator);
            self.connection = null;
            self.state = .disconnected;
            return error.Disconnected;
        },
        else => err,
    };
}

fn getSelf(ptr: *anyopaque) *AmqpClient {
    return @ptrCast(@alignCast(ptr));
}

pub fn client(self: *AmqpClient) Client {
    return .{
        .vtable = &.{
            .connect = connect,
            .disconnect = disconnect,
            .openChannel = openChannel,
            .closeChannel = closeChannel,
            .consume = consume,
            .publish = publish,
            .reset = reset,
            .declareEphemeralQueue = declareEphemeralQueue,
            .declareDurableQueue = declareDurableQueue,
            .bind = bind,
            .ack = ack,
            .reject = reject,
        },
        .ptr = self,
    };
}
