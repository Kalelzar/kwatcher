const std = @import("std");
const docs = @import("kw-gen--docs");
const http = @import("kw-http");
const core = @import("kw-core");
const zmpl = @import("zmpl.zig");

// FE-only routes return `zmpl.Html(T, statuses)` instead of `http.data.Json` — they render
// HTML only and carry no JSON a separate frontend would consume (a redirect shell, the
// driver/icon chrome, the per-operation tab fragments, the JSON pretty-printer). `WithTemplates`
// resolves their template name and skips content negotiation. Routes that genuinely expose data
// (`getDrivers`, `httpView`, `httpOperation`) keep returning `http.data.Json` and stay dual.

const DriverResponse = struct {
    drivers: []const docs.DriverInfo,
    active: docs.DriverInfo,
};

const OpStub = struct {
    id: []const u8,
    method: []const u8,
    path: []const u8,
    summary: []const u8,
};

/// The introspection JSON for one operation: `docs.HttpOperation`'s clean, already-nested
/// data model reused verbatim (params carry `required: bool`, responses keep their
/// `content_types` array and nested `examples`), with the owning document's `key` added so
/// a consumer/template can address sibling routes. Nothing is reshaped for presentation.
const OpInfo = struct {
    key: []const u8,
    operation: docs.HttpOperation,
};

const HttpView = struct {
    key: []const u8,
    operations: []const OpStub,
};

const JsonRender = struct {
    body: []const u8,
};

fn findHttpDocument(key: []const u8) ?docs.HttpDocument {
    for (docs.http_documents) |d| {
        if (std.mem.eql(u8, d.key, key)) return d;
    }
    return null;
}

fn findOp(key: []const u8, operationId: []const u8) ?docs.HttpOperation {
    const doc = findHttpDocument(key) orelse return null;
    for (doc.operations) |op| {
        if (std.mem.eql(u8, op.id, operationId)) return op;
    }
    return null;
}

fn prettyJson(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
    var buf: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{ .whitespace = .indent_2 } };
    try s.write(parsed.value);
    return buf.written();
}

pub fn @"GET _introspect @introspectIndex"(_: http.data.Request(null)) zmpl.Html(
    struct { title: []const u8 },
    &.{200},
) {
    return .{
        .value = .{
            .ok = .{
                .title = "KW-IntrospectUI",
            },
        },
    };
}

pub fn @"GET _introspect/{kind}/{key} @introspectDriver"(
    body: struct {
        request: *http.Request,
        response: *http.Response,
        captures: struct {
            kind: []const u8,
            key: []const u8,
        },
    },
    depctx: *core.deps.DepCtx,
    allocator: core.mem.ScopedAllocator,
) !zmpl.Html(docs.DriverInfo, &.{ 200, 404 }) {
    inline for (docs.drivers) |D| {
        if (std.mem.eql(u8, D.key, body.captures.key) and std.mem.eql(u8, D.kind, body.captures.kind)) {
            return .{
                .value = .{
                    .ok = .{
                        .kind = D.kind,
                        .key = D.key,
                    },
                },
            };
        }
    }

    const ev_prop = try depctx.require(core.event.ExtendedProperties);

    const instance = try std.fmt.allocPrint(
        allocator.value,
        "{d}",
        .{ev_prop.correlation_id},
    );

    return .{
        .value = .{
            .not_found = .{
                .instance = instance,
                .type = error.NotFound,
                .title = "Driver not found",
                .details = "No driver matches the given kind and key.",
            },
        },
    };
}

pub fn @"GET _introspect/{kind}/{key}/favicon.svg"(body: struct {
    request: *http.Request,
    response: *http.Response,
    captures: struct {
        kind: []const u8,
        key: []const u8,
    },
}) !http.data.File("image/svg+xml") {
    var buffer: [256]u8 = undefined;
    inline for (docs.drivers) |D| {
        if (std.mem.eql(u8, D.key, body.captures.key) and std.mem.eql(u8, D.kind, body.captures.kind)) {
            const buf = try std.fmt.bufPrint(&buffer, "static/icons/{s}/{s}.svg", .{ D.kind, D.key });

            const file = try std.fs.cwd().openFile(buf, .{});
            // TODO: If the file does not exist we should try in order:
            // icons/{kind}/default.svg
            // icons/default.svg

            // TODO: We should move icons to be embedded into the binary along with a build-time ETag so we can properly cache this instead of this hack
            body.response.header("Cache-Control", "public, max-age=60");

            return .{
                .value = file,
            };
        }
    }

    return error.NotFound;
}

pub fn @"GET _introspect/{kind}/{key}/icon @driverIcon"(
    body: struct {
        request: *http.Request,
        response: *http.Response,
        captures: struct {
            kind: []const u8,
            key: []const u8,
        },
    },
    depctx: *core.deps.DepCtx,
    allocator: core.mem.ScopedAllocator,
) !zmpl.Html(docs.DriverInfo, &.{ 200, 404 }) {
    inline for (docs.drivers) |D| {
        if (std.mem.eql(u8, D.key, body.captures.key) and std.mem.eql(u8, D.kind, body.captures.kind)) {
            return .{
                .value = .{
                    .ok = .{
                        .kind = D.kind,
                        .key = D.key,
                    },
                },
            };
        }
    }

    const ev_prop = try depctx.require(core.event.ExtendedProperties);

    const instance = try std.fmt.allocPrint(
        allocator.value,
        "{d}",
        .{ev_prop.correlation_id},
    );

    return .{
        .value = .{
            .not_found = .{
                .instance = instance,
                .type = error.NotFound,
                .title = "Icon not found",
                .details = "An icon for the given kind and key could not be found.",
            },
        },
    };
}

pub fn @"GET _introspect/drivers @getDrivers"(
    rq: http.data.FullRequest(null, struct {
        key: []const u8 = "internal",
        kind: []const u8 = "internal",
    }),
) http.data.Json(
    DriverResponse,
    &.{200},
) {
    var active: docs.DriverInfo = .{ .kind = "internal", .key = "internal" };
    inline for (docs.drivers) |D| {
        if (std.mem.eql(u8, D.key, rq.query.key) and std.mem.eql(u8, D.kind, rq.query.kind)) {
            active = .{ .kind = D.kind, .key = D.key };
        }
    }

    return .{
        .value = .{
            .ok = .{
                .drivers = docs.drivers,
                .active = active,
            },
        },
    };
}

pub fn @"GET _introspect/http/{key}/view @httpView"(
    body: struct {
        request: *http.Request,
        response: *http.Response,
        captures: struct { key: []const u8 },
    },
    allocator: core.mem.ScopedAllocator,
) !http.data.Json(HttpView, &.{200}) {
    body.response.header("Cache-Control", "public, max-age=60");

    const doc = findHttpDocument(body.captures.key) orelse return .{
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
) http.data.Json(OpInfo, &.{ 200, 404 }) {
    if (findOp(body.captures.key, body.captures.operationId)) |op| {
        body.response.header("Cache-Control", "public, max-age=60");
        return .{ .value = .{ .ok = .{ .key = body.captures.key, .operation = op } } };
    }

    return .{
        .value = .{
            .not_found = .{
                .type = error.NotFound,
                .title = "Operation not found",
                .details = "No operation with that id is registered on this driver.",
                .instance = "TODO",
            },
        },
    };
}

pub fn @"GET _introspect/http/{key}/op/{operationId}/try @httpTryForm"(
    body: struct {
        request: *http.Request,
        response: *http.Response,
        captures: struct { key: []const u8, operationId: []const u8 },
    },
) zmpl.Html(OpInfo, &.{ 200, 404 }) {
    if (findOp(body.captures.key, body.captures.operationId)) |op| {
        return .{ .value = .{ .ok = .{ .key = body.captures.key, .operation = op } } };
    }

    return .{
        .value = .{
            .not_found = .{
                .type = error.NotFound,
                .title = "Operation not found",
                .details = "No operation with that id is registered on this driver.",
                .instance = "TODO",
            },
        },
    };
}

pub fn @"GET _introspect/http/{key}/op/{operationId}/examples @httpExamples"(
    body: struct {
        request: *http.Request,
        response: *http.Response,
        captures: struct { key: []const u8, operationId: []const u8 },
    },
) zmpl.Html(OpInfo, &.{ 200, 404 }) {
    if (findOp(body.captures.key, body.captures.operationId)) |op| {
        return .{ .value = .{ .ok = .{ .key = body.captures.key, .operation = op } } };
    }

    return .{
        .value = .{
            .not_found = .{
                .type = error.NotFound,
                .title = "Operation not found",
                .details = "No operation with that id is registered on this driver.",
                .instance = "TODO",
            },
        },
    };
}

pub fn @"POST _introspect/render/application/json @renderJson"(
    body: struct {
        request: *http.Request,
        response: *http.Response,
    },
    allocator: core.mem.ScopedAllocator,
) zmpl.Html(JsonRender, &.{200}) {
    const raw = body.request.body() orelse "";
    const pretty = prettyJson(allocator.value, raw) catch raw;
    return .{ .value = .{ .ok = .{ .body = pretty } } };
}
