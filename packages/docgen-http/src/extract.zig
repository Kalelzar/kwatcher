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
const docindex = @import("kw-docindex");
const model = @import("model.zig");
const reflect = @import("kw-docschema").reflect;
const version = @import("version.zig");

const Operation = model.Operation;
const Parameter = model.Parameter;
const Response = model.Response;
const Content = model.Content;

/// Build a version-neutral `model.Document` from a driver's registered routes.
///
/// `arena` should be an arena allocator: every slice the document points at is
/// allocated from it and freed in one shot when the document is no longer needed.
pub fn buildDocument(
    comptime Driver: type,
    info: model.Info,
    ver: version.OpenApiVersion,
    doc_index: ?*const docindex.DocIndex,
    arena: std.mem.Allocator,
) !model.Document {
    var components: model.Components = .{};
    var ctx: reflect.Ctx = .{ .allocator = arena, .components = &components, .doc_index = doc_index };

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

    // The handler's `///` doc comment, looked up by its original (raw) source name,
    // drives both summary and description: summary = first sentence, description =
    // the full text when it carries more than that sentence. With no doc comment we
    // fall back to a "<METHOD> <path>" summary and no description.
    const fallback_summary = comptime methodUpper(R.method) ++ " " ++ path;
    var summary: []const u8 = fallback_summary;
    var description: ?[]const u8 = null;
    if (ctx.doc_index) |idx| {
        if (idx.declDoc(R.inner.raw)) |doc| {
            const first = firstSentence(doc);
            summary = first;
            description = if (doc.len > first.len) doc else null;
        }
    }

    const sec = comptime securityEntries(R);
    inline for (sec) |e| {
        try ctx.components.security_schemes.put(ctx.allocator, e.ref.scheme, .{ .kind = e.kind });
    }

    return .{
        .method = comptime methodOf(R.method),
        // `R.id` is the route identifier — guaranteed unique across the driver.
        .operation_id = R.id,
        .summary = summary,
        .description = description,
        .parameters = try params.toOwnedSlice(arena),
        .request_body = request_body,
        .responses = try buildResponses(R.Return, ctx, arena),
        .security = comptime blk: {
            var refs: []const model.SecurityRef = &.{};
            for (sec) |e| refs = refs ++ .{e.ref};
            break :blk refs;
        },
    };
}

const SecurityEntry = struct {
    ref: model.SecurityRef,
    kind: model.SecurityScheme.Kind,
};

/// Security metadata attached by auth middleware (`RouteBase.wrapWith`).
/// Matched structurally (scheme/kind/scopes fields) rather than by type
/// identity: the build-time docgen module deliberately does not depend on
/// kw-http, where `security.SecurityRequirement` lives.
fn securityEntries(comptime R: type) []const SecurityEntry {
    comptime {
        if (!@hasDecl(R, "metadata")) return &.{};
        var entries: []const SecurityEntry = &.{};
        for (R.metadata) |entry| {
            const T = @TypeOf(entry);
            if (@typeInfo(T) != .@"struct") continue;
            if (!@hasField(T, "scheme") or !@hasField(T, "kind") or !@hasField(T, "scopes")) continue;
            if (@typeInfo(@TypeOf(entry.kind)) != .@"enum") continue;
            const kind = std.meta.stringToEnum(model.SecurityScheme.Kind, @tagName(entry.kind)) orelse continue;
            entries = entries ++ .{SecurityEntry{
                .ref = .{ .scheme = entry.scheme, .scopes = entry.scopes },
                .kind = kind,
            }};
        }
        return entries;
    }
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
    const content_types = comptime contentTypesOf(Return);

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
                    .content = try buildContent(f.type, content_types, ctx, arena),
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
            .content = try buildContent(Return, content_types, ctx, arena),
        };
    }
    return responses;
}

/// The media types a return type advertises. A multi-representation wrapper (the
/// template `Many`) exposes them through a `pub const AllowedTypes` enum whose field
/// names are the content-type strings; anything else has the single type from
/// `contentTypeOf` (the `Json` helper's `application/json`, or the default).
fn contentTypesOf(comptime Return: type) []const []const u8 {
    switch (@typeInfo(Return)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            if (@hasDecl(Return, "AllowedTypes") and @typeInfo(Return.AllowedTypes) == .@"enum") {
                const fields = @typeInfo(Return.AllowedTypes).@"enum".fields;
                var out: [fields.len][]const u8 = undefined;
                for (fields, 0..) |f, i| out[i] = f.name;
                const frozen = out;
                return &frozen;
            }
        },
        else => {},
    }
    return &.{reflect.contentTypeOf(Return)};
}

/// Build the `content` map for one payload across the route's media types. A payload
/// that pins its own content type (`pub const ContentType`) overrides the set and is
/// emitted once with its structured schema. Otherwise each media type gets the
/// structured schema if it's JSON-shaped, or a plain string schema otherwise —
/// non-JSON representations (e.g. template-rendered `text/html`) are opaque text.
fn buildContent(
    comptime Payload: type,
    comptime content_types: []const []const u8,
    ctx: *reflect.Ctx,
    arena: std.mem.Allocator,
) ![]const Content {
    if (comptime reflect.declaredContentType(Payload)) |own| {
        const out = try arena.alloc(Content, 1);
        out[0] = .{ .content_type = own, .schema = try reflect.schemaFor(Payload, ctx) };
        return out;
    }

    const structured = try reflect.schemaFor(Payload, ctx);
    const out = try arena.alloc(Content, content_types.len);
    inline for (content_types, 0..) |ct, i| {
        out[i] = .{
            .content_type = ct,
            .schema = if (comptime isJsonLike(ct)) structured else .{ .kind = .string },
        };
    }
    return out;
}

fn isJsonLike(comptime content_type: []const u8) bool {
    return std.mem.endsWith(u8, content_type, "json");
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

/// The first sentence of a doc comment: up to the first sentence-ending period (or
/// the first line break), trimmed. Used as the short OpenAPI `summary`.
fn firstSentence(text: []const u8) []const u8 {
    var end = text.len;
    if (std.mem.indexOfScalar(u8, text, '\n')) |nl| end = nl;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (text[i] == '.') {
            const after = i + 1;
            if (after >= end or text[after] == ' ') {
                end = after;
                break;
            }
        }
    }
    return std.mem.trimRight(u8, text[0..end], " \t");
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
        pub const inner = .{ .path = path, .raw = identifier };
        pub const CallContext = Ctx;
        pub const Return = Ret;
    };
}

const TestDoc = struct { doc: model.Document, arena: *std.heap.ArenaAllocator };

fn buildTestDoc(comptime Driver: type) !TestDoc {
    return buildTestDocWith(Driver, null);
}

fn buildTestDocWith(
    comptime Driver: type,
    doc_index: ?*const docindex.DocIndex,
) !TestDoc {
    const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    const doc = try buildDocument(Driver, .{ .title = "t", .version = "1" }, .v3_2_0, doc_index, arena.allocator());
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

test "security metadata flows to op.security and components.security_schemes" {
    const Ctx = struct { request: *u8, response: *u8 };
    // Shape-compatible with kw-http's security.SecurityRequirement — matched
    // structurally, so the test needn't depend on kw-http either.
    const Requirement = struct {
        scheme: []const u8,
        kind: enum { http_bearer },
        scopes: []const []const u8 = &.{},
    };
    const Secured = struct {
        pub const method = TestVerb.get;
        pub const id = "GET /secured";
        pub const inner = .{ .path = &[_]TestSeg{.{ .static = "secured" }}, .raw = "GET /secured" };
        pub const CallContext = Ctx;
        pub const Return = HeartbeatMessage;
        pub const metadata = .{Requirement{
            .scheme = "bearer",
            .kind = .http_bearer,
            .scopes = &.{"profile"},
        }};
    };
    const Driver = struct {
        pub const Routes = &[_]type{
            Secured,
            TestRoute(.get, "GET /open", &.{.{ .static = "open" }}, Ctx, HeartbeatMessage),
        };
    };
    const r = try buildTestDoc(Driver);
    defer {
        r.arena.deinit();
        std.testing.allocator.destroy(r.arena);
    }

    const secured = findOp(r.doc, "/secured", .get).?;
    try std.testing.expectEqual(@as(usize, 1), secured.security.len);
    try std.testing.expectEqualStrings("bearer", secured.security[0].scheme);
    try std.testing.expectEqual(@as(usize, 1), secured.security[0].scopes.len);
    try std.testing.expectEqualStrings("profile", secured.security[0].scopes[0]);

    const open = findOp(r.doc, "/open", .get).?;
    try std.testing.expectEqual(@as(usize, 0), open.security.len);

    const scheme = r.doc.components.security_schemes.get("bearer").?;
    try std.testing.expectEqual(model.SecurityScheme.Kind.http_bearer, scheme.kind);
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
                try std.testing.expectEqual(@as(usize, 1), resp.content.len);
            },
            400 => {
                saw400 = true;
                try std.testing.expectEqual(@as(usize, 1), resp.content.len);
            },
            204 => {
                saw204 = true;
                try std.testing.expectEqual(@as(usize, 0), resp.content.len); // void -> no content
            },
            else => {},
        }
    }
    try std.testing.expect(saw200 and saw400 and saw204);
}

test "summary is the first sentence; description holds the full multi-sentence doc" {
    const Ctx = struct { request: *u8, response: *u8 };
    const Driver = struct {
        pub const Routes = &[_]type{
            // `inner.raw` for a fabricated route is its identifier.
            TestRoute(.get, "listThings", &.{.{ .static = "things" }}, Ctx, HeartbeatMessage),
            TestRoute(.post, "makeThing", &.{.{ .static = "things" }}, Ctx, HeartbeatMessage),
        };
    };

    var index: docindex.DocIndex = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer index.deinit();
    try docindex.indexSource(std.testing.allocator, &index,
        \\/// Lists all the things. Includes archived ones.
        \\pub fn listThings() void {}
        \\/// Creates a thing.
        \\pub fn makeThing() void {}
    );

    const r = try buildTestDocWith(Driver, &index);
    defer {
        r.arena.deinit();
        std.testing.allocator.destroy(r.arena);
    }

    // Multi-sentence: summary = first sentence, description = full text.
    const list = findOp(r.doc, "/things", .get).?;
    try std.testing.expectEqualStrings("Lists all the things.", list.summary);
    try std.testing.expectEqualStrings("Lists all the things. Includes archived ones.", list.description.?);

    // Single-sentence: summary carries it, description is omitted (no extra content).
    const make = findOp(r.doc, "/things", .post).?;
    try std.testing.expectEqualStrings("Creates a thing.", make.summary);
    try std.testing.expect(make.description == null);

    // Without an index, summary falls back to "<METHOD> <path>".
    const r2 = try buildTestDoc(Driver);
    defer {
        r2.arena.deinit();
        std.testing.allocator.destroy(r2.arena);
    }
    try std.testing.expectEqualStrings("GET /things", findOp(r2.doc, "/things", .get).?.summary);
    try std.testing.expect(findOp(r2.doc, "/things", .get).?.description == null);
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
    try std.testing.expectEqual(@as(usize, 0), op.responses[0].content.len);
}
