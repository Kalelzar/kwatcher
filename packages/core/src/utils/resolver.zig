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
const klib = @import("klib");

const dep = @import("../dep.zig");

pub fn Resolver(comptime Container: type) type {
    klib.meta.ensureStruct(Container);

    return struct {
        const Self = @This();

        // FIXME: This should check if the path can fail and conditionally return an error union
        // instead of forcing this to be always fallable.
        pub fn resolveRef(inj: *dep.DepCtx, comptime path: []const u8, container: *Container) resolveRefAsErrorUnion(path) {
            if (comptime std.mem.indexOfScalar(u8, path, '.')) |idx| {
                const first = comptime path[0..idx];
                const rest = comptime path[1 + idx ..];

                if (comptime @hasField(Container, first)) {
                    return Resolver(@FieldType(Container, first)).resolveRef(inj, rest, &@field(container, first));
                } else if (comptime @hasDecl(Container, first)) {
                    const ti: std.builtin.Type = @typeInfo(@TypeOf(@field(Container, first)));
                    if (ti.@"fn".params.len > 0) {
                        //FIXME: None of this looks correct. Check it.
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
                                        return inj.call_first(@field(Container, path), .{container.*});
                                    }
                                },
                            }
                        }
                    }
                    var value = try inj.call(@field(Container, first), .{});

                    return Resolver(@TypeOf(value)).resolveRef(inj, rest, &value);
                } else {
                    @compileError(std.fmt.comptimePrint("'{s}' is not a valid field in '{}'.", .{ first, Container }));
                }
            } else {
                if (comptime @hasField(Container, path)) {
                    if (comptime klib.meta.isValuePointer(@FieldType(Container, path))) {
                        return @field(container, path);
                    } else {
                        return &@field(container, path);
                    }
                } else if (comptime @hasDecl(Container, path)) {
                    const ti: std.builtin.Type = @typeInfo(@TypeOf(@field(Container, path)));
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
                                        return inj.call_first(@field(Container, path), .{container.*});
                                    }
                                },
                            }
                        }
                    }
                    if (comptime !klib.meta.isValuePointer(klib.meta.Return(@field(Container, path)))) {
                        @compileError("Cannot take a mutable reference to a non-pointer result type.");
                    }
                    return inj.call_first(@field(Container, path), .{});
                } else {
                    @compileError(std.fmt.comptimePrint("'{s}' is not a valid field in '{}'.", .{ path, Container }));
                }
            }
        }

        pub fn resolve(inj: *dep.DepCtx, comptime path: []const u8, container: *Container) resolveAsErrorUnion(path) {
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
                                        return inj.call_first(@field(Container, path), .{container.*});
                                    }
                                },
                            }
                        }
                    }
                    var value = try inj.call(@field(Container, first), .{});

                    return Resolver(@TypeOf(value)).resolve(inj, rest, &value);
                } else {
                    @compileError(std.fmt.comptimePrint("'{s}' is not a valid field in '{}'.", .{ first, Container }));
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
                                        return inj.call_first(@field(Container, path), .{@constCast(container)});
                                    }
                                },
                                else => {
                                    if (mself_type == Container) {
                                        return inj.call_first(@field(Container, path), .{container.*});
                                    }
                                },
                            }
                        }
                    }
                    return inj.call_first(@field(Container, path), .{});
                } else {
                    @compileError(std.fmt.comptimePrint("'{s}' is not a valid field in '{}'.", .{ path, Container }));
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

        fn resolveRefAsErrorUnion(comptime path: []const u8) type {
            const R = resolveType(path);
            const ti: std.builtin.Type = @typeInfo(R);
            const T = if (comptime klib.meta.isValuePointer(R)) R else *R;
            return switch (ti) {
                .error_union => R,
                else => @Type(.{
                    .error_union = .{ .error_set = anyerror, .payload = T },
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
                    @compileError(std.fmt.comptimePrint("'{s}' is not a valid field in '{}'.", .{ first, Container }));
                }
            } else {
                if (comptime @hasField(Container, path)) {
                    return @FieldType(Container, path);
                } else if (comptime @hasDecl(Container, path)) {
                    return klib.meta.Return(@field(Container, path));
                } else {
                    @compileError(std.fmt.comptimePrint("'{s}' is not a valid field in '{}'.", .{ path, Container }));
                }
            }
        }

        pub inline fn specifier(comptime path: []const u8) []const u8 {
            const T = resolveType(path);
            const ti: std.builtin.Type = @typeInfo(T);
            return switch (comptime ti) {
                .bool, .@"enum", .error_set, .enum_literal => "{}",
                .int, .float, .comptime_float, .comptime_int => "{d}",
                .array => |p| {
                    if (comptime p.child == u8) {
                        return "{s}";
                    } else {
                        @compileError(std.fmt.comptimePrint(
                            "The type '{}' of '{s}' is not formattable.",
                            .{
                                T,
                                path,
                            },
                        ));
                    }
                },
                .pointer => |p| {
                    if (comptime p.child == u8) {
                        return "{s}";
                    } else {
                        @compileError(std.fmt.comptimePrint(
                            "The type '{}' of '{s}' is not formattable.",
                            .{
                                T,
                                path,
                            },
                        ));
                    }
                },
                else => @compileError(std.fmt.comptimePrint(
                    "The type '{}' of '{s}' is not formattable.",
                    .{
                        T,
                        path,
                    },
                )),
            };
        }
    };
}

// Ref all decls — resolve/resolveRef are path-generic and need a *DepCtx at
// runtime (exercised via the template machinery); resolveType/specifier are
// callable directly.
comptime {
    const C = struct { x: u8, name: []const u8 };
    const R = Resolver(C);
    std.testing.refAllDeclsRecursive(R);
    _ = R.resolveType("x");
    _ = R.specifier("x");
    _ = R.specifier("name");
}
