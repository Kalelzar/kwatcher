const std = @import("std");
const Value = @import("value.zig").Value;

// FIXME: We need an auto-loader similiar to what modgen does for driver generators.
// Doing manual listing is yucky and limits expansion from third-party libraries.
const serializers = .{
    JsonSerializer,
};

/// Serialize `value` for `content_type` into `writer`. Returns false (having written
/// nothing) when no serializer is registered for the content type, so callers can
/// skip emitting an example for unsupported types.
pub fn serialize(content_type: []const u8, value: Value, writer: *std.Io.Writer) !bool {
    inline for (serializers) |S| {
        if (std.mem.eql(u8, S.ContentType, content_type)) {
            try S.serialize(value, writer);
            return true;
        }
    }
    return false;
}

pub const JsonSerializer = struct {
    pub const ContentType = "application/json";

    pub fn serialize(value: Value, writer: *std.Io.Writer) !void {
        var s: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };
        try writeValue(&s, value);
    }

    fn writeValue(s: *std.json.Stringify, v: Value) !void {
        switch (v) {
            .null => try s.write(null),
            .bool => |b| try s.write(b),
            .int => |i| try s.write(i),
            .float => |f| try s.write(f),
            .string => |str| try s.write(str),
            .array => |arr| {
                try s.beginArray();
                for (arr) |it| try writeValue(s, it);
                try s.endArray();
            },
            .object => |fields| {
                try s.beginObject();
                for (fields) |f| {
                    try s.objectField(f.name);
                    try writeValue(s, f.value);
                }
                try s.endObject();
            },
        }
    }
};

test "json serializer pretty-prints; unknown content type is skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v: Value = .{ .object = &.{
        .{ .name = "id", .value = .{ .int = 0 } },
        .{ .name = "name", .value = .{ .string = "string" } },
    } };

    var buf: std.Io.Writer.Allocating = .init(a);
    try std.testing.expect(try serialize("application/json", v, &buf.writer));
    const out = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\": \"string\"") != null);

    var buf2: std.Io.Writer.Allocating = .init(a);
    try std.testing.expect(!try serialize("text/plain", v, &buf2.writer));
}
