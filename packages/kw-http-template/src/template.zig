const std = @import("std");
const zmpl = @import("zmpl");
const http = @import("kw-http");
const value = @import("value.zig");

/// A response formatter that renders `value` through the zmpl template named `template_name`
/// within `prefix` (the source namespace). `WithTemplates` resolves the prefix/name from the
/// route's source + id; the prefixed lookup keeps each template source separate. `ContentType`
/// is `text/html`, so this slots into `http.data.Many` alongside JSON formatters.
pub fn Template(comptime prefix: []const u8, comptime T: type, comptime template_name: []const u8) type {
    const template = zmpl.findPrefixed(prefix, template_name) orelse
        @compileError("Template '" ++ prefix ++ ":" ++ template_name ++ "' not found.");
    return struct {
        value: T,
        pub const ContentType = "text/html";

        pub fn write(self: *const @This(), writer: *std.Io.Writer, res: *http.Response) !void {
            res.content_type = .HTML;

            var data = zmpl.Data.init(res.arena);
            defer data.deinit();

            data.value = try value.toValue(self.value, data.allocator);

            const tmpl = try template.render(&data, null, null, &.{}, .{});
            try writer.writeAll(tmpl);
        }
    };
}

comptime {
    _ = &Template;
}
