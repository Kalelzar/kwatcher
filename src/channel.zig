const std = @import("std");
const config = @import("config.zig");
const schema = @import("schema.zig");

const amqp = @import("zamqp");

const Channel = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    bind: *const fn (*anyopaque) anyerror!void,
    publish: *const fn (*anyopaque, schema.SendMessage) anyerror!void,
    configureConsume: *const fn (*anyopaque) anyerror!void,
    ack: *const fn (*anyopaque, delivery_tag: u64) anyerror!void,
    reject: *const fn (*anyopaque, delivery_tag: u64, requeue: bool) anyerror!void,
};

pub fn bind(self: Channel) !void {
    return self.vtable.bind(self.ptr);
}

pub fn configureConsume(self: Channel) !void {
    return self.vtable.configureConsume(self.ptr);
}

pub fn publish(self: Channel, message: schema.SendMessage) !void {
    return self.vtable.publish(self.ptr, message);
}

pub fn ack(self: Channel, delivery_tag: u64) !void {
    return self.vtable.ack(self.ptr, delivery_tag);
}

pub fn reject(self: Channel, delivery_tag: u64, requeue: bool) !void {
    return self.vtable.reject(self.ptr, delivery_tag, requeue);
}
