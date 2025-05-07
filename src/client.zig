const std = @import("std");
const config = @import("config.zig");

const amqp = @import("zamqp");

const Channel = @import("channel.zig");
const Client = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Response = struct {
    routing_key: []const u8,
    exchange: []const u8,
    queue: []const u8,

    consumer_tag: []const u8,
    delivery_tag: u64,
    channel: u16,
    redelivered: bool,
    message: struct {
        // FIXME: Remove dependency on zamqp here.
        basic_properties: amqp.BasicProperties,
        body: []const u8,
    },
};

pub const VTable = struct {
    connect: *const fn (*anyopaque, std.mem.Allocator, config.BaseConfig, []const u8) anyerror!void,
    openChannel: *const fn (*anyopaque, exchange: []const u8, queue: []const u8, route: []const u8) anyerror!void,
    consume: *const fn (*anyopaque, std.mem.Allocator, timeout: i64) anyerror!?Response,
    reset: *const fn (*anyopaque) void,
    deinit: *const fn (*anyopaque) void,
    getChannel: *const fn (*anyopaque, queue: []const u8) anyerror!Channel,
};

pub fn getChannel(self: Client, queue: []const u8) !Channel {
    return self.vtable.getChannel(self.ptr, queue);
}

pub fn connect(self: Client, allocator: std.mem.Allocator, conf: config.BaseConfig, name: []const u8) !void {
    return self.vtable.connect(self.ptr, allocator, conf, name);
}

pub fn openChannel(self: Client, exchange: []const u8, queue: []const u8, route: []const u8) anyerror!void {
    return self.vtable.openChannel(self.ptr, exchange, queue, route);
}

pub fn consume(self: Client, allocator: std.mem.Allocator, timeout: i64) !?Response {
    return self.vtable.consume(self.ptr, allocator, timeout);
}

pub fn reset(self: Client) void {
    self.vtable.reset(self.ptr);
}

pub fn deinit(self: Client) void {
    self.vtable.deinit(self.ptr);
}
