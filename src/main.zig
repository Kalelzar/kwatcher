const std = @import("std");
const builtin = @import("builtin");

const core = @import("kw-core");
const kwatcher = @import("kwatcher");
const amqp = @import("kw-amqp");
const protocol = @import("kw-protocol");
const http = @import("kw-http");
const cron = @import("kw-cron");
const action = @import("kw-action");
const signal = @import("kw-signal");
const sqlite = @import("kw-sqlite");
const auth_oidc = @import("kw-auth-oidc");
const httpz = @import("httpz");

const introspect = @import("kw-introspect");
const introspect_http = @import("kw-introspect--http");
const introspect_cron = @import("kw-introspect--cron");
const introspect_signal = @import("kw-introspect--signal");

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
    server: kwatcher.server.Config = .{},
    driver: struct {
        amqp: core.config.BaseConfig,
        public: http.Config,
        private: http.Config,
        sqlite: sqlite.Config = .{},
    },
    middleware: struct {
        cors: http.middleware.Cors.Config,
    },
    /// OIDC bearer-token verification settings for the routes wrapped in
    /// `WithAuth` below. Defaults point at a local dev Keycloak realm;
    /// override in the JSON for a real provider.
    auth: auth_oidc.Settings = .{
        .well_known = "http://localhost:8080/realms/kwatcher/.well-known/openid-configuration",
        .audience = "kwatcher",
    },
    /// IntrospectUI-only knobs — deliberately separate from `auth`: the UI
    /// is its own application with its own OIDC client/audience.
    introspect: struct {
        /// Verification settings for the UI's own bearer protection (the
        /// "introspect" scheme): same provider realm, distinct audience.
        auth: auth_oidc.Settings = .{
            .well_known = "http://localhost:8080/realms/kwatcher/.well-known/openid-configuration",
            .audience = "kw-introspect",
        },
        /// Public OIDC client for the UI's `/_introspect/login` button (must
        /// allow the `/_introspect/login/callback` redirect). Null leaves
        /// token-paste as the only way in.
        auth_client_id: ?[]const u8 = "kw-introspect",
        /// Public OIDC clients for the Auth tab's Try-it logins, one entry
        /// per scheme (drivers may each have their own scheme, and one
        /// driver may speak several). Each client must allow the
        /// `/_introspect/auth/{scheme}/callback` redirect.
        tryit_clients: []const introspect.security.LoginClient = &.{},
    } = .{},
    /// Per-protocol tunables, resolved by each protocol's deps extension
    /// (`protocols.<name>`). All defaults, so the JSON may omit the block.
    protocols: struct {
        client_registration: protocol.client_registration.Config = .{},
        secret: protocol.secret.Config = .{},
    } = .{},
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
pub const HeartbeatMessage = core.schema.Schema(1, "heartbeat", struct {
    /// Unix timestamp (seconds) when the heartbeat was produced.
    timestamp: i64,
    /// The name of the event that triggered this heartbeat.
    event: []const u8,
    count: u64,
    greeting: []const u8,
});

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

    /// Drains heartbeats back off the broker — proves that published (and
    /// replayed) messages actually landed instead of bouncing as unrouted.
    pub fn @"consume:heartbeat-drain amq.direct/heartbeat"(
        heartbeat: HeartbeatMessage,
    ) !void {
        log.info(
            "Drained heartbeat #{d} ({s}) published at {d}.",
            .{ heartbeat.count, heartbeat.greeting, heartbeat.timestamp },
        );
    }

    /// Demonstrates the secret protocol's callback flow, following the
    /// "cancel the publish and call yourself back" pattern: if the secret
    /// isn't cached yet we hand the registry a self-callback event, cancel
    /// this publish, and get re-run once the store's response is decrypted.
    /// It never actually publishes — returning null cancels — so the
    /// secret itself stays local and off the broker.
    pub fn @"publish!:secret-demo amq.direct/secret.demo"(
        reg: *protocol.secret.registry,
        persistent: std.mem.Allocator,
        inj: *core.deps.DepCtx,
    ) !?core.schema.Message(HeartbeatMessage) {
        const secret_sched = try inj.require(protocol.secret.Scheduler);
        const amqp_sched = try inj.require(Scheduler(.amqp));

        const callback = try amqp_sched.publishLater(.{ .@"secret-demo" = .{} }, .{ .inj = inj });
        const ev = try persistent.create(@TypeOf(callback));
        errdefer persistent.destroy(ev);
        ev.* = callback;

        if (try reg.getOrRequest(persistent, "secret", @ptrCast(ev), secret_sched, .{ .inj = inj })) |secret| {
            persistent.destroy(ev); // cache hit: the callback event is still ours
            log.info("[secret-demo] secret 'secret' = '{s}' ({d} bytes)", .{ secret, secret.len });
            return null;
        }

        log.info("[secret-demo] not cached yet; requested it and registered a self-callback", .{});
        return null;
    }
};

/// Cron route handlers.
/// Function names follow the pattern: "job_name schedule"
const CronRoutes = struct {
    /// Triggers every 5 seconds.
    pub fn @"heartbeat_tick */5 * * * * *"(inj: *core.deps.DepCtx) !void {
        const scheduler = try inj.require(Scheduler(.amqp));
        const timestamp = std.time.microTimestamp();

        // Publish a heartbeat event with no greeting override
        try scheduler.publish(
            .{ .heartbeat = .{ timestamp, null } },
            .{ .inj = inj },
        );

        // Record the tick in the sqlite driver's database, then queue a count
        // readback. Both go through the shared event queue, so with several
        // consumer threads the logged count may lag by a tick — it's a demo.
        const sq = try inj.require(Scheduler(.sqlite));
        try sq.call(.{ .recordVisit = .{ timestamp, "heartbeat" } }, .{ .inj = inj });
        try sq.call(.{ .logVisitCount = .{} }, .{ .inj = inj });
    }
};

/// Action route handlers.
/// Function names are the route id verbatim; the first tuple param is the call context.
const ActionRoutes = struct {
    pub fn greet(ctx: struct { []const u8 }) void {
        log.info("[action:greet] {s}", .{ctx.@"0"});
    }

    /// Cancels a cron timer: either a named route job or an anonymous timer.
    /// The payload is the type-erased `cron.ShimId` (the driver-specific id union
    /// would cycle back into this route's own signature). An anonymous id is
    /// owned by this action — callers dupe it, we free it.
    pub fn cancel(
        ctx: struct { cron.ShimId },
        inj: *core.deps.DepCtx,
        persistent: std.mem.Allocator,
    ) !void {
        const target = ctx.@"0";
        defer if (target == .anonymous) persistent.free(target.anonymous);
        const name = switch (target) {
            .route, .anonymous => |s| s,
        };
        log.info("Cancelling job: {s}", .{name});

        const scheduler = try inj.require(Scheduler(.cron));
        const Id = @typeInfo(@TypeOf(Scheduler(.cron).cancel)).@"fn".params[1].type.?;
        const id: Id = switch (target) {
            .route => |route| .{
                .route = std.meta.stringToEnum(@FieldType(Id, "route"), route) orelse {
                    log.info("No such cron route: {s}", .{route});
                    return;
                },
            },
            .anonymous => |anon| .{ .anonymous = anon },
        };

        if (scheduler.cancel(id)) |_| {
            log.info("Job cancelled successfully: {s}", .{name});
        } else {
            log.info("Job was already done: {s}", .{name});
        }
    }
};

/// Sqlite route handlers and table definitions.
/// Function names are the route id verbatim; the first tuple param is the call
/// context, followed by the driver's shared connection, then any injected deps.
/// Pub table decls are collected by `sqlite.From` and auto-migrated (CREATE
/// TABLE IF NOT EXISTS) when the driver opens its connection.
const SqliteRoutes = struct {
    pub const Visit = sqlite.orm.Table(.visit, struct {
        id: sqlite.orm.PK(u64),
        event: []const u8,
        at: i64,
    });

    pub fn recordVisit(ctx: struct { i64, []const u8 }, db: *sqlite.Db) !void {
        // id is an INTEGER PRIMARY KEY (rowid alias): omitted -> auto-assigned.
        try db.conn.exec("INSERT INTO visit (event, at) VALUES (?1, ?2)", .{ ctx.@"1", ctx.@"0" });
    }

    pub fn logVisitCount(db: *sqlite.Db, allocator: std.mem.Allocator) !void {
        var q = sqlite.orm.Query
            .from(.v, Visit)
            .select(.{ .v = .{ .id = .id } });
        defer q.deinit(allocator);
        var n: u64 = 0;
        while (try q.next(db, allocator)) |_| n += 1;
        log.info("[sqlite] {d} visits recorded", .{n});
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

    pub fn @"GET /api/v1/ok @okExample"(
        _: http.data.Request(null),
        inj: *core.deps.DepCtx,
        persistent: std.mem.Allocator,
    ) !http.data.Json(
        HeartbeatMessage,
        .{.ok},
    ) {
        const act: Scheduler(.action) = try inj.require(Scheduler(.action));
        const scron: Scheduler(.cron) = try inj.require(Scheduler(.cron));
        const ev = try act.callLater(.{ .greet = .{"hello from /ok"} }, .{ .inj = inj });
        const id = try scron.after(5, ev);
        log.info("Scheduled: {s}", .{id.anonymous});

        // The idea is that we schedule the job to be canceled if it has taken too long to run.
        // A better example would be debouncing, we can cache the id of the last job we emitted here and cancel the last one.
        const cev = try act.callLater(.{ .cancel = .{.{ .anonymous = try persistent.dupe(u8, id.anonymous) }} }, .{ .inj = inj });
        const cid = try scron.after(8, cev);
        log.info("Scheduled: {s}", .{cid.anonymous});
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

    /// Kicks off the secret-protocol demo: schedules the `secret-demo`
    /// publish, whose handler fetches the secret 'secret' via getOrRequest
    /// and re-fires itself when the store's answer arrives (check the logs).
    pub fn @"GET /api/v1/secret @requestSecret"(
        _: http.data.Request(null),
        inj: *core.deps.DepCtx,
    ) !http.data.Json(struct { status: []const u8 }, .{.ok}) {
        const sched = try inj.require(Scheduler(.amqp));
        try sched.publish(.{ .@"secret-demo" = .{} }, .{ .inj = inj });
        return .{ .value = .{ .ok = .{ .status = "requested" } } };
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

/// HTTP routes behind OIDC bearer auth. Wrapped in `auth_oidc.WithAuth`
/// below, which both enforces the check and marks the routes' security
/// metadata for OpenAPI/IntrospectUI. The verified identity arrives as an
/// ordinary dependency argument.
const SecuredHTTPRoutes = struct {
    /// Echo the verified identity of the caller.
    pub fn @"GET /api/v1/me @whoami"(
        _: http.data.Request(null),
        identity: auth_oidc.Identity,
    ) struct { sub: []const u8, username: ?[]const u8, email: ?[]const u8 } {
        return .{
            .sub = identity.claims.sub,
            .username = identity.claims.preferred_username,
            .email = identity.claims.email,
        };
    }
};

// ============================================================================
// Driver Setup
// ============================================================================

/// Context type for dynamic routing (can hold request-scoped data).
/// The `client` and `secrets` fields are the protocol registries: the
/// client-registration and secret protocols resolve them off this context
/// (and their `{client.id}`-bound consume routes resolve through `client`).
const RouteContext = struct {
    request_id: u64 = 0,
    client: protocol.client_registration.registry = .{ .assigned_id = null, .state = .unregistered },
    secrets: protocol.secret.registry = .{},
};

/// The protocols the example app speaks. `.secret` requires
/// `.client_registration` (its response route binds on the effective
/// registration id).
const protocols: []const protocol.Kind = &.{ .client_registration, .secret };

/// AMQP driver configuration
const amqp_driver = amqp.Driver
    .new(.amqp)
    .config("driver.amqp")
    .listen(true) // Consume the heartbeat drain route
    .jobs(1)
    .routes(core.meta.flatten(&.{
        amqp.From(AmqpRoutes, RouteContext),
        protocol.use(struct {
            pub const kind = .amqp;
        }, protocols, RouteContext),
    }))
    .build();

/// Cron driver configuration
const cron_driver = cron.Driver
    .new(.cron)
    .listen(true)
    .jobs(1)
    .routes(cron.From(CronRoutes) ++ cron.From(amqp.Replay) ++ protocol.use(struct {
        pub const kind = .cron;
    }, protocols, RouteContext))
    .build();

/// The private introspection-UI mount (a second `.private` HTTP driver) and its registry/dep
/// wiring, all hardcoded in the library — see `kw-introspect`'s `MountWith`. The docs manifest
/// and the backends are threaded in, plus the auth wrap: every inner route (fragments, actions,
/// renderers) goes behind the OIDC bearer middleware; shells and the login flows stay open
/// (browser navigations can't carry headers). The UI's own login page authenticates against
/// the "bearer" scheme and stores its token under kw:introspect:token.
const introspection = introspect.MountWith(
    docs,
    .{ introspect_http, introspect_cron, introspect_signal },
    .{ .auth = "introspect" },
);

const http_driver = http.Driver
    .new(.public)
    .config("driver.public")
    .listen(true)
    .jobs(1)
    .routes(http.middleware.cors(
        http.From(HTTPRoutes, RouteContext) ++
            auth_oidc.WithAuth(http.From(SecuredHTTPRoutes, RouteContext), .{}),
    ))
    .error_handler(http.DefaultErrorHandler)
    .build();

/// Action driver configuration (never listens; routes are just functions to call)
const action_driver = action.Driver
    .new(.action)
    .listen(false)
    .jobs(0)
    .routes(action.From(ActionRoutes))
    .build();

/// The sqlite driver: non-listening like action, but config-taking — the
/// config path names the database file. Tables declared in the route
/// container ride the same routes slice; the Migrations fragment wires the
/// committed history (migrations/ + schema.zon, embedded by the build), so
/// init runs the migration runner: committed migrations first, then the
/// build-time candidate (current schema vs committed snapshot).
const sqlite_snapshot: sqlite.orm.ir.Schema = @import("kw-sqlite--snapshot");
const sqlite_driver = sqlite.Driver
    .new(.sqlite)
    .config("driver.sqlite")
    .listen(false)
    .jobs(0)
    .routes(sqlite.From(SqliteRoutes) ++ sqlite.Migrations(sqlite_snapshot, @import("kw-sqlite--migrations")))
    .build();

/// The signal driver's routes, hoisted so the driver and the process-wide block
/// mask (`signal.blockRouted` in `juicyMain`) share one source of truth.
const signal_routes = signal.From(SignalRoutes) ++ signal.From(signal.default.Shutdown);

/// Signal driver configuration (always listens on a dedicated sigtimedwait thread)
const signal_driver = signal.Driver
    .new(.signal)
    .listen(true)
    .jobs(1)
    .routes(signal_routes)
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
            .registerHandler(signal_driver)
            .registerHandler(sqlite_driver);
        // The private introspection mount is appended only in normal runtime builds, not during
        // docgen (the UI is generated *from* the docs); `register` handles that gating.
        break :reg introspection.register(base);
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
    // sigtimedwait thread is their sole consumer. The mask is derived from the
    // driver's routes, so it can never drift out of sync — this is also what makes
    // the introspection UI's Send button (kill(getpid())) reliable.
    signal.blockRouted(signal_routes);

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

    // The private mount's registries — the app owns all three, and the split
    // is deliberate: AuthSchemes/LoginClients describe the *application's*
    // schemes (what the Auth tab lists for Try-it logins), while UiAuth is
    // the UI's own scheme/login client, which must never show up in the tab.
    var scheme_storage = [_]introspect.security.RuntimeScheme{
        .{ .name = "bearer", .well_known = config_slot.auth.well_known },
    };
    var auth_schemes: introspect.security.AuthSchemesCtx = .{ .schemes = .{ .schemes = &scheme_storage } };
    var login_clients: introspect.security.LoginClientsCtx = .{
        .clients = .{ .clients = config_slot.introspect.tryit_clients },
    };
    var ui_auth: introspect.security.UiAuthCtx = .{ .ui = .{
        .scheme = .{ .name = "introspect", .well_known = config_slot.introspect.auth.well_known },
        .client_id = config_slot.introspect.auth_client_id,
    } };

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
        // Register the base server's own config (kwev recording directory etc.)
        .with(.all, kwatcher.default.config(kwatcher.server.Config, "server"), allocator)
        .with(.public, kwatcher.default.config(http.middleware.Cors.Config, "middleware.cors"), allocator)
        // Register AMQP client pool and connection handling
        .with(.amqp, amqp.defaultFor(drivers.drivers, RouteContext), allocator)
        // Register the client-registration + secret protocol deps (config
        // resolvers, registries off RouteContext, scheduler shim bridges)
        .with(.amqp, protocol.deps(drivers.drivers, RouteContext, protocols), allocator)
        // Register the type-erased cron scheduler shim (drives the introspection Timers tab)
        .with(.cron, cron.defaultFor(drivers.drivers), allocator)
        // TODO: create a http.defaultFor
        .with(.public, kwatcher.default.config(http.Config, "driver.public"), allocator)
        // OIDC bearer auth on the public mount: settings resolver, JWKS
        // state, and the per-request verified identity.
        .with(.public, auth_oidc.extension("auth"), allocator)
        // Register the sqlite driver's config (database file path); the driver
        // resolves it at init to open its connection.
        .with(.sqlite, kwatcher.default.config(sqlite.Config, "driver.sqlite"), allocator)
        // Register our custom counter as a static dependency
        .static(.public, &ctx)
        .static(.amqp, &counter);

    // The private introspection mount's deps (cors config + a keyed http.Config per served http
    // mount + its own config). `introspection.deps` no-ops during docgen, so this stays one
    // unconditional `.with`.
    const with_mount = base_deps.with(.private, introspection.deps, allocator);

    // The private mount enforces the UI's own "introspect" scheme (its own
    // audience/client), and carries the scheme + login-client registries the
    // Auth tab and both login flows read. Gated like the mount itself:
    // during docgen the `.private` category does not exist.
    const deps = if (comptime docs.isDocgen) with_mount else with_mount
        .with(.private, auth_oidc.extension("introspect.auth"), allocator)
        .static(.private, &auth_schemes)
        .static(.private, &login_clients)
        .static(.private, &ui_auth);

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
