/// A dynamic dispatch wrapper for a message client that follows
/// AMQP 0.9.1 semantics and definitions
const std = @import("std");
const amqp = @import("zamqp");

const schema = @import("../schema.zig");

/// The client interface
const Client = @This();

/// Pointer to the concrete implementation
ptr: *anyopaque,

/// The vtable of the implementation
vtable: *const VTable,

/// Optional parameters for operations that can target a specific communication channel.
pub const ChannelOpts = struct {
    channel_name: ?[]const u8 = null,
};

/// Represents a consumed message.
/// TODO: Reduce dependance on amqp implementation details.
pub const Response = struct {
    /// The key that was used to route the message
    routing_key: []const u8,
    /// The exchange that routed the message to us
    exchange: []const u8,
    /// The raw envelope provided by the AMQP client
    /// TODO: Abstract this away into some context that can be freed by the user
    /// There is zero need to leak internals just so we have something to free
    envelope: amqp.Envelope,
    /// The tag of the consumer that read the message
    consumer_tag: []const u8,
    /// The delivery tag of the message
    delivery_tag: u64,
    /// A value that indicates that the message has been redelivered.
    redelivered: bool,
    /// The received message
    message: struct {
        /// Any additional properties attached to the message
        /// TODO: Abstract away amqp internals.
        basic_properties: amqp.BasicProperties,
        /// The raw string body of the message.
        body: []const u8,
    },

    /// Deinitialize the message.
    pub fn deinit(self: *Response) void {
        self.envelope.destroy();
    }
};

/// A vtable for a client inteface
pub const VTable = struct {
    /// Returns the internal id of the client.
    /// NOTE: You are probably looking for @see{ClientRegistry.id} instead.
    id: *const fn (self_ptr: *anyopaque) []const u8,
    /// Attempt to connect to the configured broker with the client.
    /// Will fail on a client that is already connected.
    connect: *const fn (self_ptr: *anyopaque) anyerror!void,
    /// Disconnect from the broker.
    disconnect: *const fn (self_ptr: *anyopaque) anyerror!void,
    /// Open a new channel with the given name.
    openChannel: *const fn (self_ptr: *anyopaque, name: []const u8) anyerror!void,
    /// Close an open channel.
    closeChannel: *const fn (self_ptr: *anyopaque, name: []const u8) anyerror!void,
    /// Declare a new ephemeral queue.
    /// Returns the name of the newly generated queue.
    declareEphemeralQueue: *const fn (self_ptr: *anyopaque) anyerror![]const u8,
    /// Declare a new durable queue with the given name.
    /// Returns the name of the newly generated queue.
    declareDurableQueue: *const fn (self_ptr: *anyopaque, queue: []const u8) anyerror![]const u8,
    /// Binds a consumer with a routing key to a given queue over an exchange.
    /// Returns the consumer tag of the new binding.
    /// NOTE: The queue will be created if it doesn't exist (as a durable queue)
    /// Passing null to queue will create a new ephemeral queue instead.
    bind: *const fn (
        self_ptr: *anyopaque,
        queue: ?[]const u8,
        route: []const u8,
        exchange: []const u8,
        opts: ChannelOpts,
    ) anyerror![]const u8,
    /// Unbinds a consumer from the broker.
    unbind: *const fn (
        self_ptr: *anyopaque,
        consumer_tag: []const u8,
        opts: ChannelOpts,
    ) anyerror!void,
    /// Attempts a non-blocking read of a message that will wait for the given timeout in ns.
    /// Will return null if no message is available.
    consume: *const fn (self_ptr: *anyopaque, timeout_ns: i64) anyerror!?Response,
    /// Publishes a new message with the given options.
    publish: *const fn (
        self_ptr: *anyopaque,
        message: schema.SendMessage,
        opts: ChannelOpts,
    ) anyerror!void,
    /// Acknowledges a message with the given tag.
    ack: *const fn (
        self_ptr: *anyopaque,
        delivery_tag: u64,
        opts: ChannelOpts,
    ) anyerror!void,
    /// Rejects a message with the given tag, optionally requeuing it.
    reject: *const fn (
        self_ptr: *anyopaque,
        delivery_tag: u64,
        requeue: bool,
        opts: ChannelOpts,
    ) anyerror!void,
    /// Frees any non-essential internal buffers.
    reset: *const fn (self_ptr: *anyopaque) void,
};

/// Returns the internal id of the client.
/// NOTE: You are probably looking for @see{ClientRegistry.id} instead.
pub fn id(self: Client) []const u8 {
    return self.vtable.id(self.ptr);
}

/// Attempt to connect to the configured broker with the client.
/// Will fail on a client that is already connected.
pub fn connect(self: Client) !void {
    return self.vtable.connect(self.ptr);
}

/// Disconnect from the broker.
pub fn disconnect(self: Client) !void {
    return self.vtable.disconnect(self.ptr);
}

/// Open a new channel with the given name.
pub fn openChannel(self: Client, name: []const u8) !void {
    return self.vtable.openChannel(self.ptr, name);
}

/// Close an open channel.
pub fn closeChannel(self: Client, name: []const u8) !void {
    return self.vtable.closeChannel(self.ptr, name);
}

/// Declare a new ephemeral queue.
/// Returns the name of the newly generated queue.
pub fn declareEphemeralQueue(self: Client) ![]const u8 {
    return self.vtable.declareEphemeralQueue(self.ptr);
}

/// Declare a new durable queue with the given name.
/// Returns the name of the newly generated queue.
pub fn declareDurableQueue(self: Client, queue: []const u8) ![]const u8 {
    return self.vtable.declareDurableQueue(self.ptr, queue);
}

/// Binds a consumer with a routing key to a given queue over an exchange.
/// Returns the consumer tag of the new binding.
/// NOTE: The queue will be created if it doesn't exist (as a durable queue)
/// Passing null to queue will create a new ephemeral queue instead.
pub fn bind(
    self: Client,
    queue: ?[]const u8,
    route: []const u8,
    exchange: []const u8,
    opts: ChannelOpts,
) ![]const u8 {
    return self.vtable.bind(self.ptr, queue, route, exchange, opts);
}

/// Unbinds a consumer from the broker.
pub fn unbind(
    self: Client,
    consumer_tag: []const u8,
    opts: ChannelOpts,
) !void {
    return self.vtable.unbind(self.ptr, consumer_tag, opts);
}

/// Attempts a non-blocking read of a message that will wait for the given timeout in ns.
/// Will return null if no message is available.
pub fn consume(self: Client, timeout_ns: i64) !?Response {
    return self.vtable.consume(self.ptr, timeout_ns);
}

/// Publishes a new message with the given options.
pub fn publish(
    self: Client,
    message: schema.SendMessage,
    opts: ChannelOpts,
) !void {
    return self.vtable.publish(self.ptr, message, opts);
}

/// Acknowledges a message with the given tag.
pub fn ack(
    self: Client,
    delivery_tag: u64,
    opts: ChannelOpts,
) !void {
    return self.vtable.ack(self.ptr, delivery_tag, opts);
}

/// Rejects a message with the given tag, optionally requeuing it.
pub fn reject(
    self: Client,
    delivery_tag: u64,
    requeue: bool,
    opts: ChannelOpts,
) !void {
    return self.vtable.reject(self.ptr, delivery_tag, requeue, opts);
}

/// Frees any non-essential internal buffers.
pub fn reset(self: Client) void {
    self.vtable.reset(self.ptr);
}
