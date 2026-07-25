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

const Value = zmpl.Data.Value;

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn makeString(alloc: std.mem.Allocator, s: []const u8) !*Value {
    const v = try alloc.create(Value);
    v.* = .{ .string = .{ .value = s, .allocator = alloc } };
    return v;
}

/// Recursively serialize an arbitrary value into a zmpl `Value` tree for template rendering.
/// zmpl's own `zmplValue` already walks structs/slices/optionals/scalars, but it rejects three
/// things our http response types use: tagged unions (the `ApiResult` status union), error sets
/// (`ProblemDetails.type: anyerror`), and `void` (no-content arms). We intercept exactly those and
/// delegate everything else to zmpl.
pub fn toValue(value: anytype, alloc: std.mem.Allocator) !*Value {
    const T = @TypeOf(value);
    if (comptime isString(T)) return makeString(alloc, value);

    switch (@typeInfo(T)) {
        // Serialize the active arm and surface the tag so templates can branch on it. zmpl has no
        // enum value type, so the tag is the status name as a string (e.g. "ok", "bad_request").
        // Merged into the payload object when possible so `{.field}` access is unaffected;
        // non-object payloads are wrapped as `{tag, value}`.
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                const inner = try toValue(payload, alloc);
                const tag_val = try makeString(alloc, @tagName(tag));
                switch (inner.*) {
                    .object => {
                        try inner.put("tag", tag_val);
                        return inner;
                    },
                    else => {
                        const obj = try zmpl.Data.createObject(alloc);
                        try obj.put("tag", tag_val);
                        try obj.put("value", inner);
                        return obj;
                    },
                }
            },
        },
        .@"struct" => |s| {
            const obj = try zmpl.Data.createObject(alloc);
            inline for (s.fields) |f| {
                if (comptime f.type == type) continue;
                try obj.put(f.name, try toValue(@field(value, f.name), alloc));
            }
            return obj;
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                const arr = try zmpl.Data.createArray(alloc);
                for (value) |item| try arr.append(try toValue(item, alloc));
                return arr;
            },
            .one => return toValue(value.*, alloc),
            else => @compileError("toValue: unsupported pointer " ++ @typeName(T)),
        },
        .array => |a| {
            if (comptime a.child == u8) return makeString(alloc, try alloc.dupe(u8, &value));
            const arr = try zmpl.Data.createArray(alloc);
            for (value) |item| try arr.append(try toValue(item, alloc));
            return arr;
        },
        .optional => {
            if (value) |v| return toValue(v, alloc);
            return zmpl.Data._null(alloc);
        },
        .error_union => if (value) |v| return toValue(v, alloc) else |e| return e,
        .error_set => return makeString(alloc, @errorName(value)),
        .void => return zmpl.Data.createObject(alloc),
        // ints, floats, bools, enums, datetime — zmpl handles these directly.
        else => return zmpl.Data.zmplValue(value, alloc),
    }
}

comptime {
    _ = &toValue;
}
