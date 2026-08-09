// This file is part of the kwatcher project.
//
// Copyright (C) 2025-2026 Borislav Atanasov
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, version 3 of the License only.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.

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
const client = @import("kw-http-client");
const httpz = @import("httpz");

const build_options = @import("build_options");

// UI-less builds (-Dui=false) have none of the introspect modules wired into
// the module graph, so these @imports must only be analyzed in the taken
// branch — every use below is gated on `build_options.ui`.
const introspect = if (build_options.ui) @import("kw-introspect") else struct {};
const introspect_http = if (build_options.ui) @import("kw-introspect--http") else struct {};
const introspect_cron = if (build_options.ui) @import("kw-introspect--cron") else struct {};
const introspect_signal = if (build_options.ui) @import("kw-introspect--signal") else struct {};
const introspect_sqlite = if (build_options.ui) @import("kw-introspect--sqlite") else struct {};

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
        /// Defaulted so the UI-less config file can omit it (the private
        /// mount only exists in UI builds).
        private: http.Config = .{},
        sqlite: sqlite.Config = .{},
        /// Egress loopback driver (kw-http-client demo): talks back into our
        /// own public ingress, so it works without any external upstream.
        loopback: client.Config = .{ .base_uri = "http://localhost:2000" },
        /// Egress driver for the OIDC provider: discovery + JWKS refreshes
        /// ride the event queue (recorded IdP traffic). base_uri is the
        /// IdP *origin*; the well-known path comes from `auth.well_known`.
        oidc: client.Config = .{ .base_uri = "http://localhost:8080" },
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
    /// is its own application with its own OIDC client/audience. The whole
    /// section only exists in UI builds (its types come from kw-introspect);
    /// UI-less builds load `example.noui.json`, which omits it, since the
    /// config parser rejects unknown fields.
    introspect: if (!build_options.ui) struct {} else struct {
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
    /// The amount of workers to spawn for the purpose of
    /// consuming events from the queue.
    workers: u8 = 2,
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
    pub fn @"publish:heartbeat amq.direct/heartbeat2"(
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
    pub fn @"consume:heartbeat-drain amq.direct/heartbeat2"(
        heartbeat: HeartbeatMessage,
    ) !void {
        log.info(
            "Drained heartbeat #{d} ({s}) published at {d}.",
            .{ heartbeat.count, heartbeat.greeting, heartbeat.timestamp },
        );
    }

    /// Demonstrates the secret protocol's callback flow, following the
    /// "cancel the publish and call yourself back" pattern: if the secret
    /// isn't cached yet we hand the registry a self-callback event and get
    /// re-run once the store's response is decrypted, plus arm a 5-minute
    /// `rerequest` retry in case the answer never comes. It never actually
    /// publishes — returning null cancels — so the secret itself stays
    /// local and off the broker.
    pub fn @"publish!:secret-demo amq.direct/secret.demo"(
        reg: *protocol.secret.registry,
        persistent: std.mem.Allocator,
        inj: *core.deps.DepCtx,
    ) !?core.schema.Message(HeartbeatMessage) {
        const amqp_sched = try inj.require(Scheduler(.amqp));

        const callback = try amqp_sched.publishLater(.{ .@"secret-demo" = .{} }, .{ .inj = inj });
        const ev = try persistent.create(@TypeOf(callback));
        errdefer persistent.destroy(ev);
        ev.* = callback;

        if (try reg.getOrRequest(persistent, "secret", @ptrCast(ev), amqp_sched, .{ .inj = inj })) |secret| {
            persistent.destroy(ev); // cache hit: the callback event is still ours
            log.info("[secret-demo] secret 'secret' = '{s}' ({d} bytes)", .{ secret, secret.len });
            return null;
        }

        // Not cached: the registry owns `ev` now and re-enqueues it once the
        // response lands. Arm a retry in case the store never answers — it
        // neutralizes itself if the secret arrived in the meantime, so no
        // timer bookkeeping is needed on the happy path.
        const action_sched = try inj.require(Scheduler(.action));
        const cron_sched = try inj.require(Scheduler(.cron));
        const act = try action_sched.callLater(.{ .rerequest = .{"secret"} }, .{ .inj = inj });
        _ = try cron_sched.after(5 * std.time.s_per_min, act);

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

    /// Keep the OIDC discovery + key material warm: every IdP fetch goes
    /// through the queue (recorded, correlation-stamped). The 30s cadence
    /// bounds the startup cold window and key-rotation recovery; identical
    /// payloads are change-detected by the store, so steady-state cost is
    /// two keep-alive GETs. On the first tick the JWKS request may cancel
    /// silently (its URL comes from the discovery document); the next tick
    /// lands it.
    pub fn @"oidc_refresh */30 * * * * *"(inj: *core.deps.DepCtx) !void {
        const sched = try inj.require(Scheduler(.oidc));
        try sched.request(.{ .oidcDiscovery = .{} }, .{ .inj = inj });
        try sched.request(.{ .oidcJwks = .{} }, .{ .inj = inj });
    }

    /// Keep the loopback PROVIDE cache warm and demo the async egress path.
    pub fn @"loopback_refresh */30 * * * * *"(inj: *core.deps.DepCtx) !void {
        const sched = try inj.require(Scheduler(.loopback));
        try sched.request(.{ .freshHealth = .{} }, .{ .inj = inj });
        try sched.request(.{ .createUser = .{ .body = .{ .name = "loopback" } } }, .{ .inj = inj });

        // The freshest snapshot from the previous refresh, injected through
        // the PROVIDE cache (fails harmlessly before the first fetch).
        if (inj.require(client.Provided(LoopbackRoutes.HealthSnapshot))) |snap| {
            log.info("[loopback] cached health '{s}' fetched at {d}", .{ snap.value.status, snap.fetched_at });
        } else |_| {
            log.info("[loopback] health not fetched yet", .{});
        }
    }
};

/// Egress routes looping back into this app's own public ingress — the
/// kw-http-client demo. Both route forms: simple const declarations (the
/// declared type IS the 2xx response schema) and operation structs
/// (`request` builds the request; other pub fns are per-status handlers).
const LoopbackRoutes = struct {
    /// The wire shape of the ingress `/health` endpoint.
    pub const HealthSnapshot = struct { status: []const u8 };

    /// The client-side mirror of `HeartbeatMessage`'s wire shape.
    pub const Heartbeat = struct {
        schema_version: u32,
        schema_name: []const u8,
        timestamp: i64,
        event: []const u8,
        count: u64,
        greeting: []const u8,
    };

    /// Plain fetch; sync `invoke` returns it typed, async validates + drops.
    pub const @"GET /health @health": HealthSnapshot = undefined;

    /// The freshest health snapshot: refreshed by the cron schedule below,
    /// injectable anywhere as `client.Provided(HealthSnapshot)`.
    pub const @"PROVIDE GET /health @freshHealth": HealthSnapshot = undefined;

    /// Create a user upstream; the scheduling site hands the draft through
    /// `Ctx.body`, `request` turns it into the wire body.
    pub const @"POST /api/v1/users @createUser" = struct {
        pub const Ctx = struct { body: struct { name: []const u8 } };

        pub fn request(ctx: Ctx) struct { name: []const u8 } {
            return .{ .name = ctx.body.name };
        }

        pub fn ok(rctx: struct { body: Heartbeat }) void {
            log.info("[loopback] upstream created user; greeting={s}", .{rctx.body.greeting});
        }

        pub fn client_error(rctx: struct { status: std.http.Status }) void {
            log.warn("[loopback] createUser rejected: {d}", .{@intFromEnum(rctx.status)});
        }

        pub fn failed(rctx: struct { err: anyerror, attempts: u32 }) void {
            log.warn("[loopback] createUser transport failure: {t} (attempt {d})", .{ rctx.err, rctx.attempts });
        }
    };

    /// Typed captures against the user endpoint.
    pub const @"GET /api/v1/users/{id} @getUser" = struct {
        pub const Ctx = struct { captures: struct { id: u64 } };

        pub fn request(ctx: Ctx) void {
            _ = ctx;
        }

        pub fn ok(rctx: struct { body: Heartbeat, captures: struct { id: u64 } }) void {
            log.info("[loopback] user {d}: event={s}", .{ rctx.captures.id, rctx.body.event });
        }

        pub fn @"error"(rctx: struct { status: std.http.Status }) void {
            log.warn("[loopback] getUser failed upstream: {d}", .{@intFromEnum(rctx.status)});
        }

        pub fn failed(rctx: struct { err: anyerror }) void {
            log.warn("[loopback] getUser transport failure: {t}", .{rctx.err});
        }
    };
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

    /// Fire-and-forget retry for a secret the store hasn't answered yet:
    /// republishes `secret-get` directly on the AMQP scheduler without
    /// registering a new callback — the original request's pending event is
    /// still armed and resumes the demo route when the answer finally
    /// lands. No-ops if the secret arrived in the meantime.
    pub fn rerequest(
        ctx: struct { []const u8 },
        inj: *core.deps.DepCtx,
        reg: *protocol.secret.registry,
    ) !void {
        if (reg.get(ctx.@"0") != null) return;
        const sched = try inj.require(Scheduler(.amqp));
        try sched.publish(.{ .@"secret-get" = .{ctx.@"0"} }, .{ .inj = inj });
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
    /// OIDC egress fragment: the spread segment in `auth_oidc.egress.Routes`
    /// resolves `oidc.well_known_path` (filled from config at startup).
    oidc: auth_oidc.egress.Context = .{},
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
const introspection = if (build_options.ui) introspect.MountWith(
    docs,
    .{ introspect_http, introspect_cron, introspect_signal, introspect_sqlite },
    .{ .auth = "introspect" },
) else NoopMount;

/// Stand-in for the introspection mount when the UI is compiled out — mirrors
/// `MountWith`'s `register` shape so the driver-registry wiring below stays
/// unconditional. `deps` is deliberately not mirrored: the `.private`
/// category itself only exists in UI builds, so the whole deps chain is
/// gated in `juicyMain` instead.
const NoopMount = struct {
    pub fn register(comptime base: anytype) @TypeOf(base) {
        return base;
    }
};

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

/// The egress loopback driver: one origin (our own public ingress), a
/// dedicated request pool of 2 blocking-IO threads fed by a driver-owned
/// queue — event workers never block on the network.
const loopback_driver = client.Driver
    .new(.loopback)
    .config("driver.loopback")
    .listen(true)
    .jobs(2)
    .routes(client.From(LoopbackRoutes, RouteContext))
    .error_handler(client.DefaultErrorHandler)
    .build();

/// The OIDC egress driver: discovery + JWKS fetches as recorded events
/// (see `auth_oidc.egress`). One job — the IdP is low-traffic.
const oidc_driver = client.Driver
    .new(.oidc)
    .config("driver.oidc")
    .listen(true)
    .jobs(1)
    .routes(client.From(auth_oidc.egress.Routes, RouteContext))
    .error_handler(client.DefaultErrorHandler)
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
            .registerHandler(sqlite_driver)
            .registerHandler(loopback_driver)
            .registerHandler(oidc_driver);
        // The signal driver is POSIX-only: its listener thread is a
        // `rt_sigtimedwait` syscall loop, which nothing outside linux can
        // serve. Registering it is what instantiates that loop, so gating the
        // registration is what keeps it out of the binary — the driver and its
        // routes above stay declared either way. Drop this once a driver
        // backed by the Windows primitives exists to swap in.
        const with_signal = if (builtin.os.tag == .linux)
            base.registerHandler(signal_driver)
        else
            base;
        // The private introspection mount is appended only in normal runtime builds, not during
        // docgen (the UI is generated *from* the docs); `register` handles that gating.
        break :reg introspection.register(with_signal);
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
    // UI-less builds load their own config file (no `introspect` /
    // `driver.private` sections) — the parser rejects unknown fields.
    const config_name = if (build_options.ui) "example" else "example.noui";
    config_slot = try core.config.findConfigFile(Config, arena.allocator(), config_name) orelse {
        std.log.err("Could not load config! Create '" ++ config_name ++ ".json' with the required fields.", .{});
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
    ctx.oidc.well_known_path = auth_oidc.egress.pathOf(config_slot.auth.well_known);

    // The OIDC discovery/JWKS store: written only by the egress driver,
    // read by the verification middleware in every enforced scope.
    var oidc_store = auth_oidc.DiscoveryStoreCtx{};
    oidc_store.store.alloc = allocator;

    // The private mount's registries — the app owns all three, and the split
    // is deliberate: AuthSchemes/LoginClients describe the *application's*
    // schemes (what the Auth tab lists for Try-it logins), while UiAuth is
    // the UI's own scheme/login client, which must never show up in the tab.
    // All UI-only: their types come from kw-introspect and their pointers are
    // registered into the `.private` scope, neither of which exists in
    // UI-less builds.
    var scheme_storage = if (comptime build_options.ui) [_]introspect.security.RuntimeScheme{
        .{ .name = "bearer", .well_known = config_slot.auth.well_known },
    } else {};
    var auth_schemes = if (comptime build_options.ui)
        introspect.security.AuthSchemesCtx{ .schemes = .{ .schemes = &scheme_storage } }
    else {};
    var login_clients = if (comptime build_options.ui) introspect.security.LoginClientsCtx{
        .clients = .{ .clients = config_slot.introspect.tryit_clients },
    } else {};
    var ui_auth = if (comptime build_options.ui) introspect.security.UiAuthCtx{ .ui = .{
        .scheme = .{ .name = "introspect", .well_known = config_slot.introspect.auth.well_known },
        .client_id = config_slot.introspect.auth_client_id,
    } } else {};

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
        // Register the type-erased sqlite DB shim (drives the introspection
        // Queries/Console tabs)
        .with(.sqlite, sqlite.defaultFor(drivers.drivers), allocator)
        // Register the egress loopback driver's config + shared transport
        // (one pooled std.http.Client) + PROVIDE caches
        .with(.loopback, client.defaultFor(drivers.drivers, RouteContext), allocator)
        // Register the OIDC egress driver's config + transport, and the
        // process-wide discovery store it feeds
        .with(.oidc, client.defaultFor(drivers.drivers, RouteContext), allocator)
        .static(.all, &oidc_store)
        // Register our custom counter as a static dependency
        .static(.all, &ctx)
        .static(.amqp, &counter);

    // The private introspection mount's deps (cors config + a keyed http.Config per served http
    // mount + its own config). `introspection.deps` no-ops during docgen, so within UI builds
    // this stays one unconditional `.with`; UI-less builds have no `.private` category at all.
    const with_mount = if (comptime build_options.ui)
        base_deps.with(.private, introspection.deps, allocator)
    else
        base_deps;

    // The private mount enforces the UI's own "introspect" scheme (its own
    // audience/client), and carries the scheme + login-client registries the
    // Auth tab and both login flows read. Gated like the mount itself:
    // during docgen (and UI-less builds) the `.private` category does not exist.
    const deps = if (comptime !build_options.ui or docs.isDocgen) with_mount else with_mount
        .with(.private, auth_oidc.extension("introspect.auth"), allocator)
        .static(.private, &auth_schemes)
        .static(.private, &login_clients)
        .static(.private, &ui_auth);

    // Create and start the server
    var server = try kwatcher.server.Server(@TypeOf(deps), drivers.drivers)
        .init(allocator, deps, config_slot.app.workers); // 4 consumer threads
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
