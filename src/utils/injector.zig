//! This is largely inspired by tokamak's implementation
//! @see https://github.com/cztomsik/tokamak/blob/main/src/injector.zig
//! The dependency injector here supports two types of injection
//! Via plain properties:
//! ```
//! context {
//!   value: *Value
//! }
//! injector.require(*Value);
//! ```
//! Or via factory functions:
//! ```
//! context {
//! timeout_s: Distinct("timeout", u64) = .{.value = 500},
//! pub fn timeControlFactor(timeout: Distinct("timeout", u64)) TimeControl {
//!   return .{ .timeout = timeout.value, .behaviour = .fatal };
//! }
//! pub fn request(timeControl: TimeControl, httpClient: HttpClient) !Response {
//!   try httpClient.get("/api/v1/request", .{.timeControl = timeControl});
//! }
//! injector.require(Response);
//! ```
//! Plain properties are directly available in the context struct
//! and must be initialized before being passed to the context
//! manually or via init AND/OR may be fully or partially contructed automatically by the injector
//! IF passed together with a parent injector and the context has a `construct` function that will
//! have it's dependencies injected from the parent.
//! If the context has a `deconstruct` it will be called automatically on injector deinit.
//!
//! Factories are a way for a property to either be lazily initialized until requested
//! or to have it's value depend on another value(s) in the same/parent contexts
//! or to implicitly initialize other properties.
//! Factories are called by injecting their parameters from the context and its parents, transiently calling and injecting
//! other factories if needed.
//! For properties that need to be initialized only once, caching them as optional plain properties is a common pattern.

const std = @import("std");

const klib = @import("klib");
const meta = klib.meta;

const mem = @import("../mem.zig");

/// A type alias for a context
const Context = *anyopaque;

/// The type of a resolver function
const Resolver = *const fn (Context, meta.TypeId) ?*anyopaque;
/// The type of a factory resolver function
const FactoryResolver = *const fn (meta.TypeId) ?*const fn (*Injector) anyerror!*anyopaque;
/// The type oof the dispose function.
const DisposeFn = *const fn (Context) void;

/// A dependency injector with support for parent injectors.
/// It can dynamically provide the contents of a struct (`Context')
/// to any function called with it, supporting both plain properties
/// and factory functions.
pub const Injector = struct {
    /// The context from which to inject dependencies
    context: Context,
    /// The resolver function
    resolver: Resolver,
    /// The factory resolver function
    resolver_factory: FactoryResolver,
    /// The parent of this injector in which to look up dependencies if they aren't in the context.
    parent: ?*Injector = null,
    /// The dispose function
    dispose: ?DisposeFn,

    /// Initialize a new injector with a context and optionally a parent
    /// The context must be passed as a pointer!
    pub fn init(context: anytype, parent: ?*Injector) !Injector {
        if (comptime !meta.isValuePointer(@TypeOf(context))) {
            @compileError("Expected pointer to a context, got " ++ @typeName(@TypeOf(context)));
        }

        var dispose: ?DisposeFn = null;
        const ContextPtrType = @TypeOf(context);
        const ContextType = std.meta.Child(ContextPtrType);

        // Check for the existance of a deconstruct function.
        // A deconstruct function must only accept a single parameter -> the context.
        // and it cannot return an error union.
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
                    const ctx: *ContextType = @ptrCast(@alignCast(@constCast(ptr)));
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

        // The internal resolver functions used by the injector.
        const InternalResolver = struct {
            /// Resolve a plain property from a context via a type id.
            /// The algorithm is as follows:
            /// 1. For every field of the context:
            ///   - Take the value of the field (or a pointer to it if it isn't already a pointer).
            ///   - If the type id of the field matches the requested type id: Return it
            ///     Otherwise continue
            /// 2. If no field was a match
            ///   - Check if the requested type was the context itself, and if it is return that.
            /// 3. If no value was returned by this point, the context does not have it. Return null.
            fn resolve(type_erased_context: Context, type_id: meta.TypeId) ?*anyopaque {
                var typed_context: ContextPtrType = @ptrCast(@alignCast(@constCast(type_erased_context)));

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

            /// Resolve a property via a factory.
            /// The algorithm is as follows:
            /// 1. For every public function declaration:
            ///  - Get the return type of the function (or a const pointer to it if it's not already a pointer.)
            ///    NOTE: If the return type is not a pointer the factory will expect to find an allocator
            ///    in the injector when the fatory is called.
            ///    It will look for the following allocators in the given order:
            ///    - an `InternalArena`
            ///    - std.heap.ArenaAllocator
            ///    - std.mem.Allocator
            ///    It is the responsibility of the caller to ensure the memory is freed as is appropriate.
            ///  - If it matches the function we found return a function that can be used to call the factory
            ///    with an injector to return the value.
            /// 2. If no function matched, return null.
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
                                const alloc = blk: {
                                    var internal_arena = try inj.get(*mem.InternalArena);
                                    if (internal_arena) |_| {
                                        break :blk internal_arena.?.allocator();
                                    }
                                    var arena = try inj.get(*std.heap.ArenaAllocator);
                                    if (arena) |_| {
                                        break :blk arena.?.allocator();
                                    }

                                    const alloc = try inj.get(std.mem.Allocator) orelse return error.MissingFactoryAllocator;
                                    break :blk alloc;
                                };
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
            .context = @ptrCast(@constCast(context)),
            .resolver = &InternalResolver.resolve,
            .resolver_factory = &InternalResolver.resolveFactory,
            .dispose = dispose,
            .parent = parent,
        };
    }

    /// Require a dependency of type `T`. Will return an error if a dependency is missing or a factory returns an error.
    pub fn require(self: *Injector, comptime T: type) !T {
        return try self.get(T) orelse {
            std.log.debug("Missing dependency: {s}", .{@typeName(T)});
            return error.MissingDependency;
        };
    }

    /// Optionally require a dependency of type `T`. Will return an error if a factory returns an error.
    /// Returns null of the type wasn't found.
    /// This follows the following algorithm:
    /// 1. If we are requesting an `Injector`, return the current instance.
    /// 2. If we are NOT requesting a pointer: First try to inject a const pointer to the type instead.
    ///    (Go to 1. as `*const T`)
    /// 3. Try to resolve it type as a plain property
    /// 4. If `T` is a const pointer `*const U`: Try to resolve a plain property of type `U` instead.
    /// 5. If a factory exists for `T` return the result of calling the factory with the current injector.
    /// 6. Else try to resolve via the parent if any or return null if no parent exists.
    pub fn get(self: *Injector, comptime T: type) !?T {
        if (comptime T == *Injector) {
            return self;
        }

        if (comptime !meta.isValuePointer(T)) {
            return if (try self.get(*const T)) |p| p.* else null;
        }

        if (self.resolver(self.context, meta.typeId(T))) |ptr| {
            return @ptrCast(@alignCast(@constCast(ptr)));
        }

        if (comptime @typeInfo(T).pointer.is_const) {
            if (self.resolver(self.context, meta.typeId(*@typeInfo(T).pointer.child))) |ptr| {
                return @ptrCast(@alignCast(@constCast(ptr)));
            }
        }
        if (self.resolver_factory(meta.typeId(T))) |factory| {
            return @ptrCast(@alignCast(@constCast(try factory(self))));
        }

        return if (self.parent) |p| try p.get(T) else null;
    }

    test "expect `get` to return the injector if requested" {
        const TestContext = struct {};
        var value: TestContext = .{};
        var inj = try Injector.init(&value, null);
        const maybe_inj = try inj.get(*Injector);
        try std.testing.expect(maybe_inj != null);
        try std.testing.expectEqualDeep(&inj, maybe_inj.?);
    }

    test "expect `get` to resolve a plain property when requested as a *const" {
        const TestContext = struct {
            i: u64 = 1,
        };
        var value: TestContext = .{};
        var inj = try Injector.init(&value, null);
        const maybe_value = try inj.get(*const u64);
        try std.testing.expect(maybe_value != null);
        try std.testing.expectEqual(&value.i, maybe_value.?);
    }

    test "expect `get` to resolve a plain property when requested as a value" {
        const TestContext = struct {
            i: u64 = 1,
        };
        var value: TestContext = .{};
        var inj = try Injector.init(&value, null);
        const maybe_value = try inj.get(u64);
        try std.testing.expect(maybe_value != null);
        try std.testing.expectEqual(value.i, maybe_value.?);
    }

    test "expect `get` to resolve a plain property when requested as a pointer" {
        const TestContext = struct {
            i: u64 = 1,
        };
        var value: TestContext = .{};
        var inj = try Injector.init(&value, null);
        const maybe_value = try inj.get(*u64);
        try std.testing.expect(maybe_value != null);
        try std.testing.expectEqual(&value.i, maybe_value.?);
        maybe_value.?.* = 2;
        try std.testing.expectEqual(2, value.i);
    }

    test "expect `get` to resolve a factory with no params" {
        const alloc = std.testing.allocator;
        var arena = std.heap.ArenaAllocator.init(alloc);
        const Value = struct {
            next: u64,
        };

        const TestContext = struct {
            counter: u64 = 0,
            arena: *std.heap.ArenaAllocator,
            pub fn next(counter: *u64) Value {
                const v = Value{ .next = counter.* };
                counter.* += 1;
                return v;
            }
        };

        var value: TestContext = .{ .arena = &arena };
        var inj = try Injector.init(&value, null);
        const maybe_value = try inj.get(Value);
        try std.testing.expect(maybe_value != null);
        try std.testing.expectEqual(0, maybe_value.?.next);

        const maybe_value2 = try inj.get(Value);
        try std.testing.expect(maybe_value2 != null);
        try std.testing.expectEqual(1, maybe_value2.?.next);
        try std.testing.expect(arena.reset(.free_all));
        arena.deinit();
    }

    /// Calls a function by injecting it's arguments from the injector, optionally passing extra parameters at the end.
    /// See call_first if you need the extra parameters at the start.
    pub fn call(self: *Injector, comptime fun: anytype, extra_args: anytype) anyerror!meta.Result(fun) {
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
        inline for (0..args.len) |i| args[i] = if (i < extra_start) try self.require(@TypeOf(args[i])) else extra_args[i - extra_start];

        return @call(.auto, fun, args);
    }

    /// Calls a function by injecting it's arguments from the injector, optionally passing extra parameters at the start.
    /// See call if you need the extra parameters at the end.
    pub fn call_first(self: *Injector, comptime fun: anytype, extra_args: anytype) anyerror!meta.Result(fun) {
        if (comptime @typeInfo(@TypeOf(extra_args)) != .@"struct") {
            @compileError("Expected a tuple of arguments");
        }

        const params = @typeInfo(@TypeOf(fun)).@"fn".params;

        const types = comptime brk: {
            var types: [params.len]type = undefined;
            for (0..extra_args.len) |i| types[i] = @TypeOf(extra_args[i]);
            for (extra_args.len..params.len) |i| types[i] = params[i].type orelse @compileError("reached anytype");
            break :brk &types;
        };

        var args: std.meta.Tuple(types) = undefined;
        inline for (0..args.len) |i| args[i] = if (i >= extra_args.len) try self.require(@TypeOf(args[i])) else extra_args[i];

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
