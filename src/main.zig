const std = @import("std");
const builtin = @import("builtin");

const core = @import("kw-core");
const kwatcher = @import("kwatcher");
const amqp = @import("kw-amqp");
const http = @import("kw-http");
const cron = @import("kw-cron");
const action = @import("kw-action");
const signal = @import("kw-signal");
const httpz = @import("httpz");

const introspect = @import("kw-introspect");
const introspect_http = @import("kw-introspect--http");

const docs = @import("kw-gen--docs");

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
        amqp: core.config.BaseConfig,
        public: http.Config,
        private: http.Config,
    },
    middleware: struct {
        cors: http.middleware.Cors.Config,
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

    /// Unix timestamp (seconds) when the heartbeat was produced.
    timestamp: i64,
    /// The name of the event that triggered this heartbeat.
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
    pub fn @"heartbeat_tick */5 * * * * *"(inj: *core.deps.DepCtx) !void {
        const scheduler = try inj.require(Scheduler(.amqp));
        const timestamp = std.time.microTimestamp();

        // Publish a heartbeat event with no greeting override
        try scheduler.publish(
            .{ .heartbeat = .{ timestamp, null } },
            .{ .inj = inj },
        );
    }
};

/// Action route handlers.
/// Function names are the route id verbatim; the first tuple param is the call context.
const ActionRoutes = struct {
    pub fn greet(ctx: struct { []const u8 }) void {
        log.info("[action:greet] {s}", .{ctx.@"0"});
    }
};

/// Signal route handlers.
/// Function names follow the pattern: "SIG @identifier" (e.g. "INT @shutdown").
/// The first parameter is always the siginfo; any further params are injected deps.
/// Multiple handlers may target the same signal — all of them run.
/// Graceful shutdown on SIGINT/SIGTERM is provided by the pre-built
/// `signal.default.Shutdown` container, concatenated into the driver below.
/// Add your own handlers here; multiple handlers may target the same signal.
const SignalRoutes = struct {
    /// A second handler on SIGINT, demonstrating multi-handler dispatch
    /// (runs alongside the pre-built shutdown handler).
    pub fn @"INT @note"(_: signal.SignalInfo) void {
        log.info("[signal] second SIGINT handler ran too", .{});
    }
};

/// HTTP route handlers.
/// Function names follow the pattern: "[MODIFIER] VERB /path [@identifier]"
const HTTPRoutes = struct {
    // --- /api/v1/users family (shared prefix) ---

    /// Get the root index.
    /// This is a placeholder that just returns an empty object
    /// @200 An empty placeholder
    pub fn @"GET / @index"(_: http.data.Request(null)) []const HeartbeatMessage {
        log.info("HELLO FROM SERVER", .{});
        return &.{};
    }

    pub fn @"GET /api/v1/ok @okExample"(_: http.data.Request(null), inj: *core.deps.DepCtx) !http.data.Json(
        HeartbeatMessage,
        .{.ok},
    ) {
        const act: Scheduler(.action) = try inj.require(Scheduler(.action));
        const scron: Scheduler(.cron) = try inj.require(Scheduler(.cron));
        const ev = try act.callLater(.{ .greet = .{"hello from /ok"} }, .{ .inj = inj });
        try scron.after(5, ev);
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

    pub fn @"GET /api/v1/bad @badExample"(_: http.data.Request(null)) http.data.Json(
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

    pub fn @"GET /api/v1/users @listUsers"(_: http.data.Request(null)) []const HeartbeatMessage {
        return &.{};
    }

    pub fn @"POST /api/v1/users @createUser"(ctx: http.data.Request(struct { name: []const u8 })) HeartbeatMessage {
        return .{
            .timestamp = 0,
            .event = "user_created",
            .count = 0,
            .greeting = ctx.body.name,
        };
    }

    /// Fetch a single user by id. Returns a heartbeat snapshot for that user.
    pub fn @"GET /api/v1/users/{id} @getUser"(ctx: struct {
        request: *http.Request,
        response: *http.Response,
        captures: struct { id: u64 },
    }) HeartbeatMessage {
        return .{
            .timestamp = 0,
            .event = "user_fetched",
            .count = ctx.captures.id,
            .greeting = "",
        };
    }

    pub fn @"GET /api/v1/users/{id}/name @getUserName"(ctx: struct {
        request: *http.Request,
        response: *http.Response,
        captures: struct { id: u64 },
    }) []const u8 {
        _ = ctx;
        return "TODO";
    }

    pub fn @"GET /api/v1/users/{id}/id @getUserId"(ctx: struct {
        request: *http.Request,
        response: *http.Response,
        captures: struct { id: u64 },
    }) []const u8 {
        _ = ctx;
        return "TODO";
    }

    pub fn @"DELETE /api/v1/users/{id} @deleteUser"(ctx: struct {
        request: *http.Request,
        response: *http.Response,
        captures: struct { id: u64 },
    }) []const u8 {
        _ = ctx;
        return "";
    }

    // --- /api/v1/config (shared /api/v1 prefix, different leaf) ---

    pub fn @"GET /api/v1/config @getConfig"(
        rq: http.data.FullRequest(
            null,
            struct { key: []const u8 },
        ),
    ) http.data.Json(
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

    pub fn @"PUT /api/v1/config @updateConfig"(ctx: http.data.Request(
        struct { greeting: []const u8, interval_seconds: u32 },
    )) AppConfig {
        return .{
            .greeting = ctx.body.greeting,
            .interval_seconds = ctx.body.interval_seconds,
        };
    }

    // --- /health (no shared prefix with /api) ---

    pub fn @"GET /health @healthCheck"(_: http.data.Request(null)) struct { status: []const u8 } {
        return .{ .status = "ok" };
    }

    // --- /files (wildcard capture, no shared prefix) ---

    pub fn @"GET /files/{*path} @serveFile"(ctx: struct {
        request: *http.Request,
        response: *http.Response,
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
const amqp_driver = amqp.Driver
    .new(.amqp)
    .config("driver.amqp")
    .listen(false) // Don't consume, only publish
    .jobs(0) // No consumer jobs when not listening
    .routes(core.meta.flatten(&.{
        amqp.From(AmqpRoutes, RouteContext),
    }))
    .build();

/// Cron driver configuration
const cron_driver = cron.Driver
    .new(.cron)
    .listen(true)
    .jobs(1)
    .routes(cron.From(CronRoutes))
    .build();

/// Introspection UI routes assembled from the per-kind backends, merged per route-kind.
/// `Assemble` returns an empty set during docgen, so there's no isDocgen hedging here.
const introspection = introspect.Assemble(docs, .{introspect_http});

const http_driver = http.Driver
    .new(.public)
    .config("driver.public")
    .listen(true)
    .jobs(1)
    .routes(http.middleware.cors(http.From(HTTPRoutes, RouteContext)))
    .error_handler(http.DefaultErrorHandler)
    .build();

/// Second HTTP mount — serves the introspection UI, split off from the public API surface.
const private_http_driver = http.Driver
    .new(.private)
    .config("driver.private")
    .listen(true)
    .jobs(1)
    .routes(http.middleware.cors(introspection(.http)))
    .error_handler(http.DefaultErrorHandler)
    .build();

/// Action driver configuration (never listens; routes are just functions to call)
const action_driver = action.Driver
    .new(.action)
    .listen(false)
    .jobs(0)
    .routes(action.From(ActionRoutes))
    .build();

/// Signal driver configuration (always listens on a dedicated sigtimedwait thread)
const signal_driver = signal.Driver
    .new(.signal)
    .listen(true)
    .jobs(1)
    .routes(signal.From(SignalRoutes) ++ signal.From(signal.default.Shutdown))
    .build();

/// Combined driver registry
pub const drivers = struct {
    pub const drivers = reg: {
        const base = core.DriverRegistry
            .new()
            .registerHandler(cron_driver)
            .registerHandler(amqp_driver)
            .registerHandler(http_driver)
            .registerHandler(action_driver)
            .registerHandler(signal_driver);
        // The private introspection mount is included only in normal runtime builds, not
        // during docgen: the introspection UI is generated *from* the docs, so it must not
        // be part of the driver graph that produces them.
        break :reg if (docs.isDocgen) base else base.registerHandler(private_http_driver);
    };
};

/// Type alias for the scheduler (used to publish events from cron routes)
/// SchedulerMap() returns a function that maps driver keys to scheduler types
const Scheduler = drivers.drivers.SchedulerMap();

// ============================================================================
// Main Application
// ============================================================================

var config_slot: Config = undefined;

pub fn juicyMain(allocator: std.mem.Allocator) !void {
    // Block the signals owned by the signal driver process-wide BEFORE any thread
    // spawns, so every runtime thread inherits the block and the driver's dedicated
    // sigtimedwait thread is their sole consumer. Keep this set in sync with SignalRoutes.
    if (comptime builtin.os.tag == .linux) {
        var mask = std.posix.sigemptyset();
        std.posix.sigaddset(&mask, std.posix.SIG.INT);
        std.posix.sigaddset(&mask, std.posix.SIG.TERM);
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &mask, null);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Initialize metrics (optional)
    try core.metrics.initialize(allocator, "example", "1.0.0", "example-client", .{});
    defer core.metrics.deinitialize();

    // Load configuration from file
    config_slot = try core.config.findConfigFile(Config, arena.allocator(), "example") orelse {
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
    const base_deps = core.deps.DependencyContainer(Config)
        .new(drivers.drivers, allocator)
        // Register default dependencies (allocator pools, user info, client info)
        .with(.all, kwatcher.default.withDefault(&config_slot, .{
            .name = "example",
            .version = "1.0.l0",
        }), allocator)
        // Register app-specific config resolver
        .with(.all, kwatcher.default.config(AppConfig, "app"), allocator)
        .with(.public, kwatcher.default.config(http.middleware.Cors.Config, "middleware.cors"), allocator)
        // Register AMQP client pool and connection handling
        .with(.amqp, amqp.defaultFor(drivers.drivers, RouteContext), allocator)
        // TODO: create a http.defaultFor
        .with(.public, kwatcher.default.config(http.Config, "driver.public"), allocator)
        // Register our custom counter as a static dependency
        .static(.public, &ctx)
        .static(.amqp, &counter);

    // The private introspection mount is only registered outside docgen, so its dep wiring
    // must be gated on the same condition — otherwise the dephub rejects `.private` as an
    // unregistered category during docgen. It needs both its cors config (the routes are
    // cors-wrapped) and its own http config section.
    const deps = if (docs.isDocgen)
        base_deps
    else
        base_deps
            .with(.private, kwatcher.default.config(http.middleware.Cors.Config, "middleware.cors"), allocator)
            .with(.private, kwatcher.default.configKeyed("public", http.Config, "driver.public"), allocator)
            .with(.private, kwatcher.default.config(http.Config, "driver.private"), allocator);

    // Create and start the server
    var server = try kwatcher.server.Server(@TypeOf(deps), drivers.drivers)
        .init(allocator, deps, 4); // 4 consumer threads
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

comptime {
    std.testing.refAllDecls(@This());
}
