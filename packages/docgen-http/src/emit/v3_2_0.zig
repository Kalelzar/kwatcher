const std = @import("std");
const model = @import("../model.zig");

const Stringify = std.json.Stringify;
const Writer = std.Io.Writer;

/// Render a neutral `model.Document` as an OpenAPI 3.2.0 JSON document.
///
/// This emitter owns every 3.2.0-specific decision (object shape, how `nullable`
/// is represented, `$ref` wrapping). Adding another target version means adding a
/// sibling emitter — extraction and the model never change.
pub fn serialize(doc: model.Document, writer: *Writer) !void {
    var s: Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };

    try s.beginObject();

    try s.objectField("openapi");
    try s.write(doc.openapi_version.toString());

    try s.objectField("info");
    try s.beginObject();
    try s.objectField("title");
    try s.write(doc.info.title);
    try s.objectField("version");
    try s.write(doc.info.version);
    try s.endObject();

    try s.objectField("paths");
    try emitPaths(&s, doc.paths);

    if (doc.components.schemas.count() > 0 or doc.components.security_schemes.count() > 0) {
        try s.objectField("components");
        try s.beginObject();
        if (doc.components.schemas.count() > 0) {
            try s.objectField("schemas");
            try s.beginObject();
            var it = doc.components.schemas.iterator();
            while (it.next()) |entry| {
                try s.objectField(entry.key_ptr.*);
                try emitSchema(&s, entry.value_ptr.*);
            }
            try s.endObject();
        }
        if (doc.components.security_schemes.count() > 0) {
            try s.objectField("securitySchemes");
            try s.beginObject();
            var it = doc.components.security_schemes.iterator();
            while (it.next()) |entry| {
                try s.objectField(entry.key_ptr.*);
                try emitSecurityScheme(&s, entry.value_ptr.*);
            }
            try s.endObject();
        }
        try s.endObject();
    }

    try s.endObject();
}

fn emitSecurityScheme(s: *Stringify, scheme: model.SecurityScheme) !void {
    try s.beginObject();
    switch (scheme.kind) {
        .http_bearer => {
            try s.objectField("type");
            try s.write("http");
            try s.objectField("scheme");
            try s.write("bearer");
            try s.objectField("bearerFormat");
            try s.write("JWT");
        },
    }
    try s.endObject();
}

fn emitPaths(s: *Stringify, paths: []const model.PathItem) !void {
    try s.beginObject();
    for (paths) |item| {
        try s.objectField(item.path);
        try s.beginObject();
        for (item.operations) |op| {
            try s.objectField(@tagName(op.method));
            try emitOperation(s, op);
        }
        try s.endObject();
    }
    try s.endObject();
}

fn emitOperation(s: *Stringify, op: model.Operation) !void {
    try s.beginObject();

    try s.objectField("operationId");
    try s.write(op.operation_id);
    try s.objectField("summary");
    try s.write(op.summary);
    if (op.description) |d| {
        try s.objectField("description");
        try s.write(d);
    }

    if (op.parameters.len > 0) {
        try s.objectField("parameters");
        try s.beginArray();
        for (op.parameters) |p| {
            try s.beginObject();
            try s.objectField("name");
            try s.write(p.name);
            try s.objectField("in");
            try s.write(@tagName(p.location));
            try s.objectField("required");
            try s.write(p.required);
            try s.objectField("schema");
            try emitSchema(s, p.schema);
            try s.endObject();
        }
        try s.endArray();
    }

    if (op.request_body) |body| {
        try s.objectField("requestBody");
        try s.beginObject();
        try s.objectField("required");
        try s.write(body.required);
        try s.objectField("content");
        try emitContentMap(s, &.{.{ .content_type = body.content_type, .schema = body.schema }});
        try s.endObject();
    }

    try s.objectField("responses");
    try s.beginObject();
    var code_buf: [3]u8 = undefined;
    for (op.responses) |resp| {
        const code = try std.fmt.bufPrint(&code_buf, "{d}", .{resp.status});
        try s.objectField(code);
        try s.beginObject();
        try s.objectField("description");
        try s.write(resp.description);
        if (resp.content.len > 0) {
            try s.objectField("content");
            try emitContentMap(s, resp.content);
        }
        try s.endObject();
    }
    try s.endObject();

    if (op.security.len > 0) {
        try s.objectField("security");
        try s.beginArray();
        for (op.security) |sec| {
            try s.beginObject();
            try s.objectField(sec.scheme);
            try s.beginArray();
            for (sec.scopes) |scope| try s.write(scope);
            try s.endArray();
            try s.endObject();
        }
        try s.endArray();
    }

    try s.endObject();
}

/// Emit an OpenAPI `content` map: one entry per media type, each `{ "schema": … }`.
fn emitContentMap(s: *Stringify, contents: []const model.Content) !void {
    try s.beginObject();
    for (contents) |c| {
        try s.objectField(c.content_type);
        try s.beginObject();
        try s.objectField("schema");
        try emitSchema(s, c.schema);
        try s.endObject();
    }
    try s.endObject();
}

/// Emit a single schema node as JSON Schema (2020-12 dialect, as used by 3.2.0).
fn emitSchema(s: *Stringify, schema: model.Schema) !void {
    switch (schema.kind) {
        .ref => {
            const ref = schema.ref orelse "";
            if (schema.nullable) {
                // A `$ref` can't carry `null` directly; wrap it.
                try s.beginObject();
                try emitDesc(s, schema.description);
                try s.objectField("anyOf");
                try s.beginArray();
                try s.beginObject();
                try s.objectField("$ref");
                try s.write(ref);
                try s.endObject();
                try emitNullType(s);
                try s.endArray();
                try s.endObject();
            } else {
                try s.beginObject();
                // In 2020-12 (3.2.0) a `$ref` may carry sibling keywords like description.
                try s.objectField("$ref");
                try s.write(ref);
                try emitDesc(s, schema.description);
                try s.endObject();
            }
        },

        .one_of => {
            try s.beginObject();
            try emitDesc(s, schema.description);
            try s.objectField("oneOf");
            try s.beginArray();
            for (schema.one_of) |variant| try emitSchema(s, variant);
            if (schema.nullable) try emitNullType(s);
            try s.endArray();
            try s.endObject();
        },

        .empty => {
            if (schema.nullable) {
                try s.beginObject();
                try emitDesc(s, schema.description);
                try emitTypeField(s, "null", false);
                try s.endObject();
            } else {
                try s.beginObject();
                try emitDesc(s, schema.description);
                try s.endObject();
            }
        },

        .object => {
            try s.beginObject();
            try emitDesc(s, schema.description);
            try emitTypeField(s, "object", schema.nullable);
            if (schema.properties.len > 0) {
                try s.objectField("properties");
                try s.beginObject();
                for (schema.properties) |prop| {
                    try s.objectField(prop.name);
                    // A property's own doc comment becomes the description of its schema.
                    var prop_schema = prop.schema;
                    if (prop.description) |d| prop_schema.description = d;
                    try emitSchema(s, prop_schema);
                }
                try s.endObject();
            }
            if (schema.required.len > 0) {
                try s.objectField("required");
                try s.beginArray();
                for (schema.required) |name| try s.write(name);
                try s.endArray();
            }
            try s.endObject();
        },

        .array => {
            try s.beginObject();
            try emitDesc(s, schema.description);
            try emitTypeField(s, "array", schema.nullable);
            if (schema.items) |items| {
                try s.objectField("items");
                try emitSchema(s, items.*);
            }
            if (schema.max_items) |n| {
                try s.objectField("maxItems");
                try s.write(n);
            }
            try s.endObject();
        },

        .@"enum" => {
            try s.beginObject();
            try emitDesc(s, schema.description);
            try emitTypeField(s, "string", schema.nullable);
            try s.objectField("enum");
            try s.beginArray();
            for (schema.enum_values) |v| try s.write(v);
            try s.endArray();
            try s.endObject();
        },

        .string, .integer, .number, .boolean => {
            try s.beginObject();
            try emitDesc(s, schema.description);
            try emitTypeField(s, @tagName(schema.kind), schema.nullable);
            if (schema.format) |f| {
                try s.objectField("format");
                try s.write(f);
            }
            if (schema.minimum) |m| {
                try s.objectField("minimum");
                try s.write(m);
            }
            if (schema.maximum) |m| {
                try s.objectField("maximum");
                try s.write(m);
            }
            try s.endObject();
        },
    }
}

/// Write the `type` field. In 3.2.0 (JSON Schema 2020-12) nullability is expressed
/// as a type array `["<base>", "null"]` rather than a separate `nullable` keyword.
fn emitTypeField(s: *Stringify, base: []const u8, nullable: bool) !void {
    try s.objectField("type");
    if (nullable) {
        try s.beginArray();
        try s.write(base);
        try s.write("null");
        try s.endArray();
    } else {
        try s.write(base);
    }
}

fn emitNullType(s: *Stringify) !void {
    try s.beginObject();
    try emitTypeField(s, "null", false);
    try s.endObject();
}

fn emitDesc(s: *Stringify, description: ?[]const u8) !void {
    if (description) |d| {
        try s.objectField("description");
        try s.write(d);
    }
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

test "emits a minimal valid-looking document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var components: model.Components = .{};
    try components.schemas.put(a, "Thing", .{
        .kind = .object,
        .properties = &.{.{ .name = "id", .schema = .{ .kind = .integer, .format = "int64" } }},
        .required = &.{"id"},
    });
    try components.security_schemes.put(a, "bearer", .{ .kind = .http_bearer });

    const doc: model.Document = .{
        .openapi_version = .v3_2_0,
        .info = .{ .title = "Test API", .version = "1.0.0" },
        .paths = &.{.{
            .path = "/things/{id}",
            .operations = &.{.{
                .method = .get,
                .operation_id = "GET /things/{id}",
                .summary = "GET /things/{id}",
                .parameters = &.{.{
                    .name = "id",
                    .location = .path,
                    .required = true,
                    .schema = .{ .kind = .integer, .format = "int64", .minimum = 0 },
                }},
                .responses = &.{
                    .{ .status = 200, .description = "OK", .content = &.{.{ .content_type = "application/json", .schema = .{ .kind = .ref, .ref = "#/components/schemas/Thing" } }} },
                    .{ .status = 404, .description = "Not Found" },
                },
                .security = &.{.{ .scheme = "bearer", .scopes = &.{"profile"} }},
            }},
        }},
        .components = components,
    };

    var buf: std.Io.Writer.Allocating = .init(a);
    try serialize(doc, &buf.writer);
    const out = buf.written();

    // Parse it back to prove it's well-formed JSON with the expected shape.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("3.2.0", root.get("openapi").?.string);
    const op = root.get("paths").?.object.get("/things/{id}").?.object.get("get").?.object;
    try std.testing.expectEqualStrings("GET /things/{id}", op.get("operationId").?.string);
    const resp = op.get("responses").?.object;
    try std.testing.expect(resp.get("200") != null);
    try std.testing.expect(resp.get("404") != null);
    try std.testing.expect(root.get("components").?.object.get("schemas").?.object.get("Thing") != null);

    // Security: per-op requirement + components scheme.
    const sec = op.get("security").?.array.items[0].object;
    try std.testing.expectEqualStrings("profile", sec.get("bearer").?.array.items[0].string);
    const scheme = root.get("components").?.object.get("securitySchemes").?.object.get("bearer").?.object;
    try std.testing.expectEqualStrings("http", scheme.get("type").?.string);
    try std.testing.expectEqualStrings("bearer", scheme.get("scheme").?.string);
    try std.testing.expectEqualStrings("JWT", scheme.get("bearerFormat").?.string);
}
