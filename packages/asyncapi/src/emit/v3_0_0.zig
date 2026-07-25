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
const model = @import("../model.zig");

const Stringify = std.json.Stringify;
const Writer = std.Io.Writer;

/// The AMQP binding object version we declare. See the AsyncAPI bindings spec.
const amqp_binding_version = "0.3.0";

/// Render a neutral `model.Document` as an AsyncAPI 3.0.0 JSON document.
///
/// This emitter owns every 3.0.0-specific decision (operations split out from
/// channels, `$ref` shapes, how `bindings` are projected). Adding another target
/// version means adding a sibling emitter — extraction and the model never change.
pub fn serialize(doc: model.Document, writer: *Writer) !void {
    var s: Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };

    try s.beginObject();

    try s.objectField("asyncapi");
    try s.write(doc.asyncapi_version.toString());

    try s.objectField("info");
    try s.beginObject();
    try s.objectField("title");
    try s.write(doc.info.title);
    try s.objectField("version");
    try s.write(doc.info.version);
    try s.endObject();

    try s.objectField("channels");
    try emitChannels(&s, doc.channels);

    try s.objectField("operations");
    try emitOperations(&s, doc.operations);

    const have_messages = doc.components.messages.count() > 0;
    const have_schemas = doc.components.schemas.schemas.count() > 0;
    if (have_messages or have_schemas) {
        try s.objectField("components");
        try s.beginObject();
        if (have_messages) {
            try s.objectField("messages");
            try s.beginObject();
            var it = doc.components.messages.iterator();
            while (it.next()) |entry| {
                try s.objectField(entry.key_ptr.*);
                try emitMessage(&s, entry.value_ptr.*);
            }
            try s.endObject();
        }
        if (have_schemas) {
            try s.objectField("schemas");
            try s.beginObject();
            var it = doc.components.schemas.schemas.iterator();
            while (it.next()) |entry| {
                try s.objectField(entry.key_ptr.*);
                try emitSchema(&s, entry.value_ptr.*);
            }
            try s.endObject();
        }
        try s.endObject();
    }

    try s.endObject();
}

fn emitChannels(s: *Stringify, channels: []const model.Channel) !void {
    try s.beginObject();
    for (channels) |ch| {
        try s.objectField(ch.id);
        try s.beginObject();

        try s.objectField("address");
        if (ch.address) |addr| try s.write(addr) else try s.write(null);

        if (ch.description) |d| {
            try s.objectField("description");
            try s.write(d);
        }

        if (ch.messages.len > 0) {
            try s.objectField("messages");
            try s.beginObject();
            for (ch.messages) |name| {
                try s.objectField(name);
                try beginRef(s, "#/components/messages/{s}", .{name});
            }
            try s.endObject();
        }

        try emitBindings(s, ch.bindings);
        try s.endObject();
    }
    try s.endObject();
}

fn emitOperations(s: *Stringify, operations: []const model.Operation) !void {
    try s.beginObject();
    for (operations) |op| {
        try s.objectField(op.id);
        try s.beginObject();

        try s.objectField("action");
        try s.write(@tagName(op.action));

        try s.objectField("channel");
        try beginRef(s, "#/channels/{s}", .{op.channel_id});

        try s.objectField("summary");
        try s.write(op.summary);
        if (op.description) |d| {
            try s.objectField("description");
            try s.write(d);
        }

        if (op.messages.len > 0) {
            try s.objectField("messages");
            try s.beginArray();
            for (op.messages) |name| {
                try beginRef(s, "#/channels/{s}/messages/{s}", .{ op.channel_id, name });
            }
            try s.endArray();
        }

        try emitBindings(s, op.bindings);
        try s.endObject();
    }
    try s.endObject();
}

fn emitMessage(s: *Stringify, msg: model.Message) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(msg.name);
    try s.objectField("contentType");
    try s.write(msg.content_type);
    try s.objectField("payload");
    try emitSchema(s, msg.payload);
    try emitBindings(s, msg.bindings);
    try s.endObject();
}

/// Write a single `{ "$ref": "<formatted>" }` object. The ref string is rendered
/// into a stack buffer; component/route names this long would be pathological.
fn beginRef(s: *Stringify, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const ref = try std.fmt.bufPrint(&buf, fmt, args);
    try s.beginObject();
    try s.objectField("$ref");
    try s.write(ref);
    try s.endObject();
}

fn emitBindings(s: *Stringify, b: model.Bindings) !void {
    if (b.isEmpty()) return;
    try s.objectField("bindings");
    try s.beginObject();
    if (b.amqp) |amqp| {
        try s.objectField("amqp");
        try s.beginObject();
        if (amqp.is) |is| {
            try s.objectField("is");
            try s.write(@tagName(is));
        }
        if (amqp.exchange) |ex| {
            try s.objectField("exchange");
            try s.beginObject();
            try s.objectField("name");
            try s.write(ex.name);
            try s.objectField("type");
            try s.write(@tagName(ex.type));
            try s.objectField("durable");
            try s.write(ex.durable);
            try s.objectField("autoDelete");
            try s.write(ex.auto_delete);
            try s.objectField("vhost");
            try s.write(ex.vhost);
            try s.endObject();
        }
        if (amqp.queue) |q| {
            try s.objectField("queue");
            try s.beginObject();
            try s.objectField("name");
            try s.write(q.name);
            try s.objectField("durable");
            try s.write(q.durable);
            try s.objectField("exclusive");
            try s.write(q.exclusive);
            try s.objectField("autoDelete");
            try s.write(q.auto_delete);
            try s.objectField("vhost");
            try s.write(q.vhost);
            try s.endObject();
        }
        try s.objectField("bindingVersion");
        try s.write(amqp_binding_version);
        try s.endObject();
    }
    try s.endObject();
}

// --- JSON Schema emission (2020-12 dialect, AsyncAPI's default) ---------------
// Mirrors the OpenAPI 3.2.0 emitter: the schema model is shared via kw-docschema,
// and both specs render it the same way.

/// Emit a single schema node as JSON Schema (2020-12 dialect).
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
                // In 2020-12 a `$ref` may carry sibling keywords like description.
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
            try s.beginObject();
            try emitDesc(s, schema.description);
            if (schema.nullable) try emitTypeField(s, "null", false);
            try s.endObject();
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

/// Write the `type` field. In JSON Schema 2020-12 nullability is expressed as a
/// type array `["<base>", "null"]` rather than a separate `nullable` keyword.
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
    try components.schemas.schemas.put(a, "Announce", .{
        .kind = .object,
        .properties = &.{.{ .name = "id", .schema = .{ .kind = .string } }},
        .required = &.{"id"},
    });
    try components.messages.put(a, "Announce", .{
        .name = "Announce",
        .payload = .{ .kind = .ref, .ref = "#/components/schemas/Announce" },
    });

    const doc: model.Document = .{
        .asyncapi_version = .v3_0_0,
        .info = .{ .title = "Test API", .version = "1.0.0" },
        .channels = &.{.{
            .id = "amq.direct/client.announce",
            .address = "client.announce",
            .messages = &.{"Announce"},
            .bindings = .{ .amqp = .{
                .is = .routingKey,
                .exchange = .{ .name = "amq.direct", .type = .direct },
            } },
        }},
        .operations = &.{.{
            .id = "client-announce",
            .action = .send,
            .channel_id = "amq.direct/client.announce",
            .summary = "Announce a client.",
            .messages = &.{"Announce"},
        }},
        .components = components,
    };

    var buf: std.Io.Writer.Allocating = .init(a);
    try serialize(doc, &buf.writer);
    const out = buf.written();

    // Parse it back to prove it's well-formed JSON with the expected shape.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("3.0.0", root.get("asyncapi").?.string);

    const ch = root.get("channels").?.object.get("amq.direct/client.announce").?.object;
    try std.testing.expectEqualStrings("client.announce", ch.get("address").?.string);
    try std.testing.expectEqualStrings(
        "routingKey",
        ch.get("bindings").?.object.get("amqp").?.object.get("is").?.string,
    );

    const op = root.get("operations").?.object.get("client-announce").?.object;
    try std.testing.expectEqualStrings("send", op.get("action").?.string);
    try std.testing.expectEqualStrings(
        "#/channels/amq.direct/client.announce",
        op.get("channel").?.object.get("$ref").?.string,
    );
    try std.testing.expectEqualStrings(
        "#/channels/amq.direct/client.announce/messages/Announce",
        op.get("messages").?.array.items[0].object.get("$ref").?.string,
    );

    const components_out = root.get("components").?.object;
    try std.testing.expect(components_out.get("messages").?.object.get("Announce") != null);
    try std.testing.expect(components_out.get("schemas").?.object.get("Announce") != null);
}
