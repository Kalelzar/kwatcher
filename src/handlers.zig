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

fn HandlerFn(comptime T: type) type {
    return *const fn (*injector.Injector) T;
}

pub const Metadata = struct {
    deps: []const meta.TypeId,
    errors: []const anyerror,
};

pub const Binding = struct {
    route: []const u8 = "",
    exchange: []const u8 = "",
    queue: ?[]const u8 = null,
    consumer_tag: ?[]const u8 = null,
};

pub fn HandlerCodeGen(comptime PathParams: type) type {
    const PublishHandlerFn = HandlerFn(anyerror!schema.SendMessage);
    const EventHandlerFn = HandlerFn(anyerror!bool);
    const ConsumeHandlerFn = *const fn (*injector.Injector, []const u8) anyerror!void;
    const ReplyHandlerFn = *const fn (*injector.Injector, []const u8) anyerror!schema.SendMessage;

    const RouteHandlerFn = *const fn (*injector.Injector) anyerror!InternFmtCache.Lease;

    return struct {
        pub const Handlers = struct {
            event: ?EventHandlerFn = null,
            publish: ?PublishHandlerFn = null,
            consume: ?ConsumeHandlerFn = null,
            reply: ?ReplyHandlerFn = null,
            route: RouteHandlerFn,
            exchange: RouteHandlerFn,
            queue: ?RouteHandlerFn = null,
        };

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

                pub fn static(inj: *injector.Injector) anyerror!InternFmtCache.Lease {
                    const alloc = try inj.require(std.mem.Allocator);
                    return .{ .new = expr.raw, .old = null, .allocator = alloc };
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

                    const binding = try inj.require(*Binding);
                    const exchange = binding.exchange;
                    const route = binding.route;

                    var arena = try inj.require(mem.InternalArena);
                    const alloc = arena.allocator();
                    if (comptime @hasField(ReturnType, "schema") and @hasField(ReturnType, "options") and @FieldType(ReturnType, "options") == schema.ConfigurableMessageOptions) {
                        const opts: schema.ConfigurableMessageOptions = result.options;
                        const body = try std.json.stringifyAlloc(alloc, result.schema, .{});
                        return .{
                            .body = body,
                            .options = .{
                                .exchange = exchange,
                                .routing_key = route,
                                .reply_to = opts.reply_to,
                            },
                        };
                    } else {
                        const body = try std.json.stringifyAlloc(alloc, result, .{});

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

                    const out_body = try std.json.stringifyAlloc(allocator, result, .{});

                    return .{
                        .body = out_body,
                        .options = .{
                            .exchange = "amq.direct",
                            .routing_key = route,
                        },
                    };
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
    };
}
