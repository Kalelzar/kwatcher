const std = @import("std");

pub fn reverse(comptime r: []const type) []const type {
    const o = comptime blk: {
        var o: [r.len]type = undefined;
        for (0..r.len) |ri| {
            const i = r.len - ri - 1;
            o[i] = r[ri];
        }
        break :blk o;
    };
    return &o;
}

pub fn flatten(r: anytype) []const type {
    const T = @TypeOf(r);
    if (comptime T == []type) {
        return r;
    }
    if (comptime T == []const type) {
        return r;
    }
    if (comptime T == type) {
        return &.{r};
    }
    const t = comptime blk: {
        var t: []const type = &.{};
        for (r) |rr| {
            const f: []const type = flatten(rr);
            t = t ++ f;
        }

        break :blk t;
    };

    return t;
}

/// Shrink an int down to the smallest unsigned integer that it will fit in.
pub fn UIntShrink(comptime i: anytype) type {
    comptime {
        const leading_zeroes = @clz(i);

        return std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(i)) - leading_zeroes);
    }
}

pub inline fn shrinkInt(comptime i: anytype) UIntShrink(i) {
    return @intCast(i);
}

/// Shrink the backing type of an enum down.
/// NOTE: This will discard any decls on the enum.
pub inline fn shrinkEnum(comptime e: type, comptime max: anytype) type {
    const ti = @typeInfo(e);
    switch (ti) {
        .@"enum" => |et| {
            @Type(.{ .@"enum" = .{
                .decls = .{},
                .fields = et.fields,
                .is_exhaustive = et.is_exhaustive,
                .tag_type = UIntShrink(max),
            } });
        },
        else => @compileError("Only enums can have their underlying type shrunk."),
    }
}

pub fn tagOf(comptime Enum: type) type {
    const ti = @typeInfo(Enum);
    switch (ti) {
        .@"enum" => |e| {
            return e.tag_type;
        },
        else => @compileError("Cannot retrieve the type of " ++ @typeName(Enum) ++ ". Not an enum."),
    }
}

pub fn lastOf(comptime Enum: type) tagOf(Enum) {
    const fields = @typeInfo(Enum).@"enum".fields;
    if (fields.len == 0) return 0;
    var max: tagOf(Enum) = std.math.minInt(tagOf(Enum));
    inline for (fields) |f| {
        max = @max(max, f.value);
    }
    return max;
}

pub fn count(comptime Enum: type) tagOf(Enum) {
    const fields = @typeInfo(Enum).@"enum".fields;
    return fields.len;
}

pub fn firstOf(comptime Enum: type) tagOf(Enum) {
    const fields = @typeInfo(Enum).@"enum".fields;
    if (fields.len == 0) return 0;
    var min: tagOf(Enum) = std.math.maxInt(tagOf(Enum));
    inline for (fields) |f| {
        min = @min(min, f.value);
    }
    return min;
}

pub fn EnumLiteral(comptime string: []const u8) type {
    const field = std.builtin.Type.EnumField{
        .name = @ptrCast(string ++ .{0}),
        .value = 0,
    };

    return @Type(.{
        .@"enum" = .{
            .decls = &.{},
            .fields = &.{field},
            .is_exhaustive = true,
            .tag_type = u1,
        },
    });
}

pub fn enumLiteral(comptime string: []const u8) EnumLiteral(string) {
    return @enumFromInt(0);
}

pub fn hasKey(comptime E: type, comptime v: anytype) bool {
    const eTi = @typeInfo(E);
    const vTi = @typeInfo(@TypeOf(v));

    if (comptime vTi != .enum_literal and vTi != .@"enum") {
        @compileError("A key value needs to be an enum literal, got " ++ @tagName(vTi));
    }

    switch (eTi) {
        .@"enum" => |e| {
            const vname = @tagName(v);
            inline for (e.fields) |f| {
                if (std.mem.eql(u8, f.name, vname)) {
                    return true;
                }
            }
            return false;
        },
        inline else => |e| @compileError("You cannot check key existance on a '" ++ @tagName(std.meta.activeTag(e)) ++ "'. Only enums are supported."),
    }
}

pub fn arrayFromEnum(comptime E: type) []const E {
    const ti = @typeInfo(E);
    switch (ti) {
        inline .@"enum" => |e| {
            const array = blk: {
                var array: [e.fields.len]E = undefined;
                for (e.fields, 0..) |f, i| {
                    array[i] = @enumFromInt(f.value);
                }
                break :blk array;
            };
            return &array;
        },
        else => @compileError("FIXME: Not an enum."),
    }
}

pub fn Bare(comptime T: type) type {
    const ti = @typeInfo(T);
    return switch (ti) {
        .@"anyframe",
        .@"enum",
        .@"fn",
        .@"opaque",
        .@"struct",
        .@"union",
        .array,
        .bool,
        .comptime_float,
        .comptime_int,
        .enum_literal,
        .error_set,
        .float,
        .frame,
        .int,
        .noreturn,
        .null,
        .type,
        .undefined,
        .vector,
        .void,
        => T,
        .error_union => |eu| Bare(eu.payload),
        .optional => |opt| Bare(opt.payload),
        .pointer => |ptr| Bare(ptr.child),
    };
}

// Ref all decls
comptime {
    std.testing.refAllDeclsRecursive(@This());
}
