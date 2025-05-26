const std = @import("std");
const schema = @import("schema.zig");
const amqp = @import("zamqp");

const Client = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const ChannelOpts = struct {
    channel_name: ?[]const u8 = null,
};

/// Represents a consumed message.
/// TODO: Reduce dependance on amqp implementation details.
pub const Response = struct {
    routing_key: []const u8,
    exchange: []const u8,
    envelope: amqp.Envelope,
    consumer_tag: []const u8,
    delivery_tag: u64,
    redelivered: bool,
    message: struct {
        basic_properties: amqp.BasicProperties,
        body: []const u8,
    },

    pub fn deinit(self: *Response) void {
        self.envelope.destroy();
    }
};

/// Optional parameters for operations that can target a specific communication channel.
pub const VTable = struct {
    id: *const fn (self_ptr: *anyopaque) []const u8,
    connect: *const fn (self_ptr: *anyopaque) anyerror!void,
    disconnect: *const fn (self_ptr: *anyopaque) anyerror!void,
    openChannel: *const fn (self_ptr: *anyopaque, name: []const u8) anyerror!void,
    closeChannel: *const fn (self_ptr: *anyopaque, name: []const u8) anyerror!void,
    declareEphemeralQueue: *const fn (self_ptr: *anyopaque) anyerror![]const u8,
    declareDurableQueue: *const fn (self_ptr: *anyopaque, queue: []const u8) anyerror![]const u8,
    bind: *const fn (
        self_ptr: *anyopaque,
        queue: ?[]const u8,
        route: []const u8,
        exchange: []const u8,
        opts: ChannelOpts,
    ) anyerror![]const u8,
    unbind: *const fn (
        self_ptr: *anyopaque,
        consumer_tag: []const u8,
        opts: ChannelOpts,
    ) anyerror!void,
    consume: *const fn (self_ptr: *anyopaque, timeout: i64) anyerror!?Response,
    publish: *const fn (
        self_ptr: *anyopaque,
        message: schema.SendMessage,
        opts: ChannelOpts,
    ) anyerror!void,
    ack: *const fn (
        self_ptr: *anyopaque,
        delivery_tag: u64,
        opts: ChannelOpts,
    ) anyerror!void,
    reject: *const fn (
        self_ptr: *anyopaque,
        delivery_tag: u64,
        requeue: bool,
        opts: ChannelOpts,
    ) anyerror!void,
    reset: *const fn (self_ptr: *anyopaque) void,
};

pub fn id(self: Client) []const u8 {
    return self.vtable.id(self.ptr);
}

pub fn connect(self: Client) !void {
    return self.vtable.connect(self.ptr);
}

pub fn disconnect(self: Client) !void {
    return self.vtable.disconnect(self.ptr);
}

pub fn openChannel(self: Client, name: []const u8) !void {
    return self.vtable.openChannel(self.ptr, name);
}

pub fn closeChannel(self: Client, name: []const u8) !void {
    return self.vtable.closeChannel(self.ptr, name);
}

pub fn declareEphemeralQueue(self: Client) ![]const u8 {
    return self.vtable.declareEphemeralQueue(self.ptr);
}

pub fn declareDurableQueue(self: Client, queue: []const u8) ![]const u8 {
    return self.vtable.declareDurableQueue(self.ptr, queue);
}

pub fn bind(
    self: Client,
    queue: ?[]const u8,
    route: []const u8,
    exchange: []const u8,
    opts: ChannelOpts,
) ![]const u8 {
    return self.vtable.bind(self.ptr, queue, route, exchange, opts);
}

pub fn unbind(
    self: Client,
    consumer_tag: []const u8,
    opts: ChannelOpts,
) !void {
    return self.vtable.unbind(self.ptr, consumer_tag, opts);
}

pub fn consume(self: Client, timeout: i64) !?Response {
    return self.vtable.consume(self.ptr, timeout);
}

pub fn publish(
    self: Client,
    message: schema.SendMessage,
    opts: ChannelOpts,
) !void {
    return self.vtable.publish(self.ptr, message, opts);
}

pub fn ack(
    self: Client,
    delivery_tag: u64,
    opts: ChannelOpts,
) !void {
    return self.vtable.ack(self.ptr, delivery_tag, opts);
}

pub fn reject(
    self: Client,
    delivery_tag: u64,
    requeue: bool,
    opts: ChannelOpts,
) !void {
    return self.vtable.reject(self.ptr, delivery_tag, requeue, opts);
}

pub fn reset(self: Client) void {
    self.vtable.reset(self.ptr);
}
