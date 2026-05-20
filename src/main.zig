const std = @import("std");
const builtin = @import("builtin");

const kw = @import("kwatcher");
const httpz = @import("httpz");

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .dependency, .level = .info },
        .{ .scope = .server, .level = .info },
        .{ .scope = .amqp_client, .level = .info },
        .{ .scope = .circuit_breaker_client, .level = .warn },
        .{ .scope = .intern_fmt_cache, .level = .warn },
        .{ .scope = .replay, .level = .info },
        .{ .scope = .client, .level = .info },
        .{ .scope = .example, .level = .info },
    },
};

const log = std.log.scoped(.example);

// ============================================================================
// Configuration
// ============================================================================

/// The application configuration schema.
/// This maps to a JSON config file (e.g., example.json)
pub const Config = struct {
    driver: struct {
        amqp: kw.config.BaseConfig,
    },
    middleware: struct {
        cors: kw.middleware.Cors.Config,
    },
    app: AppConfig,
};

pub const AppConfig = struct {
    greeting: []const u8 = "Hello",
    interval_seconds: u32 = 5,
};

// ============================================================================
// Custom Dependencies
// ============================================================================

/// A singleton dependency that maintains state across requests.
/// Registered as a static dependency.
const CounterDependency = struct {
    count: u64 = 0,

    pub fn increment(self: *CounterDependency) u64 {
        self.count += 1;
        return self.count;
    }
};

// ============================================================================
// Schemas
// ============================================================================

/// A simple heartbeat message schema
pub const HeartbeatMessage = struct {
    pub const schema_name = "heartbeat";
    pub const schema_version = 1;

    timestamp: i64,
    event: []const u8,
    count: u64,
    greeting: []const u8,
};

// ============================================================================
// Routes
// ============================================================================

/// AMQP route handlers.
/// Function names follow the pattern: "method:event exchange/routing_key"
const AmqpRoutes = struct {
    /// Publishes a heartbeat message to the "amq.direct" exchange with routing key "heartbeat"
    /// The context tuple contains: (timestamp, greeting_override)
    pub fn @"publish:heartbeat amq.direct/heartbeat"(
        ctx: struct { i64, ?[]const u8 },
        counter: *CounterDependency,
        app_config: *AppConfig,
    ) HeartbeatMessage {
        const count = counter.increment();
        const greeting = ctx.@"1" orelse app_config.greeting;

        log.info("Publishing heartbeat #{d} with greeting: {s}", .{ count, greeting });

        return .{
            .timestamp = ctx.@"0",
            .event = "heartbeat",
            .count = count,
            .greeting = greeting,
        };
    }
};

/// Cron route handlers.
/// Function names follow the pattern: "job_name schedule"
const CronRoutes = struct {
    /// Triggers every 5 seconds (second minute hour day month weekday)
    pub fn @"heartbeat_tick */5 * * * * *"(inj: *kw.deps.DepCtx) !void {
        const scheduler = try inj.require(Scheduler(.amqp));
        const timestamp = std.time.microTimestamp();

        // Publish a heartbeat event with no greeting override
        try scheduler.publish(
            .{ .heartbeat = .{ timestamp, null } },
            .{ .inj = inj },
        );
    }
};

/// HTTP route handlers.
/// Function names follow the pattern: "[MODIFIER] VERB /path [@identifier]"
const HTTPRoutes = struct {
    // --- /api/v1/users family (shared prefix) ---

    pub fn @"GET /"(_: kw.http.data.Request(null)) []const HeartbeatMessage {
        log.info("HELLO FROM SERVER", .{});
        return &.{};
    }

    pub fn @"GET /api/v1/users"(_: kw.http.data.Request(null)) []const HeartbeatMessage {
        return &.{};
    }

    pub fn @"GET /api/v1/ok"(_: kw.http.data.Request(null)) kw.http.data.Json(
        HeartbeatMessage,
        .{.ok},
    ) {
        return .{
            .value = .{
                .ok = .{
                    .timestamp = 0,
                    .event = "ok",
                    .count = 1,
                    .greeting = "Hello",
                },
            },
        };
    }

    pub fn @"GET /api/v1/bad"(_: kw.http.data.Request(null)) kw.http.data.Json(
        HeartbeatMessage,
        &.{400},
    ) {
        return .{
            .value = .{
                .bad_request = .{
                    .type = error.Bad,
                    .title = "Bad",
                    .instance = "HELLO",
                    .details = "An expected bad request",
                },
            },
        };
    }

    pub fn @"POST /api/v1/users"(ctx: kw.http.data.Request(struct { name: []const u8 })) HeartbeatMessage {
        return .{
            .timestamp = 0,
            .event = "user_created",
            .count = 0,
            .greeting = ctx.body.name,
        };
    }

    pub fn @"GET /api/v1/users/{id}"(ctx: struct {
        request: *kw.http.Request,
        response: *kw.http.Response,
        captures: struct { id: u64 },
    }) HeartbeatMessage {
        return .{
            .timestamp = 0,
            .event = "user_fetched",
            .count = ctx.captures.id,
            .greeting = "",
        };
    }

    pub fn @"GET /api/v1/users/{id}/name"(ctx: struct {
        request: *kw.http.Request,
        response: *kw.http.Response,
        captures: struct { id: u64 },
    }) []const u8 {
        _ = ctx;
        return "TODO";
    }

    pub fn @"GET /api/v1/users/{id}/id"(ctx: struct {
        request: *kw.http.Request,
        response: *kw.http.Response,
        captures: struct { id: u64 },
    }) []const u8 {
        _ = ctx;
        return "TODO";
    }

    pub fn @"DELETE /api/v1/users/{id}"(ctx: struct {
        request: *kw.http.Request,
        response: *kw.http.Response,
        captures: struct { id: u64 },
    }) []const u8 {
        _ = ctx;
        return "";
    }

    // --- /api/v1/config (shared /api/v1 prefix, different leaf) ---

    pub fn @"GET /api/v1/config"(
        rq: kw.http.data.FullRequest(
            null,
            struct { key: []const u8 },
        ),
    ) kw.http.data.Json(
        struct { key: []const u8, value: []const u8 },
        &.{ .ok, .bad_request },
    ) {
        if (rq.query.key.len == 0) {
            return .{
                .value = .{
                    .bad_request = .{
                        .type = error.EmptyQueryParam,
                        .title = "Empty query parameter",
                        .details = "Parameter 'key' is empty",
                        .instance = "TODO",
                    },
                },
            };
        }

        return .{
            .value = .{
                .ok = .{
                    .key = rq.query.key,
                    .value = "value",
                },
            },
        };
    }

    pub fn @"PUT /api/v1/config"(ctx: kw.http.data.Request(
        struct { greeting: []const u8, interval_seconds: u32 },
    )) AppConfig {
        return .{
            .greeting = ctx.body.greeting,
            .interval_seconds = ctx.body.interval_seconds,
        };
    }

    // --- /health (no shared prefix with /api) ---

    pub fn @"GET /health @healthCheck"(_: kw.http.data.Request(null)) struct { status: []const u8 } {
        return .{ .status = "ok" };
    }

    // --- /files (wildcard capture, no shared prefix) ---

    pub fn @"GET /files/{*path}"(ctx: struct {
        request: *kw.http.Request,
        response: *kw.http.Response,
        captures: struct { path: []const u8 },
    }) struct { content: []const u8 } {
        _ = ctx;
        return .{ .content = "" };
    }
};

// ============================================================================
// Driver Setup
// ============================================================================

/// Context type for dynamic routing (can hold request-scoped data)
const RouteContext = struct {
    request_id: u64 = 0,
};

/// AMQP driver configuration
const amqp_driver = kw.amqp.Driver
    .new(.amqp)
    .config("driver.amqp")
    .listen(false) // Don't consume, only publish
    .jobs(0) // No consumer jobs when not listening
    .routes(kw.meta.flatten(&.{
        kw.amqp.From(AmqpRoutes, RouteContext),
    }))
    .build();

/// Cron driver configuration
const cron_driver = kw.cron.Driver
    .new(.cron)
    .listen(true)
    .jobs(1)
    .routes(kw.cron.From(CronRoutes))
    .build();

const http_driver = kw.http.Driver
    .new(.http)
    .config("driver.http")
    .listen(true)
    .jobs(1)
    .routes(kw.middleware.cors(kw.http.From(HTTPRoutes, RouteContext)))
    .build();

/// Combined driver registry
const drivers = kw.DriverRegistry
    .new()
    .registerHandler(cron_driver)
    .registerHandler(amqp_driver)
    .registerHandler(http_driver);

/// Type alias for the scheduler (used to publish events from cron routes)
/// SchedulerMap() returns a function that maps driver keys to scheduler types
const Scheduler = drivers.SchedulerMap();

// ============================================================================
// Main Application
// ============================================================================

var config_slot: Config = undefined;

pub fn juicyMain(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Initialize metrics (optional)
    try kw.metrics.initialize(allocator, "example", "1.0.0", "example-client", .{});
    defer kw.metrics.deinitialize();

    // Load configuration from file
    config_slot = try kw.config.findConfigFile(Config, arena.allocator(), "example") orelse {
        std.log.err("Could not load config! Create 'example.json' with the required fields.", .{});
        std.log.err("Example config:", .{});
        std.log.err(
            \\{{
            \\  "driver": {{
            \\    "amqp": {{
            \\      "server": {{
            \\        "host": "localhost",
            \\        "port": 5672,
            \\        "heartbeat": 5
            \\      }},
            \\      "credentials": {{
            \\        "username": "guest",
            \\        "password": "guest"
            \\      }}
            \\    }}
            \\  }},
            \\  "app": {{
            \\    "greeting": "Hello",
            \\    "interval_seconds": 5
            \\  }}
            \\}}
        , .{});
        return error.MissingConfig;
    };

    // Create singleton dependencies
    var counter = CounterDependency{};
    var ctx: RouteContext = .{};

    // Build the dependency container
    // The chain of .with() and .static() calls registers dependencies at different lifetimes:
    // - .static(): Lives for the entire application lifetime
    // - .scoped(): Created fresh for each request
    const deps = kw.deps.DependencyContainer(Config)
        .new(drivers, allocator)
        // Register default dependencies (allocator pools, user info, client info)
        .with(.all, kw.default.withDefault(&config_slot, .{
            .name = "example",
            .version = "1.0.0",
        }), allocator)
        // Register app-specific config resolver
        .with(.all, kw.default.config(AppConfig, "app"), allocator)
        .with(.http, kw.default.config(kw.middleware.Cors.Config, "middleware.cors"), allocator)
        // Register AMQP client pool and connection handling
        .with(.amqp, kw.amqp.defaultFor(drivers, RouteContext), allocator)
        // Register our custom counter as a static dependency
        .static(.http, &ctx, allocator)
        .static(.amqp, &counter, allocator);

    // Create and start the server
    var server = try kw.server.Server(@TypeOf(deps), drivers)
        .init(allocator, deps, 4); // 2 consumer threads
    defer server.deinit();

    log.info("Starting example server...", .{});
    log.info("Press Ctrl+C to stop.", .{});

    try server.start();
}

pub fn main() !void {
    if (comptime builtin.mode == .Debug) {
        var gpa = std.heap.GeneralPurposeAllocator(.{
            .stack_trace_frames = 10,
        }).init;
        const allocator = gpa.allocator();
        juicyMain(allocator) catch |e| {
            std.log.err("Application error: {}", .{e});
        };
        _ = gpa.detectLeaks();
    } else {
        const alloc = std.heap.smp_allocator;
        try juicyMain(alloc);
    }
}
