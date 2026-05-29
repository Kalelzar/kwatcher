const std = @import("std");

const signature = 0x64;

pub fn serialize(w: *std.io.Writer, data: anytype, comptime version: u8) !void {
    try w.writeByte(signature);
    try w.writeByte(version);
    try typedSerialize(w, data);
    try w.flush();
}

fn typedSerialize(
    w: *std.io.Writer,
    data: anytype,
) !void {
    const ti = @typeInfo(@TypeOf(data));
    switch (comptime ti) {
        .@"fn",
        .@"opaque",
        .@"anyframe",
        .frame,
        .void,
        .noreturn,
        .error_set,
        .error_union,
        .null,
        .undefined,
        .type,
        => @compileError("Unserializable"),
        .@"enum" => |e| {
            try w.writeInt(e.tag_type, data, .big);
        },
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                try typedSerialize(w, @field(data, field.name));
            }
        },
        .@"union" => |s| {
            if (comptime s.tag_type) |_| {
                typedSerialize(w, std.meta.activeTag(data));
            } else {
                @compileError(std.fmt.comptimePrint(
                    "Cannot serialize the plain enum {s} automatically.",
                    .{@typeName(@TypeOf(data))},
                ));
            }
            try typedSerialize(w, @field(data, @tagName(std.meta.activeTag(data))));
        },
        .array, .vector => |a| {
            comptime for (0..a.len) |i| {
                try typedSerialize(w, data[i]);
            };
        },
        .bool => |_| {
            try w.writeByte(if (data) 1 else 0);
        },
        .comptime_float => |_| {
            try w.writeSliceEndian(u8, &std.mem.toBytes(data), .big);
        },
        .float => |_| {
            try w.writeSliceEndian(u8, &std.mem.toBytes(data), .big);
        },
        .comptime_int => |_| {
            try w.writeInt(@TypeOf(data), data, .big);
        },
        .int => |_| {
            try w.writeInt(@TypeOf(data), data, .big);
        },
        .enum_literal => |_| {
            try typedSerialize(w, @tagName(data));
        },
        .optional => |_| {
            if (data) |v| {
                try w.writeByte(1);
                try typedSerialize(w, v);
            } else {
                try w.writeByte(0);
            }
        },
        .pointer => |p| {
            switch (p.size) {
                .c => @compileError("Cannot serialize a C pointer"),
                .one, .many => @compileError("Serializing pointers to one/many is not supported yet."),
                .slice => |_| {
                    try typedSerialize(w, data.len);
                    for (0..data.len) |i| {
                        try typedSerialize(w, data[i]);
                    }
                },
            }
        },
    }
}

pub fn deserialize(r: *std.io.Reader, Data: type, allocator: std.mem.Allocator, comptime version: u8) !Data {
    if (try r.takeByte() != signature) return error.BadSignature;
    if (try r.takeByte() != version) return error.BadVersion;

    return typedDeserialize(r, Data, allocator);
}

pub fn typedDeserialize(r: *std.io.Reader, Data: type, allocator: std.mem.Allocator) !Data {
    const ti = @typeInfo(Data);
    switch (comptime ti) {
        .@"fn",
        .@"opaque",
        .@"anyframe",
        .frame,
        .void,
        .noreturn,
        .error_set,
        .error_union,
        .null,
        .undefined,
        .type,
        => @compileError("Unserializable"),
        .@"enum" => |e| {
            return r.takeInt(e.tag_type, .big);
        },
        .@"struct" => |s| {
            var val: Data = undefined;
            inline for (s.fields) |field| {
                @field(val, field.name) = try typedDeserialize(
                    r,
                    field.type,
                    allocator,
                );
            }
            return val;
        },
        .@"union" => |s| {
            if (comptime s.tag_type) |_| {
                var val: Data = undefined;
                const e = try typedDeserialize(r, s.tag_type, allocator);
                @field(val, @tagName(e)) = try typedDeserialize(
                    r,
                    @FieldType(Data, @tagName(e)),
                    allocator,
                );
            } else {
                @compileError(std.fmt.comptimePrint(
                    "Cannot serialize the plain enum {s} automatically.",
                    .{@typeName(Data)},
                ));
            }
        },
        .array, .vector => |a| {
            var buf: Data = try allocator.alloc(a.child, a.len);
            comptime for (0..a.len) |i| {
                buf[i] = try typedDeserialize(r, a.child, allocator);
            };
            return buf;
        },
        .bool => |_| {
            const b = try r.takeByte();
            if (b == 0) return false else if (b == 1) return true else return error.Corrupt;
        },
        .comptime_float => |_| {
            const bytes = try r.take(@sizeOf(comptime_float));
            const ptr = std.mem.bytesAsValue(comptime_float, bytes);
            return ptr.*;
        },
        .float => |_| {
            const bytes = try r.take(@sizeOf(Data));
            const ptr = std.mem.bytesAsValue(Data, bytes);
            return ptr.*;
        },
        .comptime_int => |_| {
            return try r.takeInt(Data, .big);
        },
        .int => |_| {
            return try r.takeInt(Data, .big);
        },
        .enum_literal => |_| {
            return try typedDeserialize(r, []const u8, allocator);
        },
        .optional => |o| {
            const mark = try r.takeByte();
            if (mark == 0) {
                return null;
            } else if (mark == 1) {
                return try typedDeserialize(r, o.child, allocator);
            } else {
                return error.Corrupt;
            }
        },
        .pointer => |p| {
            switch (p.size) {
                .c => @compileError("Cannot serialize a C pointer"),
                .one, .many => @compileError("Serializing pointers to one/many is not supported yet."),
                .slice => |_| {
                    const len = try typedDeserialize(r, usize, allocator);
                    var buf = try allocator.alloc(p.child, len);
                    for (0..len) |i| {
                        buf[i] = try typedDeserialize(r, p.child, allocator);
                    }
                    return buf;
                },
            }
        },
    }
}
