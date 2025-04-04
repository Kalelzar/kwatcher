const std = @import("std");
const log = std.log.scoped(.kwatcher);
const klib = @import("klib");
const meta = klib.meta;
const DisjointSlice = klib.DisjointSlice;

const schema = @import("schema.zig");
const config = @import("config.zig");
const metrics = @import("metrics.zig");
const mem = @import("mem.zig");
const client = @import("client.zig");

const DefaultRoutes = @import("default_routes.zig");

const Injector = @import("injector.zig").Injector;
const Route = @import("route.zig").Route;

pub const Timer = struct {
    const TimerEntry = struct { interval: u64, last_activation: std.time.Instant };
    store: std.StringHashMap(TimerEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Timer {
        const map = std.StringHashMap(TimerEntry).init(allocator);
        return .{
            .store = map,
            .allocator = allocator,
        };
    }

    pub fn register(self: *Timer, name: []const u8, interval: u64) !void {
        const current_time = try std.time.Instant.now();
        const entry = TimerEntry{
            .interval = interval,
            .last_activation = current_time,
        };
        try self.store.put(name, entry);
    }

    pub fn ready(self: *const Timer, name: []const u8) !bool {
        const entry = self.store.get(name) orelse return error.NotFound;

        const current_time = try std.time.Instant.now();
        if (current_time.since(entry.last_activation) >= entry.interval) {
            return true;
        }
        return false;
    }

    pub fn step(self: *Timer) !void {
        const current_time = try std.time.Instant.now();
        var iter = self.store.valueIterator();
        while (iter.next()) |entry_ptr| {
            if (current_time.since(entry_ptr.last_activation) >= entry_ptr.interval) {
                entry_ptr.last_activation = current_time;
            }
        }
    }

    pub fn deinit(self: *Timer) void {
        self.store.deinit();
    }
};

fn Dependencies(comptime UserConfig: type, comptime client_name: []const u8, comptime client_version: []const u8) type {
    const __ignore = struct {};

    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        internal_arena: mem.InternalArena,
        instrumented_allocator: *klib.mem.InstrumentedAllocator,

        client_cache: ?*client.AmqpClient = null,
        timer: ?Timer = null,
        user_info: ?schema.UserInfo = null,
        user_config: ?UserConfig = null,
        base_config: ?config.BaseConfig = null,
        merged_config: ?config.Config(UserConfig) = null,

        clientInfo: schema.ClientInfo = .{
            .version = client_version,
            .name = client_name,
        },

        pub fn timerFactory(self: *Self, allocator: std.mem.Allocator, base_config: config.BaseConfig) !Timer {
            if (self.timer) |res| {
                return res;
            } else {
                var timer = Timer.init(allocator);
                try timer.register("heartbeat", base_config.config.heartbeat_interval);
                try timer.register("metrics", base_config.config.metrics_interval_ns);
                self.timer = timer;
                return self.timer.?;
            }
        }

        pub fn userInfo(self: *Self, allocator: std.mem.Allocator) schema.UserInfo {
            if (self.user_info) |res| {
                return res;
            } else {
                self.user_info = schema.UserInfo.init(allocator, null);
                return self.user_info.?;
            }
        }

        pub fn mergedConfig(self: *Self, arena: *std.heap.ArenaAllocator) !config.Config(UserConfig) {
            if (self.merged_config) |m| {
                return m;
            } else {
                const merged_config = try config.findConfigFileWithDefaults(
                    UserConfig,
                    client_name,
                    arena,
                );
                self.merged_config = merged_config;
                return self.merged_config.?;
            }
        }

        pub fn userConfig(self: *Self, merged_config: config.Config(UserConfig)) UserConfig {
            if (self.user_config) |res| {
                return res;
            } else {
                const user_config = meta.copy(
                    @TypeOf(merged_config.value),
                    UserConfig,
                    merged_config.value,
                );
                self.user_config = user_config;

                return self.user_config.?;
            }
        }

        pub fn baseConfig(self: *Self, merged_config: config.Config(UserConfig)) !config.BaseConfig {
            if (self.base_config) |res| {
                return res;
            } else {
                const base_config = meta.copy(
                    @TypeOf(merged_config.value),
                    config.BaseConfig,
                    merged_config.value,
                );
                self.base_config = base_config;
                return self.base_config.?;
            }
        }

        pub fn clientFactory(self: *Self, allocator: std.mem.Allocator, config_file: config.BaseConfig) !*client.AmqpClient {
            if (self.client_cache) |res| {
                return res;
            } else {
                const amqp_client = try allocator.create(client.AmqpClient);
                amqp_client.* = try client.AmqpClient.init(allocator, config_file, client_name);
                self.client_cache = amqp_client;
                return self.client_cache.?;
            }
        }

        pub fn init(allocator: std.mem.Allocator) !Self {
            const arr_ptr = try allocator.create(std.heap.ArenaAllocator);
            const instr_ptr = try allocator.create(klib.mem.InstrumentedAllocator);
            errdefer allocator.destroy(arr_ptr);
            const result = Self{
                .allocator = allocator,
                .instrumented_allocator = instr_ptr,
                .arena = arr_ptr,
                .internal_arena = try mem.InternalArena.init(allocator, metrics.shim),
            };
            result.instrumented_allocator.* = metrics.instrumentAllocator(std.heap.page_allocator);
            result.arena.* = std.heap.ArenaAllocator.init(instr_ptr.allocator());
            return result;
        }

        pub fn deinit(self: *Self) __ignore {
            if (self.timer) |_|
                self.timer.?.deinit();

            if (self.user_info) |u|
                u.deinit();

            if (self.client_cache) |c| {
                c.deinit();
                self.allocator.destroy(c);
            }

            self.internal_arena.deinit();
            self.arena.deinit();
            self.allocator.destroy(self.arena);
            self.allocator.destroy(self.instrumented_allocator);

            return .{};
        }
    };
}

const DefaultEventProvider = struct {
    pub fn metrics(timer: Timer) !bool {
        return try timer.ready("metrics");
    }
};

pub fn Server(
    comptime client_name: []const u8,
    comptime client_version: []const u8,
    comptime UserSingletonDependencies: type,
    comptime UserScopedDependencies: type,
    comptime UserConfig: type,
    comptime Routes: type,
    comptime EventProvider: type,
) type {
    return struct {
        const Self = @This();
        instrumented_allocator: *klib.mem.InstrumentedAllocator,
        deps: Dependencies(UserConfig, client_name, client_version),
        user_deps: *UserSingletonDependencies,
        routes: []const Route,
        default_routes: []const Route,
        retries: i8 = 0,
        backoff: u64 = 5,

        pub fn init(allocator: std.mem.Allocator, deps: *UserSingletonDependencies) !Self {
            var instrumented_allocator = try allocator.create(klib.mem.InstrumentedAllocator);
            instrumented_allocator.* = metrics.instrumentAllocator(allocator);
            const alloc = instrumented_allocator.allocator();
            try metrics.initialize(alloc, client_name, client_version, .{});
            const default_deps = try Dependencies(
                UserConfig,
                client_name,
                client_version,
            ).init(alloc);
            const routes = comptime Route.from(Routes, EventProvider);
            const default_routes = comptime Route.from(DefaultRoutes, DefaultEventProvider);

            return .{
                .instrumented_allocator = instrumented_allocator,
                .user_deps = deps,
                .deps = default_deps,
                .routes = routes,
                .default_routes = default_routes,
            };
        }

        pub fn deinit(self: *Self) void {
            log.info("Shutting server down...", .{});
            metrics.deinitialize();
            _ = self.deps.deinit();
            self.instrumented_allocator.*.child_allocator.destroy(self.instrumented_allocator);
        }

        pub fn configure(self: *Self) !void {
            var base_injector = try Injector.init(&self.deps, null);
            var user_injector = try Injector.init(self.user_deps, &base_injector);

            var cl = try user_injector.require(*client.AmqpClient);

            var routes = DisjointSlice(Route){ .slices = &.{ self.routes, self.default_routes } };
            var iter = routes.iterator();
            while (iter.next()) |route| {
                try cl.openChannel(
                    route.metadata.exchange,
                    route.metadata.queue,
                    route.metadata.queue,
                );
                if (route.method == .consume) {
                    var channel = try cl.getChannel(route.metadata.queue);
                    try channel.configureConsume();
                    try metrics.consumeQueue(route.metadata.queue);
                } else {
                    try metrics.publishQueue(route.metadata.queue, route.metadata.exchange);
                }
            }
        }

        pub fn handlePublish(self: *Self) !void {
            var base_injector = try Injector.init(&self.deps, null);
            var user_injector = try Injector.init(self.user_deps, &base_injector);
            const PublishArgs = std.meta.Tuple(&.{*Injector});
            var cl = try user_injector.require(*client.AmqpClient);
            defer cl.reset();
            var internal_arena = try user_injector.require(mem.InternalArena);
            defer internal_arena.reset();
            var timer = try base_injector.require(Timer);

            var routes = DisjointSlice(Route){ .slices = &.{ self.routes, self.default_routes } };
            var route_iterator = routes.iterator();

            while (route_iterator.next()) |route| {
                if (route.method != .publish) continue;
                if (route.handlers.event) |event_handler| {
                    var scoped_deps = std.mem.zeroInit(UserScopedDependencies, .{});
                    var scoped_injector = try Injector.init(&scoped_deps, &user_injector);
                    defer scoped_injector.maybeDeconstruct();
                    const args = PublishArgs{&scoped_injector};
                    const ready = @call(.auto, event_handler, args) catch |e| {
                        log.err(
                            "Encountered an error while querying the event provider for '{s}/{s}': {}",
                            .{ route.metadata.exchange, route.metadata.queue, e },
                        );
                        continue;
                    };
                    if (ready) {
                        const msg = @call(.auto, route.handlers.publish.?, args) catch |e| {
                            try metrics.publishError(route.metadata.queue, route.metadata.exchange);
                            log.err(
                                "Encountered an error while publishing an event on '{s}/{s}': {}",
                                .{ route.metadata.exchange, route.metadata.queue, e },
                            );
                            continue;
                        };
                        var current_channel = try cl.getChannel(route.metadata.queue);
                        try current_channel.publish(msg);
                        try metrics.publish(route.metadata.queue, route.metadata.exchange);
                    }
                }
                internal_arena.reset();
            }
            try timer.step();
        }

        pub fn handleConsume(self: *Self, interval: u64) !void {
            const ConsumeArgs = std.meta.Tuple(&.{ *Injector, []const u8 });
            var base_injector = try Injector.init(&self.deps, null);
            var user_injector = try Injector.init(self.user_deps, &base_injector);
            var cl = try user_injector.require(*client.AmqpClient);
            defer cl.reset();
            var internal_arena = try user_injector.require(mem.InternalArena);
            defer internal_arena.reset();
            var routes = DisjointSlice(Route){ .slices = &.{ self.routes, self.default_routes } };

            var remaining: i64 = @intCast(interval);
            var total: i32 = 0;
            var handled: i32 = 0;
            main: while (remaining > 0) {
                const rabbitmq_wait = @divTrunc(remaining, std.time.ns_per_us);
                const start_time = try std.time.Instant.now();
                const envelope = try cl.consume(internal_arena.allocator(), rabbitmq_wait);
                defer internal_arena.reset();
                if (envelope) |response| {
                    total += 1;
                    try metrics.consume(response.queue);
                    var pub_route_iterator = routes.iterator();
                    while (pub_route_iterator.next()) |route| {
                        if (route.method != .consume) continue;
                        if (!std.mem.eql(u8, route.metadata.queue, response.queue) or
                            !std.mem.eql(u8, route.metadata.exchange, response.exchange)) continue;
                        handled += 1;
                        {
                            var scoped_deps = std.mem.zeroInit(UserScopedDependencies, .{});
                            var scoped_injector = try Injector.init(&scoped_deps, &user_injector);
                            defer scoped_injector.maybeDeconstruct();
                            const args = ConsumeArgs{ &scoped_injector, response.message.body };
                            @call(.auto, route.handlers.consume.?, args) catch |e| {
                                log.err(
                                    "Encountered an error while consuming a message on '{s}/{s}': {}\n\t{s}\n",
                                    .{ route.metadata.exchange, route.metadata.queue, e, response.message.body },
                                );
                                var current_channel = try cl.getChannel(route.metadata.queue);
                                try current_channel.reject(response.delivery_tag, false);
                            };
                            var current_channel = try cl.getChannel(route.metadata.queue);
                            try current_channel.ack(response.delivery_tag);
                            try metrics.ack(route.metadata.queue);
                            const end_time = try std.time.Instant.now();
                            const diff = end_time.since(start_time);
                            remaining -= @intCast(diff);
                        }
                        internal_arena.reset();
                        // Release the memory used up by the message processing.
                        // In high volume scenarios it might be worth letting memory accumulate
                        // and then releasing it at the end though since we hold on to the memory
                        // this probably doesn't cost us very much.

                        continue :main; // We can just let the loop fall through but this way we
                        // are already prepped in case we need to add more substantial
                        // logic after i.e rejection and whatnot
                    }
                }
                const end_time = try std.time.Instant.now();
                const diff = end_time.since(start_time);
                remaining -= @intCast(diff);
            }
            //std.log.info("Cycle: {}/{}.", .{ handled, total });
        }

        pub fn run(self: *Self, extra: struct { cycles: u64 }) !void {
            var base_injector = try Injector.init(&self.deps, null);
            var user_injector = try Injector.init(self.user_deps, &base_injector);
            const base_conf = try user_injector.require(config.BaseConfig);
            var rem_cycles = extra.cycles;
            self.configure() catch |e| {
                log.err("Encountered an error while configuring the client: {}", .{e});
                return e;
            };
            const interval: u64 = base_conf.config.polling_interval;
            while (true) {
                if (extra.cycles > 0 and rem_cycles == 0) {
                    break;
                } else if (extra.cycles > 0) {
                    rem_cycles -= 1;
                }

                try metrics.resetCycle();
                const start_time = try std.time.Instant.now();
                self.handlePublish() catch |e| {
                    log.err("Encountered an error while handling publishing events: {}. This is likely a bug in KWatcher.", .{e});
                    return e;
                };
                self.handleConsume(interval) catch |e| {
                    log.err("Encountered an error while handling publishing events: {}. This is likely a bug in KWatcher.", .{e});
                    return e;
                };
                const end_time = try std.time.Instant.now();
                const duration_us = end_time.since(start_time) / std.time.ns_per_us;
                try metrics.cycle(duration_us);
                self.retries = 0;
                self.backoff = 5;
            }
        }

        pub fn reset(self: *Self) !void {
            var base_injector = try Injector.init(&self.deps, null);
            var user_injector = try Injector.init(self.user_deps, &base_injector);
            const allocator = try user_injector.require(std.mem.Allocator);

            if (self.deps.client_cache) |cl| {
                cl.deinit(); // This is probably pointless since the connection is dead anyway but might as well.
                allocator.destroy(cl);
            }
            self.deps.client_cache = null; // let it get reinitialized again by the factory.
            std.time.sleep(self.backoff * std.time.ns_per_s);
            try self.configure(); // if this fails we let it abort.
        }

        pub fn start(self: *Self) !void {
            // In contrast to run, start will try to connect again in case a disconnection occurs.
            var base_injector = try Injector.init(&self.deps, null);
            var user_injector = try Injector.init(self.user_deps, &base_injector);
            const allocator = try user_injector.require(std.mem.Allocator);
            while (true) {
                self.run(.{ .cycles = 0 }) catch |e| {
                    if (e == error.AuthFailure) {
                        return e; // We really can't do anything if the credentials are wrong.
                    }

                    if (self.retries > 10) {
                        log.err("Failed to reconnect after {} retries. Aborting...", .{self.retries});
                        return error.ReconnectionFailure;
                    }
                    log.err(
                        "Got disconnected with: {}. Retrying ({}) after {} seconds.",
                        .{ e, self.retries, self.backoff },
                    );
                    std.time.sleep(self.backoff * std.time.ns_per_s);
                    //NOTE: It might be worth it to clean out the configuration as well.
                    //      So we can potentially 'hot-reload' a configuration that caused the error.
                    if (self.deps.client_cache) |cl| {
                        cl.deinit(); // This is probably pointless since the connection is dead anyway but might as well.
                        allocator.destroy(cl);
                    }
                    self.deps.client_cache = null; // let it get reinitialized again by the factory.
                    self.backoff *= 2;
                    self.retries += 1;
                };
            }
        }
    };
}
