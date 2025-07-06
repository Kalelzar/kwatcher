const std = @import("std");
const config = @import("config.zig");
const schema = @import("schema.zig");
const Client = @import("client.zig");
const ChannelOpts = Client.ChannelOpts;
const Response = Client.Response;
const Recorder = @import("recorder.zig").Recorder;

const DurableCacheClient = @This();

const Ops = @import("ops.zig").Ops;

id: []const u8,
allocator: std.mem.Allocator,
recorder: ?*Recorder(Ops) = null,

pub fn init(allocator: std.mem.Allocator) !DurableCacheClient {
    return .{
        .allocator = allocator,
        .id = try std.fmt.allocPrint(allocator, "dcc_{x}", .{std.crypto.random.int(u128)}),
    };
}

pub fn deinit(self: *DurableCacheClient) void {
    if (self.recorder) |r| {
        r.deinit();
        self.allocator.destroy(r);
        self.recorder = null;
    }
    self.allocator.free(self.id);
}

fn nextFile() !std.fs.File {
    var buf: [512]u8 = undefined;
    const file_name =
        try std.fmt.bufPrint(&buf, ".recording/{}.rcd", .{std.time.timestamp()});
    return std.fs.cwd().createFile(file_name, .{
        .exclusive = true,
    });
}

fn getSelf(ptr: *anyopaque) *DurableCacheClient {
    return @ptrCast(@alignCast(ptr));
}

/// Returns the internal id of the client.
/// NOTE: You are probably looking for @see{ClientRegistry.id} instead.
fn getId(ptr: *anyopaque) []const u8 {
    const self = getSelf(ptr);
    return self.id;
}

/// Attempt to connect to the configured broker with the client.
/// Will fail on a client that is already connected.
pub fn connect(ptr: *anyopaque) anyerror!void {
    const self = getSelf(ptr);
    if (self.recorder != null) {
        return error.InvalidState;
    }
    const file = try nextFile();
    errdefer file.close();
    var recorder = try Recorder(Ops).init(self.allocator, file);
    errdefer recorder.deinit();
    self.recorder = try self.allocator.create(Recorder(Ops));
    self.recorder.?.* = recorder;
}

/// Disconnect from the broker.
fn disconnect(ptr: *anyopaque) anyerror!void {
    const self = getSelf(ptr);
    if (self.recorder) |r| {
        r.deinit();
        self.allocator.destroy(r);
        self.recorder = null;
    } else {
        return error.InvalidState;
    }
}
/// Open a new channel with the given name.
fn openChannel(ptr: *anyopaque, name: []const u8) anyerror!void {
    const self = getSelf(ptr);
    var r = self.recorder orelse return error.InvalidState;
    try r.op(.open_channel);
    try r.str(name);
}
/// Close an open channel.
fn closeChannel(ptr: *anyopaque, name: []const u8) anyerror!void {
    const self = getSelf(ptr);
    var r = self.recorder orelse return error.InvalidState;
    try r.op(.close_channel);
    try r.str(name);
}
/// Declare a new ephemeral queue.
/// Returns the name of the newly generated queue.
fn declareEphemeralQueue(ptr: *anyopaque) anyerror![]const u8 {
    const self = getSelf(ptr);
    var r = self.recorder orelse return error.InvalidState;
    const anchor = try r.anchor();
    try r.op(.declare_ephemeral_queue);
    try r.str(anchor);
    return anchor;
}
/// Declare a new durable queue with the given name.
/// Returns the name of the newly generated queue.
fn declareDurableQueue(ptr: *anyopaque, queue: []const u8) anyerror![]const u8 {
    const self = getSelf(ptr);
    var r = self.recorder orelse return error.InvalidState;
    try r.op(.declare_durable_queue);
    try r.str(queue);
    return queue;
}
/// Binds a consumer with a routing key to a given queue over an exchange.
/// Returns the consumer tag of the new binding.
/// NOTE: The queue will be created if it doesn't exist (as a durable queue)
/// Passing null to queue will create a new ephemeral queue instead.
fn bind(
    ptr: *anyopaque,
    queue: ?[]const u8,
    route: []const u8,
    exchange: []const u8,
    opts: ChannelOpts,
) anyerror![]const u8 {
    const self = getSelf(ptr);
    var r = self.recorder orelse return error.InvalidState;
    try r.op(.bind);
    try r.strOpt(queue);
    try r.str(route);
    try r.str(exchange);
    try r.strOpt(opts.channel_name);
    const consumer_tag = try r.anchor();
    try r.str(consumer_tag);
    return consumer_tag;
}
/// Unbinds a consumer from the broker.
fn unbind(
    ptr: *anyopaque,
    consumer_tag: []const u8,
    opts: ChannelOpts,
) anyerror!void {
    const self = getSelf(ptr);
    var r = self.recorder orelse return error.InvalidState;
    try r.op(.unbind);
    try r.str(consumer_tag);
    try r.strOpt(opts.channel_name);
}

/// You can't consume a message while recording
// This is a noop and always returns null
fn consume(ptr: *anyopaque, timeout_ns: i64) anyerror!?Response {
    const self = getSelf(ptr);
    _ = self;
    _ = timeout_ns;
    return null;
}

/// Publishes a new message with the given options.
fn publish(
    ptr: *anyopaque,
    message: schema.SendMessage,
    opts: ChannelOpts,
) anyerror!void {
    const self = getSelf(ptr);
    var r = self.recorder orelse return error.InvalidState;
    if (message.options.norecord) return;
    try r.op(.publish);
    try r.strOpt(opts.channel_name);
    try r.str(message.body);
    try r.str(message.options.routing_key);
    try r.str(message.options.exchange);
    try r.strOpt(message.options.reply_to);
    try r.strOpt(message.options.correlation_id);
    try r.byteOpt(u64, message.options.expiration);
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

pub fn client(self: *DurableCacheClient) Client {
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
