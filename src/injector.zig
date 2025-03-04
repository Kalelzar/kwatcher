// This is largely inspired by tokamak's implementation
// @see https://github.com/cztomsik/tokamak/blob/main/src/injector.zig

const std = @import("std");

const meta = @import("meta.zig");
const mem = @import("mem.zig");
const schema = @import("schema.zig");

const Context = *anyopaque;
const Resolver = *const fn (Context, meta.TypeId) ?*anyopaque;
const FactoryResolver = *const fn (meta.TypeId) ?*const fn (*Injector) anyerror!*anyopaque;
const DisposeFn = *const fn (Context) void;

/// A dependency injector with support for parent injectors.
/// It can dynamically provide the contents of a struct (`Context')
/// to any function called with it, supporting both plain properties
/// and factory functions.
pub const Injector = struct {
    context: Context,
    resolver: Resolver,
    resolver_factory: FactoryResolver,
    parent: ?*Injector = null,
    dispose: ?DisposeFn,

    pub const empty: Injector = .{ .context = undefined, .resolver = resolveNull };

    pub fn init(context: anytype, parent: ?*Injector) !Injector {
        if (comptime !meta.isValuePointer(@TypeOf(context))) {
            @compileError("Expected pointer to a context, got " ++ @typeName(@TypeOf(context)));
        }

        var dispose: ?DisposeFn = null;
        const ContextPtrType = @TypeOf(context);
        const ContextType = std.meta.Child(ContextPtrType);

        if (comptime @hasDecl(ContextType, "deconstruct")) blk: {
            const fun = @field(ContextType, "deconstruct");
            if (@typeInfo(@TypeOf(fun)) != .@"fn") break :blk;

            const fields = std.meta.fields(std.meta.ArgsTuple(@TypeOf(fun)));
            const n_deps = comptime fields.len;
            if (n_deps < 1) {
                @compileError("Deconstruct must accept self. Why else would you need it?");
            }

            if (n_deps > 1) {
                @compileError("Deconstruct does not support injection.");
            }

            const F = struct {
                fn dispose_handler(ptr: *anyopaque) void {
                    const ctx: *ContextType = @constCast(@ptrCast(@alignCast(ptr)));
                    @field(ContextType, "deconstruct")(ctx);
                }
            };

            switch (comptime @typeInfo(meta.Return(fun))) {
                .error_union => @compileError("Doconstruct must not return an error."),
                else => dispose = F.dispose_handler,
            }
        }

        if (parent) |p| blk: {
            // If we have a parent and a construct function on the context we might as well try to call it by injecting it's dependencies via
            // our parent.
            // This still lets us init contexts manually as users but we open the door to allow the framework to handle some of it for us
            // instead.
            if (comptime @hasDecl(ContextType, "construct")) {
                const fun = @field(ContextType, "construct");
                if (@typeInfo(@TypeOf(fun)) != .@"fn") break :blk;
                var args: std.meta.ArgsTuple(@TypeOf(fun)) = undefined;
                const fields = std.meta.fields(std.meta.ArgsTuple(@TypeOf(fun)));
                const n_deps = comptime fields.len;
                if (n_deps < 1) {
                    @compileError("Construct must accept self. Why else would you need it?");
                }
                args[0] = context;
                inline for (1..n_deps) |i| {
                    args[i] = try p.require(@TypeOf(args[i]));
                }

                switch (comptime @typeInfo(meta.Return(fun))) {
                    .error_union => try @call(.auto, fun, args),
                    else => @call(.auto, fun, args),
                }
            }
        }

        const InternalResolver = struct {
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
                    if (@typeInfo(@TypeOf(fun)) != .@"fn") continue;

                    const FieldType = if (comptime meta.isValuePointer(meta.Result(fun))) meta.Result(fun) else *const meta.Result(fun);

                    if (meta.typeId(FieldType) == type_id) {
                        const Internal = struct {
                            fn handle(inj: *Injector) !*anyopaque {
                                var args: std.meta.ArgsTuple(@TypeOf(fun)) = undefined;
                                const fields = std.meta.fields(std.meta.ArgsTuple(@TypeOf(fun)));
                                const n_deps = comptime fields.len;
                                var arena = try inj.require(mem.InternalArena);
                                const alloc = arena.allocator();
                                inline for (0..n_deps) |i| {
                                    args[i] = try inj.require(@TypeOf(args[i]));
                                }
                                switch (comptime @typeInfo(meta.Result(fun))) {
                                    .pointer => {
                                        if (comptime meta.canBeError(fun)) {
                                            const result = try @call(.auto, fun, args);
                                            return @ptrCast(@constCast(result));
                                        } else {
                                            const result = @call(.auto, fun, args);
                                            return @ptrCast(@constCast(result));
                                        }
                                    },
                                    else => {
                                        const result = try alloc.create(meta.Result(fun));
                                        if (comptime meta.canBeError(fun)) {
                                            result.* = try @call(.auto, fun, args);
                                        } else {
                                            result.* = @call(.auto, fun, args);
                                        }
                                        return @ptrCast(@constCast(result));
                                    },
                                }
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
            .dispose = dispose,
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

    /// Attempt to destroy the enclosed dependency context.
    /// You should consider the injector effectively invalidated after this is called
    /// unless you are 110% sure the dependency context doesn't support destruction.
    /// And even then - please don't... unless you really have to.
    /// This will check for the existance of a `deconstruct' method on the context instance.
    pub fn maybeDeconstruct(self: *Injector) void {
        if (self.dispose) |destructor| {
            const Args = std.meta.Tuple(&.{*anyopaque});
            const args = Args{self.context};
            @call(.auto, destructor, args);
        }
    }
};

fn resolveNull(_: Context, _: meta.TypeId) ?*anyopaque {
    return null;
}
