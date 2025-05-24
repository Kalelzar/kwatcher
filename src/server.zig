const std = @import("std");
const log = std.log.scoped(.kwatcher);
const klib = @import("klib");
const meta = klib.meta;
const DisjointSlice = klib.DisjointSlice;

const schema = @import("schema.zig");
const config = @import("config.zig");
const metrics = @import("metrics.zig");
const mem = @import("mem.zig");
const Client = @import("client.zig");
const AmqpClient = @import("amqp_client.zig");

const DefaultRoutes = @import("default_routes.zig");

const Injector = @import("injector.zig").Injector;
const Route = @import("route.zig").Route;
const context = @import("context.zig");
const InternFmtCache = @import("intern_fmt_cache.zig");

const protocol = @import("protocol/protocol.zig");
const Timer = @import("timer.zig");

fn Dependencies(comptime Context: type, comptime UserConfig: type, comptime client_name: []const u8, comptime client_version: []const u8) type {
    const __ignore = struct {};

    return struct {
        const Self = @This();
        const UserContext = @FieldType(Context, "custom");
        allocator: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        internal_arena: mem.InternalArena,
        instrumented_allocator: *klib.mem.InstrumentedAllocator,
        intern_fmt_cache: *InternFmtCache,

        client_cache: ?*AmqpClient = null,
        timer: ?Timer = null,
        user_info: ?schema.UserInfo = null,
        user_config: ?UserConfig = null,
        base_config: ?config.BaseConfig = null,
        merged_config: ?config.Config(UserConfig) = null,
        context: Context = .{},

        clientInfo: schema.ClientInfo = .{
            .version = client_version,
            .name = client_name,
        },

        pub fn userContextFactory(ctx: *Context) *UserContext {
            return &ctx.custom;
        }

        pub fn clientRegistryFactory(ctx: *Context) *protocol.client_registration.registry {
            return &ctx.client;
        }

        pub fn timerFactory(self: *Self, allocator: std.mem.Allocator, base_config: config.BaseConfig) !Timer {
            if (self.timer) |res| {
                return res;
            } else {
                var timer = Timer.init(allocator);
                try timer.register("heartbeat", base_config.config.heartbeat_interval);
                try timer.register("metrics", base_config.config.metrics_interval_ns);
                // TODO: Register elsewhere
                try timer.register("announce", base_config.config.heartbeat_interval);
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

        pub fn clientFactory(self: *Self, allocator: std.mem.Allocator, config_file: config.BaseConfig) !*AmqpClient {
            if (self.client_cache) |res| {
                return res;
            } else {
                const amqp_client = try allocator.create(AmqpClient);
                amqp_client.* = try AmqpClient.init(allocator, config_file, client_name);
                try AmqpClient.connect(amqp_client);
                self.client_cache = amqp_client;
                return self.client_cache.?;
            }
        }

        pub fn clientProxyFactory(amqp_client: *AmqpClient) Client {
            return amqp_client.client();
        }

        pub fn init(allocator: std.mem.Allocator) !Self {
            const arr_ptr = try allocator.create(std.heap.ArenaAllocator);
            const instr_ptr = try allocator.create(klib.mem.InstrumentedAllocator);
            errdefer allocator.destroy(arr_ptr);
            const ifc_ptr = try allocator.create(InternFmtCache);
            errdefer allocator.destroy(ifc_ptr);

            const result = Self{
                .intern_fmt_cache = ifc_ptr,
                .allocator = allocator,
                .instrumented_allocator = instr_ptr,
                .arena = arr_ptr,
                .internal_arena = try mem.InternalArena.init(allocator, metrics.shim),
            };
            result.instrumented_allocator.* = metrics.instrumentAllocator(std.heap.page_allocator);
            result.arena.* = std.heap.ArenaAllocator.init(instr_ptr.allocator());
            result.intern_fmt_cache.* = InternFmtCache.init(instr_ptr.allocator());
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

            self.intern_fmt_cache.deinit();
            self.allocator.destroy(self.intern_fmt_cache);
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
    comptime UserContext: type,
    comptime Routes: type,
    comptime EventProvider: type,
) type {
    return struct {
        const Self = @This();
        const Context = context.Context(UserContext);
        instrumented_allocator: *klib.mem.InstrumentedAllocator,
        deps: Dependencies(Context, UserConfig, client_name, client_version),
        user_deps: *UserSingletonDependencies,
        routes: std.ArrayListUnmanaged(Route(Context)),

        consumers: std.StringHashMapUnmanaged(Route(Context)),
        publishers: std.ArrayListUnmanaged(Route(Context)),

        retries: i8 = 0,
        backoff: u64 = 5,
        should_run: std.atomic.Value(bool) = .init(true),

        pub fn init(allocator: std.mem.Allocator, deps: *UserSingletonDependencies) !Self {
            var instrumented_allocator = try allocator.create(klib.mem.InstrumentedAllocator);
            instrumented_allocator.* = metrics.instrumentAllocator(allocator);
            const alloc = instrumented_allocator.allocator();
            try metrics.initialize(alloc, client_name, client_version, .{});
            const default_deps = try Dependencies(
                Context,
                UserConfig,
                client_name,
                client_version,
            ).init(alloc);

            const user_routes = comptime Route(Context).from(Routes, EventProvider);
            const default_routes = comptime Route(Context).from(DefaultRoutes, DefaultEventProvider);
            const client_registration_routes = comptime Route(Context).from(
                protocol.client_registration.route,
                protocol.client_registration.events,
            );

            const route_count = user_routes.len + client_registration_routes.len + default_routes.len;

            var routes = try std.ArrayListUnmanaged(Route(Context)).initCapacity(alloc, route_count);

            routes.appendSliceAssumeCapacity(user_routes);
            routes.appendSliceAssumeCapacity(default_routes);
            routes.appendSliceAssumeCapacity(client_registration_routes);

            return .{
                .instrumented_allocator = instrumented_allocator,
                .user_deps = deps,
                .deps = default_deps,
                .routes = routes,
                .consumers = .{},
                .publishers = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            log.info("Shutting server down...", .{});
            metrics.deinitialize();
            _ = self.deps.deinit();
            self.instrumented_allocator.*.child_allocator.destroy(self.instrumented_allocator);
        }

        pub fn configure(self: *Self) !void {
            log.debug("Configuring server", .{});
            var base_injector = try Injector.init(&self.deps, null);
            var user_injector = try Injector.init(self.user_deps, &base_injector);

            const client = try user_injector.require(Client);

            const alloc = self.instrumented_allocator.allocator();
            self.publishers.clearRetainingCapacity();
            var ki = self.consumers.keyIterator();
            while (ki.next()) |e| {
                alloc.free(e.*);
            }
            self.consumers.clearRetainingCapacity();

            for (self.routes.items) |*route_ptr| {
                var route = route_ptr.*;
                const existing = try (&route).updateBindings(&user_injector);
                if (existing) |_| {
                    @panic("A consumer tag shouldn't exist yet. Something is very wrong. Server state corrupted... Aborting");
                }
                const ct = try (&route).bind(client);
                if (ct) |consumer_tag| {
                    log.debug(
                        "Assigning '{} {s}/{s}/{?s}' to {s}",
                        .{
                            route.method,
                            route.binding.exchange,
                            route.binding.route,
                            route.binding.queue,
                            consumer_tag,
                        },
                    );
                    try self.consumers.put(alloc, try alloc.dupe(u8, consumer_tag), route);
                } else {
                    try self.publishers.append(alloc, route);
                }
            }
        }

        pub fn handlePublish(self: *Self) !void {
            var base_injector = try Injector.init(&self.deps, null);
            var user_injector = try Injector.init(self.user_deps, &base_injector);
            const PublishArgs = std.meta.Tuple(&.{*Injector});
            var cl = try user_injector.require(Client);
            defer cl.reset();
            var internal_arena = try user_injector.require(mem.InternalArena);
            defer internal_arena.reset();
            var timer = try base_injector.require(Timer);
            for (self.publishers.items) |*route| {
                defer internal_arena.reset();
                const event_handler = route.handlers.event.?;

                // Prepare dependency injection
                var scoped_deps = std.mem.zeroInit(UserScopedDependencies, .{});
                var scoped_injector = try Injector.init(&scoped_deps, &user_injector);
                defer scoped_injector.maybeDeconstruct();
                var binding_injector = try Injector.init(@constCast(&.{ .binding = @constCast(&route.binding) }), &scoped_injector);
                defer binding_injector.maybeDeconstruct();
                const args = PublishArgs{&binding_injector};

                // Readiness check
                const ready = @call(.auto, event_handler, args) catch |e| {
                    log.err(
                        "Encountered an error while querying the event provider for '{s}/{s}': {}",
                        .{ route.binding.exchange, route.binding.route, e },
                    );
                    continue;
                };
                if (!ready) continue;

                // Publish message to the client.
                const msg = @call(.auto, route.handlers.publish.?, args) catch |e| {
                    try metrics.publishError(route.binding.route, route.binding.exchange);
                    log.err(
                        "Encountered an error while publishing an event on '{s}/{s}': {}",
                        .{ route.binding.exchange, route.binding.route, e },
                    );
                    continue;
                };
                try cl.publish(msg, .{});
                try metrics.publish(route.binding.route, route.binding.exchange);
            }
            try timer.step();
        }

        pub fn handleConsume(self: *Self, interval: u64) !void {
            const ConsumeArgs = std.meta.Tuple(&.{ *Injector, []const u8 });
            var base_injector = try Injector.init(&self.deps, null);
            var user_injector = try Injector.init(self.user_deps, &base_injector);
            var cl = try user_injector.require(Client);
            defer cl.reset();
            var internal_arena = try user_injector.require(mem.InternalArena);
            defer internal_arena.reset();

            var remaining: i64 = @intCast(interval);
            var total: i32 = 0;
            var handled: i32 = 0;
            main: while (remaining > 0) {
                const rabbitmq_wait = @divTrunc(remaining, std.time.ns_per_us);
                const start_time = try std.time.Instant.now();
                var envelope = try cl.consume(rabbitmq_wait);
                defer internal_arena.reset();
                if (envelope) |*response| {
                    defer response.deinit();
                    total += 1;
                    try metrics.consume(response.routing_key);
                    const maybe_route = self.consumers.getPtr(response.consumer_tag);
                    if (maybe_route == null) return error.InvalidConsumer;
                    const route = maybe_route.?;

                    var scoped_deps = std.mem.zeroInit(UserScopedDependencies, .{});
                    var scoped_injector = try Injector.init(&scoped_deps, &user_injector);
                    defer scoped_injector.maybeDeconstruct();
                    var binding_injector = try Injector.init(@constCast(&.{ .binding = &route.binding }), &scoped_injector);
                    defer binding_injector.maybeDeconstruct();
                    switch (route.method) {
                        .consume => {
                            handled += 1;
                            {
                                const args = ConsumeArgs{ &binding_injector, response.message.body };
                                @call(.auto, route.handlers.consume.?, args) catch |e| {
                                    log.err(
                                        "Encountered an error while consuming a message on '{s}/{s}': {}\n\t{s}\n",
                                        .{ route.binding.exchange, route.binding.route, e, response.message.body },
                                    );
                                    try cl.reject(response.delivery_tag, false, .{});
                                    continue;
                                };
                                try cl.ack(response.delivery_tag, .{});
                                try metrics.ack(route.binding.route);
                                const end_time = try std.time.Instant.now();
                                const diff = end_time.since(start_time);
                                remaining -= @intCast(diff);
                            }
                        },
                        .reply => {
                            handled += 1;
                            {
                                const reply_to = (response.message.basic_properties.get(.reply_to) orelse {
                                    log.err("Reply handler didn't receive a reply queue. Not acknowledging invalid request", .{});
                                    continue;
                                }).slice() orelse unreachable;

                                const args = ConsumeArgs{ &binding_injector, response.message.body };
                                log.info("Replying to {s}/{s}", .{ route.binding.exchange, reply_to });
                                var msg: schema.SendMessage = @call(.auto, route.handlers.reply.?, args) catch |e| {
                                    log.err(
                                        "Encountered an error while replying a message on '{s}/{s}': {}\n\t{s}\n",
                                        .{ route.binding.exchange, route.binding.route, e, response.message.body },
                                    );
                                    try cl.reject(response.delivery_tag, false, .{});
                                    continue;
                                };
                                if (response.message.basic_properties.get(.correlation_id)) |ci| {
                                    msg.options.correlation_id = ci.slice();
                                }
                                msg.options.routing_key = reply_to;
                                try cl.publish(msg, .{});
                                try metrics.publish(reply_to, route.binding.exchange);
                                // Only ack the message if the response is successful. That way we get to retry it if it fails.
                                try cl.ack(response.delivery_tag, .{});
                                try metrics.ack(route.binding.route);
                                const end_time = try std.time.Instant.now();
                                const diff = end_time.since(start_time);
                                remaining -= @intCast(diff);
                            }
                        },
                        else => {
                            return error.InvalidMethod;
                        },
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
                const end_time = try std.time.Instant.now();
                const diff = end_time.since(start_time);
                remaining -= @intCast(diff);
            }
            //std.log.info("Cycle: {}/{}.", .{ handled, total });
        }

        pub fn run(self: *Self, extra: struct { cycles: u64 }) !void {
            const alloc = self.instrumented_allocator.allocator();
            var base_injector = try Injector.init(&self.deps, null);
            var user_injector = try Injector.init(self.user_deps, &base_injector);
            const base_conf = try user_injector.require(config.BaseConfig);
            var rem_cycles = extra.cycles;
            self.configure() catch |e| {
                log.err("Encountered an error while configuring the client: {}", .{e});
                return e;
            };
            const interval: u64 = base_conf.config.polling_interval;
            while (self.should_run.raw) {
                if (extra.cycles > 0 and rem_cycles == 0) {
                    break;
                } else if (extra.cycles > 0) {
                    rem_cycles -= 1;
                }

                try metrics.resetCycle();
                const start_time = try std.time.Instant.now();
                for (self.publishers.items) |*route| {
                    const ct = try route.updateBindings(&user_injector);
                    if (ct) |_| {
                        return error.UnexpectedConsumerTag;
                    }
                }

                var it = self.consumers.iterator();
                while (it.next()) |entry| {
                    const maybe_new = try entry.value_ptr.updateBindings(&user_injector);
                    if (maybe_new == null) return error.ExpectedConsumerTag;
                    const new = maybe_new.?;
                    if (!std.mem.eql(u8, new, entry.key_ptr.*)) {
                        const v = entry.value_ptr.*;
                        const k = entry.key_ptr.*;
                        self.consumers.removeByPtr(entry.key_ptr);
                        alloc.free(k);
                        try self.consumers.put(alloc, try alloc.dupe(u8, new), v);
                        log.debug("--------------- NEW {s}     -----------", .{new});
                        continue;
                    }
                }

                self.handlePublish() catch |e| {
                    log.err("Encountered an error while handling publishing events: {}. This is likely a bug in KWatcher.", .{e});
                    return e;
                };
                self.handleConsume(interval) catch |e| {
                    log.err("Encountered an error while handling consuming events: {}. This is likely a bug in KWatcher.", .{e});
                    return e;
                };
                const end_time = try std.time.Instant.now();
                const duration_us = end_time.since(start_time) / std.time.ns_per_us;
                try metrics.cycle(duration_us);
            }
        }

        pub fn reset(self: *Self) !void {
            var base_injector = try Injector.init(&self.deps, null);
            var user_injector = try Injector.init(self.user_deps, &base_injector);
            const client = try user_injector.require(Client);

            client.disconnect() catch |e| switch (e) {
                .InvalidState => {},
                else => return e,
            };

            std.time.sleep(self.backoff * std.time.ns_per_s);
            try client.connect();
            try self.configure(); // if this fails we let it abort.
        }

        pub fn stop(self: *Self) void {
            self.should_run.store(false, .unordered);
        }

        pub fn start(self: *Self) !void {
            // In contrast to run, start will try to connect again in case a disconnection occurs.
            var base_injector = try Injector.init(&self.deps, null);
            var user_injector = try Injector.init(self.user_deps, &base_injector);
            main_loop: while (self.should_run.raw) {
                self.run(.{ .cycles = 0 }) catch |e| {
                    if (e == error.AuthFailure) {
                        return e; // We really can't do anything if the credentials are wrong.
                    }

                    switch (e) {
                        error.Disconnected,
                        error.HeartbeatTimeout,
                        => {},
                        error.InvalidState => {
                            const old_client = self.deps.client_cache;
                            if (old_client) |c| {
                                c.deinit();
                            }
                            self.deps.client_cache = null;
                        },
                        else => {
                            log.err("Cannot recover from error: {}. Aborting..", .{e});
                            return error.ReconnectionFailure;
                        },
                    }

                    var last_error: anyerror = e;

                    while (self.retries <= 10) {
                        log.err(
                            "Got disconnected with: {}. Retrying ({}) after {} seconds.",
                            .{ last_error, self.retries, self.backoff },
                        );
                        std.time.sleep(self.backoff * std.time.ns_per_s);

                        self.backoff *= 2;
                        self.retries += 1;

                        _ = user_injector.require(Client) catch |ce| {
                            last_error = ce;
                            continue;
                        };

                        self.backoff = 5;
                        self.retries = 0;
                        continue :main_loop;
                    }

                    log.err("Failed to reconnect after {} retries. Aborting...", .{self.retries});
                    return error.ReconnectionFailure;
                };
            }
        }
    };
}
