const std = @import("std");

const klib = @import("klib");
const meta = klib.meta;
const mem = @import("mem.zig");
const schema = @import("schema.zig");
const injector = @import("injector.zig");
const resolver = @import("resolver.zig");
const InternFmtCache = @import("intern_fmt_cache.zig");

pub const Method = enum {
    publish,
    consume,
    reply,
};

fn HandlerFn(comptime T: type) type {
    return *const fn (*injector.Injector) T;
}

const PublishHandlerFn = HandlerFn(anyerror!schema.SendMessage);
const EventHandlerFn = HandlerFn(anyerror!bool);
const ConsumeHandlerFn = *const fn (*injector.Injector, []const u8) anyerror!void;
const ReplyHandlerFn = *const fn (*injector.Injector, []const u8) anyerror!schema.SendMessage;

pub const Handlers = struct {
    event: ?EventHandlerFn = null,
    publish: ?PublishHandlerFn = null,
    consume: ?ConsumeHandlerFn = null,
    reply: ?ReplyHandlerFn = null,
};

pub fn Route(PathParams: type) type {
    const RouteHandlerFn = *const fn (*injector.Injector) anyerror![]const u8;

    const RouteHandlers = struct {
        pub fn with(comptime ctx: []const u8) type {
            return struct {
                pub fn fromParams(inj: *injector.Injector) anyerror![]const u8 {
                    const params: *PathParams = try inj.require(*PathParams);
                    const intern_cache: *InternFmtCache = try inj.require(*InternFmtCache);

                    const Resolver = resolver.Resolver(PathParams);

                    const value = try Resolver.resolve(inj, ctx, params);
                    if (comptime @TypeOf(value) != []const u8) {
                        @compileError("Currently only []const u8 parameters are supported. Sorry!");
                    } else {
                        return intern_cache.internFmt(ctx, "{s}", .{value});
                    }
                }

                pub fn static(_: *injector.Injector) anyerror![]const u8 {
                    return ctx;
                }
            };
        }
    };

    return struct {
        method: Method,
        handlers: Handlers,
        metadata: *const Metadata,

        const Self = @This();

        const Metadata = struct {
            deps: []const meta.TypeId,
            errors: []const anyerror,
            route: RouteHandlerFn,
            exchange: RouteHandlerFn,
            queue: ?RouteHandlerFn,
        };

        fn parseRouteHandlers(comptime path: []const u8) RouteHandlerFn {
            if (path.len > 3 and path[0] == '{' and path[path.len - 1] == '}') {
                const realpath = path[1 .. path.len - 1];
                return &RouteHandlers.with(realpath).fromParams;
            }
            return &RouteHandlers.with(path).static;
        }

        pub fn from(comptime ContainerType: type, comptime EventProvider: type) []const Self {
            meta.ensureStruct(ContainerType);

            const routes = comptime blk: {
                @setEvalBranchQuota(@typeInfo(ContainerType).@"struct".decls.len * 100);
                var res: []const Self = &.{};

                for (std.meta.declarations(ContainerType)) |d| {
                    if (@typeInfo(@TypeOf(@field(ContainerType, d.name))) != .@"fn") continue;

                    const end_of_method_and_event = std.mem.indexOfScalar(
                        u8,
                        d.name,
                        ' ',
                    ) orelse @compileError("route must contain a space");

                    const end_of_method = std.mem.indexOfScalar(
                        u8,
                        d.name[0..end_of_method_and_event],
                        ':',
                    ) orelse end_of_method_and_event;

                    const event: ?[]const u8 = if (end_of_method_and_event == end_of_method) null else d.name[end_of_method + 1 .. end_of_method_and_event];

                    const event_handler = if (event) |event_v| @field(EventProvider, event_v) else null;

                    var method_buf: [end_of_method]u8 = undefined;
                    const method = std.ascii.lowerString(&method_buf, d.name[0..end_of_method]);
                    const route = d.name[end_of_method_and_event + 1 ..];

                    const end_of_exchange = std.mem.indexOfScalar(
                        u8,
                        route,
                        '/',
                    ) orelse @compileError("route must contain a routing key and exchange");
                    const exchange = route[0..end_of_exchange];
                    const routing_key_and_maybe_queue = route[end_of_exchange + 1 ..];

                    const end_of_routing_key = std.mem.indexOfScalar(u8, routing_key_and_maybe_queue, '/') orelse routing_key_and_maybe_queue.len;
                    const routing_key = routing_key_and_maybe_queue[0..end_of_routing_key];
                    const queue = if (routing_key.len == routing_key_and_maybe_queue.len) null else routing_key_and_maybe_queue[end_of_routing_key + 1 ..];

                    const exchange_handler = parseRouteHandlers(exchange);
                    const route_handler = parseRouteHandlers(routing_key);
                    const queue_handler = if (routing_key.len == routing_key_and_maybe_queue.len) null else parseRouteHandlers(queue);

                    res = res ++ .{@field(@This(), method)(exchange_handler, route_handler, queue_handler, event_handler, @field(ContainerType, d.name))};
                }

                break :blk res;
            };

            return routes;
        }

        fn routeMetadata(
            comptime handler: anytype,
            exchange: RouteHandlerFn,
            route: RouteHandlerFn,
            queue: ?RouteHandlerFn,
        ) Self.Metadata {
            const fields = std.meta.fields(std.meta.ArgsTuple(@TypeOf(handler)));
            const n_deps = comptime fields.len;

            return .{
                .deps = comptime brk: {
                    var deps: [n_deps]meta.TypeId = undefined;
                    for (0..n_deps) |i| deps[i] = meta.typeId(fields[i].type);
                    const res = deps;
                    break :brk &res;
                },
                .exchange = exchange,
                .route = route,
                .queue = queue,
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
            comptime metadata: Self.Metadata,
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

                    var inj_args: std.meta.Tuple(&.{*injector.Injector}) = undefined;
                    inj_args[0] = inj;
                    const exchange = try @call(.auto, metadata.exchange, inj_args);
                    const route = try @call(.auto, metadata.route, inj_args);

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
            comptime metadata: Self.Metadata,
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
            comptime metadata: Self.Metadata,
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

                    var inj_args: std.meta.Tuple(&.{*injector.Injector}) = undefined;
                    inj_args[0] = inj;
                    const route = try @call(.auto, metadata.route, inj_args);

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
            comptime metadata: Self.Metadata,
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

        fn publish(exchange: RouteHandlerFn, route: RouteHandlerFn, comptime queue: ?RouteHandlerFn, comptime event_handler: anytype, comptime handler: anytype) Self {
            if (comptime queue != null) @compileError("You cannot specify a queue while publishing");
            const metadata = comptime routeMetadata(handler, exchange, route, queue);
            const e_metadata = comptime routeMetadata(event_handler, exchange, route, queue);
            return .{
                .method = .publish,
                .handlers = .{
                    .publish = publishHandler(metadata, handler),
                    .event = eventHandler(e_metadata, event_handler),
                },
                .metadata = &metadata,
            };
        }

        fn consume(exchange: RouteHandlerFn, route: RouteHandlerFn, queue: ?RouteHandlerFn, comptime event_handler: anytype, comptime handler: anytype) Self {
            _ = event_handler;
            const metadata = comptime routeMetadata(handler, exchange, route, queue);
            return .{
                .method = .consume,
                .handlers = .{ .consume = consumeHandler(metadata, handler) },
                .metadata = &metadata,
            };
        }

        fn reply(exchange: RouteHandlerFn, route: RouteHandlerFn, queue: ?RouteHandlerFn, comptime event_handler: anytype, comptime handler: anytype) Self {
            _ = event_handler;
            const metadata = comptime routeMetadata(handler, exchange, route, queue);
            return .{
                .method = .reply,
                .handlers = .{ .reply = replyHandler(metadata, handler) },
                .metadata = &metadata,
            };
        }
    };
}
