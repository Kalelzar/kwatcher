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
                /// The routes slice minus carriers — the per-route surface
                /// docgen backends project (id/meta/CallContext/Result).
                pub const Routes = RealRoutes(_Routes);
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
                                // @FieldType, not std.meta.TagPayload: the
                                // latter's comptime field scan re-runs per
                                // instantiation and blows the eval-branch
                                // quota once a bridge inline-else expands
                                // this for every route of a large driver.
                                args: @FieldType(CallContext, @tagName(tag)),
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

/// Docgen-facing route identity. `raw` is the original fn name — the doc
/// index is keyed by it, so it survives `.mod(.{ .name = ... })` renames.
pub const Meta = struct { raw: []const u8 };

pub fn RouteBase(comptime HandlerFac: anytype, comptime parsed_id: []const u8, comptime route_meta: Meta) type {
    return struct {
        pub const Handler = HandlerFac(@This());
        pub const id = parsed_id;
        pub const meta = route_meta;

        pub const CallContext = Handler.CallContext;
        pub const Dependencies = Handler.Dependencies;
        pub const Result = Handler.Result;
        pub const call = Handler.call;
        pub const name = Handler.name;

        pub fn swap(comptime NextHandler: anytype) type {
            return RouteBase(NextHandler, parsed_id, route_meta);
        }

        pub fn wrap(comptime NextHandlerFac: anytype) type {
            return RouteBase(NextHandlerFac(HandlerFac).make, parsed_id, route_meta);
        }

        pub fn requires(comptime ct: anytype) void {
            if (comptime !server.meta.hasKey(CapabilityType, ct)) {
                @compileError(
                    "Required capability '" ++ @tagName(ct) ++ "' is not supported by SQLITE routes.",
                );
            }
        }

        pub fn satisfies(comptime ct: anytype) bool {
            return server.meta.hasKey(CapabilityType, ct);
        }

        pub fn mod(
            comptime capability: Capability,
        ) type {
            return switch (capability) {
                inline .name => |n| RouteBase(HandlerFac, n, route_meta),
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

                const RB = RouteBase(H.make, fnname, .{ .raw = fnname });

                return self.extend(RB);
            }
        }
    };
}

/// Console safety valve: an arbitrary SELECT stops rendering after this many
/// rows so a `SELECT * FROM huge` can't balloon the introspection response.
const max_console_rows = 500;

/// One executed statement's rendered result — every cell stringified so the
/// introspection console can render it with no type information.
pub const QueryResult = struct {
    columns: []const []const u8 = &.{},
    /// rows[i][j] is the stringified value of column j in row i.
    rows: []const []const []const u8 = &.{},
    /// Affected-row count, set when the statement returned no columns (DML).
    affected: ?i64 = null,
    /// True when `max_console_rows` cut the result short.
    truncated: bool = false,
    /// The sqlite error message when preparation or stepping failed.
    err: ?[]const u8 = null,
};

/// A named-query invocation's rendered outcome.
pub const RunResult = struct {
    /// JSON of the route's result; empty for void routes.
    output: []const u8 = "",
    err: ?[]const u8 = null,
};

/// Executes one SQL statement against the given connection and renders the
/// full result as arena-owned strings. Only the FIRST statement of `sql`
/// runs — sqlite's prepare discards everything after the first ';'. SQL-level
/// failures come back in `.err`; error returns are allocation failures only.
pub fn rawQuery(db: *Db, sql: []const u8, arena: std.mem.Allocator) !QueryResult {
    var stmt = db.conn.prepare(sql) catch {
        return .{ .err = try arena.dupe(u8, std.mem.span(db.conn.lastError())) };
    };
    defer stmt.deinit();

    var columns: []const []const u8 = &.{};
    var rows: std.ArrayList([]const []const u8) = .empty;
    var truncated = false;
    while (true) {
        const has_row = stmt.step() catch {
            return .{
                .columns = columns,
                .rows = rows.items,
                .err = try arena.dupe(u8, std.mem.span(db.conn.lastError())),
            };
        };
        if (!has_row) break;
        if (columns.len == 0) {
            // zqlite's columnCount wraps sqlite3_data_count, which is only
            // valid while the statement sits on a row — read the header here,
            // not after prepare.
            const ncols: usize = @intCast(@max(0, stmt.columnCount()));
            const cols = try arena.alloc([]const u8, ncols);
            for (cols, 0..) |*col, i| col.* = try arena.dupe(u8, std.mem.span(stmt.columnName(i)));
            columns = cols;
        }
        if (rows.items.len >= max_console_rows) {
            truncated = true;
            break;
        }
        const cells = try arena.alloc([]const u8, columns.len);
        for (cells, 0..) |*cell, i| cell.* = switch (stmt.columnType(i)) {
            .null => "NULL",
            .int => try std.fmt.allocPrint(arena, "{d}", .{stmt.int(i)}),
            .float => try std.fmt.allocPrint(arena, "{d}", .{stmt.float(i)}),
            // Text is only valid until the next step: copy now.
            .text => try arena.dupe(u8, stmt.text(i)),
            .blob => try std.fmt.allocPrint(arena, "<blob {d} B>", .{stmt.columnBytes(i)}),
            .unknown => "?",
        };
        try rows.append(arena, cells);
    }

    return .{
        .columns = columns,
        .rows = rows.items,
        .truncated = truncated,
        // A row-returning statement that yielded zero rows lands here too
        // (no row, so no header was readable) — gate the affected count on
        // the statement's first keyword so an empty SELECT doesn't report a
        // stale connection-global change count.
        .affected = if (rows.items.len == 0 and !returnsRows(sql))
            @as(i64, @intCast(db.conn.changes()))
        else
            null,
    };
}

/// Whether the statement's first keyword marks it row-returning. Only used to
/// suppress the misleading affected-count on empty result sets; DML with a
/// RETURNING clause is handled naturally by its rows.
fn returnsRows(sql: []const u8) bool {
    const t = std.mem.trimLeft(u8, sql, " \t\r\n(");
    inline for (.{ "SELECT", "WITH", "VALUES", "PRAGMA", "EXPLAIN" }) |kw| {
        if (std.ascii.startsWithIgnoreCase(t, kw)) return true;
    }
    return false;
}

/// Type-erased handle to a sqlite driver's live connection and routes.
///
/// The real `Yield(ET, EV).Scheduler` is parameterized by the app's event
/// union — types only known once the driver set is assembled — so framework
/// packages (the introspection UI) depend on this fixed vtable instead, the
/// cron `SchedulerShim` model. All surface types are file-scope.
pub const DbShim = struct {
    _queryFn: *const fn (*anyopaque, []const u8, std.mem.Allocator) anyerror!QueryResult,
    _runNamedFn: *const fn (*anyopaque, []const u8, []const []const u8, *dep.DepCtx, std.mem.Allocator) anyerror!RunResult,
    _ctx: *anyopaque,

    /// Runs one arbitrary SQL statement; see `rawQuery` for the contract.
    pub fn query(self: @This(), sql: []const u8, arena: std.mem.Allocator) !QueryResult {
        return self._queryFn(self._ctx, sql, arena);
    }

    /// Runs the named route synchronously with one string per call-context
    /// element, each converted to the element's type. The route's DI deps
    /// resolve from the CALLER's injector — a dep the caller's mount cannot
    /// see fails resolution and surfaces as an error return.
    pub fn runNamed(
        self: @This(),
        route: []const u8,
        args: []const []const u8,
        inj: *dep.DepCtx,
        arena: std.mem.Allocator,
    ) !RunResult {
        return self._runNamedFn(self._ctx, route, args, inj, arena);
    }
};

/// Converts one string element to a call-context element type. Primitives get
/// friendly bare forms (`42`, `true`, an unquoted string / enum tag); any
/// other type is parsed as JSON text — the same shape a REST caller embeds
/// inline in the args array. Failures report at runtime rather than
/// compile-erroring the bridge.
fn convertArg(comptime T: type, s: []const u8, arena: std.mem.Allocator) !T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, std.mem.trim(u8, s, " \t"), 10) catch error.InvalidArgument,
        .float => std.fmt.parseFloat(T, std.mem.trim(u8, s, " \t")) catch error.InvalidArgument,
        .bool => blk: {
            const t = std.mem.trim(u8, s, " \t");
            if (std.ascii.eqlIgnoreCase(t, "true") or std.mem.eql(u8, t, "1")) break :blk true;
            if (std.ascii.eqlIgnoreCase(t, "false") or std.mem.eql(u8, t, "0")) break :blk false;
            break :blk error.InvalidArgument;
        },
        .@"enum" => std.meta.stringToEnum(T, std.mem.trim(u8, s, " \t")) orelse error.InvalidArgument,
        // An empty field means null; anything present converts as the child.
        .optional => |o| if (s.len == 0) null else try convertArg(o.child, s, arena),
        .pointer => |p| if (comptime p.size == .slice and p.child == u8 and p.sentinel_ptr == null)
            try arena.dupe(u8, s)
        else
            jsonArg(T, s, arena),
        else => jsonArg(T, s, arena),
    };
}

/// Non-primitive elements (structs, arrays, unions, non-u8 slices) arrive as
/// JSON text.
fn jsonArg(comptime T: type, s: []const u8, arena: std.mem.Allocator) !T {
    return std.json.parseFromSliceLeaky(T, arena, s, .{ .allocate = .alloc_always }) catch error.InvalidArgument;
}

/// Adapts a concrete sqlite `Scheduler` to the type-erased `DbShim` vtable.
/// Route names map to `RouteKeys` at runtime via `stringToEnum`, then to a
/// comptime tag via `inline else` — `callImmediate` needs one so the result
/// type flows through.
pub fn DbBridge(comptime RealScheduler: type) type {
    // Extract the driver's nested per-app types from method signatures.
    const CallContext = @typeInfo(@TypeOf(RealScheduler.call)).@"fn".params[1].type.?;
    const RouteKeys = std.meta.Tag(CallContext);

    return struct {
        real: RealScheduler,

        fn queryImpl(ctx: *anyopaque, sql: []const u8, arena: std.mem.Allocator) anyerror!QueryResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return rawQuery(&self.real.parent.db, sql, arena);
        }

        fn runNamedImpl(
            ctx: *anyopaque,
            route: []const u8,
            args: []const []const u8,
            inj: *dep.DepCtx,
            arena: std.mem.Allocator,
        ) anyerror!RunResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const tag = std.meta.stringToEnum(RouteKeys, route) orelse return error.UnknownRoute;
            switch (tag) {
                inline else => |ctag| {
                    const Args = @FieldType(CallContext, @tagName(ctag));
                    const arg_fields = std.meta.fields(Args);
                    if (args.len != arg_fields.len) {
                        return .{ .err = try std.fmt.allocPrint(
                            arena,
                            "expected {d} argument(s), got {d}",
                            .{ arg_fields.len, args.len },
                        ) };
                    }
                    var call_args: Args = undefined;
                    inline for (arg_fields, 0..) |f, i| {
                        call_args[i] = convertArg(f.type, args[i], arena) catch |e| {
                            return .{ .err = try std.fmt.allocPrint(
                                arena,
                                "argument {d} ({s}): {s}",
                                .{ i, @typeName(f.type), @errorName(e) },
                            ) };
                        };
                    }
                    const res = self.real.callImmediate(ctag, call_args, inj) catch |e| {
                        return .{ .err = try std.fmt.allocPrint(arena, "route failed: {s}", .{@errorName(e)}) };
                    };
                    if (comptime @TypeOf(res) == void) {
                        return .{};
                    } else {
                        return .{ .output = try std.fmt.allocPrint(
                            arena,
                            "{f}",
                            .{std.json.fmt(res, .{ .whitespace = .indent_2 })},
                        ) };
                    }
                },
            }
        }

        pub fn toShim(self: *@This()) DbShim {
            return .{
                ._queryFn = &queryImpl,
                ._runNamedFn = &runNamedImpl,
                ._ctx = @ptrCast(self),
            };
        }
    };
}

/// DI factory wrapper that lazily builds a `DbBridge` on first request.
/// `shimDbFac` depends on the concrete `RealScheduler`, which the DI system
/// resolves from the `SchedulerCtx` the Server registers in `bind()`.
pub fn BridgeShimCtx(comptime RealScheduler: type) type {
    const BridgeType = DbBridge(RealScheduler);
    return struct {
        bridge: ?BridgeType = null,

        pub fn shimDbFac(self: *@This(), real_sched: RealScheduler) DbShim {
            if (self.bridge == null) {
                self.bridge = .{ .real = real_sched };
            }
            return self.bridge.?.toShim();
        }
    };
}

/// Dephub extension registering the type-erased sqlite DB shim under `.all`
/// (visible to every mount, including the private introspection UI).
/// Wire with `.with(.<sqlite driver key>, sqlite.defaultFor(<registry>), allocator)`.
pub fn defaultFor(comptime drv: server.DriverRegistry) type {
    return struct {
        pub fn apply(
            dephub: anytype,
            comptime category: anytype,
            allocator: std.mem.Allocator,
            comptime DriverConfig: type,
        ) Return(category, DriverConfig, @TypeOf(dephub)) {
            _ = allocator;
            const drk: drv.DriverKeys() = category;
            const Shim = BridgeShimCtx(drv.Schedulers()[@intFromEnum(drk)]);
            const H = struct {
                var shim = Shim{};
            };
            return dephub.static(.all, &H.shim);
        }

        pub fn Return(comptime category: anytype, comptime DriverConfig: type, comptime DH: type) type {
            _ = DriverConfig;
            const drk: drv.DriverKeys() = category;
            const Shim = BridgeShimCtx(drv.Schedulers()[@intFromEnum(drk)]);
            return DH.Static(.all, *Shim);
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

    /// Composite call-context element: reachable from the shim via JSON text.
    pub fn insertRecord(ctx: struct { struct { n: i64 } }, db: *Db) !void {
        try db.conn.exec("INSERT INTO t (n) VALUES (?1)", .{ctx[0].n});
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
    try std.testing.expectEqual(5, @typeInfo(Built.RouteKeys).@"enum".fields.len);
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
    // simple, insert, withDI, count, insertRecord — NotATable produced nothing.
    try std.testing.expectEqual(5, @typeInfo(Built.RouteKeys).@"enum".fields.len);
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

test "rawQuery renders SELECT rows, DML affected count, and errors" {
    var conf: Config = .{ .path = ":memory:" };
    var h = try TestHandler.init(&conf, std.testing.allocator);
    defer h.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try h.db.exec("INSERT INTO t (n) VALUES (5)");
    try h.db.exec("INSERT INTO t (n) VALUES (7)");

    const sel = try rawQuery(&h.db, "SELECT n FROM t ORDER BY n", arena);
    try std.testing.expect(sel.err == null);
    try std.testing.expectEqual(1, sel.columns.len);
    try std.testing.expectEqualStrings("n", sel.columns[0]);
    try std.testing.expectEqual(2, sel.rows.len);
    try std.testing.expectEqualStrings("5", sel.rows[0][0]);
    try std.testing.expectEqualStrings("7", sel.rows[1][0]);
    try std.testing.expect(sel.affected == null);

    const dml = try rawQuery(&h.db, "DELETE FROM t WHERE n = 5", arena);
    try std.testing.expect(dml.err == null);
    try std.testing.expectEqual(0, dml.columns.len);
    try std.testing.expectEqual(@as(?i64, 1), dml.affected);

    // Empty result set: no header is readable, but it must not report a
    // stale affected count either.
    const empty = try rawQuery(&h.db, "SELECT n FROM t WHERE n = 999", arena);
    try std.testing.expect(empty.err == null);
    try std.testing.expectEqual(0, empty.rows.len);
    try std.testing.expect(empty.affected == null);

    const bad = try rawQuery(&h.db, "SELEC 1", arena);
    try std.testing.expect(bad.err != null);
}

test "DbShim runs named routes with string args and arbitrary SQL" {
    var conf: Config = .{ .path = ":memory:" };
    var h = try TestHandler.init(&conf, std.testing.allocator);
    defer h.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Never dereferenced: the exercised routes have no DI deps and the
    // immediate path does not stamp.
    var inj: dep.DepCtx = undefined;
    var bridge = DbBridge(@TypeOf(h.scheduler())){ .real = h.scheduler() };
    const shim = bridge.toShim();

    // insert takes (i64) — one converted string arg, void result.
    const ins = try shim.runNamed("insert", &.{"42"}, &inj, arena);
    try std.testing.expect(ins.err == null);
    try std.testing.expectEqualStrings("", ins.output);

    // count takes no args and returns i64 — JSON output flows back.
    const cnt = try shim.runNamed("count", &.{}, &inj, arena);
    try std.testing.expect(cnt.err == null);
    try std.testing.expectEqualStrings("1", cnt.output);

    // A composite (struct) element arrives as JSON text.
    const rec = try shim.runNamed("insertRecord", &.{"{\"n\": 7}"}, &inj, arena);
    try std.testing.expect(rec.err == null);
    const cnt2 = try shim.runNamed("count", &.{}, &inj, arena);
    try std.testing.expectEqualStrings("2", cnt2.output);

    // Arg-count mismatch and failed conversion surface as error strings.
    const wrong = try shim.runNamed("insert", &.{}, &inj, arena);
    try std.testing.expect(wrong.err != null);
    const badconv = try shim.runNamed("insert", &.{"pear"}, &inj, arena);
    try std.testing.expect(badconv.err != null);

    // An unknown route is a hard error, not a rendered result.
    try std.testing.expectError(error.UnknownRoute, shim.runNamed("nope", &.{}, &inj, arena));

    const sel = try shim.query("SELECT COUNT(*) AS c FROM t", arena);
    try std.testing.expect(sel.err == null);
    try std.testing.expectEqualStrings("c", sel.columns[0]);
    try std.testing.expectEqualStrings("2", sel.rows[0][0]);
}

test "convertArg parses enums and JSON composites" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const E = enum { alpha, beta };
    try std.testing.expectEqual(E.beta, try convertArg(E, "beta", arena));
    try std.testing.expectError(error.InvalidArgument, convertArg(E, "gamma", arena));

    const S = struct { n: i64, s: []const u8 };
    const v = try convertArg(S, "{\"n\": 4, \"s\": \"x\"}", arena);
    try std.testing.expectEqual(@as(i64, 4), v.n);
    try std.testing.expectEqualStrings("x", v.s);
    try std.testing.expectError(error.InvalidArgument, convertArg(S, "notjson", arena));

    const arr = try convertArg([]const i64, "[1, 2, 3]", arena);
    try std.testing.expectEqual(@as(i64, 2), arr[1]);
}

test "routes expose meta.raw across renames" {
    const Rts = From(TestRoutes);
    const R1 = comptime blk: {
        for (Rts) |R| {
            if (!isTableCarrier(R)) break :blk R;
        }
        unreachable;
    };
    try std.testing.expectEqualStrings(R1.id, R1.meta.raw);
    const R2 = R1.mod(.{ .name = "renamed" });
    try std.testing.expectEqualStrings("renamed", R2.id);
    // The doc-index key survives the rename.
    try std.testing.expectEqualStrings(R1.id, R2.meta.raw);
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
