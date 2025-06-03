const std = @import("std");

const klib = @import("klib");
const meta = klib.meta;
const mem = @import("mem.zig");

const schema = @import("schema.zig");
const injector = @import("injector.zig");
const resolver = @import("resolver.zig");
const InternFmtCache = @import("intern_fmt_cache.zig");
const template = @import("template.zig");
const Template = template.Template;
const routes = @import("route.zig");

/// A helper for creating a handler function
fn HandlerFn(comptime T: type) type {
    return *const fn (*injector.Injector) T;
}

/// The metadata for a handler.
pub const Metadata = struct {
    deps: []const meta.TypeId,
    errors: []const anyerror,
};

/// A generic binding structure.
pub const Binding = struct {
    route: []const u8 = "",
    exchange: []const u8 = "",
    queue: ?[]const u8 = null,
    consumer_tag: ?[]const u8 = null,
};

/// A code generator for handlers that depends on a specific Context for the route parameters.
pub fn HandlerCodeGen(comptime PathParams: type) type {
    const PublishHandlerFn = HandlerFn(anyerror!schema.SendMessage);
    const EventHandlerFn = HandlerFn(anyerror!bool);
    const ConsumeHandlerFn = *const fn (*injector.Injector, []const u8) anyerror!void;
    const ReplyHandlerFn = *const fn (*injector.Injector, []const u8) anyerror!schema.SendMessage;
    const RouteHandlerFn = HandlerFn(anyerror!InternFmtCache.Lease);

    return struct {
        pub const Handlers = struct {
            /// A handler for events. Used by publish routes.
            event: ?EventHandlerFn = null,
            /// A handler for `publish` routes.
            publish: ?PublishHandlerFn = null,
            /// A handler for `consume` routes.
            consume: ?ConsumeHandlerFn = null,
            /// A handler for `reply` routes.
            reply: ?ReplyHandlerFn = null,
            /// A handler for retrieving a parameter-substituted route.
            route: RouteHandlerFn,
            /// A handler for retrieving a parameter-substituted exchange.
            exchange: RouteHandlerFn,
            /// A handler for retrieving a parameter-substituted queue. Optional.
            queue: ?RouteHandlerFn = null,
        };

        /// Generate the appropriate handler for a given route string.
        pub fn gen(comptime ContainerType: type, comptime EventProvider: type, comptime source: []const u8) routes.Route(PathParams) {
            var tmpl = Template(PathParams).init(source);
            const expression = tmpl.parseTokens();
            const handler = @field(ContainerType, source);
            return switch (expression.method) {
                .publish => genPublishRoute(source, EventProvider, handler, expression),
                .reply => genReplyRoute(source, handler, expression),
                .consume => genConsumeRoute(source, handler, expression),
            };
        }

        fn genPublishRoute(
            comptime name: []const u8,
            comptime EventProvider: type,
            comptime handler: anytype,
            comptime expr: template.PublishExpr,
        ) routes.Route(PathParams) {
            const metadata = metadataFromHandler(handler);

            const event_handler = @field(EventProvider, expr.event.raw);
            const event_metadata = metadataFromHandler(event_handler);

            const exchangeHandler = genRouteHandler(name ++ "__exch", expr.exchange);
            const routeHandler = genRouteHandler(name ++ "__rout", expr.route);
            const pubHandler = publishHandler(metadata, handler);
            const evHandler = eventHandler(event_metadata, event_handler);

            return .{
                .method = .publish,
                .binding = .{},
                .handlers = .{
                    .exchange = exchangeHandler,
                    .route = routeHandler,
                    .publish = pubHandler,
                    .event = evHandler,
                },
                .metadata = &metadata,
            };
        }

        fn genConsumeRoute(
            comptime name: []const u8,
            comptime handler: anytype,
            comptime expr: template.ConsumeExpr,
        ) routes.Route(PathParams) {
            const metadata = metadataFromHandler(handler);

            const exchangeHandler = genRouteHandler(name ++ "__exch", expr.exchange);
            const routeHandler = genRouteHandler(name ++ "__rout", expr.route);
            const queueHandler = if (expr.queue) |q|
                genRouteHandler(name ++ "__queu", q)
            else
                null;
            const consHandler = consumeHandler(metadata, handler);

            return .{
                .method = .consume,
                .binding = .{},
                .handlers = .{
                    .exchange = exchangeHandler,
                    .route = routeHandler,
                    .queue = queueHandler,
                    .consume = consHandler,
                },
                .metadata = &metadata,
            };
        }

        fn genReplyRoute(
            comptime name: []const u8,
            comptime handler: anytype,
            comptime expr: template.ReplyExpr,
        ) routes.Route(PathParams) {
            const metadata = metadataFromHandler(handler);

            const exchangeHandler = genRouteHandler(name ++ "__exch", expr.exchange);
            const routeHandler = genRouteHandler(name ++ "__rout", expr.route);
            const queueHandler = if (expr.queue) |q|
                genRouteHandler(name ++ "__queu", q)
            else
                null;
            const repHandler = replyHandler(metadata, handler);

            return .{
                .method = .reply,
                .binding = .{},
                .handlers = .{
                    .exchange = exchangeHandler,
                    .route = routeHandler,
                    .queue = queueHandler,
                    .reply = repHandler,
                },
                .metadata = &metadata,
            };
        }

        fn genRouteHandler(comptime key: []const u8, comptime expr: template.ValueExpr) RouteHandlerFn {
            const RouteHandlers = struct {
                pub fn fromParams(inj: *injector.Injector) anyerror!InternFmtCache.Lease {
                    const params: *PathParams = try inj.require(*PathParams);
                    const intern_cache: *InternFmtCache = try inj.require(*InternFmtCache);

                    const Resolver = resolver.Resolver(PathParams);

                    const types = comptime blk: {
                        var types: [expr.params.len]type = undefined;
                        for (0..expr.params.len) |i| {
                            types[i] = Resolver.resolveType(expr.params[i]);
                        }
                        break :blk &types;
                    };

                    var args: std.meta.Tuple(types) = undefined;
                    inline for (0..expr.params.len) |i| {
                        args[i] = try Resolver.resolve(inj, expr.params[i], params);
                    }

                    return intern_cache.internFmtWithLease(key, expr.fmt, args);
                }

                pub fn static(_: *injector.Injector) anyerror!InternFmtCache.Lease {
                    return .{ .new = expr.raw, .old = null, .allocator = null };
                }
            };

            if (comptime expr.params.len == 0) {
                return &RouteHandlers.static;
            } else {
                return &RouteHandlers.fromParams;
            }
        }

        fn metadataFromHandler(
            comptime handler: anytype,
        ) Metadata {
            const fields = std.meta.fields(std.meta.ArgsTuple(@TypeOf(handler)));
            const n_deps = comptime fields.len;

            return .{
                .deps = comptime brk: {
                    var deps: [n_deps]meta.TypeId = undefined;
                    for (0..n_deps) |i| deps[i] = meta.typeId(fields[i].type);
                    const res = deps;
                    break :brk &res;
                },
                .errors = comptime brk: {
                    switch (@typeInfo(meta.Return(handler))) {
                        .error_union => |r| {
                            if (@typeInfo(r.error_set).error_set == null) break :brk &.{};
                            const names = std.meta.fieldNames(r.error_set);
                            var errors: [names.len]anyerror = undefined;
                            for (names, 0..) |e, i| errors[i] = @field(anyerror, e);
                            const res = errors;
                            break :brk &res;
                        },
                        else => break :brk &.{},
                    }
                },
            };
        }

        fn publishHandler(
            comptime metadata: Metadata,
            comptime handler: anytype,
        ) PublishHandlerFn {
            const n_deps = metadata.deps.len;

            const Internal = struct {
                fn handle(inj: *injector.Injector) !schema.SendMessage {
                    var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;
                    const ReturnType = meta.Result(handler);

                    inline for (0..n_deps) |i| {
                        args[i] = try inj.require(@TypeOf(args[i]));
                    }

                    const maybe_result = @call(.auto, handler, args);

                    const result =
                        switch (comptime @typeInfo(meta.Return(handler))) {
                            .error_union => try maybe_result,
                            else => maybe_result,
                        };

                    switch (comptime @typeInfo(ReturnType)) {
                        .optional => {
                            if (result == null) return error.Cancelled;
                        },
                        else => {},
                    }

                    const binding = try inj.require(*Binding);
                    const exchange = binding.exchange;
                    const route = binding.route;

                    var arena = try inj.require(mem.InternalArena);
                    const alloc = arena.allocator();
                    return handlePublish(
                        ReturnType,
                        result,
                        alloc,
                        exchange,
                        route,
                    );
                }
            };

            return &Internal.handle;
        }

        fn consumeHandler(
            comptime metadata: Metadata,
            comptime handler: anytype,
        ) ConsumeHandlerFn {
            const n_deps = metadata.deps.len;

            const Internal = struct {
                fn handle(inj: *injector.Injector, body: []const u8) !void {
                    var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;
                    if (comptime std.meta.fields(@TypeOf(args)).len == 0) {
                        @compileError("Consumer routes need at least one parameter for the incoming message");
                    }

                    if (comptime !@hasField(@TypeOf(args[0]), "schema_name") or
                        !@hasField(@TypeOf(args[0]), "schema_version"))
                    {
                        @compileError("The first parameter of a consumer route has to be a schema.");
                    }

                    var arena = try inj.require(mem.InternalArena);
                    const allocator = arena.allocator();

                    args[0] = std.json.parseFromSliceLeaky(
                        @TypeOf(args[0]),
                        allocator,
                        body,
                        .{},
                    ) catch |e| blk: {
                        std.log.warn("Error encountered while parsing schema: {}", .{e});
                        break :blk try std.json.parseFromSliceLeaky(
                            @TypeOf(args[0]),
                            allocator,
                            body,
                            .{
                                .duplicate_field_behavior = .use_last,
                                .ignore_unknown_fields = true,
                            },
                        );
                    };

                    inline for (1..n_deps) |i| {
                        args[i] = try inj.require(@TypeOf(args[i]));
                    }

                    if (comptime meta.canBeError(handler)) {
                        try @call(.auto, handler, args);
                    } else {
                        @call(.auto, handler, args);
                    }
                }
            };

            return &Internal.handle;
        }

        fn replyHandler(
            comptime metadata: Metadata,
            comptime handler: anytype,
        ) ReplyHandlerFn {
            const n_deps = metadata.deps.len;

            const Internal = struct {
                fn handle(inj: *injector.Injector, body: []const u8) !schema.SendMessage {
                    var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;
                    if (comptime std.meta.fields(@TypeOf(args)).len == 0) {
                        @compileError("Reply routes need at least one parameter for the incoming message");
                    }

                    if (comptime !@hasField(@TypeOf(args[0]), "schema_name") or
                        !@hasField(@TypeOf(args[0]), "schema_version"))
                    {
                        @compileError("The first parameter of a reply route has to be a schema.");
                    }

                    var arena = try inj.require(mem.InternalArena);
                    const allocator = arena.allocator();

                    const binding = try inj.require(*Binding);
                    const route = binding.route;

                    args[0] = std.json.parseFromSliceLeaky(
                        @TypeOf(args[0]),
                        allocator,
                        body,
                        .{},
                    ) catch |e| blk: {
                        std.log.warn("Error encountered while parsing schema: {}", .{e});
                        break :blk try std.json.parseFromSliceLeaky(
                            @TypeOf(args[0]),
                            allocator,
                            body,
                            .{
                                .duplicate_field_behavior = .use_last,
                                .ignore_unknown_fields = true,
                            },
                        );
                    };

                    inline for (1..n_deps) |i| {
                        args[i] = try inj.require(@TypeOf(args[i]));
                    }

                    const maybe_result = @call(.auto, handler, args);

                    const result =
                        switch (comptime @typeInfo(meta.Return(handler))) {
                            .error_union => try maybe_result,
                            else => maybe_result,
                        };

                    switch (comptime @typeInfo(meta.Result(handler))) {
                        .optional => {
                            if (result == null) return error.Cancelled;
                        },
                        else => {},
                    }

                    return handlePublish(
                        meta.Result(handler),
                        result,
                        allocator,
                        "amq.direct",
                        route,
                    );
                }
            };

            return &Internal.handle;
        }

        fn eventHandler(
            comptime metadata: Metadata,
            comptime handler: anytype,
        ) EventHandlerFn {
            const n_deps = metadata.deps.len;

            const Internal = struct {
                fn handle(inj: *injector.Injector) !bool {
                    var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;

                    inline for (0..n_deps) |i| {
                        args[i] = try inj.require(@TypeOf(args[i]));
                    }

                    return @call(.auto, handler, args);
                }
            };

            return &Internal.handle;
        }

        fn handlePublish(
            comptime ResultType: type,
            result: anytype,
            alloc: std.mem.Allocator,
            exchange: []const u8,
            route: []const u8,
        ) !schema.SendMessage {
            const ActualResultType =
                switch (comptime @typeInfo(ResultType)) {
                    .optional => |o| o.child,
                    else => ResultType,
                };

            const actual_result =
                try @as(anyerror!ActualResultType, switch (comptime @typeInfo(ResultType)) {
                    .optional => result orelse error.Cancelled,
                    else => result,
                });

            if (comptime @hasField(ActualResultType, "schema") and @hasField(ActualResultType, "options") and @FieldType(ActualResultType, "options") == schema.ConfigurableMessageOptions) {
                const opts: schema.ConfigurableMessageOptions = actual_result.options;
                const body = try std.json.stringifyAlloc(alloc, actual_result.schema, .{});
                return .{
                    .body = body,
                    .options = .{
                        .exchange = exchange,
                        .routing_key = route,
                        .reply_to = opts.reply_to,
                        .correlation_id = opts.correlation_id,
                        .expiration = opts.expiration,
                    },
                };
            } else {
                const body = try std.json.stringifyAlloc(alloc, actual_result, .{});

                return .{
                    .body = body,
                    .options = .{
                        .exchange = exchange,
                        .routing_key = route,
                    },
                };
            }
        }
    };
}

fn noop(_: usize) void {}

const metrics_shim: klib.mem.MemMetricsShim = .{
    .alloc = noop,
    .free = noop,
};

test "expect `gen` to generate the correct route from string" {
    const Context = struct {};
    const Gen = HandlerCodeGen(Context);
    const Events = struct {
        pub fn event() bool {
            return true;
        }
    };
    const Route = struct {
        pub fn @"publish:event exchange/route"() struct {} {
            return .{};
        }

        pub fn @"reply exchange/route"(_: schema.Schema(0, "test", struct {})) struct {} {
            return .{};
        }

        pub fn @"consume exchange/route"(_: schema.Schema(0, "test", struct {})) void {
            return;
        }
    };
    var ctx: struct {} = .{};
    var inj = try injector.Injector.init(&ctx, null);
    {
        @setEvalBranchQuota(10000);
        var publish_route = comptime Gen.gen(Route, Events, "publish:event exchange/route");
        const p_consumer_tag = try publish_route.updateBindings(&inj);
        try std.testing.expectEqual(null, p_consumer_tag);
        try std.testing.expectEqualStrings("exchange", publish_route.binding.exchange);
        try std.testing.expectEqualStrings("route", publish_route.binding.route);
        try std.testing.expectEqual(publish_route.method, .publish);

        var consume_route = comptime Gen.gen(Route, Events, "consume exchange/route");
        const c_consumer_tag = try consume_route.updateBindings(&inj);
        try std.testing.expectEqual(null, c_consumer_tag);
        try std.testing.expectEqualStrings("exchange", consume_route.binding.exchange);
        try std.testing.expectEqualStrings("route", consume_route.binding.route);
        try std.testing.expectEqual(consume_route.method, .consume);

        var reply_route = comptime Gen.gen(Route, Events, "reply exchange/route");
        const r_consumer_tag = try reply_route.updateBindings(&inj);
        try std.testing.expectEqual(null, r_consumer_tag);
        try std.testing.expectEqualStrings("exchange", reply_route.binding.exchange);
        try std.testing.expectEqualStrings("route", reply_route.binding.route);
        try std.testing.expectEqual(reply_route.method, .reply);
    }
}

test "expect `genRouteHandler` to create a static handler for a string with no params" {
    const Context = struct {};
    const Gen = HandlerCodeGen(Context);
    var ctx: struct {} = .{};
    var inj = try injector.Injector.init(&ctx, null);
    const route = comptime blk: {
        @setEvalBranchQuota(10000);
        var tmpl = template.Template(Context).init("consume $/test");
        break :blk tmpl.parseTokens().route;
    };

    const handler = comptime Gen.genRouteHandler("key", route);
    const Args = std.meta.Tuple(&.{*injector.Injector});
    const res: InternFmtCache.Lease = try @call(.auto, handler, Args{&inj});
    try std.testing.expectEqual(null, res.allocator);
    try std.testing.expectEqual(null, res.old);
    try std.testing.expectEqualStrings("test", res.new);
}

test "expect `genRouteHandler` to create a dynamic handler for a string with one parameter" {
    const Context = struct { arg: i64 = 1 };
    const Gen = HandlerCodeGen(Context);

    var params = Context{};
    var ifc = InternFmtCache.init(std.testing.allocator);
    defer ifc.deinit();

    var ctx: struct {
        ctx: *Context,
        ifc: *InternFmtCache,
    } = .{
        .ctx = &params,
        .ifc = &ifc,
    };
    var inj = try injector.Injector.init(&ctx, null);
    const route = comptime blk: {
        @setEvalBranchQuota(10000);
        var tmpl = template.Template(Context).init("consume $/{arg}");
        break :blk tmpl.parseTokens().route;
    };

    const handler = comptime Gen.genRouteHandler("key", route);
    const Args = std.meta.Tuple(&.{*injector.Injector});
    const res: InternFmtCache.Lease = try @call(.auto, handler, Args{&inj});
    try std.testing.expectEqual(null, res.old);
    try std.testing.expectEqualStrings("1", res.new);

    var res_unchanged: InternFmtCache.Lease = try @call(.auto, handler, Args{&inj});
    defer res_unchanged.deinit();
    try std.testing.expectEqual(null, res_unchanged.old);
    try std.testing.expectEqualStrings("1", res_unchanged.new);
    try std.testing.expectEqual(res.new.len, res_unchanged.new.len);
    try std.testing.expectEqual(res.new.ptr, res_unchanged.new.ptr);

    params.arg = 2;

    var res_updated: InternFmtCache.Lease = try @call(.auto, handler, Args{&inj});
    defer res_updated.deinit();
    try std.testing.expect(res_updated.old != null);
    try std.testing.expectEqualStrings("1", res_updated.old.?);
    try std.testing.expectEqualStrings("2", res_updated.new);
}

test "expect `publishHandler` to create a valid publish route handler" {
    const Context = struct {};
    const Gen = HandlerCodeGen(Context);
    const Handler = struct {
        pub fn handle() schema.Schema(1, "test", struct {}) {
            return .{};
        }
    };

    var arena = try mem.InternalArena.init(
        std.testing.allocator,
        metrics_shim,
    );
    defer arena.deinit();

    var binding: Binding = .{
        .consumer_tag = null,
        .exchange = "exchange",
        .queue = null,
        .route = "route",
    };

    const metadata: Metadata = comptime Gen.metadataFromHandler(Handler.handle);
    const handle = Gen.publishHandler(metadata, Handler.handle);
    var ctx: struct { bind: *Binding, arena: *mem.InternalArena } = .{
        .bind = &binding,
        .arena = &arena,
    };
    var inj = try injector.Injector.init(&ctx, null);
    const Args = std.meta.Tuple(&.{*injector.Injector});
    const res: schema.SendMessage = try @call(.auto, handle, Args{&inj});
    try std.testing.expectEqualStrings(binding.exchange, res.options.exchange);
    try std.testing.expectEqualStrings(binding.route, res.options.routing_key);
    try std.testing.expectEqual(null, res.options.correlation_id);
    try std.testing.expectEqual(null, res.options.reply_to);
    try std.testing.expectEqual(null, res.options.expiration);
    try std.testing.expectEqualStrings("{\"schema_version\":1,\"schema_name\":\"test\"}", res.body);
}

test "expect `publishHandler` to allow customizing options" {
    const Context = struct {};
    const Gen = HandlerCodeGen(Context);
    const Handler = struct {
        pub fn handle() schema.Message(schema.Schema(1, "test", struct {})) {
            return .{
                .options = .{
                    .correlation_id = "req-0001",
                    .expiration = 60,
                    .reply_to = "reply_to",
                },
                .schema = .{},
            };
        }
    };

    var arena = try mem.InternalArena.init(
        std.testing.allocator,
        metrics_shim,
    );
    defer arena.deinit();

    var binding: Binding = .{
        .consumer_tag = null,
        .exchange = "exchange",
        .queue = null,
        .route = "route",
    };

    const metadata: Metadata = comptime Gen.metadataFromHandler(Handler.handle);
    const handle = Gen.publishHandler(metadata, Handler.handle);
    var ctx: struct { bind: *Binding, arena: *mem.InternalArena } = .{
        .bind = &binding,
        .arena = &arena,
    };
    var inj = try injector.Injector.init(&ctx, null);
    const Args = std.meta.Tuple(&.{*injector.Injector});
    const res: schema.SendMessage = try @call(.auto, handle, Args{&inj});
    try std.testing.expectEqualStrings(binding.exchange, res.options.exchange);
    try std.testing.expectEqualStrings(binding.route, res.options.routing_key);
    try std.testing.expect(res.options.correlation_id != null);
    try std.testing.expect(res.options.reply_to != null);
    try std.testing.expect(res.options.expiration != null);
    try std.testing.expectEqualStrings("req-0001", res.options.correlation_id.?);
    try std.testing.expectEqualStrings("reply_to", res.options.reply_to.?);
    try std.testing.expectEqual(60, res.options.expiration.?);
    try std.testing.expectEqualStrings("{\"schema_version\":1,\"schema_name\":\"test\"}", res.body);
}

test "expect `publishHandler` to cancel if handler returns null" {
    const Context = struct {};
    const Gen = HandlerCodeGen(Context);
    const Handler = struct {
        pub fn handle() ?schema.Message(schema.Schema(1, "test", struct {})) {
            return null;
        }
    };

    var arena = try mem.InternalArena.init(
        std.testing.allocator,
        metrics_shim,
    );
    defer arena.deinit();

    var binding: Binding = .{
        .consumer_tag = null,
        .exchange = "exchange",
        .queue = null,
        .route = "route",
    };

    const metadata: Metadata = comptime Gen.metadataFromHandler(Handler.handle);
    const handle = Gen.publishHandler(metadata, Handler.handle);
    var ctx: struct { bind: *Binding, arena: *mem.InternalArena } = .{
        .bind = &binding,
        .arena = &arena,
    };
    var inj = try injector.Injector.init(&ctx, null);
    const Args = std.meta.Tuple(&.{*injector.Injector});
    try std.testing.expectError(
        error.Cancelled,
        @call(.auto, handle, Args{&inj}),
    );
}
