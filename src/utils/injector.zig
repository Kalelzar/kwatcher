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
const builtin = @import("builtin");

const klib = @import("klib");
const meta = klib.meta;

const mem = @import("../mem.zig");

/// A type alias for a context
const Context = *anyopaque;

/// The type of a resolver function
const Resolver = *const fn (Context, meta.TypeId) ?*anyopaque;
/// The type of a factory resolver function
const FactoryResolver = *const fn (meta.TypeId) ?*const fn (*Injector) anyerror!*anyopaque;
/// The type of the dispose function.
const DisposeFn = *const fn (Context) void;

const use_analysis = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

/// A dependency injector with support for parent injectors.
/// It can dynamically provide the contents of a struct (`Context')
/// to any function called with it, supporting both plain properties
/// and factory functions.
pub const Injector = struct {
    const TidHashContext = struct {
        pub fn hash(self: @This(), key: klib.meta.TypeId) u32 {
            _ = self;
            const res: u32 = @truncate(@intFromPtr(key));
            return res;
        }

        pub fn eql(self: @This(), a: klib.meta.TypeId, b: klib.meta.TypeId) bool {
            _ = self;
            return a == b;
        }
    };
    /// Dependency graph
    graph: if (use_analysis) Analyser.Graph else void,
    /// The context from which to inject dependencies
    context: Context,
    /// The name of the context.
    context_name: []const u8,
    /// The resolver function
    resolver: Resolver,
    /// The factory resolver function
    resolver_factory: FactoryResolver,
    /// The parent of this injector in which to look up dependencies if they aren't in the context.
    parent: ?*Injector = null,
    /// The dispose function
    dispose: ?DisposeFn,

    resolver_buffer: [32768]u8 = undefined,
    allocator: ?std.heap.FixedBufferAllocator = null,
    resolver_cache: std.HashMapUnmanaged(klib.meta.TypeId, ResolutionPath, TidHashContext, 99) = .empty,

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
                .error_union => @compileError("Deconstruct must not return an error."),
                else => dispose = F.dispose_handler,
            }
        }

        const configured_parent: ?*Injector = if (comptime @hasDecl(ContextType, "preconfigure")) blk: {
            const fun = @field(ContextType, "preconfigure");
            const ti = @typeInfo(@TypeOf(fun));
            if (comptime ti != .@"fn") {
                break :blk parent;
            } else {
                if (parent) |p| {
                    break :blk try p.call_first(ContextType.preconfigure, .{p});
                } else {
                    var bogus = struct {}{};
                    var p = try Injector.init(&bogus, null);
                    break :blk try p.call_first(ContextType.preconfigure, .{null});
                }
            }
        } else parent;

        var graph = if (comptime use_analysis) comptime Analyser.analyse(ContextType) else void{};

        if (configured_parent) |p| blk: {
            if (comptime use_analysis) {
                graph.fulfill(p.graph);
            }
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

        if (comptime use_analysis) {
            if (!graph.isFulfilled()) {
                graph.blame();
                return error.Unfulfilled;
            } else {
                // std.log.info(
                //     "Generated injector from context: {s}. Provides: ",
                //     .{@typeName(ContextType)},
                // );
                // for (0..graph.len) |i| {
                //     const n = graph.nodes[i];
                //     std.log.info("  {s} from {s}.", .{ n.name, n.source });
                // }
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

                if (type_id == meta.typeId(ContextPtrType)) {
                    return typed_context;
                }

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
                        @branchHint(.unpredictable);
                        std.debug.assert(@intFromPtr(p) != 0xaaaaaaaaaaaaaaaa);
                        return @ptrCast(@constCast(p));
                    }
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
                        @branchHint(.unpredictable);
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
            .graph = graph,
            .context = @ptrCast(@constCast(context)),
            .context_name = @typeName(ContextType),
            .resolver = &InternalResolver.resolve,
            .resolver_factory = &InternalResolver.resolveFactory,
            .dispose = dispose,
            .parent = configured_parent,
        };
    }

    /// Require a dependency of type `T`. Will return an error if a dependency is missing or a factory returns an error.
    pub inline fn require(self: *Injector, comptime T: type) !T {
        if (comptime use_analysis) {
            if (self.graph.indexOf(T)) |i| blk: {
                const n = self.graph.nodes[i];
                if (n.isFulfilled(&self.graph)) break :blk;
                n.blame(&self.graph);
                std.log.err("[{s}] Unfulfilled dependency: {s}", .{ self.context_name, @typeName(T) });
                return error.UnfulfilledDependency;
            } else {
                std.log.err("[{s}] Missing dependency in graph: {s}", .{ self.context_name, @typeName(T) });
                std.debug.dumpCurrentStackTrace(null);
                return error.MissingDependency;
            }
        }

        return try self.get(T) orelse {
            std.log.err("[{s}] Missing dependency: {s}", .{ self.context_name, @typeName(T) });
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
    pub inline fn get(self: *Injector, comptime T: type) !?T {
        if (comptime use_analysis) {
            if (self.graph.indexOf(T)) |i| blk: {
                const n = self.graph.nodes[i];
                if (n.isFulfilled(&self.graph)) break :blk;
                n.blame(&self.graph);
                std.log.warn("Unfulfilled dependency: {s}", .{@typeName(T)});
                return null;
            } else {
                return null;
            }
        }

        if (self.allocator == null) {
            self.allocator = .init(&self.resolver_buffer);
            try self.resolver_cache.ensureTotalCapacity(
                self.allocator.?.allocator(),
                256,
            );
        }

        const entry = self.resolver_cache.getOrPutAssumeCapacity(klib.meta.typeId(T));

        if (entry.found_existing) {
            @branchHint(.likely);
            return self.replay(T, entry.value_ptr.*);
        } else {
            @branchHint(.unlikely);
            entry.value_ptr.* = self.record(T);
            return self.replay(T, entry.value_ptr.*);
        }
    }

    pub fn record(self: *Injector, comptime T: type) ResolutionPath {
        if (comptime T == *Injector) {
            @branchHint(.unlikely);
            return .{
                .injector = self,
            };
        }

        if (comptime !meta.isValuePointer(T)) {
            return self.record(*const T);
        }

        if (self.resolver(self.context, meta.typeId(T))) |ptr| {
            return .{
                .resolver = ptr,
            };
        }

        if (comptime @typeInfo(T).pointer.is_const) {
            if (self.resolver(self.context, meta.typeId(*@typeInfo(T).pointer.child))) |ptr| {
                return .{
                    .resolver = ptr,
                };
            }
        }
        if (self.resolver_factory(meta.typeId(T))) |factory| {
            const cache = self.resolver(self.context, meta.typeId(*?T)) orelse self.resolver(self.context, meta.typeId(*?*T));

            return .{
                .factory = .{
                    .inj = self,
                    .cache = cache,
                    .fac = factory,
                },
            };
        }

        return if (self.parent) |p| p.record(T) else .{
            .not_found = {},
        };
    }

    pub fn replay(self: *Injector, comptime T: type, path: ResolutionPath) !?T {
        _ = self;
        return switch (path) {
            .injector => |i| if (comptime T == *Injector) i else error.TypeMismatch,
            .resolver => |p| blk: {
                if (comptime klib.meta.isValuePointer(T)) {
                    break :blk @ptrCast(@alignCast(@constCast(p)));
                } else {
                    const r: *T = @ptrCast(@alignCast(@constCast(p)));
                    break :blk r.*;
                }
            },
            .factory => |f| blk: {
                if (comptime klib.meta.isValuePointer(T)) {
                    if (f.cache) |c| {
                        const cr: *?T = @ptrCast(@alignCast(@constCast(c)));
                        if (cr.*) |o| {
                            break :blk o;
                        }
                    }

                    break :blk @ptrCast(@alignCast(@constCast(try f.fac(f.inj))));
                } else {
                    const r: *T = @ptrCast(@alignCast(@constCast(try f.fac(f.inj))));
                    break :blk r.*;
                }
            },
            .not_found => null,
        };
    }

    pub fn getWithOverride(self: *Injector, child: *Injector, comptime T: type) !?T {
        if (comptime use_analysis) {
            if (self.graph.indexOf(T)) |i| blk: {
                const n = self.graph.nodes[i];
                if (n.isFulfilled(&self.graph)) break :blk;
                n.blame(&self.graph);
                std.log.warn("Unfulfilled dependency: {s}", .{@typeName(T)});
                return null;
            } else {
                return null;
            }
        }

        if (comptime T == *Injector) {
            @branchHint(.unlikely);
            return child;
        }

        if (comptime !meta.isValuePointer(T)) {
            return if (try self.getWithOverride(child, *const T)) |p| p.* else null;
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
            return @ptrCast(@alignCast(@constCast(try factory(child))));
        }

        return if (self.parent) |p| try p.getWithOverride(child, T) else null;
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

        const params = @typeInfo(klib.meta.Fn(@TypeOf(fun))).@"fn".params;

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
        // FIXME: we need to deconstruct any interdicted parents here.
    }
};

const Analyser = struct {
    const Node = struct {
        name: []const u8,
        source: []const u8,
        id: klib.meta.TypeId,
        to: [256]u8 = undefined,
        len: u8 = 0,
        provided: bool = false,

        pub fn isFulfilled(self: *const Node, g: *const Graph) bool {
            if (self.len == 0) return self.provided;
            for (0..self.len) |i| {
                const dep = self.to[i];
                const nod = g.nodes[dep];
                if (!nod.isFulfilled(g)) return false;
            }
            return true;
        }

        pub fn blame(self: *const Node, g: *const Graph) void {
            if (self.len == 0) {
                if (!self.provided) {
                    std.debug.print("Unresolved static of type '{s}'\n", .{self.name});
                }
            }
            for (0..self.len) |i| {
                const dep = self.to[i];
                const nod = g.nodes[dep];
                if (!nod.isFulfilled(g)) {
                    std.debug.print("Unresolved factory {s} of type '{s}'\n", .{ self.source, self.name });
                    nod.blame(g);
                }
            }
        }
    };

    const Graph = struct {
        nodes: [256]Node = undefined,
        len: u8 = 0,

        pub fn isAvailable(self: *Graph, comptime T: type) bool {
            const tid = klib.meta.typeId(T);
            for (0..self.len) |i| {
                if (self.nodes[i].id == tid) return self.nodes[i].isFulfilled(self);
            }
            return false;
        }

        pub fn indexOf(self: *Graph, comptime T: type) ?u8 {
            const tid = klib.meta.typeId(T);
            // std.log.info("Index of: {s}", .{@typeName(T)});
            for (0..self.len) |i| {
                // std.log.info("  [{d:03}] Trying {s}", .{ i, self.nodes[i].name });
                if (self.nodes[i].id == tid) {
                    // std.log.info("  [{d:03}] Found {s}", .{ i, self.nodes[i].name });
                    return @intCast(i);
                }
            }
            return null;
        }

        pub fn fulfill(self: *Graph, other: Graph) void {
            outer: for (0..other.len) |i| {
                const theirs = other.nodes[i];
                const og = self.len;
                for (0..og) |j| {
                    const ours = self.nodes[j];
                    if (ours.isFulfilled(self)) continue;
                    if (theirs.id == ours.id) {
                        self.nodes[j] = theirs;
                        continue :outer;
                    }
                }
                self.cloneInto(other, theirs);
            }
        }

        pub fn cloneInto(self: *Graph, other: Graph, node: Node) void {
            if (self.len == 255) @panic("Oveflow on dependency graph buffer!");
            const target = self.len;
            self.nodes[self.len] = node;
            self.len += 1;
            deps: for (0..node.len) |j| {
                const their_dep = other.nodes[node.to[j]];
                for (0..self.len) |k| {
                    const ours = self.nodes[k];
                    if (ours.id == their_dep.id) {
                        self.nodes[target].to[j] = @intCast(k);
                        continue :deps;
                    }
                }
                const dtarget = self.len;
                self.cloneInto(other, their_dep);
                self.nodes[target].to[j] = dtarget;
            }
        }

        pub fn blame(self: *const Graph) void {
            for (0..self.len) |i| {
                const n = self.nodes[i];
                if (!n.isFulfilled(self)) {
                    n.blame(self);
                }
            }
        }

        pub fn isFulfilled(self: *const Graph) bool {
            for (0..self.len) |i| {
                const n = self.nodes[i];
                if (!n.isFulfilled(self)) {
                    if (@inComptime()) {
                        @compileError(std.fmt.comptimePrint(
                            "Factory {s} cannot be fulfilled.",
                            .{n.name},
                        ));
                    } else {
                        std.log.err("Factory {s} cannot be fulfilled.", .{n.name});
                        return false;
                    }
                }
            }
            return true;
        }

        pub fn provides(comptime self: *Graph, n: Node) void {
            for (0..self.len) |i| {
                if (self.nodes[i].id == n.id) {
                    self.nodes[i].provided = true;
                    return;
                }
            }
            if (comptime self.len == 255) @compileError("Exceeded maximum dependency graph size.");
            self.nodes[self.len] = n;
            self.nodes[self.len].provided = true;
            self.len += 1;
        }

        pub fn depends(comptime self: *Graph, of: klib.meta.TypeId, n: Node) void {
            var idx: ?u8 = null;
            for (0..self.len) |i| {
                if (self.nodes[i].id == n.id) {
                    if (idx) |j| {
                        self.nodes[j].to[self.nodes[j].len] = i;
                        self.nodes[j].len += 1;
                        return;
                    } else {
                        idx = i;
                    }
                }
                if (self.nodes[i].id == of) {
                    if (idx) |j| {
                        self.nodes[i].to[self.nodes[i].len] = j;
                        self.nodes[i].len += 1;
                        return;
                    } else {
                        idx = i;
                    }
                }
            }
            if (idx) |i| {
                if (comptime self.len == 255) @compileError("Exceeded maximum dependency graph size.");
                self.nodes[self.len] = n;
                self.nodes[i].to[self.nodes[i].len] = self.len;
                self.nodes[i].len += 1;
                self.len += 1;
            } else {
                @compileError("Invalid depend call. Expected dependant type to already be in the graph");
            }
        }
    };

    pub fn analyse(comptime Ctx: type) Graph {
        comptime {
            @setEvalBranchQuota(1_000_000);
            const ti = @typeInfo(Ctx);
            var g: Graph = .{};

            if (ti != .@"struct") @compileError("You can only analyze the dependencies of structs");

            const sti = ti.@"struct";

            g.provides(.{
                .name = @typeName(*Ctx),
                .source = "self",
                .id = klib.meta.typeId(*Ctx),
            });

            g.provides(.{
                .name = @typeName(*Injector),
                .source = "injector",
                .id = klib.meta.typeId(*Injector),
            });

            for (sti.fields) |f| {
                const fti = @typeInfo(f.type);
                switch (fti) {
                    .optional => continue,
                    .pointer => |p| {
                        const isConst = p.is_const;
                        const t = if (isConst) *p.child else f.type;
                        const ct = if (isConst) f.type else *const p.child;
                        g.provides(.{
                            .name = @typeName(t),
                            .source = f.name,
                            .id = klib.meta.typeId(t),
                        });
                        g.provides(.{
                            .name = @typeName(ct),
                            .source = f.name,
                            .id = klib.meta.typeId(ct),
                        });
                        g.provides(.{
                            .name = @typeName(p.child),
                            .source = f.name,
                            .id = klib.meta.typeId(p.child),
                        });
                    },
                    else => {
                        g.provides(.{
                            .name = @typeName(f.type),
                            .source = f.name,
                            .id = klib.meta.typeId(f.type),
                        });
                        g.provides(.{
                            .name = @typeName(*f.type),
                            .source = f.name,
                            .id = klib.meta.typeId(*f.type),
                        });
                        g.provides(.{
                            .name = @typeName(*const f.type),
                            .source = f.name,
                            .id = klib.meta.typeId(*const f.type),
                        });
                    },
                }
            }
            for (std.meta.declarations(Ctx)) |d| {
                if (reserved_declarations_map.has(d.name)) continue;
                const fun = @field(Ctx, d.name);
                const dsti = @typeInfo(@TypeOf(fun));
                switch (dsti) {
                    .@"fn" => |_| {
                        const rid = @typeInfo(klib.meta.Result(fun));
                        const fid = klib.meta.typeId(klib.meta.Result(fun));
                        switch (rid) {
                            .pointer => |p| {
                                const isConst = p.is_const;
                                const other = if (isConst) *p.child else *const p.child;
                                g.provides(.{
                                    .name = @typeName(p.child),
                                    .source = d.name,
                                    .id = klib.meta.typeId(p.child),
                                });
                                g.provides(.{
                                    .name = @typeName(other),
                                    .source = d.name,
                                    .id = klib.meta.typeId(other),
                                });
                            },
                            else => {
                                g.provides(.{
                                    .name = @typeName(*const klib.meta.Result(fun)),
                                    .source = d.name,
                                    .id = klib.meta.typeId(*const klib.meta.Result(fun)),
                                });
                            },
                        }
                        g.provides(.{
                            .name = @typeName(klib.meta.Result(fun)),
                            .source = d.name,
                            .id = fid,
                        });
                        const args = std.meta.ArgsTuple(@TypeOf(fun));
                        for (std.meta.fields(args)) |a| {
                            switch (rid) {
                                .pointer => |p| {
                                    const isConst = p.is_const;
                                    const other = if (isConst) *p.child else *const p.child;
                                    g.depends(klib.meta.typeId(p.child), .{
                                        .name = @typeName(a.type),
                                        .source = a.name,
                                        .id = klib.meta.typeId(a.type),
                                    });
                                    g.depends(klib.meta.typeId(other), .{
                                        .name = @typeName(a.type),
                                        .source = a.name,
                                        .id = klib.meta.typeId(a.type),
                                    });
                                },
                                else => {
                                    g.depends(klib.meta.typeId(*const klib.meta.Result(fun)), .{
                                        .name = @typeName(a.type),
                                        .source = a.name,
                                        .id = klib.meta.typeId(a.type),
                                    });
                                },
                            }
                            g.depends(fid, .{
                                .name = @typeName(a.type),
                                .source = a.name,
                                .id = klib.meta.typeId(a.type),
                            });
                        }
                    },
                    else => {},
                }
            }
            return g;
        }
    }
};

const reserved_declarations_map = std.StaticStringMap(void).initComptime(.{
    .{"deconstruct"},
    .{"deinit"},
    .{"init"},
    .{"preconfigure"}, //FIXME: This does need to be checked
});

const ResolutionPath = union(enum) {
    injector: *Injector,
    resolver: *anyopaque,
    factory: struct {
        inj: *Injector,
        cache: ?*anyopaque,
        fac: *const fn (*Injector) anyerror!*anyopaque,
    },
    not_found: void,
};

fn resolveNull(_: Context, _: meta.TypeId) ?*anyopaque {
    return null;
}
