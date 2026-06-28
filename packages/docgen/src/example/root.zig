//! `kw-docexample` — backend-agnostic, build-time example-value generation, layered
//! on the kw-docschema kernel. Two reusable layers: synthesize a neutral sample
//! `Value` from a `Schema` (synthesize.zig), then serialize it per content type
//! (serialize.zig). Any docgen backend reuses both and writes only the glue to emit
//! the resulting strings into its runtime projection.
const std = @import("std");
const docschema = @import("kw-docschema");
const Schema = docschema.Schema;
const Components = docschema.Components;

pub const Value = @import("value.zig").Value;
pub const synthesize = @import("synthesize.zig").synthesize;
pub const serialize = @import("serialize.zig").serialize;

/// Synthesize ∘ serialize: the single call a backend makes per (schema, content
/// type). Returns null when no serializer is registered for the content type.
pub fn exampleFor(
    schema: Schema,
    content_type: []const u8,
    components: *const Components,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const value = try synthesize(schema, components, allocator);
    var buf: std.Io.Writer.Allocating = .init(allocator);
    if (!try serialize(content_type, value, &buf.writer)) return null;
    return buf.written();
}

/// A plain-string sample for a scalar schema (a parameter value). Non-scalar
/// schemas (object/array) yield "" — parameters are expected to be scalar.
pub fn scalarExample(
    schema: Schema,
    components: *const Components,
    allocator: std.mem.Allocator,
) ![]const u8 {
    return switch (try synthesize(schema, components, allocator)) {
        .string => |s| s,
        .bool => |b| if (b) "true" else "false",
        .int => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        else => "",
    };
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

test {
    _ = @import("value.zig");
    _ = @import("synthesize.zig");
    _ = @import("serialize.zig");
}

test "exampleFor: JSON body, and null for unsupported content type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var comps: Components = .{};

    const body: Schema = .{ .kind = .object, .properties = &.{
        .{ .name = "name", .schema = .{ .kind = .string } },
    } };

    const json = (try exampleFor(body, "application/json", &comps, a)).?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"string\"") != null);
    try std.testing.expect((try exampleFor(body, "text/csv", &comps, a)) == null);
}

test "scalarExample: integer renders unquoted" {
    var comps: Components = .{};
    const a = std.testing.allocator;
    const s = try scalarExample(.{ .kind = .integer, .minimum = 42 }, &comps, a);
    defer a.free(s);
    try std.testing.expectEqualStrings("42", s);
}
