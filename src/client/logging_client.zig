const std = @import("std");

const schema = @import("../schema.zig");

const Client = @import("client.zig");
const ChannelOpts = Client.ChannelOpts;
const Response = Client.Response;

const LoggingClient = @This();

file: std.fs.File,

pub fn init(file: std.fs.File) LoggingClient {
    return .{
        .file = file,
    };
}

pub fn deinit(self: *LoggingClient) void {
    self.file.close();
}

pub fn client(self: *LoggingClient) Client {
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
            .unbind = unbind,
            .ack = ack,
            .reject = reject,
            .id = getId,
        },
        .ptr = self,
    };
}

fn getSelf(ptr: *anyopaque) *LoggingClient {
    return @ptrCast(@alignCast(ptr));
}

/// Returns the internal id of the client.
/// NOTE: You are probably looking for @see{ClientRegistry.id} instead.
fn getId(ptr: *anyopaque) []const u8 {
    _ = ptr;
    return "logging_client";
}

pub fn connect(ptr: *anyopaque) anyerror!void {
    const self = getSelf(ptr);
    _ = try self.file.write("connect()\n");
}

fn disconnect(ptr: *anyopaque) anyerror!void {
    const self = getSelf(ptr);
    _ = try self.file.write("disconnect()\n");
}

fn openChannel(ptr: *anyopaque, name: []const u8) anyerror!void {
    const self = getSelf(ptr);
    var buf: [256]u8 = undefined;
    _ = try self.file.write(try std.fmt.bufPrint(&buf, "openChannel({s})\n", .{name}));
}

fn closeChannel(ptr: *anyopaque, name: []const u8) anyerror!void {
    const self = getSelf(ptr);
    var buf: [256]u8 = undefined;
    _ = try self.file.write(try std.fmt.bufPrint(&buf, "closeChannel({s})\n", .{name}));
}

fn declareEphemeralQueue(ptr: *anyopaque) anyerror![]const u8 {
    const self = getSelf(ptr);
    _ = try self.file.write("declareEphemeralQueue()\n");
    return "ephemeral";
}

fn declareDurableQueue(ptr: *anyopaque, queue: []const u8) anyerror![]const u8 {
    const self = getSelf(ptr);
    var buf: [256]u8 = undefined;
    _ = try self.file.write(try std.fmt.bufPrint(&buf, "declareDurableQueue({s})\n", .{queue}));
    return queue;
}

fn bind(
    ptr: *anyopaque,
    queue: ?[]const u8,
    route: []const u8,
    exchange: []const u8,
    opts: ChannelOpts,
) anyerror![]const u8 {
    const self = getSelf(ptr);
    var buf: [256]u8 = undefined;
    _ = try self.file.write(try std.fmt.bufPrint(
        &buf,
        "bind({s}): queue({s}) exchange({s}) opts.channel({s})\n",
        .{
            route,
            queue orelse "ephemeral",
            exchange,
            opts.channel_name orelse "default",
        },
    ));
    return "consumer_tag";
}

/// Unbinds a consumer from the broker.
fn unbind(
    ptr: *anyopaque,
    consumer_tag: []const u8,
    opts: ChannelOpts,
) anyerror!void {
    const self = getSelf(ptr);
    var buf: [256]u8 = undefined;
    _ = try self.file.write(try std.fmt.bufPrint(&buf, "unbind({s}): opts.channel({s})\n", .{
        consumer_tag,
        opts.channel_name orelse "default",
    }));
}

/// You can't consume a message while recording
// This is a noop and always returns null
fn consume(ptr: *anyopaque, timeout_ns: i64) anyerror!?Response {
    const self = getSelf(ptr);
    var buf: [256]u8 = undefined;
    _ = try self.file.write(
        try std.fmt.bufPrint(&buf, "consume({})\n", .{timeout_ns}),
    );
    return null;
}

/// Publishes a new message with the given options.
fn publish(
    ptr: *anyopaque,
    message: schema.SendMessage,
    opts: ChannelOpts,
) anyerror!void {
    const self = getSelf(ptr);
    var buf: [4096]u8 = undefined;
    _ = try self.file.write(
        try std.fmt.bufPrint(
            &buf,
            "publish({s}): exchange({s}) reply_to({s}) correlation_id({s}) expiration({}) norecord({}) opts.channel({s})\n\t{s}\n",
            .{
                message.options.routing_key,
                message.options.exchange,
                message.options.reply_to orelse "none",
                message.options.correlation_id orelse "default",
                message.options.expiration orelse 0,
                message.options.norecord,
                opts.channel_name orelse "default",
                message.body,
            },
        ),
    );
}

/// This is a NOOP.
fn ack(
    ptr: *anyopaque,
    delivery_tag: u64,
    opts: ChannelOpts,
) anyerror!void {
    const self = getSelf(ptr);
    _ = self;
    _ = delivery_tag;
    _ = opts;
}
/// This is a NOOP.
fn reject(
    ptr: *anyopaque,
    delivery_tag: u64,
    requeue: bool,
    opts: ChannelOpts,
) anyerror!void {
    const self = getSelf(ptr);
    _ = self;
    _ = delivery_tag;
    _ = requeue;
    _ = opts;
}
/// Frees any non-essential internal buffers.
fn reset(ptr: *anyopaque) void {
    const self = getSelf(ptr);
    _ = self;
}
