const std = @import("std");

// Check if a given type is a struct.
pub fn isStruct(comptime Type: type) bool {
    return switch (@typeInfo(Type)) {
        .@"struct" => true,
        else => false,
    };
}

pub fn ensureStruct(comptime Type: type) void {
    if (!isStruct(Type)) {
        @compileError("Only structs are supported");
    }
}

// Merge two structs into a single type.
// NOTE: This discards any declarations they have (fn, var, etc...)
pub fn MergeStructs(comptime Base: type, comptime Child: type) type {
    const base_info = @typeInfo(Base);
    const child_info = @typeInfo(Child);

    ensureStruct(Base);
    ensureStruct(Child);

    var fields: []const std.builtin.Type.StructField = base_info.@"struct".fields;

    fields = fields ++ child_info.@"struct".fields;

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

// Validates that a struct has the same fields as another.
pub fn overlaps(comptime Left: type, comptime Right: type) bool {
    ensureStruct(Left);
    ensureStruct(Right);
    const left_info = @typeInfo(Left);
    const right_info = @typeInfo(Right);
    const left_fields: []const std.builtin.Type.StructField = left_info.@"struct".fields;
    const right_fields: []const std.builtin.Type.StructField = right_info.@"struct".fields;

    inline for (left_fields) |left_field| {
        var found = false;
        const left_type = @typeInfo(left_field.type);
        inline for (right_fields) |right_field| {
            if (!std.mem.eql(u8, left_field.name, right_field.name)) continue;
            found = true;
            const right_type = @typeInfo(right_field.type);
            switch (left_type) {
                .@"struct" => {
                    // We need to verify that the inner structs also overlap.
                    // We do not compare types since we only care about structure.
                    if (!overlaps(left_field.type, right_field.type)) {
                        return false;
                    }
                },
                .optional => {
                    const InnerLeftType = left_type.optional.child;
                    switch (right_type) {
                        .optional => {
                            const InnerRightType = right_type.optional.child;
                            if (isStruct(InnerLeftType) and isStruct(InnerRightType)) {
                                if (!overlaps(InnerLeftType, InnerRightType)) {
                                    @compileError("Non-overlapping child for struct? and struct?");
                                    //return false;
                                }
                            } else {
                                if (InnerLeftType != InnerRightType) {
                                    @compileError("Differing types for type? and type?");
                                    //return false;
                                }
                            }
                        },
                        else => {
                            if (isStruct(InnerLeftType) and isStruct(right_field.type)) {
                                if (!overlaps(InnerLeftType, right_field.type)) {
                                    @compileError("Non-overlapping child for struct? and struct");
                                    //return false;
                                }
                            } else {
                                if (InnerLeftType != right_field.type) {
                                    @compileError("Differing types for type? and type");
                                }
                            }
                        },
                    }
                },
                else => {
                    switch (right_type) {
                        .optional => {
                            if (left_field.type != right_type.optional.child) {
                                @compileLog(left_field.type, right_type.optional.child);
                                @compileError("Differing types for type and type?");
                                //return false;
                            }
                        },
                        else => {
                            if (left_field.type != right_field.type) {
                                @compileLog(left_field.type, right_field.type);
                                @compileError("Differing types for type and type");
                                //return false;
                            }
                        },
                    }
                },
            }
        }
        if (!found) {
            return false;
        }
    }

    return true;
}

pub fn ensureStructure(comptime Left: type, comptime Right: type) void {
    if (!overlaps(Left, Right) or !overlaps(Right, Left)) {
        @compileError("Structs differ in structure");
    }
}

pub const ValidationError = error{
    Null,
    EmptyArray,
    EmptyPointer,
};

fn assertNotEmptyInternal(comptime field: std.builtin.Type.StructField, comptime Type: type, field_value: Type) ValidationError!void {
    switch (@typeInfo(Type)) {
        .optional => {
            if (field_value) |value| {
                const ValueType = @TypeOf(value);
                try assertNotEmptyInternal(field, ValueType, value);
            } else {
                return ValidationError.Null;
            }
        },
        .@"struct" => {
            try assertNotEmpty(Type, field_value);
        },
        .array => {
            if (field_value.len == 0) {
                return ValidationError.EmptyArray;
            }
            for (field_value) |value| {
                const ValueType = @TypeOf(value);
                try assertNotEmptyInternal(field, ValueType, value);
            }
        },
        .pointer => {
            if (field_value.len == 0) {
                return ValidationError.EmptyPointer;
            }
            for (field_value) |value| {
                const ValueType = @TypeOf(value);
                try assertNotEmptyInternal(field, ValueType, value);
            }
        },
        else => {},
    }
}

pub fn assertNotEmpty(comptime StructType: type, struct_value: StructType) ValidationError!void {
    const fields = @typeInfo(StructType).@"struct".fields;
    inline for (fields) |field| {
        const value = @field(struct_value, field.name);
        try assertNotEmptyInternal(field, field.type, value);
    }
}

fn assign(
    comptime Target: type,
    comptime ValueType: type,
    comptime field: std.builtin.Type.StructField,
    value_maybe_optional: ValueType,
    target: *Target,
) void {
    const FieldType = @typeInfo(ValueType);
    switch (FieldType) {
        .optional => {
            if (value_maybe_optional) |value| {
                assign(Target, FieldType.optional.child, field, value, target);
            }
        },
        .@"struct" => {
            var child_target = @field(target, field.name);
            const ChildTarget = @TypeOf(child_target);
            @field(target, field.name) = copyTo(field.type, ChildTarget, value_maybe_optional, &child_target).*;
        },
        else => {
            @field(target, field.name) = value_maybe_optional;
        },
    }
}

pub fn copyTo(comptime Source: type, comptime Target: type, source: Source, target: *Target) *Target {
    const fields = @typeInfo(Source).@"struct".fields;

    inline for (fields) |field| {
        if (comptime @hasField(Target, field.name)) {
            const value_maybe_optional = @field(source, field.name);
            assign(
                Target,
                field.type,
                field,
                value_maybe_optional,
                target,
            );
        }
    }

    return target;
}

pub fn copy(comptime Source: type, comptime Target: type, source: Source) Target {
    var target = std.mem.zeroInit(Target, .{});

    return copyTo(Source, Target, source, &target).*;
}

pub fn merge(comptime Base: type, comptime Child: type, comptime ResultT: type, base: Base, child: Child) ResultT {
    var result = std.mem.zeroInit(ResultT, .{});
    const result1 = copyTo(Base, ResultT, base, &result);
    const result2 = copyTo(Child, ResultT, child, result1);
    return result2.*;
}

// As per: https://github.com/ziglang/zig/issues/19858#issuecomment-2369861301
pub const TypeId = *const struct {
    _: u8 = undefined,
};

pub inline fn typeId(comptime T: type) TypeId {
    const TCache = &struct {
        comptime {
            _ = T;
        }
        var id: std.meta.Child(TypeId) = .{};
    };
    return &TCache.id;
}

pub fn isValuePointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .one,
        else => false,
    };
}

pub fn Return(comptime fun: anytype) type {
    return switch (@typeInfo(@TypeOf(fun))) {
        .@"fn" => |f| f.return_type.?,
        else => @compileError("Expected a function, got " ++ @typeName(@TypeOf(fun))),
    };
}

pub fn Result(comptime fun: anytype) type {
    const R = Return(fun);

    return switch (@typeInfo(R)) {
        .error_union => |r| r.payload,
        else => R,
    };
}

pub fn HoldType(comptime Type: type) *const fn () type {
    const Internal = struct {
        fn resolve() type {
            return Type;
        }
    };

    return &Internal.resolve;
}
