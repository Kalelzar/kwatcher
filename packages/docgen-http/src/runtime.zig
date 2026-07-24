//! Emit a runtime-facing projection of each http driver's API into the generated
//! `manifest.zig`, so the in-app introspection UI can render real routes (not just
//! the OpenAPI JSON written to disk).
//!
//! This is a *projection*, not the full neutral `model.Document`: schemas are
//! flattened to a display type string (e.g. "integer<int64>", "User[]") because the
//! current view renders type summaries, not nested schema trees. The complete
//! `Document` still lives in the emitted OpenAPI JSON; promote fields here as the
//! view grows to need them.
//!
//! The emitted Zig is self-contained — it defines its own `Http*` types and a
//! `pub const http_documents` literal, importing nothing — matching how the manifest
//! emits `DriverInfo`/`drivers`.

const std = @import("std");
const docindex = @import("kw-docindex");
const model = @import("model.zig");
const extract = @import("extract.zig");
const example = @import("kw-docexample");

/// Called once for the http kind by the docgen framework, with every driver in the
/// app (we filter to http-kind ourselves). Appends the runtime types + the
/// `http_documents` array to the manifest writer.
pub fn emitRuntime(
    comptime Drivers: []const type,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    doc_index: *const docindex.DocIndex,
    name: []const u8,
    version_str: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writer.writeAll(runtime_types);
    try writer.writeAll("pub const http_documents: []const HttpDocument = &.{\n");

    inline for (Drivers) |Drv| {
        if (comptime std.mem.eql(u8, @tagName(Drv.kind), "http")) {
            const info: model.Info = .{ .title = name, .version = version_str };
            const doc = try extract.buildDocument(Drv, info, .v3_2_0, doc_index, a);
            try emitDocument(writer, a, @tagName(Drv.key), doc);
        }
    }

    try writer.writeAll("};\n");
}

const runtime_types =
    \\pub const HttpExample = struct { content_type: []const u8, body: []const u8 };
    \\pub const HttpParam = struct { name: []const u8, location: []const u8, type: []const u8, required: bool, description: []const u8, example: []const u8 };
    \\pub const HttpField = struct { name: []const u8, type: []const u8, required: bool, description: []const u8 };
    \\pub const HttpBody = struct { content_type: []const u8, fields: []const HttpField };
    \\pub const HttpResponse = struct { status: u16, description: []const u8, content_types: []const []const u8, examples: []const HttpExample };
    \\pub const HttpSecurity = struct { scheme: []const u8, scopes: []const []const u8 };
    \\pub const HttpOperation = struct {
    \\    id: []const u8,
    \\    method: []const u8,
    \\    path: []const u8,
    \\    summary: []const u8,
    \\    description: []const u8,
    \\    parameters: []const HttpParam,
    \\    body: ?HttpBody,
    \\    request_example: ?HttpExample,
    \\    responses: []const HttpResponse,
    \\    security: ?HttpSecurity,
    \\};
    \\pub const HttpDocument = struct { key: []const u8, title: []const u8, version: []const u8, operations: []const HttpOperation };
    \\
;

fn emitDocument(w: *std.Io.Writer, a: std.mem.Allocator, key: []const u8, doc: model.Document) !void {
    try w.writeAll("    .{ .key = ");
    try emitStr(w, key);
    try w.writeAll(", .title = ");
    try emitStr(w, doc.info.title);
    try w.writeAll(", .version = ");
    try emitStr(w, doc.info.version);
    try w.writeAll(", .operations = &.{\n");
    for (doc.paths) |p| {
        for (p.operations) |op| {
            // Skip CORS preflight handlers (auto-added OPTIONS routes): they aren't
            // documented API operations, and their ids ("[CORS] ...") aren't URL-safe
            // for the per-operation fragment path.
            if (op.method == .options) continue;
            try emitOperation(w, a, op, p.path, doc.components);
        }
    }
    try w.writeAll("    } },\n");
}

fn emitOperation(
    w: *std.Io.Writer,
    a: std.mem.Allocator,
    op: model.Operation,
    path: []const u8,
    components: model.Components,
) !void {
    try w.writeAll("        .{ .id = ");
    try emitStr(w, op.operation_id);
    try w.writeAll(", .method = ");
    try emitStr(w, try upper(a, @tagName(op.method)));
    try w.writeAll(", .path = ");
    try emitStr(w, path);
    try w.writeAll(", .summary = ");
    try emitStr(w, op.summary);
    try w.writeAll(", .description = ");
    try emitStr(w, op.description orelse "");

    try w.writeAll(", .parameters = &.{");
    for (op.parameters) |prm| {
        try w.writeAll(" .{ .name = ");
        try emitStr(w, prm.name);
        try w.writeAll(", .location = ");
        try emitStr(w, @tagName(prm.location));
        try w.writeAll(", .type = ");
        try emitStr(w, try typeString(a, prm.schema));
        try w.print(", .required = {}", .{prm.required});
        try w.writeAll(", .description = ");
        try emitStr(w, prm.schema.description orelse "");
        try w.writeAll(", .example = ");
        try emitStr(w, try example.scalarExample(prm.schema, &components, a));
        try w.writeAll(" },");
    }
    try w.writeAll(" }");

    if (op.request_body) |rb| {
        try w.writeAll(", .body = .{ .content_type = ");
        try emitStr(w, rb.content_type);
        try w.writeAll(", .fields = &.{");
        // A named body type is a `ref`; resolve it to the component so we can list
        // its fields. Inline object bodies carry their properties directly.
        const bs = if (rb.schema.kind == .ref)
            (components.schemas.get(refName(rb.schema.ref orelse "")) orelse rb.schema)
        else
            rb.schema;
        if (bs.kind == .object) {
            for (bs.properties) |prop| {
                try w.writeAll(" .{ .name = ");
                try emitStr(w, prop.name);
                try w.writeAll(", .type = ");
                try emitStr(w, try typeString(a, prop.schema));
                try w.print(", .required = {}", .{contains(bs.required, prop.name)});
                try w.writeAll(", .description = ");
                try emitStr(w, prop.description orelse "");
                try w.writeAll(" },");
            }
        }
        try w.writeAll(" } }");
    } else {
        try w.writeAll(", .body = null");
    }

    // A synthesized example payload for the request body (Try-it prefill + Examples
    // tab), serialized for the body's content type. Null when there's no body or no
    // serializer is registered for that content type.
    if (op.request_body) |rb| {
        if (try example.exampleFor(rb.schema, rb.content_type, &components, a)) |ex| {
            try w.writeAll(", .request_example = .{ .content_type = ");
            try emitStr(w, rb.content_type);
            try w.writeAll(", .body = ");
            try emitStr(w, ex);
            try w.writeAll(" }");
        } else {
            try w.writeAll(", .request_example = null");
        }
    } else {
        try w.writeAll(", .request_example = null");
    }

    // First security requirement only: routes carry at most one today.
    if (op.security.len > 0) {
        try w.writeAll(", .security = .{ .scheme = ");
        try emitStr(w, op.security[0].scheme);
        try w.writeAll(", .scopes = &.{");
        for (op.security[0].scopes) |scope| {
            try w.writeByte(' ');
            try emitStr(w, scope);
            try w.writeByte(',');
        }
        try w.writeAll(" } }");
    } else {
        try w.writeAll(", .security = null");
    }

    try w.writeAll(", .responses = &.{");
    for (op.responses) |r| {
        try w.print(" .{{ .status = {d}", .{r.status});
        try w.writeAll(", .description = ");
        try emitStr(w, r.description);
        try w.writeAll(", .content_types = &.{");
        for (r.content) |c| {
            try w.writeByte(' ');
            try emitStr(w, c.content_type);
            try w.writeByte(',');
        }
        try w.writeAll(" }");
        // One synthesized example per content type that has a serializer.
        try w.writeAll(", .examples = &.{");
        for (r.content) |c| {
            if (try example.exampleFor(c.schema, c.content_type, &components, a)) |ex| {
                try w.writeAll(" .{ .content_type = ");
                try emitStr(w, c.content_type);
                try w.writeAll(", .body = ");
                try emitStr(w, ex);
                try w.writeAll(" },");
            }
        }
        try w.writeAll(" } },");
    }
    try w.writeAll(" } },\n");
}

/// A concise display type for a schema, e.g. "string", "integer<int64>", "User[]",
/// "User" (a ref). Recurses through array item types.
fn typeString(a: std.mem.Allocator, schema: model.Schema) error{OutOfMemory}![]const u8 {
    return switch (schema.kind) {
        .string => "string",
        .boolean => "boolean",
        .object => "object",
        .@"enum" => "enum",
        .one_of => "oneOf",
        .empty => "any",
        .ref => schema.ref orelse "object",
        .integer => if (schema.format) |f| try std.fmt.allocPrint(a, "integer<{s}>", .{f}) else "integer",
        .number => if (schema.format) |f| try std.fmt.allocPrint(a, "number<{s}>", .{f}) else "number",
        .array => blk: {
            const item = if (schema.items) |it| try typeString(a, it.*) else "any";
            break :blk try std.fmt.allocPrint(a, "{s}[]", .{item});
        },
    };
}

/// Write `s` as a Zig string literal (with surrounding quotes), escaping the bytes
/// that would break out of the literal.
fn emitStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try std.zig.stringEscape(s, w);
    try w.writeByte('"');
}

fn upper(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const buf = try a.alloc(u8, s.len);
    return std.ascii.upperString(buf, s);
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

/// The bare component name from a `$ref` JSON pointer ("#/components/schemas/Foo" →
/// "Foo"); the components map is keyed by bare name.
fn refName(ref: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, ref, '/')) |i| ref[i + 1 ..] else ref;
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
