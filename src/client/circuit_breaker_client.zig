const std = @import("std");
const meta = @import("klib").meta;

const schema = @import("../schema.zig");

const Client = @import("client.zig");
const ChannelOpts = Client.ChannelOpts;
const Response = Client.Response;

const CircuitBreakingClient = @This();

const State = enum {
    closed, // Using main client
    open, // Using fallback client
    half_open, // Testing if main is back
};

const Config = struct {
    failure_threshold: u32 = 3,
    recovery_timeout_ms: u64 = 30000, // 30 seconds
    half_open_max_calls: u32 = 3,
};

id: []const u8,
allocator: std.mem.Allocator,
main_client: Client,
fallback_client: Client,
state: State = .closed,
failure_count: u32 = 0,
last_failure_time: i64 = 0,
half_open_successes: u32 = 0,
config: Config,
mutex: std.Thread.Mutex = .{},

pub fn init(
    allocator: std.mem.Allocator,
    main_client: Client,
    fallback_client: Client,
    config: Config,
) !CircuitBreakingClient {
    return .{
        .allocator = allocator,
        .id = try std.fmt.allocPrint(allocator, "cb_{x}", .{std.crypto.random.int(u64)}),
        .main_client = main_client,
        .fallback_client = fallback_client,
        .config = config,
    };
}

pub fn deinit(self: *CircuitBreakingClient) void {
    self.allocator.free(self.id);
}

fn getCurrentClient(self: *CircuitBreakingClient) Client {
    self.mutex.lock();
    defer self.mutex.unlock();

    switch (self.state) {
        .closed, .half_open => return self.main_client,
        .open => {
            // Check if we should try half-open
            const now = std.time.milliTimestamp();
            if (now - self.last_failure_time > self.config.recovery_timeout_ms) {
                self.state = .half_open;
                self.half_open_successes = 0;
                std.log.info("Circuit breaker entering half-open state", .{});
                return self.main_client;
            }
            return self.fallback_client;
        },
    }
}

fn recordSuccess(self: *CircuitBreakingClient) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    switch (self.state) {
        .closed => {
            self.failure_count = 0;
        },
        .half_open => {
            self.half_open_successes += 1;
            if (self.half_open_successes >= self.config.half_open_max_calls) {
                self.state = .closed;
                try self.fallback_client.disconnect();
                self.failure_count = 0;
                std.log.info("Circuit breaker closed - main client recovered", .{});
            }
        },
        .open => {}, // Success on fallback doesn't change state
    }
}

fn recordFailure(self: *CircuitBreakingClient, err: anyerror) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    std.log.warn("Circuit breaker: recording failure: {}", .{err});
    // Only count specific errors as failures
    switch (err) {
        error.Disconnected,
        => {},
        else => return, // Don't trip on application errors
    }

    self.last_failure_time = std.time.milliTimestamp();

    switch (self.state) {
        .closed => {
            self.failure_count += 1;
            if (self.failure_count >= self.config.failure_threshold) {
                self.state = .open;
                std.log.warn("Circuit breaker opened - switching to fallback", .{});
                try self.fallback_client.connect();
            }
        },
        .half_open => {
            self.state = .open;
            self.failure_count = self.config.failure_threshold;
            std.log.warn("Circuit breaker reopened - main client still failing", .{});
        },
        .open => {}, // Already open
    }
}

// Wrapper to execute operations with circuit breaker logic
fn executeWithCircuitBreaker(
    self: *CircuitBreakingClient,
    comptime op: anytype,
    args: anytype,
) meta.Return(op) {
    const client_instance = self.getCurrentClient();

    const result = @call(.auto, op, .{client_instance} ++ args);

    // Handle success/failure based on return type
    if (@typeInfo(@TypeOf(result)) == .error_union) {
        if (result) |success| {
            try self.recordSuccess();
            return success;
        } else |err| {
            try self.recordFailure(err);

            // If we failed on main and are now open, retry on fallback
            if (self.state == .open and client_instance.ptr == self.main_client.ptr) {
                std.log.info("Retrying operation on fallback client", .{});
                return @call(.auto, op, .{self.fallback_client} ++ args);
            }

            return err;
        }
    } else {
        try self.recordSuccess();
        return result;
    }
}

// Client interface implementation
fn getSelf(ptr: *anyopaque) *CircuitBreakingClient {
    return @ptrCast(@alignCast(ptr));
}

fn getId(ptr: *anyopaque) []const u8 {
    const self = getSelf(ptr);
    return self.id;
}

pub fn connect(ptr: *anyopaque) anyerror!void {
    const self = getSelf(ptr);
    // Try main first
    self.main_client.connect() catch |err| {
        try self.recordFailure(err);
        std.log.warn("Main client connection failed, using fallback", .{});
        return self.fallback_client.connect();
    };
    try self.recordSuccess();
}

fn disconnect(ptr: *anyopaque) anyerror!void {
    const self = getSelf(ptr);
    // Disconnect both
    self.main_client.disconnect() catch {};
    self.fallback_client.disconnect() catch {};
}

fn openChannel(ptr: *anyopaque, name: []const u8) anyerror!void {
    const self = getSelf(ptr);
    return self.executeWithCircuitBreaker(Client.openChannel, .{name});
}

fn closeChannel(ptr: *anyopaque, name: []const u8) anyerror!void {
    const self = getSelf(ptr);
    return self.executeWithCircuitBreaker(Client.closeChannel, .{name});
}

fn declareEphemeralQueue(ptr: *anyopaque) anyerror![]const u8 {
    const self = getSelf(ptr);
    return self.executeWithCircuitBreaker(Client.declareEphemeralQueue, .{});
}

fn declareDurableQueue(ptr: *anyopaque, queue: []const u8) anyerror![]const u8 {
    const self = getSelf(ptr);
    return self.executeWithCircuitBreaker(Client.declareDurableQueue, .{queue});
}

fn bind(
    ptr: *anyopaque,
    queue: ?[]const u8,
    route: []const u8,
    exchange: []const u8,
    opts: ChannelOpts,
) anyerror![]const u8 {
    const self = getSelf(ptr);
    return self.executeWithCircuitBreaker(Client.bind, .{ queue, route, exchange, opts });
}

fn unbind(
    ptr: *anyopaque,
    consumer_tag: []const u8,
    opts: ChannelOpts,
) anyerror!void {
    const self = getSelf(ptr);
    return self.executeWithCircuitBreaker(Client.unbind, .{ consumer_tag, opts });
}

fn consume(ptr: *anyopaque, timeout_ns: i64) anyerror!?Response {
    const self = getSelf(ptr);
    return self.executeWithCircuitBreaker(Client.consume, .{timeout_ns});
}

fn publish(
    ptr: *anyopaque,
    message: schema.SendMessage,
    opts: ChannelOpts,
) anyerror!void {
    const self = getSelf(ptr);
    return self.executeWithCircuitBreaker(Client.publish, .{ message, opts });
}

fn ack(
    ptr: *anyopaque,
    delivery_tag: u64,
    opts: ChannelOpts,
) anyerror!void {
    const self = getSelf(ptr);
    return self.executeWithCircuitBreaker(Client.ack, .{ delivery_tag, opts });
}

fn reject(
    ptr: *anyopaque,
    delivery_tag: u64,
    requeue: bool,
    opts: ChannelOpts,
) anyerror!void {
    const self = getSelf(ptr);
    return self.executeWithCircuitBreaker(Client.reject, .{ delivery_tag, requeue, opts });
}

fn reset(ptr: *anyopaque) void {
    const self = getSelf(ptr);
    self.getCurrentClient().reset();
}

pub fn client(self: *CircuitBreakingClient) Client {
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
