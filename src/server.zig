const std = @import("std");

const schema = @import("schema.zig");
const config = @import("config.zig");
const meta = @import("meta.zig");
const mem = @import("mem.zig");
const client = @import("client.zig");

const Injector = @import("injector.zig").Injector;
const Route = @import("route.zig").Route;

pub const Timer = struct {
    //NOTE: The resolution here is down to the second which isn't very accurate.
    //This should use at least milliseconds.
    const TimerEntry = struct { interval: i64, last_activation: i64 };
    store: std.StringHashMap(TimerEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Timer {
        const map = std.StringHashMap(TimerEntry).init(allocator);
        return .{
            .store = map,
            .allocator = allocator,
        };
    }

    pub fn register(self: *Timer, name: []const u8, interval: i64) !void {
        const current_time = std.time.timestamp();
        const entry = TimerEntry{
            .interval = interval,
            .last_activation = current_time - interval,
        };
        try self.store.put(name, entry);
    }

    pub fn ready(self: *const Timer, name: []const u8) !bool {
        const entry = self.store.get(name) orelse return error.NotFound;
        const current_time = std.time.timestamp();
        if (current_time - entry.last_activation >= entry.interval) {
            return true;
        }
        return false;
    }

    pub fn step(self: *Timer) void {
        const current_time = std.time.timestamp();
        var iter = self.store.valueIterator();
        while (iter.next()) |entry_ptr| {
            if (current_time - entry_ptr.last_activation >= entry_ptr.interval) {
                entry_ptr.last_activation += entry_ptr.interval;
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

        client_cache: ?client.AmqpClient = null,
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

        pub fn clientFactory(self: *Self, allocator: std.mem.Allocator, config_file: config.BaseConfig) !client.AmqpClient {
            if (self.client_cache) |res| {
                return res;
            } else {
                const amqp_client = try client.AmqpClient.init(allocator, config_file, client_name);
                self.client_cache = amqp_client;
                return self.client_cache.?;
            }
        }

        pub fn init(allocator: std.mem.Allocator) !Self {
            const arr_ptr = try allocator.create(std.heap.ArenaAllocator);
            errdefer allocator.destroy(arr_ptr);
            const result = Self{
                .allocator = allocator,
                .arena = arr_ptr,
                .internal_arena = try mem.InternalArena.init(allocator),
            };
            result.arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            return result;
        }

        pub fn deinit(self: *Self) __ignore {
            if (self.timer) |_|
                self.timer.?.deinit();

            if (self.user_info) |u|
                u.deinit();

            if (self.client_cache) |c|
                c.deinit();

            self.arena.deinit();
            self.allocator.destroy(self.arena);

            return .{};
        }
    };
}

pub fn Server(
    comptime client_name: []const u8,
    comptime client_version: []const u8,
    comptime UserSingletonDependencies: type,
    comptime UserScopedDependencies: type,
    comptime UserConfig: type,
    comptime Routes: type,
    comptime EventHandler: type,
) type {
    return struct {
        const Self = @This();
        deps: Dependencies(UserConfig, client_name, client_version),
        user_deps: UserSingletonDependencies,
        routes: []const Route,

        pub fn init(allocator: std.mem.Allocator, deps: UserSingletonDependencies) !Self {
            const default_deps = try Dependencies(
                UserConfig,
                client_name,
                client_version,
            ).init(allocator);
            const routes = comptime Route.from(Routes, EventHandler);

            return .{
                .user_deps = deps,
                .deps = default_deps,
                .routes = routes,
            };
        }

        pub fn deinit(self: *Self) void {
            std.log.info("Shutting server down...", .{});
            _ = self.deps.deinit();
        }

        pub fn run(self: *Self) !void {
            var base_injector = try Injector.init(&self.deps, null);
            var user_injector = try Injector.init(&self.user_deps, &base_injector);
            const IT = std.meta.Tuple(&.{*Injector});
            const ConsumeArgs = std.meta.Tuple(&.{ *Injector, []const u8 });

            var cl = try user_injector.require(client.AmqpClient);
            var internal_arena = try user_injector.require(mem.InternalArena);
            const base_conf = try user_injector.require(config.BaseConfig);

            for (self.routes) |route| {
                try cl.openChannel(
                    route.metadata.exchange,
                    route.metadata.queue,
                    route.metadata.queue,
                );
                if (route.method == .consume) {
                    var channel = try cl.getChannel(route.metadata.queue);
                    try channel.configureConsume();
                }
            }
            while (true) {
                var timer = try base_injector.require(Timer);
                for (0..self.routes.len) |i| {
                    const route = self.routes[i];
                    if (route.method != .publish) continue;
                    if (route.handlers.event) |e| {
                        var scoped_deps = std.mem.zeroInit(UserScopedDependencies, .{});
                        var scoped_injector = try Injector.init(&scoped_deps, &user_injector);
                        defer scoped_injector.maybeDeconstruct();
                        const args = IT{&scoped_injector};
                        const ready = try @call(.auto, e, args);
                        if (ready) {
                            const msg = try @call(.auto, route.handlers.publish.?, args);
                            var current_channel = try cl.getChannel(route.metadata.queue);
                            try current_channel.publish(msg);
                        }
                    }
                    internal_arena.reset();
                }
                timer.step();
                cl.reset();

                var interval: i64 = base_conf.config.polling_interval;
                var total: i32 = 0;
                var handled: i32 = 0;
                main: while (interval > 0) {
                    const start = try std.time.Instant.now();
                    const e = try cl.consume(interval);
                    if (e) |response| {
                        total += 1;
                        for (self.routes) |route| {
                            if (route.method != .consume) continue;
                            if (!std.mem.eql(u8, route.metadata.queue, response.queue) or
                                !std.mem.eql(u8, route.metadata.exchange, response.exchange)) continue;
                            handled += 1;
                            {
                                var scoped_deps = std.mem.zeroInit(UserScopedDependencies, .{});
                                var scoped_injector = try Injector.init(&scoped_deps, &user_injector);
                                defer scoped_injector.maybeDeconstruct();
                                const args = ConsumeArgs{ &scoped_injector, response.message.body };
                                try @call(.auto, route.handlers.consume.?, args);
                                var current_channel = try cl.getChannel(route.metadata.queue);
                                try current_channel.ack(response.delivery_tag);
                                const end = try std.time.Instant.now();
                                const diff: i64 = @intCast(end.since(start));
                                interval -= diff;
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
                    const end = try std.time.Instant.now();
                    const diff: i64 = @intCast(end.since(start));
                    interval -= diff;
                }
                //std.log.info("Cycle: {}/{}.", .{ handled, total });
            }
        }
    };
}
