const std = @import("std");
const klib = @import("klib");
const injector = @import("injector.zig");

pub fn Resolver(comptime Container: type) type {
    klib.meta.ensureStruct(Container);

    return struct {
        const Self = @This();

        pub fn resolve(inj: *injector.Injector, comptime path: []const u8, container: *Container) resolveAsErrorUnion(path) {
            if (comptime std.mem.indexOfScalar(u8, path, '.')) |idx| {
                const first = comptime path[0..idx];
                const rest = comptime path[1 + idx ..];

                if (comptime @hasField(Container, first)) {
                    return Resolver(@FieldType(Container, first)).resolve(inj, rest, &@field(container, first));
                } else if (comptime @hasDecl(Container, first)) {
                    const ti: std.builtin.Type = @typeInfo(@TypeOf(@field(Container, first)));
                    if (ti.@"fn".params.len > 0) {
                        const maybe_self = ti.@"fn".params[0];
                        if (maybe_self.type) |mself_type| {
                            const mself_ti: std.builtin.Type = @typeInfo(mself_type);
                            switch (mself_ti) {
                                .pointer => |p| {
                                    if (p.child == Container) {
                                        return inj.call_first(@field(Container, path), .{@constCast(container)});
                                    }
                                },
                                else => {
                                    if (mself_type == Container) {
                                        return inj.call_first(@field(Container, path), .{@constCast(container.*)});
                                    }
                                },
                            }
                        }
                    }
                    var value = try inj.call(@field(Container, first), .{});

                    return Resolver(@TypeOf(value)).resolve(inj, rest, &value);
                } else {
                    @compileLog(Container, first);
                    @compileError("No such field is available within struct.");
                }
            } else {
                if (comptime @hasField(Container, path)) {
                    return @field(container, path);
                } else if (comptime @hasDecl(Container, path)) {
                    const ti: std.builtin.Type = @typeInfo(@TypeOf(@field(Container, path)));
                    if (ti.@"fn".params.len > 0) {
                        const maybe_self = ti.@"fn".params[0];
                        if (maybe_self.type) |mself_type| {
                            const mself_ti: std.builtin.Type = @typeInfo(mself_type);
                            switch (mself_ti) {
                                .pointer => |p| {
                                    if (p.child == Container) {
                                        return try inj.call_first(@field(Container, path), .{@constCast(container)});
                                    }
                                },
                                else => {
                                    if (mself_type == Container) {
                                        return try inj.call_first(@field(Container, path), .{container.*});
                                    }
                                },
                            }
                        }
                    }
                    return try inj.call(@field(Container, path), .{});
                } else {
                    @compileLog(Container, path);
                    @compileError("No such field is available within struct.");
                }
            }
        }

        fn resolveAsErrorUnion(comptime path: []const u8) type {
            const R = resolveType(path);
            const ti: std.builtin.Type = @typeInfo(R);
            return switch (ti) {
                .error_union => R,
                else => @Type(.{
                    .error_union = .{ .error_set = anyerror, .payload = R },
                }),
            };
        }

        pub fn resolveType(comptime path: []const u8) type {
            if (std.mem.indexOfScalar(u8, path, '.')) |idx| {
                const first = path[0..idx];
                const rest = path[1 + idx ..];

                if (comptime @hasField(Container, first)) {
                    return Resolver(@FieldType(Container, first)).resolveType(rest);
                } else if (comptime @hasDecl(Container, first)) {
                    return Resolver(klib.meta.Return(@field(Container, first))).resolveType(rest);
                } else {
                    @compileLog(Container, first);
                    @compileError("No such field is available within struct.");
                }
            } else {
                if (comptime @hasField(Container, path)) {
                    return @FieldType(Container, path);
                } else if (comptime @hasDecl(Container, path)) {
                    return klib.meta.Return(@field(Container, path));
                } else {
                    @compileLog(Container, path);
                    @compileError("No such field is available within struct.");
                }
            }
        }
    };
}
