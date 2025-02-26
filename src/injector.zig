// This is largely inspired by tokamak's implementation
// @see https://github.com/cztomsik/tokamak/blob/main/src/injector.zig

const std = @import("std");

const meta = @import("meta.zig");
const schema = @import("schema.zig");

const Context = *anyopaque;
const Resolver = *const fn (Context, meta.TypeId) ?*anyopaque;
const FactoryResolver = *const fn (meta.TypeId) ?*const fn (*Injector) anyerror!*anyopaque;

pub const Injector = struct {
    context: Context,
    resolver: Resolver,
    resolver_factory: FactoryResolver,
    parent: ?*Injector = null,

    pub const empty: Injector = .{ .c_ontext = undefined, .resolver = resolveNull };

    pub fn init(context: anytype, parent: ?*Injector) Injector {
        if (comptime !meta.isValuePointer(@TypeOf(context))) {
            @compileError("Expected pointer to a context, got " ++ @typeName(@TypeOf(context)));
        }

        const InternalResolver = struct {
            const ContextPtrType = @TypeOf(context);
            const ContextType = std.meta.Child(ContextPtrType);

            fn resolve(type_erased_context: Context, type_id: meta.TypeId) ?*anyopaque {
                var typed_context: ContextPtrType = @constCast(@ptrCast(@alignCast(type_erased_context)));

                inline for (std.meta.fields(ContextType)) |f| {
                    // What do we do if a context has two fields of the same type?
                    // Right now we just take the first one that matches but maybe
                    // it might be worth it to support some keyed resolution mechanism?
                    // Is it even possible with just the type id? Still...
                    // TODO: Allow for the resolution of multiple types via a key.
                    const p = if (comptime meta.isValuePointer(f.type))
                        @field(typed_context, f.name)
                    else
                        &@field(typed_context, f.name);

                    const FieldType = @TypeOf(p);
                    if (type_id == meta.typeId(FieldType)) {
                        std.debug.assert(@intFromPtr(p) != 0xaaaaaaaaaaaaaaaa);
                        return @ptrCast(@constCast(p));
                    }
                }

                if (type_id == meta.typeId(ContextPtrType)) {
                    return typed_context;
                }

                return null;
            }

            fn resolveFactory(type_id: meta.TypeId) ?*const fn (*Injector) anyerror!*anyopaque {
                inline for (comptime std.meta.declarations(ContextType)) |d| {
                    const fun = @field(ContextType, d.name);
                    // std.log.debug("Tried factory for {}", .{meta.Result(fun)});
                    if (@typeInfo(@TypeOf(fun)) != .@"fn") continue;

                    const FieldType = if (comptime meta.isValuePointer(meta.Result(fun))) meta.Result(fun) else *const meta.Result(fun);

                    if (meta.typeId(FieldType) == type_id) {
                        const Internal = struct {
                            fn handle(inj: *Injector) !*anyopaque {
                                var args: std.meta.ArgsTuple(@TypeOf(fun)) = undefined;
                                const fields = std.meta.fields(std.meta.ArgsTuple(@TypeOf(fun)));
                                const n_deps = comptime fields.len;

                                inline for (0..n_deps) |i| {
                                    args[i] = try inj.require(@TypeOf(args[i]));
                                }

                                const result = @call(.auto, fun, args);
                                switch (comptime @typeInfo(meta.Return(fun))) {
                                    .error_union => {
                                        _ = try result;
                                    },
                                    .pointer => {
                                        return @ptrCast(@constCast(result));
                                    },
                                    else => {},
                                }
                                return @ptrCast(@constCast(&result));
                            }
                        };
                        return &Internal.handle;
                    }
                }

                return null;
            }
        };

        return .{
            .context = @constCast(@ptrCast(context)),
            .resolver = &InternalResolver.resolve,
            .resolver_factory = &InternalResolver.resolveFactory,
            .parent = parent,
        };
    }

    pub fn require(self: *Injector, comptime T: type) !T {
        return try self.get(T) orelse {
            std.log.debug("Missing dependency: {s}", .{@typeName(T)});
            return error.MissingDependency;
        };
    }

    pub fn get(self: *Injector, comptime T: type) !?T {
        if (comptime T == Injector) {
            return self;
        }

        if (comptime !meta.isValuePointer(T)) {
            return if (try self.get(*const T)) |p| p.* else null;
        }

        if (self.resolver(self.context, meta.typeId(T))) |ptr| {
            return @ptrCast(@constCast(@alignCast(ptr)));
        }

        if (comptime @typeInfo(T).pointer.is_const) {
            if (self.resolver(self.context, meta.typeId(*@typeInfo(T).pointer.child))) |ptr| {
                return @ptrCast(@constCast(@alignCast(ptr)));
            }
        }
        if (self.resolver_factory(meta.typeId(T))) |factory| {
            return @ptrCast(@constCast(@alignCast(try factory(self))));
        }

        return if (self.parent) |p| try p.get(T) else null;
    }

    pub fn call(self: Injector, comptime fun: anytype, extra_args: anytype) anyerror!meta.Result(fun) {
        if (comptime @typeInfo(@TypeOf(extra_args)) != .@"struct") {
            @compileError("Expected a tuple of arguments");
        }

        const params = @typeInfo(@TypeOf(fun)).@"fn".params;
        const extra_start = params.len - extra_args.len;

        const types = comptime brk: {
            var types: [params.len]type = undefined;
            for (0..extra_start) |i| types[i] = params[i].type orelse @compileError("reached anytype");
            for (extra_start..params.len, 0..) |i, j| types[i] = @TypeOf(extra_args[j]);
            break :brk &types;
        };

        var args: std.meta.Tuple(types) = undefined;
        inline for (0..args.len) |i| args[i] = if (i < extra_start) try self.get(@TypeOf(args[i])) else extra_args[i - extra_start];

        return @call(.auto, fun, args);
    }
};

fn resolveNull(_: Context, _: meta.TypeId) ?*anyopaque {
    return null;
}
