//! kw-sqlite — the sqlite database driver.
//!
//! Turns the `kw-orm-sqlite` ORM into a kwatcher driver: routes are plain
//! functions that receive the driver's shared database connection (folded
//! into the standard `call(inj, context)` route contract via `CallCtx`) and
//! run queries through the comptime query builder (or raw prepared
//! statements).
//! Like the action driver it never listens (no background loop, `jobs(0)`),
//! but it is config-taking: `.config("driver.sqlite")` names the config path
//! holding the database file location. The driver opens ONE connection at
//! init — the vendored sqlite3 is compiled THREADSAFE=1 (serialized), so
//! sharing it across the server's consumer workers is safe; long-running
//! route transactions will serialize all sqlite routes.
//!
//! Route containers may also declare ORM table definitions as pub decls
//! (`pub const Visit = sqlite.Table(.visit, ...)`); `From` collects them and
//! the driver auto-migrates (CREATE TABLE IF NOT EXISTS) when it opens the
//! connection.
//!
//! The contract every driver must satisfy is enforced at comptime by
//! `packages/core/src/driver.zig` → `AssertDriver` (and checked in the
//! `comptime` block at the bottom of this file).

const std = @import("std");
const klib = @import("klib");

const log = std.log.scoped(.sqlite);

const dep = @import("kw-core").deps;
const server = @import("kw-core");
const Event = @import("kw-core").event.Event;
const EventProperties = @import("kw-core").event.Properties;

const meta = @import("kw-core").meta;
const shared = @import("kw-core").shared;
const MPMCQueue = @import("kw-core").queue.StaticStrict;

/// The ORM this driver fronts. The full surface (Table/PK/FK, the query
/// builder, the IR) lives there; only the connection type is lifted out
/// because every route signature names it.
pub const orm = @import("kw-orm-sqlite");
pub const Db = orm.Db;

pub const kind = .sqlite;
const Root = @This();

/// The context handed to a route's generated `call`: the schedulable payload
/// plus the driver's connection, folded together so `call` keeps the standard
/// two-parameter driver signature (`call(inj, context)`).
pub fn CallCtx(comptime T: type) type {
    return struct {
        db: *Db,
        ctx: T,
    };
}

pub const Config = struct {
    /// Database file path (":memory:" allowed).
    path: []const u8 = "kwatcher.db",
};

pub const Driver = shared.DriverBuilder(DriverBuilder, true);

/// Comptime carrier letting a table definition ride the `.routes()` slice —
/// the fluent builder's only channel into the driver. `DriverBuilder`
/// partitions carriers out before any shared route helper sees them.
pub fn TableCarrier(comptime T: type) type {
    return struct {
        pub const __kw_sqlite_table = {};
        pub const TableDef = T;
    };
}

fn isTableCarrier(comptime R: type) bool {
    return @typeInfo(R) == .@"struct" and @hasDecl(R, "__kw_sqlite_table");
}

/// Comptime carrier wiring an app's migration history into the driver, riding
/// the `.routes()` slice like `TableCarrier`. `snapshot` is the committed
/// schema IR (`migrations/schema.zon`, wired as a zon import by the build);
/// `Embedded` is the generated module embedding the committed migration files
/// (duck-typed: `pub const all: []const struct { version, up, down }`).
pub fn MigrationSource(comptime snapshot: orm.ir.Schema, comptime Embedded: type) type {
    return struct {
        pub const __kw_sqlite_migrations = {};
        pub const committed_snapshot = snapshot;
        pub const EmbeddedMigrations = Embedded;
    };
}

fn isMigrationSource(comptime R: type) bool {
    return @typeInfo(R) == .@"struct" and @hasDecl(R, "__kw_sqlite_migrations");
}

/// The MigrationSource carrier as a routes-slice fragment, so wiring reads
/// as plain concatenation: `.routes(From(Container) ++ Migrations(snap, Em))`.
pub fn Migrations(comptime snapshot: orm.ir.Schema, comptime Embedded: type) []const type {
    return &.{MigrationSource(snapshot, Embedded)};
}

/// The routes slice minus carriers, order preserved (order = RouteKeys
/// enum order = dispatch index).
fn RealRoutes(comptime Rs: []const type) []const type {
    comptime {
        var routes: []const type = &.{};
        for (Rs) |R| {
            if (!isTableCarrier(R) and !isMigrationSource(R)) routes = routes ++ &[_]type{R};
        }
        return routes;
    }
}

/// The migration source extracted from the routes slice, if any.
fn MigrationDef(comptime Rs: []const type) ?type {
    comptime {
        var found: ?type = null;
        for (Rs) |R| {
            if (isMigrationSource(R)) {
                if (found != null) @compileError("At most one MigrationSource may be wired per sqlite driver.");
                found = R;
            }
        }
        return found;
    }
}

/// The table definitions extracted from carriers, order preserved.
fn TableDefs(comptime Rs: []const type) []const type {
    comptime {
        var tables: []const type = &.{};
        for (Rs) |R| {
            if (isTableCarrier(R)) tables = tables ++ &[_]type{R.TableDef};
        }
        return tables;
    }
}

pub fn DriverBuilder(
    comptime driver_key: @Type(.enum_literal),
    comptime config: []const u8,
    comptime listen: bool,
    comptime _jobs: comptime_int,
    comptime _Routes: []const type,
    comptime ErrorHandler: type,
) *const fn (comptime u12) type {
    _ = listen;
    _ = ErrorHandler;
    const Routes = RealRoutes(_Routes);
    const Tables = TableDefs(_Routes);
    const MigrationSrc = MigrationDef(_Routes);
    const H = struct {
        pub fn SqliteHandler(comptime block_start: u12) type {
            return struct {
                pub const ConfigType = Root.Config;
                pub const config_path = config;
                pub const jobs = _jobs;
                pub const key = driver_key;
                pub const kind = Root.kind;
                /// The table definitions collected from the route containers;
                /// migrated at init.
                pub const tables = Tables;
                /// Schema IR + rendered DDL for the collected tables — the
                /// surface the docgen-sqlite backend consumes. Published here
                /// because the backend cannot import the ORM itself: a second
                /// kw-orm-sqlite instance in the generator graph would not be
                /// marker-identity-compatible with the app's table types.
                pub const schema = orm.SchemaIr(Tables);
                pub const schema_sql = blk: {
                    var s: []const u8 = "";
                    for (Tables) |T| s = s ++ orm.TableGen(T) ++ ";\n";
                    break :blk s;
                };
                /// The migration source collected from the carrier (null when
                /// the app didn't wire one; init then auto-migrates instead).
                pub const migration_source = MigrationSrc;
                pub const committed_migrations: []const orm.runner.Committed = blk: {
                    const M = MigrationSrc orelse break :blk &.{};
                    var res: []const orm.runner.Committed = &.{};
                    for (M.EmbeddedMigrations.all) |m| {
                        res = res ++ &[_]orm.runner.Committed{.{ .version = m.version, .up = m.up }};
                    }
                    break :blk res;
                };
                /// The build-time candidate migration: committed snapshot ->
                /// current schema. Empty when they already match. Applied at
                /// init by the runner, emitted as files by docgen-sqlite.
                pub const candidate_up: []const u8 = blk: {
                    const old: orm.ir.Schema = if (MigrationSrc) |M| M.committed_snapshot else .{ .tables = &.{} };
                    break :blk orm.migration.renderMigration(orm.migration.diff(old, schema), .up);
                };
                pub const candidate_down: []const u8 = blk: {
                    const old: orm.ir.Schema = if (MigrationSrc) |M| M.committed_snapshot else .{ .tables = &.{} };
                    break :blk orm.migration.renderMigration(orm.migration.diff(old, schema), .down);
                };
                pub const RouteKeys = shared.EnumerateRoutes(Routes);
                pub const CallContext = shared.UniteCallContext(Routes);
                pub const Dependencies = shared.MergeDeps(Routes, &.{std.mem.Allocator});
                pub const map = shared.RouteMap(Routes);

                pub const EventType = enum(u12) {
                    call = block_start,
                };

                pub const EventValues = union(EventType) {
                    call: CallContext,
                };

                pub inline fn __block_end() u12 {
                    comptime {
                        return block_start + meta.count(EventType);
                    }
                }

                pub fn Yield(comptime ET: type, comptime EV: type) type {
                    const E = Event(ET, EV);
                    return struct {
                        const Self = @This();

                        queue: ?*MPMCQueue(E) = null,
                        db: Db,

                        pub const accepts = server.genAccepts(ET, EventType);

                        pub const Scheduler = struct {
                            parent: *Self,

                            pub fn call(self: @This(), data: CallContext, extra: struct { inj: ?*dep.DepCtx = null }) !void {
                                const value = @unionInit(
                                    EV,
                                    @tagName(key),
                                    .{
                                        .call = data,
                                    },
                                );

                                var ev = E{
                                    .event_data = value,
                                    .event_type = @field(ET, @tagName(key) ++ "_call"),
                                };

                                if (extra.inj) |inj| {
                                    const p = try inj.require(EventProperties);
                                    if (p.correlation_id.isUnset()) {
                                        log.err("scheduling a query from a handler without a correlation id (bug)", .{});
                                    }
                                    ev.properties.correlation_id = p.correlation_id;
                                }

                                _ = self.parent.queue.?.tryPush(
                                    ev,
                                    std.time.ns_per_ms * 1,
                                ) catch |e| switch (e) {
                                    error.WouldBlock => {
                                        @panic("Preemptive execution is not implemented!");
                                    },
                                    else => return e,
                                };
                            }

                            pub fn callLater(self: @This(), data: CallContext, extra: struct { inj: ?*dep.DepCtx = null }) !E {
                                _ = self;
                                const value = @unionInit(
                                    EV,
                                    @tagName(key),
                                    .{
                                        .call = data,
                                    },
                                );

                                var ev = E{
                                    .event_data = value,
                                    .event_type = @field(ET, @tagName(key) ++ "_call"),
                                };

                                if (extra.inj) |inj| {
                                    const p = try inj.require(EventProperties);
                                    if (p.correlation_id.isUnset()) {
                                        log.err("scheduling a query from a handler without a correlation id (bug)", .{});
                                    }
                                    ev.properties.correlation_id = p.correlation_id;
                                }

                                return ev;
                            }

                            /// Runs the route synchronously on the caller's
                            /// thread and returns its result. The route tag is
                            /// comptime so the result type flows through —
                            /// unlike the queued paths, which discard results.
                            /// Runs inside the CURRENT event's scope: no
                            /// stamp — the event record can only carry
                            /// one, and re-stamping here would orphan
                            /// anything the outer route already scheduled.
                            pub fn callImmediate(
                                self: @This(),
                                comptime tag: std.meta.Tag(CallContext),
                                args: std.meta.TagPayload(CallContext, tag),
                                inj: *dep.DepCtx,
                            ) anyerror!Routes[@intFromEnum(tag)].Result {
                                const R = Routes[@intFromEnum(tag)];
                                return R.call(inj, .{ .db = &self.parent.db, .ctx = args });
                            }
                        };

                        fn dispatch(data: CallContext, inj: *dep.DepCtx, db: *Db, comptime stamp: bool) anyerror!void {
                            if (comptime Routes.len == 0) return;
                            switch (data) {
                                inline else => |rctx, tag| {
                                    const R = comptime Routes[@intFromEnum(tag)];
                                    if (comptime stamp) {
                                        _ = try server.event.stampRoute(inj, R.id);
                                    }
                                    // Queued events have no receiver: discard.
                                    _ = try R.call(inj, .{ .db = db, .ctx = rctx });
                                },
                            }
                        }

                        pub fn init(conf: *ConfigType, allocator: std.mem.Allocator) !@This() {
                            const path_z = try allocator.dupeZ(u8, conf.path);
                            defer allocator.free(path_z);
                            var db = try Db.open(path_z);
                            errdefer db.close();
                            if (comptime MigrationSrc != null) {
                                // Full migration lifecycle: committed history
                                // first, then the build-time candidate. The
                                // runner owns its own transaction.
                                try orm.runner.apply(
                                    &db,
                                    committed_migrations,
                                    if (comptime candidate_up.len == 0) null else .{ .up = candidate_up, .down = candidate_down },
                                    allocator,
                                );
                            } else {
                                // All-or-nothing migration: a failure mid-schema
                                // must not leave a partial table set behind in a
                                // file-backed database.
                                try db.conn.transaction();
                                errdefer db.conn.rollback();
                                inline for (Tables) |T| {
                                    try db.exec(comptime orm.TableGen(T));
                                }
                                try db.conn.commit();
                            }
                            return .{ .db = db };
                        }

                        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                            _ = allocator;
                            self.db.close();
                        }

                        pub fn bind(self: *@This(), queue: *MPMCQueue(E)) void {
                            self.queue = queue;
                        }

                        pub fn scheduler(self: *@This()) Scheduler {
                            return .{
                                .parent = self,
                            };
                        }

                        pub fn watch(
                            self: *@This(),
                            wg: *std.Thread.WaitGroup,
                            pool: *std.Thread.Pool,
                            deps: anytype,
                            allocator: std.mem.Allocator,
                        ) anyerror!void {
                            _ = self;
                            _ = wg;
                            _ = pool;
                            _ = deps;
                            _ = allocator;
                            // This driver never listens: it has no background loop.
                        }

                        pub fn stop(self: *@This()) void {
                            _ = self;
                        }

                        pub fn handle(self: *@This(), comptime ehint: ET, event: E, inj: *dep.DepCtx) anyerror!void {
                            const et: EventType = comptime @enumFromInt(@intFromEnum(ehint));
                            const ev: EventValues = @field(event.event_data, @tagName(key));

                            switch (et) {
                                inline .call => try dispatch(ev.call, inj, &self.db, true),
                            }
                        }
                    };
                }
            };
        }
    };

    return H.SqliteHandler;
}

pub fn From(comptime Container: type) []type {
    comptime {
        var rp = RouteParser(){ .routes = &.{} };
        for (std.meta.declarations(Container)) |d| {
            const decl = @field(Container, d.name);
            if (@TypeOf(decl) == type) {
                // Table definitions ride the routes slice as carriers;
                // other pub types are none of our business.
                if (orm.model.markerKind(decl)) |k| {
                    if (k == .table) rp = rp.extend(TableCarrier(decl));
                }
                continue;
            }
            if (@typeInfo(@TypeOf(decl)) != .@"fn") continue;
            rp = rp.parse(Container, d.name);
        }
        return rp.routes;
    }
}

pub const CapabilityType = enum { name };

pub const Capability = union(CapabilityType) {
    name: []const u8,
};

pub fn RouteBase(comptime HandlerFac: anytype, comptime parsed_id: []const u8) type {
    return struct {
        pub const Handler = HandlerFac(@This());
        pub const id = parsed_id;

        pub const CallContext = Handler.CallContext;
        pub const Dependencies = Handler.Dependencies;
        pub const Result = Handler.Result;
        pub const call = Handler.call;
        pub const name = Handler.name;

        pub fn swap(comptime NextHandler: anytype) type {
            return RouteBase(NextHandler, parsed_id);
        }

        pub fn wrap(comptime NextHandlerFac: anytype) type {
            return RouteBase(NextHandlerFac(HandlerFac).make, parsed_id);
        }

        pub fn requires(comptime ct: anytype) void {
            if (comptime !meta.hasKey(CapabilityType, ct)) {
                @compileError(
                    "Required capability '" ++ @tagName(ct) ++ "' is not supported by SQLITE routes.",
                );
            }
        }

        pub fn satisfies(comptime ct: anytype) bool {
            return meta.hasKey(CapabilityType, ct);
        }

        pub fn mod(
            comptime capability: Capability,
        ) type {
            return switch (capability) {
                inline .name => |n| RouteBase(HandlerFac, n),
            };
        }

        pub fn query(comptime ct: anytype) @FieldType(
            Capability,
            @tagName(ct),
        ) {
            requires(ct);
            return switch (ct) {
                .name => parsed_id,
                else => unreachable,
            };
        }
    };
}

pub fn RouteParser() type {
    return struct {
        routes: []type,

        fn extend(comptime self: @This(), comptime Other: type) @This() {
            comptime {
                const routes = blk: {
                    var routes: [self.routes.len + 1]type = undefined;
                    for (self.routes, 0..) |o, i| {
                        routes[i] = o;
                    }
                    routes[self.routes.len] = Other;
                    break :blk routes;
                };
                return .{
                    .routes = @constCast(&routes),
                };
            }
        }

        pub fn parse(
            comptime self: @This(),
            comptime Container: type,
            comptime fnname: []const u8,
        ) @This() {
            comptime {
                const f = @field(Container, fnname);

                const fargs = @typeInfo(@TypeOf(f)).@"fn".params;
                const has_context = fargs.len > 0 and blk: {
                    const ti = @typeInfo(fargs[0].type.?);
                    switch (ti) {
                        .@"struct" => |s| break :blk s.is_tuple,
                        else => break :blk false,
                    }
                };

                // The connection param is mandatory: right after the
                // call-context tuple, or first when there is none. It is
                // threaded by dispatch, not DI — deliberately absent from
                // Dependencies.
                const db_idx = if (has_context) 1 else 0;
                if (fargs.len <= db_idx or fargs[db_idx].type.? != *Root.Db) {
                    @compileError("sqlite route '" ++ fnname ++ "' must declare `*sqlite.Db` as its " ++
                        (if (has_context) "second parameter (after the call-context tuple)." else "first parameter."));
                }

                const di_start_idx = db_idx + 1;
                const __CallContext = if (has_context) fargs[0].type.? else struct {};

                const __Dependencies = blk: {
                    var deps: [fargs.len - di_start_idx]type = undefined;
                    for (fargs[di_start_idx..fargs.len], 0..) |a, i| {
                        deps[i] = a.type.?;
                    }
                    break :blk deps;
                };

                const H = struct {
                    pub fn make(comptime Base: type) type {
                        _ = Base;
                        return struct {
                            pub const CallContext = __CallContext;
                            pub const Dependencies = __Dependencies;
                            /// The route fn's payload result (error union
                            /// stripped). Returned by `call`; call sites
                            /// with no receiver (the queued paths) discard it.
                            pub const Result = klib.meta.Result(f);

                            pub fn name(inj: *dep.DepCtx) ![]const u8 {
                                const allocator = try inj.require(std.mem.Allocator);
                                return std.fmt.allocPrint(allocator, "sqlite: {s}", .{fnname});
                            }

                            pub fn call(inj: *dep.DepCtx, context: Root.CallCtx(CallContext)) anyerror!Result {
                                var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;

                                inline for (0..db_idx) |i| {
                                    args[i] = context.ctx;
                                }
                                args[db_idx] = context.db;

                                inline for (di_start_idx..args.len) |i| {
                                    args[i] = try inj.require(@TypeOf(args[i]));
                                }
                                const maybe_result = @call(.auto, f, args);

                                return switch (comptime @typeInfo(klib.meta.Return(f))) {
                                    .error_union => try maybe_result,
                                    else => maybe_result,
                                };
                            }
                        };
                    }
                };

                const RB = RouteBase(H.make, fnname);

                return self.extend(RB);
            }
        }
    };
}

comptime {
    const Drv = Driver
        .new(.sqlite)
        .config("driver.sqlite")
        .listen(false)
        .jobs(0)
        .routes(&.{})
        .build();

    @import("kw-core").driver.AssertDriver(Drv, .sqlite);
}

// Test fixtures — shared by the comptime instantiation block and the runtime
// tests below.
const TestRoutes = struct {
    pub const T = orm.Table(.t, struct {
        id: orm.PK(u64),
        n: i64,
    });

    /// Must be skipped by From: pub type, but not a table.
    pub const NotATable = struct { x: u8 };

    pub fn simple(db: *Db) void {
        _ = db;
    }

    pub fn insert(ctx: struct { i64 }, db: *Db) !void {
        try db.conn.exec("INSERT INTO t (n) VALUES (?1)", .{ctx[0]});
    }

    pub fn withDI(ctx: struct { i64 }, db: *Db, dependency: i64) void {
        _ = ctx;
        _ = db;
        _ = dependency;
    }

    pub fn count(db: *Db) !i64 {
        return db.scalarInt("SELECT COUNT(*) FROM t");
    }
};

const TestDriver = Driver
    .new(.sqlite)
    .config("driver.sqlite")
    .listen(false)
    .jobs(0)
    .routes(From(TestRoutes))
    .build();

// Ref all decls
comptime {
    const core = @import("kw-core");

    const Rts = From(TestRoutes);

    // Find a real route: table carriers share the slice.
    const R1 = blk: {
        for (Rts) |R| {
            if (!isTableCarrier(R)) break :blk R;
        }
        unreachable;
    };
    R1.requires(.name);
    if (R1.satisfies(.nothing)) @compileError("BUG: Incorrect constraint return");
    const R2 = R1.mod(.{ .name = "new" });
    if (!std.mem.eql(u8, R2.query(.name), "new")) @compileError("BUG: Wrong name - " ++ R2.query(.name));

    const Ds = core.driver.Drivers.new().registerHandler(TestDriver);

    const ET = Ds.EventList();
    const EV = Ds.EventValues();
    const E = Event(ET, EV);

    _ = Ds.Handlers(ET, EV)[1];
    const Sch = Ds.SchedulerMap();
    _ = Sch(.sqlite);

    _ = E;
}

const TestRegistry = @import("kw-core").driver.Drivers.new().registerHandler(TestDriver);
const TestET = TestRegistry.EventList();
const TestEV = TestRegistry.EventValues();
const TestHandler = TestRegistry.Handlers(TestET, TestEV)[1];
const TestEvent = Event(TestET, TestEV);

const EmptyEmbedded = struct {
    pub const Migration = struct { version: []const u8, up: []const u8, down: []const u8 };
    pub const all = [_]Migration{};
};

const TestMigDriver = Driver
    .new(.sqlite)
    .config("driver.sqlite")
    .listen(false)
    .jobs(0)
    .routes(From(TestRoutes) ++ Migrations(.{ .tables = &.{} }, EmptyEmbedded))
    .build();

const TestMigRegistry = @import("kw-core").driver.Drivers.new().registerHandler(TestMigDriver);
const TestMigHandler = TestMigRegistry.Handlers(TestMigRegistry.EventList(), TestMigRegistry.EventValues())[1];

test "MigrationSource carrier is partitioned out and publishes decls" {
    const Built = TestMigDriver(100);
    // The carrier is invisible to routing: same routes/tables as TestDriver.
    try std.testing.expectEqual(1, Built.tables.len);
    try std.testing.expectEqual(4, @typeInfo(Built.RouteKeys).@"enum".fields.len);
    try std.testing.expect(Built.migration_source != null);
    try std.testing.expectEqual(0, Built.committed_migrations.len);
    // Empty snapshot -> the candidate is the full schema create.
    try std.testing.expect(std.mem.indexOf(u8, Built.candidate_up, "CREATE TABLE IF NOT EXISTS t(") != null);
    try std.testing.expect(std.mem.indexOf(u8, Built.candidate_down, "DROP TABLE t") != null);
    // The legacy driver publishes no source and an equivalent candidate.
    try std.testing.expect(TestDriver(100).migration_source == null);
}

test "init with a MigrationSource runs the runner instead of auto-migrate" {
    var conf: Config = .{ .path = ":memory:" };
    var h = try TestMigHandler.init(&conf, std.testing.allocator);
    defer h.deinit(std.testing.allocator);

    // The candidate (full create) was applied and recorded.
    try h.db.exec("INSERT INTO t (n) VALUES (5)");
    try std.testing.expectEqual(@as(i64, 1), try h.db.scalarInt("SELECT COUNT(*) FROM _db_migrations WHERE version = '_candidate'"));
    try std.testing.expectEqual(@as(i64, 1), try h.db.scalarInt("SELECT COUNT(*) FROM t"));
}

test "From partitions tables from routes" {
    const Built = TestDriver(100);
    try std.testing.expectEqual(1, Built.tables.len);
    try std.testing.expect(Built.tables[0] == TestRoutes.T);
    // simple, insert, withDI, count — NotATable produced nothing.
    try std.testing.expectEqual(4, @typeInfo(Built.RouteKeys).@"enum".fields.len);
}

test "init migrates the collected tables and callImmediate hits the db" {
    var conf: Config = .{ .path = ":memory:" };
    var h = try TestHandler.init(&conf, std.testing.allocator);
    defer h.deinit(std.testing.allocator);

    // Never dereferenced: the exercised routes have no DI deps and the
    // immediate path does not stamp.
    var inj: dep.DepCtx = undefined;

    try h.scheduler().callImmediate(.insert, .{42}, &inj);
    try h.scheduler().callImmediate(.insert, .{7}, &inj);
    // A result-returning route hands its value back through callImmediate.
    try std.testing.expectEqual(@as(i64, 2), try h.scheduler().callImmediate(.count, .{}, &inj));

    var q = orm.Query
        .from(.t, TestRoutes.T)
        .select(.{ .t = .{ .n = .n } })
        .orderby(.n, .asc);
    defer q.deinit(std.testing.allocator);
    const r1 = (try q.next(&h.db, std.testing.allocator)).?;
    try std.testing.expectEqual(@as(i64, 7), r1.n);
    const r2 = (try q.next(&h.db, std.testing.allocator)).?;
    try std.testing.expectEqual(@as(i64, 42), r2.n);
    try std.testing.expect((try q.next(&h.db, std.testing.allocator)) == null);
}

test "callLater builds the event without queueing" {
    var conf: Config = .{ .path = ":memory:" };
    var h = try TestHandler.init(&conf, std.testing.allocator);
    defer h.deinit(std.testing.allocator);

    const ev = try h.scheduler().callLater(.{ .insert = .{1} }, .{});
    try std.testing.expectEqual(@field(TestET, "sqlite_call"), ev.event_type);
    const data = @field(ev.event_data, "sqlite");
    try std.testing.expectEqual(@as(i64, 1), data.call.insert[0]);
}

test "call pushes onto the bound queue" {
    var conf: Config = .{ .path = ":memory:" };
    var h = try TestHandler.init(&conf, std.testing.allocator);
    defer h.deinit(std.testing.allocator);

    var buf: [4]TestEvent = undefined;
    var occ = [_]u1{0} ** 4;
    var q = MPMCQueue(TestEvent).init(&buf, &occ);
    h.bind(&q);

    try h.scheduler().call(.{ .insert = .{9} }, .{});
    const popped = q.tryPop(std.time.ns_per_ms).?;
    try std.testing.expectEqual(@field(TestET, "sqlite_call"), popped.event_type);
    const data = @field(popped.event_data, "sqlite");
    try std.testing.expectEqual(@as(i64, 9), data.call.insert[0]);
}
