//! The sqlite-specific introspection routes: the named-query list (with a Run
//! action), the table-structure pane, the SQL console, and the migration
//! state. They read the sqlite projection (`sqlite_documents`) that this
//! package's `runtime.zig` emits into the docgen manifest — threaded in as the
//! comptime `Docs` parameter (not `@import`ed) so this module carries no
//! static edge to docgen's output (which would form a build cycle).
//!
//! Live database access goes through the type-erased `sqlite.DbShim`
//! (registered by `sqlite.defaultFor`); every route degrades to a status line
//! when the shim is not wired.
//!
//! The two POST actions are plain REST endpoints as much as they are UI
//! backends: both take JSON bodies (`["42", "x"]` or `{"args": [...]}` for a
//! run, `{"sql": "..."}` for the console), so they are directly curl-able —
//! deliberately no form-data anywhere.

const std = @import("std");
const core = @import("kw-core");
const http = @import("kw-http");
const http_template = @import("kw-http-template");
const sqlite = @import("kw-sqlite");

/// One call-context element as the templates consume it: the synthesized
/// form-field name and the element's Zig type (its only identity — the
/// call context is a positional tuple, so there are no parameter names).
const ParamVM = struct { field: []const u8, type_name: []const u8 };

/// One named query as the templates consume it.
const QueryVM = struct {
    id: []const u8,
    summary: []const u8,
    description: []const u8,
    signature: []const u8,
    params: []const ParamVM,
};

/// One table column, constraints and FK preformatted — zmpl interpolation
/// consumes strings.
const ColumnVM = struct {
    name: []const u8,
    affinity: []const u8,
    constraints: []const u8,
    fk: []const u8,
};

const TableVM = struct { name: []const u8, columns: []const ColumnVM };

/// Console result cells, wrapped in structs so the template iterates proven
/// territory (struct fields) rather than bare nested slices.
const HeadVM = struct { name: []const u8 };
const CellVM = struct { value: []const u8 };
const RowVM = struct { cells: []const CellVM };

const MigrationVM = struct { version: []const u8 };

/// The tab chrome: just enough to render the tab bar.
fn Chrome(comptime Docs: type) type {
    _ = Docs;
    return struct { key: []const u8 };
}

/// The named-query pane. Split into with/without-args lists so the template
/// needs no conditional around the inputs (the cron jobs/cancelled pattern).
fn SqliteQueries(comptime Docs: type) type {
    _ = Docs;
    return struct {
        key: []const u8,
        with_args: []const QueryVM,
        no_args: []const QueryVM,
        status: []const u8,
    };
}

/// Response of the Run action: empty `status` renders `output`, non-empty
/// renders as an error line.
fn SqliteRun(comptime Docs: type) type {
    _ = Docs;
    return struct { status: []const u8, output: []const u8 };
}

fn SqliteTables(comptime Docs: type) type {
    _ = Docs;
    return struct { key: []const u8, tables: []const TableVM, status: []const u8 };
}

/// The console pane is a static form; results arrive via the exec fragment.
fn SqliteConsole(comptime Docs: type) type {
    _ = Docs;
    return struct { key: []const u8 };
}

/// Console execution result: `status` non-empty = error line; `show_table`
/// gates the result grid ("yes"/""); `note` is the row/affected summary.
fn SqliteConsoleOut(comptime Docs: type) type {
    _ = Docs;
    return struct {
        status: []const u8,
        show_table: []const u8,
        columns: []const HeadVM,
        rows: []const RowVM,
        note: []const u8,
    };
}

fn SqliteMigrations(comptime Docs: type) type {
    _ = Docs;
    return struct {
        key: []const u8,
        committed: []const MigrationVM,
        committed_note: []const u8,
        show_candidate: []const u8,
        candidate_note: []const u8,
        candidate_up: []const u8,
        candidate_down: []const u8,
    };
}

fn findSqliteDocument(comptime Docs: type, key: []const u8) ?Docs.SqliteDocument {
    for (Docs.sqlite_documents) |d| {
        if (std.mem.eql(u8, d.key, key)) return d;
    }
    return null;
}

/// Project one manifest query to its view model. `q` is `Docs.SqliteQuery`
/// (anytype: the manifest types are per-app generated, so they can't be
/// named here).
fn queryVM(q: anytype, allocator: std.mem.Allocator) !QueryVM {
    var sig: std.ArrayList(u8) = .empty;
    try sig.appendSlice(allocator, "(");
    const params = try allocator.alloc(ParamVM, q.params.len);
    for (q.params, 0..) |p, i| {
        params[i] = .{ .field = p.field, .type_name = p.type_name };
        if (i != 0) try sig.appendSlice(allocator, ", ");
        try sig.appendSlice(allocator, p.type_name);
    }
    try sig.appendSlice(allocator, ") → ");
    try sig.appendSlice(allocator, q.result);

    return .{
        .id = q.id,
        .summary = q.summary,
        .description = q.description,
        .signature = sig.items,
        .params = params,
    };
}

/// Preformat one manifest column's constraint and FK strings.
fn columnVM(col: anytype, allocator: std.mem.Allocator) !ColumnVM {
    var cons: std.ArrayList(u8) = .empty;
    if (col.pk) try cons.appendSlice(allocator, "PK");
    if (col.unique) {
        if (cons.items.len != 0) try cons.appendSlice(allocator, " · ");
        try cons.appendSlice(allocator, "UNIQUE");
    }
    if (cons.items.len != 0) try cons.appendSlice(allocator, " · ");
    try cons.appendSlice(allocator, if (col.nullable) "NULL" else "NOT NULL");

    return .{
        .name = col.name,
        .affinity = col.affinity,
        .constraints = cons.items,
        .fk = if (col.fk_table.len == 0)
            ""
        else
            try std.fmt.allocPrint(allocator, "→ {s}.{s} · on delete {s} · on update {s}", .{
                col.fk_table, col.fk_column, col.on_delete, col.on_update,
            }),
    };
}

/// Parse a Run body: a JSON array of arguments, or `{"args": [...]}`. Values
/// may be typed (numbers, bools, null) or strings — everything is normalized
/// to the string form the shim's per-element converter consumes. An empty
/// body means no arguments.
fn parseArgs(raw: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return &.{};
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{}) catch return error.BadArgs;
    const arr = switch (parsed) {
        .array => |ar| ar,
        .object => |o| switch (o.get("args") orelse return error.BadArgs) {
            .array => |ar| ar,
            else => return error.BadArgs,
        },
        else => return error.BadArgs,
    };
    const out = try allocator.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |v, i| out[i] = switch (v) {
        .string => |s| s,
        .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| if (b) "true" else "false",
        // Null maps to the empty string, which the converter reads as null
        // for optional elements.
        .null => "",
        // Composite values (objects, arrays) pass through as JSON text; the
        // bridge parses them into the tuple element type. This is also what
        // a UI user types into a non-primitive param's input field.
        else => try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(v, .{})}),
    };
    return out;
}

/// Parse a console body: `{"sql": "..."}` or a bare JSON string.
fn parseSql(raw: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.BadSql;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{}) catch return error.BadSql;
    return switch (parsed) {
        .string => |s| s,
        .object => |o| switch (o.get("sql") orelse return error.BadSql) {
            .string => |s| s,
            else => return error.BadSql,
        },
        else => return error.BadSql,
    };
}

/// The console shares the application's single connection: a dangling BEGIN
/// would leave a connection-global open transaction under every route, and
/// ATTACH would widen the reachable file set. First-keyword guard, with a
/// word boundary so e.g. a table named "endpoints" doesn't trip "END".
fn forbiddenConsole(sql: []const u8) ?[]const u8 {
    const t = std.mem.trimLeft(u8, sql, " \t\r\n;");
    inline for (.{ "BEGIN", "COMMIT", "ROLLBACK", "END", "SAVEPOINT", "RELEASE", "ATTACH", "DETACH" }) |kw| {
        if (std.ascii.startsWithIgnoreCase(t, kw) and
            (t.len == kw.len or !std.ascii.isAlphanumeric(t[kw.len])))
        {
            return "Transaction and attach statements are disabled: the connection is shared with the application.";
        }
    }
    return null;
}

fn Routes(comptime Docs: type) type {
    return struct {
        pub fn @"GET _introspect/sqlite/{key}/view @sqliteView"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8 },
            },
        ) !http.data.Html(Chrome(Docs), &.{200}) {
            return .{ .value = .{ .ok = .{ .key = body.captures.key } } };
        }

        pub fn @"GET _introspect/sqlite/{key}/queries @sqliteQueries"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8 },
            },
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(SqliteQueries(Docs), &.{200}) {
            body.response.header("Cache-Control", "no-cache");
            const a = allocator.value;

            const doc = findSqliteDocument(Docs, body.captures.key) orelse return .{
                .value = .{ .ok = .{
                    .key = body.captures.key,
                    .with_args = &.{},
                    .no_args = &.{},
                    .status = "Unknown driver key.",
                } },
            };

            var n_args: usize = 0;
            for (doc.queries) |q| {
                if (q.params.len > 0) n_args += 1;
            }
            const with_args = try a.alloc(QueryVM, n_args);
            const no_args = try a.alloc(QueryVM, doc.queries.len - n_args);
            var wi: usize = 0;
            var ni: usize = 0;
            for (doc.queries) |q| {
                const vm = try queryVM(q, a);
                if (q.params.len > 0) {
                    with_args[wi] = vm;
                    wi += 1;
                } else {
                    no_args[ni] = vm;
                    ni += 1;
                }
            }

            return .{ .value = .{ .ok = .{
                .key = doc.key,
                .with_args = with_args,
                .no_args = no_args,
                .status = if (doc.queries.len == 0) "No named queries declared on this driver." else "",
            } } };
        }

        fn runFail(msg: []const u8) http.data.Html(SqliteRun(Docs), &.{200}) {
            return .{ .value = .{ .ok = .{ .status = msg, .output = "" } } };
        }

        pub fn @"POST _introspect/sqlite/{key}/query/{name}/run @sqliteQueryRun"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8, name: []const u8 },
            },
            depctx: *core.deps.DepCtx,
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(SqliteRun(Docs), &.{200}) {
            body.response.header("Cache-Control", "no-cache");
            const a = allocator.value;

            const doc = findSqliteDocument(Docs, body.captures.key) orelse
                return runFail("Unknown driver key.");

            // The manifest is the allowlist: only routes this driver actually
            // declares are runnable — anything else resolves to a status line.
            const known = for (doc.queries) |q| {
                if (std.mem.eql(u8, q.id, body.captures.name)) break true;
            } else false;
            if (!known) return runFail("No such named query.");

            const shim = depctx.require(sqlite.DbShim) catch
                return runFail("The sqlite DB shim is not wired; runs are unavailable.");

            const args = parseArgs(body.request.body() orelse "", a) catch
                return runFail("Body must be a JSON array of arguments (or {\"args\": [...]}).");

            const run = shim.runNamed(body.captures.name, args, depctx, a) catch |e| switch (e) {
                error.UnknownRoute => return runFail("Route is not registered on the driver."),
                else => return runFail("Internal error while running the route."),
            };
            if (run.err) |msg| return runFail(msg);
            return .{ .value = .{ .ok = .{
                .status = "",
                .output = if (run.output.len == 0) "✓ completed (no result)" else run.output,
            } } };
        }

        pub fn @"GET _introspect/sqlite/{key}/tables @sqliteTables"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8 },
            },
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(SqliteTables(Docs), &.{200}) {
            body.response.header("Cache-Control", "no-cache");
            const a = allocator.value;

            const doc = findSqliteDocument(Docs, body.captures.key) orelse return .{
                .value = .{ .ok = .{ .key = body.captures.key, .tables = &.{}, .status = "Unknown driver key." } },
            };

            const tables = try a.alloc(TableVM, doc.tables.len);
            for (doc.tables, 0..) |t, i| {
                const columns = try a.alloc(ColumnVM, t.columns.len);
                for (t.columns, 0..) |col, j| columns[j] = try columnVM(col, a);
                tables[i] = .{ .name = t.name, .columns = columns };
            }

            return .{ .value = .{ .ok = .{
                .key = doc.key,
                .tables = tables,
                .status = if (doc.tables.len == 0) "No tables declared on this driver." else "",
            } } };
        }

        pub fn @"GET _introspect/sqlite/{key}/console @sqliteConsole"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8 },
            },
        ) !http.data.Html(SqliteConsole(Docs), &.{200}) {
            body.response.header("Cache-Control", "no-cache");
            return .{ .value = .{ .ok = .{ .key = body.captures.key } } };
        }

        fn execFail(msg: []const u8) http.data.Html(SqliteConsoleOut(Docs), &.{200}) {
            return .{ .value = .{ .ok = .{
                .status = msg,
                .show_table = "",
                .columns = &.{},
                .rows = &.{},
                .note = "",
            } } };
        }

        pub fn @"POST _introspect/sqlite/{key}/console/exec @sqliteConsoleExec"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8 },
            },
            depctx: *core.deps.DepCtx,
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(SqliteConsoleOut(Docs), &.{200}) {
            body.response.header("Cache-Control", "no-cache");
            const a = allocator.value;

            if (findSqliteDocument(Docs, body.captures.key) == null)
                return execFail("Unknown driver key.");

            const shim = depctx.require(sqlite.DbShim) catch
                return execFail("The sqlite DB shim is not wired; the console is unavailable.");

            const sql = parseSql(body.request.body() orelse "", a) catch
                return execFail("Body must be {\"sql\": \"...\"} (or a bare JSON string).");
            if (forbiddenConsole(sql)) |msg| return execFail(msg);

            const qr = try shim.query(sql, a);
            if (qr.err) |msg| return execFail(msg);

            const columns = try a.alloc(HeadVM, qr.columns.len);
            for (qr.columns, 0..) |c, i| columns[i] = .{ .name = c };
            const rows = try a.alloc(RowVM, qr.rows.len);
            for (qr.rows, 0..) |r, i| {
                const cells = try a.alloc(CellVM, r.len);
                for (r, 0..) |c, j| cells[j] = .{ .value = c };
                rows[i] = .{ .cells = cells };
            }

            const note = if (qr.affected) |n|
                try std.fmt.allocPrint(a, "{d} row(s) affected.", .{n})
            else if (qr.truncated)
                try std.fmt.allocPrint(a, "Showing the first {d} rows (result truncated).", .{qr.rows.len})
            else
                try std.fmt.allocPrint(a, "{d} row(s).", .{qr.rows.len});

            return .{ .value = .{ .ok = .{
                .status = "",
                .show_table = if (qr.columns.len > 0) "yes" else "",
                .columns = columns,
                .rows = rows,
                .note = note,
            } } };
        }

        pub fn @"GET _introspect/sqlite/{key}/migrations @sqliteMigrations"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8 },
            },
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(SqliteMigrations(Docs), &.{200}) {
            body.response.header("Cache-Control", "no-cache");
            const a = allocator.value;

            const doc = findSqliteDocument(Docs, body.captures.key) orelse return .{
                .value = .{ .ok = .{
                    .key = body.captures.key,
                    .committed = &.{},
                    .committed_note = "Unknown driver key.",
                    .show_candidate = "",
                    .candidate_note = "",
                    .candidate_up = "",
                    .candidate_down = "",
                } },
            };

            const committed = try a.alloc(MigrationVM, doc.committed.len);
            for (doc.committed, 0..) |m, i| committed[i] = .{ .version = m.version };

            const pending = doc.candidate_up.len > 0;
            return .{ .value = .{ .ok = .{
                .key = doc.key,
                .committed = committed,
                .committed_note = if (doc.committed.len == 0) "No committed migrations." else "",
                .show_candidate = if (pending) "yes" else "",
                .candidate_note = if (pending)
                    "Pending candidate — make it permanent with `zig build commit-migration -Dmigration-name=<name>`."
                else
                    "No pending candidate migration.",
                .candidate_up = doc.candidate_up,
                .candidate_down = doc.candidate_down,
            } } };
        }
    };
}

/// Build this backend's introspection routes. All are HTTP-served, so the result is keyed
/// `http`; templates ship in this package under the `sqlite` prefix.
///
/// Routes pass `void` as their context: their captures are all string-typed and they never
/// read a routing context, so `void` keeps them context-agnostic and out of the `*Context`
/// dependency graph — they fold into any driver's routes regardless of its context type.
pub fn generate(comptime Docs: type) struct { http: []const type } {
    return .{ .http = http_template.WithTemplates("sqlite", http.From(Routes(Docs), void), &.{}) };
}
