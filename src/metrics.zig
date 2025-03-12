const std = @import("std");
const m = @import("metrics");

const meta = @import("meta.zig");
const schema = @import("schema.zig");

const Metrics = struct {
    total_memory_allocated: MemUsage,
    published_messages: Publish,
    total_published_messages: TotalPublish,
    consumed_messages: Consume,
    acked_messages: Acked,
    rejected_messages: Rejected,
    channels: Channels,
    queues: Queues,
    consumed_cycle: ConsumedCycle,
    published_cycle: PublishedCycle,
    publish_errors: PublishError,
    consume_errors: ConsumeError,
    time_per_cycle: Cycle,
    publishing_on: PublishQueue,
    consuming_from: ConsumeQueue,

    const ClientLabel = struct { client_name: []const u8, client_version: []const u8 };
    const QueueLabel = struct { queue: []const u8 };
    const ClientWithQueueLabel = meta.MergeStructs(ClientLabel, QueueLabel);
    const ExchangeLabel = struct { exchange: []const u8 };
    const TargetLabel = meta.MergeStructs(QueueLabel, ExchangeLabel);
    const FullLabel = meta.MergeStructs(ClientLabel, TargetLabel);

    const MemUsage = m.GaugeVec(i64, ClientLabel);
    const Publish = m.CounterVec(u64, FullLabel);
    const TotalPublish = m.CounterVec(u64, ClientLabel);
    const Consume = m.CounterVec(u64, ClientWithQueueLabel);
    const Acked = m.CounterVec(u64, ClientWithQueueLabel);
    const Rejected = m.CounterVec(u64, ClientWithQueueLabel);
    const Channels = m.CounterVec(u64, ClientLabel);
    const Queues = m.CounterVec(u64, ClientLabel);
    const ConsumedCycle = m.GaugeVec(u64, ClientWithQueueLabel);
    const PublishedCycle = m.GaugeVec(u64, FullLabel);
    const PublishError = m.CounterVec(u64, FullLabel);
    const ConsumeError = m.CounterVec(u64, ClientWithQueueLabel);
    const Cycle = m.GaugeVec(u64, ClientLabel);
    const PublishQueue = m.GaugeVec(u1, FullLabel);
    const ConsumeQueue = m.GaugeVec(u1, ClientWithQueueLabel);
};

var metrics = m.initializeNoop(Metrics);
var client_label: Metrics.ClientLabel = undefined;
var memsafe_buffer: [4 * 1024]u8 = undefined;
var buf_alloc: std.heap.FixedBufferAllocator = undefined;

pub fn initialize(allocator: std.mem.Allocator, client_name: []const u8, client_version: []const u8, comptime opts: m.RegistryOpts) !void {
    buf_alloc = std.heap.FixedBufferAllocator.init(&memsafe_buffer);
    client_label = .{
        .client_name = client_name,
        .client_version = client_version,
    };
    metrics = .{
        .total_memory_allocated = try Metrics.MemUsage.init(
            buf_alloc.allocator(),
            "kwatcher_total_memory_bytes",
            .{ .help = "The total allocated memory by the kwatcher" },
            opts,
        ),
        .published_messages = try Metrics.Publish.init(
            allocator,
            "kwatcher_published",
            .{ .help = "The total messages published to a specific queue over a given exchange." },
            opts,
        ),
        .total_published_messages = try Metrics.TotalPublish.init(
            allocator,
            "kwatcher_published_total",
            .{ .help = "The total messages published by the watcher." },
            opts,
        ),
        .consumed_messages = try Metrics.Consume.init(
            allocator,
            "kwatcher_consumed",
            .{ .help = "The total messages consumed from a specific queue." },
            opts,
        ),
        .acked_messages = try Metrics.Acked.init(
            allocator,
            "kwatcher_acked",
            .{ .help = "The total messages consumed from a specific queue that were acknowledged." },
            opts,
        ),
        .rejected_messages = try Metrics.Rejected.init(
            allocator,
            "kwatcher_rejected",
            .{ .help = "The total messages consumed from a specific queue that were rejected." },
            opts,
        ),
        .channels = try Metrics.Channels.init(
            allocator,
            "kwatcher_channels",
            .{ .help = "The total number of channels opened by the watcher." },
            opts,
        ),
        .queues = try Metrics.Queues.init(
            allocator,
            "kwatcher_queues",
            .{ .help = "The total number of queues this watcher interacts with." },
            opts,
        ),
        .consumed_cycle = try Metrics.ConsumedCycle.init(
            allocator,
            "kwatcher_consumed_cycle",
            .{ .help = "The number of messages this watcher consumed over the last cycle from a specific queue." },
            opts,
        ),
        .published_cycle = try Metrics.PublishedCycle.init(
            allocator,
            "kwatcher_published_cycle",
            .{ .help = "The number of messages this watcher published over the last cycle to a specific queue over a given exchange." },
            opts,
        ),
        .publish_errors = try Metrics.PublishError.init(
            allocator,
            "kwatcher_publish_errors",
            .{ .help = "The number of errors this watcher encountered while publishing messages to a specific queue over a given exchange." },
            opts,
        ),
        .consume_errors = try Metrics.ConsumeError.init(
            allocator,
            "kwatcher_consume_errors",
            .{ .help = "The number of errors this watcher encountered while consuming messages from a specific queue." },
            opts,
        ),
        .time_per_cycle = try Metrics.Cycle.init(
            allocator,
            "kwatcher_cycle_duration",
            .{ .help = "The time (in microseconds) that the last cycle took." },
            opts,
        ),
        .publishing_on = try Metrics.PublishQueue.init(
            allocator,
            "kwatcher_queue_publish",
            .{ .help = "The queues (per exchange) over which this watcher publishes messages." },
            opts,
        ),
        .consuming_from = try Metrics.ConsumeQueue.init(
            allocator,
            "kwatcher_queue_consume",
            .{ .help = "The queues from which this watcher consumesx messages." },
            opts,
        ),
    };
}

pub fn publish(queue: []const u8, exchange: []const u8) !void {
    const label: Metrics.FullLabel = .{
        .client_name = client_label.client_name,
        .client_version = client_label.client_version,
        .queue = queue,
        .exchange = exchange,
    };
    try metrics.published_messages.incr(label);
    try metrics.published_cycle.incr(label);
    try metrics.total_published_messages.incr(client_label);
}

pub fn consume(queue: []const u8) !void {
    const label: Metrics.ClientWithQueueLabel = .{
        .client_name = client_label.client_name,
        .client_version = client_label.client_version,
        .queue = queue,
    };
    try metrics.consumed_messages.incr(label);
    try metrics.consumed_cycle.incr(label);
}

pub fn resetCycle() !void {
    var pub_iter = metrics.published_cycle.impl.values.keyIterator();
    var consume_iter = metrics.consumed_cycle.impl.values.keyIterator();

    while (pub_iter.next()) |label_ptr| {
        try metrics.published_cycle.set(label_ptr.*, 0);
    }
    while (consume_iter.next()) |label_ptr| {
        try metrics.consumed_cycle.set(label_ptr.*, 0);
    }
}

pub fn ack(queue: []const u8) !void {
    const label: Metrics.ClientWithQueueLabel = .{
        .client_name = client_label.client_name,
        .client_version = client_label.client_version,
        .queue = queue,
    };
    try metrics.acked_messages.incr(label);
}

pub fn reject(queue: []const u8) !void {
    const label: Metrics.ClientWithQueueLabel = .{
        .client_name = client_label.client_name,
        .client_version = client_label.client_version,
        .queue = queue,
    };
    try metrics.rejected_messages.incr(label);
}

pub fn addChannel() !void {
    try metrics.channels.incr(client_label);
}

pub fn addQueue() !void {
    try metrics.queues.incr(client_label);
}

pub fn publishError(queue: []const u8, exchange: []const u8) !void {
    const label: Metrics.FullLabel = .{
        .client_name = client_label.client_name,
        .client_version = client_label.client_version,
        .queue = queue,
        .exchange = exchange,
    };
    try metrics.publish_errors.incr(label);
}

pub fn consumeError(queue: []const u8) !void {
    const label: Metrics.ClientWithQueueLabel = .{
        .client_name = client_label.client_name,
        .client_version = client_label.client_version,
        .queue = queue,
    };
    try metrics.consume_errors.incr(label);
}

pub fn cycle(timestamp_us: u64) !void {
    try metrics.time_per_cycle.set(client_label, timestamp_us);
}

pub fn publishQueue(queue: []const u8, exchange: []const u8) !void {
    const label: Metrics.FullLabel = .{
        .client_name = client_label.client_name,
        .client_version = client_label.client_version,
        .queue = queue,
        .exchange = exchange,
    };
    try metrics.publishing_on.set(label, 1);
}

pub fn consumeQueue(queue: []const u8) !void {
    const label: Metrics.ClientWithQueueLabel = .{
        .client_name = client_label.client_name,
        .client_version = client_label.client_version,
        .queue = queue,
    };
    try metrics.consuming_from.set(label, 1);
}

pub fn alloc(size: usize) void {
    metrics.total_memory_allocated.incrBy(client_label, @as(i64, @intCast(size))) catch unreachable;
}

pub fn free(size: usize) void {
    metrics.total_memory_allocated.incrBy(client_label, -@as(i64, @intCast(size))) catch unreachable;
}

pub fn write(writer: anytype) !void {
    return m.write(&metrics, writer);
}

pub fn v1(arena_allocator: std.mem.Allocator, client_info: schema.Client.V1, user_info: schema.User.V1) !schema.Metrics.V1() {
    var arr = std.ArrayListUnmanaged(u8){};

    const writer = arr.writer(arena_allocator);
    try write(writer);
    return .{
        .timestamp = std.time.microTimestamp(),
        .client = client_info,
        .user = user_info,
        .metrics = arr.items,
    };
}
