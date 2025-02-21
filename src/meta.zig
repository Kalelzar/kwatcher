const std = @import("std");

pub fn MergeStructs(comptime Base: type, comptime Child: type) type {
    const base_info = @typeInfo(Base);

    var fields: []const std.builtin.Type.StructField = base_info.Struct.fields;

    const child_info = @typeInfo(Child);
    fields = fields ++ child_info.Struct.fields;

    return @Type(.{
        .Struct = .{
            .layout = .auto,
            .fields = fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub fn copyTo(comptime Source: type, comptime Target: type, source: Source, target: *Target) *Target {
    const fields = @typeInfo(Source).Struct.fields;

    inline for (fields) |field| {
        const valueOpt = @field(source, field.name);
        const fieldType = @typeInfo(field.type);
        switch (fieldType) {
            .Optional => {
                if (valueOpt) |value| {
                    @field(target, field.name) = value;
                }
            },
            .Array => {},
            .Struct => {
                var childTarget = @field(target, field.name);
                const ChildTarget = @TypeOf(childTarget);
                @field(target, field.name) = copyTo(field.type, ChildTarget, @field(source, field.name), &childTarget).*;
            },
            else => {
                @field(target, field.name) = valueOpt;
            },
        }
    }

    return target;
}

pub fn copy(comptime Source: type, comptime Target: type, source: Source) Target {
    var target = std.mem.zeroInit(Target, .{});

    return copyTo(Source, Target, source, &target).*;
}

pub fn merge(comptime Base: type, comptime Child: type, comptime Result: type, base: Base, child: Child) Result {
    var result = std.mem.zeroInit(Result, .{});
    const result1 = copyTo(Base, Result, base, &result);
    const result2 = copyTo(Child, Result, child, result1);
    return result2.*;
}
