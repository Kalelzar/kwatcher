const std = @import("std");
const m = @import("metrics");
const klib = @import("klib");
const meta = klib.meta;
const mem = klib.mem;

const schema = @import("../schema.zig");

const Metrics = struct {
    total_memory_allocated: MemUsage,
    peak_memory_allocated: MemUsage,
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
    recordings_created: RecordingsCreated,
    recordings_replayed: RecordingsReplayed,
    recording_failures: RecordingFailures,
    replay_failures: ReplayFailures,
    replay_resumptions: ReplayResumptions,
    recording_file_size_bytes: RecordingFileSize,
    replay_duration_us: ReplayDuration,
    recorded_operations: RecordedOperations,
    cache_size: CacheSize,
    cache_hits: CacheHits,
    cache_misses: CacheMisses,
    action_latency: ActionLatency,

    const ClientLabel = struct { client_name: []const u8, client_version: []const u8 };
    const QueueLabel = struct { queue: []const u8 };
    const ClientWithQueueLabel = meta.MergeStructs(ClientLabel, QueueLabel);
    const ExchangeLabel = struct { exchange: []const u8 };
    const TargetLabel = meta.MergeStructs(QueueLabel, ExchangeLabel);
    const FullLabel = meta.MergeStructs(ClientLabel, TargetLabel);
    const OpLabel = struct { operation: []const u8 };
    const ClientWithOpLabel = meta.MergeStructs(ClientLabel, OpLabel);
    const CacheLabel = struct { cache_key: []const u8, cache_type: []const u8 };
    const ClientCacheLabel = meta.MergeStructs(CacheLabel, ClientLabel);
    const ActionLatencyLabel = struct { name: []const u8 };
    const ClientActionLatencyLabel = meta.MergeStructs(
        ActionLatencyLabel,
        ClientLabel,
    );

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
    const RecordingsCreated = m.CounterVec(u64, ClientLabel);
    const RecordingsReplayed = m.CounterVec(u64, ClientLabel);
    const RecordingFailures = m.CounterVec(u64, ClientLabel);
    const ReplayFailures = m.CounterVec(u64, ClientLabel);
    const ReplayResumptions = m.CounterVec(u64, ClientLabel);
    const RecordingFileSize = m.GaugeVec(u64, ClientLabel);
    const ReplayDuration = m.GaugeVec(u64, ClientLabel);
    const RecordedOperations = m.CounterVec(u64, ClientWithOpLabel);
    const CacheSize = m.GaugeVec(i64, ClientCacheLabel);
    const CacheHits = m.CounterVec(u64, ClientCacheLabel);
    const CacheMisses = m.CounterVec(u64, ClientCacheLabel);
    const ActionLatency = m.HistogramVec(
        u64,
        ClientActionLatencyLabel,
        &.{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 20000 },
    );

    pub fn deinit(self: *Metrics) void {
        self.acked_messages.deinit();
        self.channels.deinit();
        self.consume_errors.deinit();
        self.consumed_cycle.deinit();
        self.consumed_messages.deinit();
        self.consuming_from.deinit();
        self.publish_errors.deinit();
        self.published_cycle.deinit();
        self.published_messages.deinit();
        self.publishing_on.deinit();
        self.queues.deinit();
        self.rejected_messages.deinit();
        self.time_per_cycle.deinit();
        self.total_published_messages.deinit();
        self.recordings_created.deinit();
        self.recordings_replayed.deinit();
        self.recording_failures.deinit();
        self.replay_failures.deinit();
        self.replay_resumptions.deinit();
        self.recording_file_size_bytes.deinit();
        self.replay_duration_us.deinit();
        self.recorded_operations.deinit();
        self.cache_hits.deinit();
        self.cache_misses.deinit();
        self.cache_size.deinit();
        self.action_latency.deinit();
    }
};

var metrics = m.initializeNoop(Metrics);
var client_label: Metrics.ClientLabel = undefined;
var memsafe_buffer: [4 * 1024]u8 = undefined;
var buf_alloc: std.heap.FixedBufferAllocator = undefined;

pub fn deinitialize() void {
    metrics.deinit();
}

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
        .peak_memory_allocated = try Metrics.MemUsage.init(
            buf_alloc.allocator(),
            "kwatcher_peak_memory_bytes",
            .{ .help = "The maximum allocated memory by the kwatcher" },
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
        .recordings_created = try Metrics.RecordingsCreated.init(
            allocator,
            "kwatcher_recordings_created_total",
            .{ .help = "The total number of recording files created by this watcher." },
            opts,
        ),
        .recordings_replayed = try Metrics.RecordingsReplayed.init(
            allocator,
            "kwatcher_recordings_replayed_total",
            .{ .help = "The total number of recording files successfully replayed by this watcher." },
            opts,
        ),
        .recording_failures = try Metrics.RecordingFailures.init(
            allocator,
            "kwatcher_recording_failures_total",
            .{ .help = "The total number of recording failures encountered by this watcher." },
            opts,
        ),
        .replay_failures = try Metrics.ReplayFailures.init(
            allocator,
            "kwatcher_replay_failures_total",
            .{ .help = "The total number of replay failures encountered by this watcher." },
            opts,
        ),
        .replay_resumptions = try Metrics.ReplayResumptions.init(
            allocator,
            "kwatcher_replay_resumptions_total",
            .{ .help = "The total number of replay resumptions from checkpoints by this watcher." },
            opts,
        ),
        .recording_file_size_bytes = try Metrics.RecordingFileSize.init(
            allocator,
            "kwatcher_recording_file_size_bytes",
            .{ .help = "The current size in bytes of the active recording file." },
            opts,
        ),
        .replay_duration_us = try Metrics.ReplayDuration.init(
            allocator,
            "kwatcher_replay_duration_microseconds",
            .{ .help = "The duration in microseconds of the last completed replay operation." },
            opts,
        ),
        .recorded_operations = try Metrics.RecordedOperations.init(
            allocator,
            "kwatcher_recorded_operations_total",
            .{ .help = "The total number of operations recorded by type." },
            opts,
        ),
        .cache_hits = try .init(
            allocator,
            "kwatcher_cache_hits",
            .{ .help = "The total amount of cache hits" },
            opts,
        ),
        .cache_misses = try .init(
            allocator,
            "kwatcher_cache_misses",
            .{ .help = "The total amount of cache misses" },
            opts,
        ),
        .cache_size = try .init(
            allocator,
            "kwatcher_cache_size",
            .{ .help = "The total amount of elements in the cache" },
            opts,
        ),
        .action_latency = try .init(
            allocator,
            "kwatcher_action_latency",
            .{ .help = "The latency in us of an action." },
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

pub fn latency(action: []const u8, value: i64) !void {
    try metrics.action_latency.observe(Metrics.ClientActionLatencyLabel{
        .client_name = client_label.client_name,
        .client_version = client_label.client_version,
        .name = action,
    }, @intCast(value));
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
    const max = metrics.peak_memory_allocated.impl.values.get(client_label);
    const current = metrics.total_memory_allocated.impl.values.get(client_label).?;
    if (max) |v| {
        if (v.value < current.value)
            metrics.peak_memory_allocated.set(client_label, current.value) catch unreachable;
    }
    metrics.peak_memory_allocated.set(client_label, current.value) catch unreachable;
}

pub fn free(size: usize) void {
    metrics.total_memory_allocated.incrBy(client_label, -@as(i64, @intCast(size))) catch unreachable;
}

pub fn cacheHit(cache: []const u8, cache_type: []const u8) !void {
    const label: Metrics.ClientCacheLabel = .{
        .client_name = client_label.client_name,
        .client_version = client_label.client_version,
        .cache_key = cache,
        .cache_type = cache_type,
    };

    try metrics.cache_hits.incr(label);
}

pub fn cacheMiss(cache: []const u8, cache_type: []const u8) !void {
    const label: Metrics.ClientCacheLabel = .{
        .client_name = client_label.client_name,
        .client_version = client_label.client_version,
        .cache_key = cache,
        .cache_type = cache_type,
    };

    try metrics.cache_misses.incr(label);
}

pub fn cacheGrow(cache: []const u8, cache_type: []const u8) !void {
    const label: Metrics.ClientCacheLabel = .{
        .client_name = client_label.client_name,
        .client_version = client_label.client_version,
        .cache_key = cache,
        .cache_type = cache_type,
    };

    try metrics.cache_size.incr(label);
}

pub fn cacheShrink(cache: []const u8, cache_type: []const u8) !void {
    const label: Metrics.ClientCacheLabel = .{
        .client_name = client_label.client_name,
        .client_version = client_label.client_version,
        .cache_key = cache,
        .cache_type = cache_type,
    };

    try metrics.cache_size.incrBy(label, -1);
}

pub fn write(writer: *std.io.Writer) !void {
    return m.write(&metrics, writer);
}

pub fn v1(arena_allocator: std.mem.Allocator, client_info: schema.Client.V1, user_info: schema.User.V1) !schema.Metrics.V1() {
    var writer = std.io.Writer.Allocating.init(arena_allocator);
    defer writer.deinit();
    // NOTE: It feels like we are copying the buffer one too many times here... I am sure that can be improved.

    try write(&writer.writer);
    return .{
        .timestamp = std.time.microTimestamp(),
        .client = client_info,
        .user = user_info,
        .metrics = try writer.toOwnedSlice(),
    };
}

pub const shim: mem.MemMetricsShim = .{
    .free = &free,
    .alloc = &alloc,
};

pub fn instrumentAllocator(allocator: std.mem.Allocator) mem.InstrumentedAllocator {
    return mem.InstrumentedAllocator.init(
        allocator,
        shim,
    );
}

pub fn recordingCreated() !void {
    try metrics.recordings_created.incr(client_label);
}

pub fn recordingReplayed() !void {
    try metrics.recordings_replayed.incr(client_label);
}

pub fn recordingFailure() !void {
    try metrics.recording_failures.incr(client_label);
}

pub fn replayFailure() !void {
    try metrics.replay_failures.incr(client_label);
}

pub fn replayResumption() !void {
    try metrics.replay_resumptions.incr(client_label);
}

pub fn recordingFileSize(size_bytes: u64) !void {
    try metrics.recording_file_size_bytes.set(client_label, size_bytes);
}

pub fn replayDuration(duration_us: u64) !void {
    try metrics.replay_duration_us.set(client_label, duration_us);
}

pub fn recordedOperation(operation: []const u8) !void {
    const label: Metrics.ClientWithOpLabel = .{
        .client_name = client_label.client_name,
        .client_version = client_label.client_version,
        .operation = operation,
    };
    try metrics.recorded_operations.incr(label);
}
