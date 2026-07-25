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
const docschema = @import("kw-docschema");
const Schema = docschema.Schema;
const Components = docschema.Components;
const Value = @import("value.zig").Value;

/// Depth ceiling so a self-referential schema (a type that transitively refs itself)
/// can't recurse forever. Past it we emit `null`.
const max_depth = 16;

/// Synthesize a sample `Value` from a neutral `Schema`. Backend-agnostic: it reads
/// only the shared kw-docschema model plus a `Components` map to resolve `ref`s, so
/// any docgen backend can drive it.
pub fn synthesize(
    schema: Schema,
    components: *const Components,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!Value {
    return synth(schema, components, allocator, 0);
}

fn synth(
    schema: Schema,
    components: *const Components,
    a: std.mem.Allocator,
    depth: usize,
) error{OutOfMemory}!Value {
    if (depth >= max_depth) return .null;

    switch (schema.kind) {
        .empty => return .{ .object = &.{} },
        .boolean => return .{ .bool = false },
        .integer => return .{ .int = schema.minimum orelse 0 },
        .number => {
            const v: f64 = if (schema.minimum) |m| @floatFromInt(m) else 0;
            return .{ .float = v };
        },
        .string => return .{ .string = sampleString(schema.format) },
        .@"enum" => return .{
            .string = if (schema.enum_values.len > 0) schema.enum_values[0] else "string",
        },
        .one_of => return if (schema.one_of.len > 0)
            try synth(schema.one_of[0], components, a, depth + 1)
        else
            .null,
        .ref => {
            const ref = schema.ref orelse return .null;
            const name = if (std.mem.lastIndexOfScalar(u8, ref, '/')) |i| ref[i + 1 ..] else ref;
            const target = components.schemas.get(name) orelse return .null;
            return try synth(target, components, a, depth + 1);
        },
        .array => {
            const item_schema = schema.items orelse return .{ .array = &.{} };
            const arr = try a.alloc(Value, 1);
            arr[0] = try synth(item_schema.*, components, a, depth + 1);
            return .{ .array = arr };
        },
        .object => {
            const fields = try a.alloc(Value.Field, schema.properties.len);
            for (schema.properties, 0..) |prop, i| {
                fields[i] = .{
                    .name = prop.name,
                    .value = try synth(prop.schema, components, a, depth + 1),
                };
            }
            return .{ .object = fields };
        },
    }
}

/// A representative value for a `string` schema, refined by its `format` hint so
/// examples read realistically (a date-time looks like a date-time, not "string").
fn sampleString(format: ?[]const u8) []const u8 {
    const f = format orelse return "string";
    const eql = std.mem.eql;
    if (eql(u8, f, "date-time")) return "2024-01-01T00:00:00Z";
    if (eql(u8, f, "date")) return "2024-01-01";
    if (eql(u8, f, "time")) return "00:00:00";
    if (eql(u8, f, "duration")) return "P1D";
    if (eql(u8, f, "uuid")) return "00000000-0000-0000-0000-000000000000";
    if (eql(u8, f, "email")) return "user@example.com";
    if (eql(u8, f, "uri") or eql(u8, f, "url")) return "https://example.com";
    if (eql(u8, f, "hostname")) return "example.com";
    if (eql(u8, f, "ipv4")) return "127.0.0.1";
    if (eql(u8, f, "ipv6")) return "::1";
    if (eql(u8, f, "byte")) return "ZXhhbXBsZQ==";
    return "string";
}

test "synthesize: scalars, enum, and format hints" {
    var comps: Components = .{};
    const a = std.testing.allocator;

    try std.testing.expectEqual(@as(i64, 0), (try synthesize(.{ .kind = .integer }, &comps, a)).int);
    try std.testing.expectEqual(@as(i64, 5), (try synthesize(.{ .kind = .integer, .minimum = 5 }, &comps, a)).int);
    try std.testing.expectEqual(false, (try synthesize(.{ .kind = .boolean }, &comps, a)).bool);
    try std.testing.expectEqualStrings("string", (try synthesize(.{ .kind = .string }, &comps, a)).string);
    try std.testing.expectEqualStrings(
        "2024-01-01T00:00:00Z",
        (try synthesize(.{ .kind = .string, .format = "date-time" }, &comps, a)).string,
    );
    try std.testing.expectEqualStrings(
        "a",
        (try synthesize(.{ .kind = .@"enum", .enum_values = &.{ "a", "b" } }, &comps, a)).string,
    );
}

test "synthesize: nested object + array + ref, with cycle guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var comps: Components = .{};

    const node: Schema = .{ .kind = .object, .properties = &.{
        .{ .name = "next", .schema = .{ .kind = .ref, .ref = "#/components/schemas/Node" } },
    } };
    try comps.schemas.put(a, "Node", node);

    const user: Schema = .{ .kind = .object, .properties = &.{
        .{ .name = "id", .schema = .{ .kind = .integer } },
        .{ .name = "tags", .schema = .{ .kind = .array, .items = &.{ .kind = .string } } },
        .{ .name = "node", .schema = .{ .kind = .ref, .ref = "#/components/schemas/Node" } },
    } };

    const v = try synthesize(user, &comps, a);
    try std.testing.expectEqual(@as(usize, 3), v.object.len);
    try std.testing.expectEqualStrings("id", v.object[0].name);
    try std.testing.expectEqual(@as(usize, 1), v.object[1].value.array.len);
    try std.testing.expectEqualStrings("string", v.object[1].value.array[0].string);
}
