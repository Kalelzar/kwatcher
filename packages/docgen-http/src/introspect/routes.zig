//! The HTTP-specific introspection routes: the operation browser (list + per-operation
//! detail), the client-side "Try it" form, and the per-operation examples tab. They read the
//! HTTP projection (`http_documents`) that this package's `runtime.zig` emits into the docgen
//! manifest — threaded in as the comptime `Docs` parameter (not `@import`ed) so this module
//! carries no static edge to docgen's output (which would form a build cycle).
//!
//! Template prefixes: the browser/detail/try templates use the `methodBadge` partial and ship
//! in this package under the `http` prefix; `httpExamples` renders through the shared
//! `viewJson` partial, so its template lives in the generic core package and the examples
//! route is wrapped under the `core` prefix (see `generate`).

const std = @import("std");
const core = @import("kw-core");
const http = @import("kw-http");
const http_template = @import("kw-http-template");

const OpStub = struct {
    id: []const u8,
    method: []const u8,
    path: []const u8,
    summary: []const u8,
};

/// One operation's introspection JSON. `port` is the configured port of the http mount that
/// serves this operation (as a string, "" when unknown), so the Try-it form targets that mount
/// rather than the introspection UI's own origin.
fn OpInfo(comptime Docs: type) type {
    return struct { key: []const u8, operation: Docs.HttpOperation, port: []const u8 = "" };
}

fn HttpView(comptime Docs: type) type {
    _ = Docs;
    return struct { key: []const u8, operations: []const OpStub };
}

fn findHttpDocument(comptime Docs: type, key: []const u8) ?Docs.HttpDocument {
    for (Docs.http_documents) |d| {
        if (std.mem.eql(u8, d.key, key)) return d;
    }
    return null;
}

fn findOp(comptime Docs: type, key: []const u8, operationId: []const u8) ?Docs.HttpOperation {
    const doc = findHttpDocument(Docs, key) orelse return null;
    for (doc.operations) |op| {
        if (std.mem.eql(u8, op.id, operationId)) return op;
    }
    return null;
}

/// The problem-detail `instance` for a not-found response: the request's correlation id.
/// `Properties` is injected per-event into the ad-hoc inner container, so it is pulled from
/// `depctx` in the body rather than declared as a handler param (the outer-generator analysis
/// can't see it).
fn instanceId(depctx: *core.deps.DepCtx, allocator: core.mem.ScopedAllocator) ![]const u8 {
    const properties = try depctx.require(core.event.Properties);
    return std.fmt.allocPrint(allocator.value, "{f}", .{properties.correlation_id});
}

/// Routes whose templates live under the `http` prefix.
fn Browser(comptime Docs: type) type {
    return struct {
        pub fn @"GET _introspect/http/{key}/view @httpView"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8 },
            },
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Json(HttpView(Docs), &.{200}) {
            body.response.header("Cache-Control", "public, max-age=60");

            const doc = findHttpDocument(Docs, body.captures.key) orelse return .{
                .value = .{ .ok = .{ .key = body.captures.key, .operations = &.{} } },
            };

            const stubs = try allocator.value.alloc(OpStub, doc.operations.len);
            for (doc.operations, 0..) |op, i| {
                stubs[i] = .{ .id = op.id, .method = op.method, .path = op.path, .summary = op.summary };
            }

            return .{ .value = .{ .ok = .{ .key = doc.key, .operations = stubs } } };
        }

        pub fn @"GET _introspect/http/{key}/op/{operationId} @httpOperation"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8, operationId: []const u8 },
            },
            depctx: *core.deps.DepCtx,
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Json(OpInfo(Docs), &.{ 200, 404 }) {
            if (findOp(Docs, body.captures.key, body.captures.operationId)) |op| {
                body.response.header("Cache-Control", "public, max-age=60");
                return .{ .value = .{ .ok = .{ .key = body.captures.key, .operation = op } } };
            }

            return .{ .value = notFound(Docs, try instanceId(depctx, allocator)) };
        }

        pub fn @"GET _introspect/http/{key}/op/{operationId}/try @httpTryForm"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8, operationId: []const u8 },
            },
            depctx: *core.deps.DepCtx,
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(OpInfo(Docs), &.{ 200, 404 }) {
            if (findOp(Docs, body.captures.key, body.captures.operationId)) |op| {
                const cfg = blk: {
                    inline for (Docs.drivers) |D| {
                        if (std.mem.eql(u8, D.kind, "http") and std.mem.eql(u8, D.key, body.captures.key)) {
                            const res = try depctx.require(core.mem.Keyed(*http.Config, D.key));
                            break :blk res.value;
                        }
                    }

                    unreachable;
                };

                const port = try std.fmt.allocPrint(allocator.value, "{d}", .{cfg.port});
                return .{ .value = .{ .ok = .{ .key = body.captures.key, .operation = op, .port = port } } };
            }

            return .{ .value = notFound(Docs, try instanceId(depctx, allocator)) };
        }
    };
}

/// Routes whose templates live under the `core` prefix.
fn Examples(comptime Docs: type) type {
    return struct {
        pub fn @"GET _introspect/http/{key}/op/{operationId}/examples @httpExamples"(
            body: struct {
                request: *http.Request,
                response: *http.Response,
                captures: struct { key: []const u8, operationId: []const u8 },
            },
            depctx: *core.deps.DepCtx,
            allocator: core.mem.ScopedAllocator,
        ) !http.data.Html(OpInfo(Docs), &.{ 200, 404 }) {
            if (findOp(Docs, body.captures.key, body.captures.operationId)) |op| {
                return .{ .value = .{ .ok = .{ .key = body.captures.key, .operation = op } } };
            }

            return .{ .value = notFound(Docs, try instanceId(depctx, allocator)) };
        }
    };
}

fn notFound(comptime Docs: type, instance: []const u8) http.data.ApiResult(OpInfo(Docs), http.data.ProblemDetails, &.{ 200, 404 }) {
    return .{
        .not_found = .{
            .type = error.NotFound,
            .title = "Operation not found",
            .details = "No operation with that id is registered on this driver.",
            .instance = instance,
        },
    };
}

/// Build this backend's introspection routes. All are HTTP-served, so the result is keyed
/// `http`; the templated routes split by prefix — browser/detail/try under `http`, examples
/// under `core` (shared `viewJson` partial). No `cron`/etc. routes today.
///
/// Routes pass `void` as their context: their captures are all string-typed and they never
/// read a routing context, so `void` keeps them context-agnostic and out of the `*Context`
/// dependency graph — they fold into any driver's routes regardless of its context type.
pub fn generate(comptime Docs: type) struct { http: []const type } {
    const browser = http_template.WithTemplates("http", http.From(Browser(Docs), void), &.{});
    const examples = http_template.WithTemplates("core", http.From(Examples(Docs), void), &.{});
    return .{ .http = browser ++ examples };
}
