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
