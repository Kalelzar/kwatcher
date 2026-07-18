const std = @import("std");

const core = @import("kw-core");
const schema = core.schema;
const config = core.config;
const Recorder = core.recorder.Recorder;

const Ops = @import("../recording/ops.zig").Ops;

const Client = @import("client.zig");
const ChannelOpts = Client.ChannelOpts;
const Response = Client.Response;

const DurableCacheClient = @This();

id: []const u8,
allocator: std.mem.Allocator,
recording: ?*Recording = null,
config_file: config.BaseConfig,

/// One open recording: the client owns the file and its buffered writer;
/// the recorder only serializes through the writer interface. The struct
/// is heap-allocated so the writer's pointers into it stay stable.
const Recording = struct {
    buffer: [4096]u8,
    file: std.fs.File,
    writer: std.fs.File.Writer,
    recorder: Recorder(Ops),
    filepath: []const u8,
    temppath: []const u8,
};

/// Tracks one persistent DurableCacheClient per primary client id. Keeping
/// the fallback alive across dependency scopes means an outage produces one
/// recording per pool client instead of one file per scope.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    clients: std.StringHashMapUnmanaged(*DurableCacheClient) = .{},

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.clients.valueIterator();
        while (it.next()) |c| {
            c.*.deinit();
            self.allocator.destroy(c.*);
        }
        self.clients.deinit(self.allocator);
    }

    /// Returns the persistent fallback Client for `primary_id`, creating it
    /// on first use. `primary_id` must be stable for the registry's lifetime
    /// (pool client ids are).
    pub fn get(self: *Registry, primary_id: []const u8, config_file: config.BaseConfig) !Client {
        self.mutex.lock();
        defer self.mutex.unlock();

        const gop = try self.clients.getOrPut(self.allocator, primary_id);
        if (!gop.found_existing) {
            errdefer _ = self.clients.remove(primary_id);
            const dcc = try self.allocator.create(DurableCacheClient);
            errdefer self.allocator.destroy(dcc);
            dcc.* = try DurableCacheClient.init(self.allocator, config_file);
            gop.value_ptr.* = dcc;
        }

        return gop.value_ptr.*.client();
    }
};

pub fn init(allocator: std.mem.Allocator, config_file: config.BaseConfig) !DurableCacheClient {
    return .{
        .allocator = allocator,
        .id = try std.fmt.allocPrint(allocator, "dcc_{x}", .{std.crypto.random.int(u128)}),
        .config_file = config_file,
    };
}

pub fn deinit(self: *DurableCacheClient) void {
    self.finalize();
    self.allocator.free(self.id);
}

fn nextFile(self: *DurableCacheClient) ![]const u8 {
    // The id disambiguates recordings created in the same second (several
    // circuit breakers can fault their fallbacks simultaneously).
    const file_name =
        try std.fmt.allocPrint(
            self.allocator,
            "{s}/{}_{s}.rcd",
            .{ self.config_file.config.recording_dir, std.time.timestamp(), self.id },
        );
    return file_name;
}

/// Flush, close, and rename the current recording, if any.
fn finalize(self: *DurableCacheClient) void {
    const rec = self.recording orelse return;
    self.recording = null;
    rec.writer.interface.flush() catch |e| {
        std.log.err("Failed to flush recording '{s}' with '{}'", .{ rec.temppath, e });
    };
    rec.file.close();
    std.fs.cwd().rename(rec.temppath, rec.filepath) catch |e| {
        std.log.err("Failed to rename part file '{s}' to '{s}' with '{}'", .{ rec.temppath, rec.filepath, e });
    };
    self.allocator.free(rec.filepath);
    self.allocator.free(rec.temppath);
    self.allocator.destroy(rec);
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

/// Flush the record that was just written, then rotate the recording once
/// it grows past the configured size. Every record is flushed to disk as
/// soon as it is complete — this client is a fallback for a broker that is
/// already failing, so durability beats write batching. Rotation is a
/// finalize + fresh recording (KWRC files are stateful: each needs its own
/// header and anchor numbering), which only ever happens on a record
/// boundary, so every rotated file is self-contained.
fn recordFlushed(self: *DurableCacheClient, rec: *Recording) !void {
    try rec.writer.interface.flush();
    const written = rec.file.getPos() catch return;
    if (written >= self.config_file.config.recording_max_bytes) {
        self.finalize();
        try self.startRecording();
    }
}

/// Start a new recording.
/// A no-op when already recording: circuit-breaker fault paths connect the
/// fallback more than once (trip + connect fault), and must not fail.
pub fn connect(ptr: *anyopaque) anyerror!void {
    const self = getSelf(ptr);
    if (self.recording != null) {
        return;
    }

    try self.startRecording();
}

fn startRecording(self: *DurableCacheClient) !void {
    const filepath = try self.nextFile();
    errdefer self.allocator.free(filepath);
    const temppath = try std.mem.concat(self.allocator, u8, &.{ filepath, ".part" });
    errdefer self.allocator.free(temppath);

    if (std.fs.path.dirname(filepath)) |d| {
        try std.fs.cwd().makePath(d);
    }

    const rec = try self.allocator.create(Recording);
    errdefer self.allocator.destroy(rec);
    rec.filepath = filepath;
    rec.temppath = temppath;
    rec.file = try std.fs.cwd().createFile(temppath, .{ .exclusive = true });
    errdefer rec.file.close();
    rec.writer = rec.file.writerStreaming(&rec.buffer);
    rec.recorder = try Recorder(Ops).init(self.allocator, &rec.writer.interface);
    try rec.writer.interface.flush();
    self.recording = rec;
}

/// Finalize the current recording.
/// A no-op when not recording: the circuit breaker disconnects the fallback
/// on recovery even if it never faulted it, and must not fail.
fn disconnect(ptr: *anyopaque) anyerror!void {
    const self = getSelf(ptr);
    self.finalize();
}

/// Open a new channel with the given name.
fn openChannel(ptr: *anyopaque, name: []const u8) anyerror!void {
    const self = getSelf(ptr);
    const rec = self.recording orelse return error.InvalidState;
    try rec.recorder.op(.open_channel);
    try rec.recorder.str(name);
    try self.recordFlushed(rec);
}

/// Close an open channel.
fn closeChannel(ptr: *anyopaque, name: []const u8) anyerror!void {
    const self = getSelf(ptr);
    const rec = self.recording orelse return error.InvalidState;
    try rec.recorder.op(.close_channel);
    try rec.recorder.str(name);
    try self.recordFlushed(rec);
}

/// Declare a new ephemeral queue.
/// Returns the name of the newly generated queue.
fn declareEphemeralQueue(ptr: *anyopaque) anyerror![]const u8 {
    const self = getSelf(ptr);
    const rec = self.recording orelse return error.InvalidState;
    const anchor = try rec.recorder.anchor();
    try rec.recorder.op(.declare_ephemeral_queue);
    try rec.recorder.str(anchor);
    try self.recordFlushed(rec);
    return anchor;
}

/// Declare a new durable queue with the given name.
/// Returns the name of the newly generated queue.
fn declareDurableQueue(ptr: *anyopaque, queue: []const u8) anyerror![]const u8 {
    const self = getSelf(ptr);
    const rec = self.recording orelse return error.InvalidState;
    try rec.recorder.op(.declare_durable_queue);
    try rec.recorder.str(queue);
    try self.recordFlushed(rec);
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
    opts: Client.BindOpts,
) anyerror![]const u8 {
    const self = getSelf(ptr);
    const rec = self.recording orelse return error.InvalidState;
    try rec.recorder.op(.bind);
    try rec.recorder.strOpt(queue);
    try rec.recorder.str(route);
    try rec.recorder.str(exchange);
    try rec.recorder.strOpt(opts.channel_name);
    const consumer_tag = try rec.recorder.anchor();
    try rec.recorder.str(consumer_tag);
    try self.recordFlushed(rec);
    return consumer_tag;
}

/// Unbinds a consumer from the broker.
fn unbind(
    ptr: *anyopaque,
    consumer_tag: []const u8,
    opts: ChannelOpts,
) anyerror!void {
    const self = getSelf(ptr);
    const rec = self.recording orelse return error.InvalidState;
    try rec.recorder.op(.unbind);
    try rec.recorder.str(consumer_tag);
    try rec.recorder.strOpt(opts.channel_name);
    try self.recordFlushed(rec);
}

/// You can't consume a message while recording
// This always returns null, but honors the blocking contract of consume
// (wait up to timeout_ns) so polling consumers don't hot-spin on it.
fn consume(ptr: *anyopaque, timeout_ns: i64) anyerror!?Response {
    const self = getSelf(ptr);
    _ = self;
    if (timeout_ns > 0) std.Thread.sleep(@intCast(timeout_ns));
    return null;
}

/// You can't return a message while recording
// This always returns null, but honors the blocking contract of getReturns
// (wait up to timeout_ns) so polling consumers don't hot-spin on it.
fn getReturns(ptr: *anyopaque, timeout_ns: i64) anyerror!?Client.ReturnedMessage {
    const self = getSelf(ptr);
    _ = self;
    if (timeout_ns > 0) std.Thread.sleep(@intCast(timeout_ns));
    return null;
}

/// Publishes a new message with the given options.
fn publish(
    ptr: *anyopaque,
    message: schema.SendMessage,
    opts: ChannelOpts,
) anyerror!void {
    const self = getSelf(ptr);
    const rec = self.recording orelse return error.InvalidState;
    if (message.options.norecord) return;
    try rec.recorder.op(.publish);
    try rec.recorder.strOpt(opts.channel_name);
    try rec.recorder.str(message.body);
    try rec.recorder.str(message.options.routing_key);
    try rec.recorder.str(message.options.exchange);
    try rec.recorder.strOpt(message.options.reply_to);
    try rec.recorder.strOpt(message.options.correlation_id);
    try rec.recorder.byteOpt(u64, message.options.expiration);
    // The real client sends this as the x-publisher-key header; without it
    // a replayed message can't be attributed (or returned as unrouted).
    try rec.recorder.str(message.options.publisher_key);
    try self.recordFlushed(rec);
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

/// Flushes the recording buffer so records written so far are durable.
fn reset(ptr: *anyopaque) void {
    const self = getSelf(ptr);
    if (self.recording) |rec| {
        rec.writer.interface.flush() catch |e| {
            std.log.err("Failed to flush recording '{s}' with '{}'", .{ rec.temppath, e });
        };
    }
}

pub fn client(self: *DurableCacheClient) Client {
    return .{
        .vtable = &.{
            .connect = connect,
            .disconnect = disconnect,
            .openChannel = openChannel,
            .closeChannel = closeChannel,
            .consume = consume,
            .getReturns = getReturns,
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
