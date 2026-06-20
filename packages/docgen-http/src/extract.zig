const std = @import("std");
const model = @import("model.zig");
const reflect = @import("reflect.zig");
const version = @import("version.zig");

const Operation = model.Operation;
const Parameter = model.Parameter;
const Response = model.Response;

/// Build a version-neutral `model.Document` from a driver's registered routes.
///
/// `arena` should be an arena allocator: every slice the document points at is
/// allocated from it and freed in one shot when the document is no longer needed.
pub fn buildDocument(
    comptime Driver: type,
    info: model.Info,
    ver: version.OpenApiVersion,
    arena: std.mem.Allocator,
) !model.Document {
    var components: model.Components = .{};
    var ctx: reflect.Ctx = .{ .allocator = arena, .components = &components };

    // Group operations by path so routes sharing a path (different methods)
    // collapse into one Path Item. Insertion order is preserved for stable output.
    var by_path: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(Operation)) = .empty;

    inline for (Driver.Routes) |R| {
        const path = comptime routePath(R.inner.path);
        const op = try buildOperation(R, path, &ctx, arena);
        const gop = try by_path.getOrPut(arena, path);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, op);
    }

    const paths = try arena.alloc(model.PathItem, by_path.count());
    var it = by_path.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        paths[i] = .{
            .path = entry.key_ptr.*,
            .operations = try entry.value_ptr.toOwnedSlice(arena),
        };
    }

    return .{
        .openapi_version = ver,
        .info = info,
        .paths = paths,
        .components = components,
    };
}

fn buildOperation(
    comptime R: type,
    comptime path: []const u8,
    ctx: *reflect.Ctx,
    arena: std.mem.Allocator,
) !Operation {
    const CallContext = R.CallContext;

    var params: std.ArrayListUnmanaged(Parameter) = .empty;
    // Path parameters, in path order (captures and `[...]` parameters alike).
    try appendPathParams(R.inner.path, ctx, arena, &params);
    // Query parameters from the handler's `query` context field, if any.
    if (@hasField(CallContext, "query")) {
        const Query = @FieldType(CallContext, "query");
        inline for (@typeInfo(Query).@"struct".fields) |f| {
            try params.append(arena, .{
                .name = f.name,
                .location = .query,
                .required = fieldIsRequired(f),
                .schema = try reflect.schemaFor(f.type, ctx),
            });
        }
    }

    var request_body: ?model.RequestBody = null;
    if (@hasField(CallContext, "body")) {
        const Body = @FieldType(CallContext, "body");
        request_body = .{
            .required = true,
            .content_type = reflect.contentTypeOf(Body),
            .schema = try reflect.schemaFor(Body, ctx),
        };
    }

    return .{
        .method = comptime methodOf(R.method),
        // `R.id` is the route identifier — guaranteed unique across the driver.
        .operation_id = R.id,
        .summary = comptime methodUpper(R.method) ++ " " ++ path,
        .parameters = try params.toOwnedSlice(arena),
        .request_body = request_body,
        .responses = try buildResponses(R.Return, ctx, arena),
    };
}

/// Locate a status union on the return type and emit one response per variant;
/// otherwise emit a single 200 (or 204 for an empty return).
///
/// A union qualifies as a "status union" when every variant name resolves to an
/// `std.http.Status` tag — true for the `Json`/`ApiResult` helper (whose variant
/// names are built from status tags) and for any hand-rolled union with
/// status-named variants. This deliberately does not depend on the `Json` helper.
fn buildResponses(comptime Return: type, ctx: *reflect.Ctx, arena: std.mem.Allocator) ![]const Response {
    @setEvalBranchQuota(100_000);
    if (comptime findStatusUnion(Return)) |StatusUnion| {
        const fields = @typeInfo(StatusUnion).@"union".fields;
        const responses = try arena.alloc(Response, fields.len);
        inline for (fields, 0..) |f, i| {
            const status = std.meta.stringToEnum(std.http.Status, f.name).?;
            const code: u16 = @intFromEnum(status);
            if (@typeInfo(f.type) == .void) {
                responses[i] = .{ .status = code, .description = phraseOf(status) };
            } else {
                responses[i] = .{
                    .status = code,
                    .description = phraseOf(status),
                    // A variant may override the content type; otherwise it inherits
                    // the wrapper's (e.g. the `Json` helper's `application/json`).
                    .content_type = reflect.declaredContentType(f.type) orelse reflect.contentTypeOf(Return),
                    .schema = try reflect.schemaFor(f.type, ctx),
                };
            }
        }
        return responses;
    }

    // Plain return type: a single success response.
    const responses = try arena.alloc(Response, 1);
    if (@typeInfo(Return) == .void) {
        responses[0] = .{ .status = 204, .description = phraseOf(.no_content) };
    } else {
        responses[0] = .{
            .status = 200,
            .description = phraseOf(.ok),
            .content_type = reflect.contentTypeOf(Return),
            .schema = try reflect.schemaFor(Return, ctx),
        };
    }
    return responses;
}

/// `Return` itself, a `value` field, or any single union-typed field — whichever
/// is a status union. Returns the union type, or `null`.
fn findStatusUnion(comptime Return: type) ?type {
    if (comptime isStatusUnion(Return)) return Return;
    if (@typeInfo(Return) == .@"struct") {
        if (@hasField(Return, "value")) {
            const V = @FieldType(Return, "value");
            if (comptime isStatusUnion(V)) return V;
        }
        inline for (@typeInfo(Return).@"struct".fields) |f| {
            if (comptime isStatusUnion(f.type)) return f.type;
        }
    }
    return null;
}

fn isStatusUnion(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    const info = switch (@typeInfo(T)) {
        .@"union" => |u| u,
        else => return false,
    };
    if (info.fields.len == 0) return false;
    inline for (info.fields) |f| {
        if (std.meta.stringToEnum(std.http.Status, f.name) == null) return false;
    }
    return true;
}

fn phraseOf(status: std.http.Status) []const u8 {
    return status.phrase() orelse "";
}

// --- path rendering -------------------------------------------------------

/// Render a route's parsed segments into a templated path, e.g. "/api/v1/users/{id}".
/// `segs` is the comptime `[]const RouteGen.Segment` value carried by `R.inner.path`;
/// taken as `anytype` so we don't need to import the http package's union type.
fn routePath(comptime segs: anytype) []const u8 {
    comptime {
        var p: []const u8 = "";
        for (segs) |seg| p = p ++ "/" ++ segmentContent(seg);
        return if (p.len == 0) "/" else p;
    }
}

fn segmentContent(comptime seg: anytype) []const u8 {
    comptime {
        return switch (seg) {
            .static => |s| s,
            .capture => |c| "{" ++ c.name ++ "}",
            .parameter => |prm| "{" ++ prm.name ++ "}",
            .compound => |inner| blk: {
                var s: []const u8 = "";
                for (inner) |x| s = s ++ segmentContent(x);
                break :blk s;
            },
        };
    }
}

fn appendPathParams(
    comptime segs: anytype,
    ctx: *reflect.Ctx,
    arena: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Parameter),
) !void {
    inline for (segs) |seg| {
        switch (seg) {
            .static => {},
            .capture => |c| try list.append(arena, .{
                .name = c.name,
                .location = .path,
                .required = true,
                .schema = try reflect.schemaFor(c.type, ctx),
            }),
            .parameter => |prm| try list.append(arena, .{
                .name = prm.name,
                .location = .path,
                .required = true,
                .schema = try reflect.schemaFor(prm.type, ctx),
            }),
            .compound => |inner| try appendPathParams(inner, ctx, arena, list),
        }
    }
}

// --- method mapping -------------------------------------------------------

/// Map the http package's `HttpVerb` (taken as `anytype`) onto our neutral
/// `model.Method`. The tag names are identical, so we key off the tag name.
fn methodOf(comptime verb: anytype) model.Method {
    return @field(model.Method, @tagName(verb));
}

fn methodUpper(comptime verb: anytype) []const u8 {
    comptime {
        const name = @tagName(verb);
        var out: [name.len]u8 = undefined;
        for (name, 0..) |c, i| out[i] = std.ascii.toUpper(c);
        const frozen = out;
        return &frozen;
    }
}

fn fieldIsRequired(comptime f: std.builtin.Type.StructField) bool {
    if (f.default_value_ptr != null) return false;
    return @typeInfo(f.type) != .optional;
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

// --- tests ----------------------------------------------------------------
// These fabricate route/driver types matching the shape the http package
// produces (see RouteBase / RouteGen.Segment) so we can exercise extraction
// without depending on the http package.

const TestSeg = union(enum) {
    static: []const u8,
    capture: struct { type: type, name: []const u8, wildcard: bool },
    parameter: struct { type: type, name: []const u8, spread: bool },
    compound: []const TestSeg,
};

const TestVerb = enum { get, post, put, delete };

const HeartbeatMessage = struct { timestamp: u64, count: u64 };
const ProblemDetails = struct { title: []const u8, details: ?[]const u8 = null };

fn TestRoute(
    comptime verb: TestVerb,
    comptime identifier: []const u8,
    comptime path: []const TestSeg,
    comptime Ctx: type,
    comptime Ret: type,
) type {
    return struct {
        pub const method = verb;
        pub const id = identifier;
        pub const inner = .{ .path = path };
        pub const CallContext = Ctx;
        pub const Return = Ret;
    };
}

fn buildTestDoc(comptime Driver: type) !struct { doc: model.Document, arena: *std.heap.ArenaAllocator } {
    const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    const doc = try buildDocument(Driver, .{ .title = "t", .version = "1" }, .v3_2_0, arena.allocator());
    return .{ .doc = doc, .arena = arena };
}

fn findOp(doc: model.Document, path: []const u8, method: model.Method) ?model.Operation {
    for (doc.paths) |p| {
        if (!std.mem.eql(u8, p.path, path)) continue;
        for (p.operations) |op| if (op.method == method) return op;
    }
    return null;
}

test "templated paths, path params, and methods" {
    const Ctx = struct { request: *u8, response: *u8, captures: struct { id: u64 } };
    const Driver = struct {
        pub const Routes = &[_]type{
            TestRoute(.get, "GET /api/v1/users/{id}", &.{
                .{ .static = "api" },                                              .{ .static = "v1" }, .{ .static = "users" },
                .{ .capture = .{ .type = u64, .name = "id", .wildcard = false } },
            }, Ctx, HeartbeatMessage),
        };
    };
    const r = try buildTestDoc(Driver);
    defer {
        r.arena.deinit();
        std.testing.allocator.destroy(r.arena);
    }

    const op = findOp(r.doc, "/api/v1/users/{id}", .get).?;
    try std.testing.expectEqualStrings("GET /api/v1/users/{id}", op.operation_id);
    try std.testing.expectEqualStrings("GET /api/v1/users/{id}", op.summary);
    try std.testing.expectEqual(@as(usize, 1), op.parameters.len);
    try std.testing.expectEqual(model.ParameterLocation.path, op.parameters[0].location);
    try std.testing.expect(op.parameters[0].required);
    try std.testing.expectEqualStrings("id", op.parameters[0].name);
    // Plain return -> single 200 referencing the registered component.
    try std.testing.expectEqual(@as(usize, 1), op.responses.len);
    try std.testing.expectEqual(@as(u16, 200), op.responses[0].status);
    try std.testing.expect(r.doc.components.schemas.contains("HeartbeatMessage"));
}

test "query params and request body" {
    const QueryCtx = struct { request: *u8, response: *u8, query: struct { key: []const u8, page: ?u32 = null } };
    const BodyCtx = struct { request: *u8, response: *u8, body: struct { name: []const u8 } };
    const Driver = struct {
        pub const Routes = &[_]type{
            TestRoute(.get, "GET /cfg", &.{.{ .static = "cfg" }}, QueryCtx, HeartbeatMessage),
            TestRoute(.post, "POST /users", &.{.{ .static = "users" }}, BodyCtx, HeartbeatMessage),
        };
    };
    const r = try buildTestDoc(Driver);
    defer {
        r.arena.deinit();
        std.testing.allocator.destroy(r.arena);
    }

    const get = findOp(r.doc, "/cfg", .get).?;
    try std.testing.expectEqual(@as(usize, 2), get.parameters.len);
    try std.testing.expectEqual(model.ParameterLocation.query, get.parameters[0].location);
    try std.testing.expect(get.parameters[0].required); // key: required
    try std.testing.expect(!get.parameters[1].required); // page: optional w/ default

    const post = findOp(r.doc, "/users", .post).?;
    try std.testing.expect(post.request_body != null);
    try std.testing.expectEqualStrings("application/json", post.request_body.?.content_type);
    try std.testing.expectEqual(model.SchemaKind.object, post.request_body.?.schema.kind); // anonymous -> inline
}

test "generic status union (not the Json helper) yields a response per status" {
    // A hand-rolled union with status-named variants — no `Json`/`ApiResult` in sight.
    const Ret = union(enum) { ok: HeartbeatMessage, bad_request: ProblemDetails, no_content: void };
    const Ctx = struct { request: *u8, response: *u8 };
    const Driver = struct {
        pub const Routes = &[_]type{
            TestRoute(.get, "GET /thing", &.{.{ .static = "thing" }}, Ctx, Ret),
        };
    };
    const r = try buildTestDoc(Driver);
    defer {
        r.arena.deinit();
        std.testing.allocator.destroy(r.arena);
    }

    const op = findOp(r.doc, "/thing", .get).?;
    try std.testing.expectEqual(@as(usize, 3), op.responses.len);
    var saw200 = false;
    var saw400 = false;
    var saw204 = false;
    for (op.responses) |resp| {
        switch (resp.status) {
            200 => {
                saw200 = true;
                try std.testing.expect(resp.schema != null);
            },
            400 => {
                saw400 = true;
                try std.testing.expect(resp.schema != null);
            },
            204 => {
                saw204 = true;
                try std.testing.expect(resp.schema == null); // void -> no content
            },
            else => {},
        }
    }
    try std.testing.expect(saw200 and saw400 and saw204);
}

test "void return becomes a 204" {
    const Ctx = struct { request: *u8, response: *u8 };
    const Driver = struct {
        pub const Routes = &[_]type{
            TestRoute(.delete, "DELETE /thing", &.{.{ .static = "thing" }}, Ctx, void),
        };
    };
    const r = try buildTestDoc(Driver);
    defer {
        r.arena.deinit();
        std.testing.allocator.destroy(r.arena);
    }

    const op = findOp(r.doc, "/thing", .delete).?;
    try std.testing.expectEqual(@as(usize, 1), op.responses.len);
    try std.testing.expectEqual(@as(u16, 204), op.responses[0].status);
    try std.testing.expect(op.responses[0].schema == null);
}
