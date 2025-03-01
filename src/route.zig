const std = @import("std");

const meta = @import("meta.zig");
const mem = @import("mem.zig");
const schema = @import("schema.zig");
const injector = @import("injector.zig");

pub const Method = enum {
    publish,
    consume,
};

fn HandlerFn(comptime T: type) type {
    return *const fn (*injector.Injector) T;
}

const PublishHandlerFn = HandlerFn(anyerror!schema.SendMessage);
const EventHandlerFn = HandlerFn(anyerror!bool);
const ConsumeHandlerFn = *const fn (*injector.Injector, []const u8) anyerror!void;

pub const Handlers = struct {
    event: ?EventHandlerFn = null,
    publish: ?PublishHandlerFn = null,
    consume: ?ConsumeHandlerFn = null,
};

pub const Route = struct {
    method: Method,
    handlers: Handlers,
    metadata: *const Metadata,

    const Metadata = struct {
        deps: []const meta.TypeId,
        errors: []const anyerror,
        queue: []const u8,
        exchange: []const u8,
    };

    pub fn from(comptime ContainerType: type, comptime EventProvider: type) []const Route {
        meta.ensureStruct(ContainerType);

        const routes = comptime blk: {
            @setEvalBranchQuota(@typeInfo(ContainerType).@"struct".decls.len * 100);
            var res: []const Route = &.{};

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
                ) orelse @compileError("route must contain an exchange");
                const exchange = route[0..end_of_exchange];
                const queue = route[end_of_exchange + 1 ..];

                res = res ++ .{@field(@This(), method)(exchange, queue, event_handler, @field(ContainerType, d.name))};
            }

            break :blk res;
        };

        return routes;
    }

    fn routeMetadata(
        comptime handler: anytype,
        exchange: []const u8,
        queue: []const u8,
    ) Route.Metadata {
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
        comptime metadata: Route.Metadata,
        comptime handler: anytype,
    ) PublishHandlerFn {
        const n_deps = metadata.deps.len;

        const Internal = struct {
            fn handle(inj: *injector.Injector) !schema.SendMessage {
                var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;

                inline for (0..n_deps) |i| {
                    args[i] = try inj.require(@TypeOf(args[i]));
                }

                const maybe_result = @call(.auto, handler, args);

                const result =
                    switch (comptime @typeInfo(meta.Return(handler))) {
                        .error_union => try maybe_result,
                        else => maybe_result,
                    };

                var arena = try inj.require(mem.InternalArena);
                const alloc = arena.allocator();
                const body = try std.json.stringifyAlloc(alloc, result, .{});

                return .{
                    .body = body,
                    .options = .{
                        .exchange = metadata.exchange,
                        .queue = metadata.queue,
                        .routing_key = metadata.queue,
                    },
                };
            }
        };

        return &Internal.handle;
    }

    fn consumeHandler(
        comptime metadata: Route.Metadata,
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

                args[0] = try std.json.parseFromSliceLeaky(@TypeOf(args[0]), allocator, body, .{});

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

    fn eventHandler(
        comptime metadata: Route.Metadata,
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

    fn publish(exchange: []const u8, queue: []const u8, comptime event_handler: anytype, comptime handler: anytype) Route {
        const metadata = comptime routeMetadata(handler, exchange, queue);
        const e_metadata = comptime routeMetadata(event_handler, exchange, queue);
        return .{
            .method = .publish,
            .handlers = .{
                .publish = publishHandler(metadata, handler),
                .event = eventHandler(e_metadata, event_handler),
            },
            .metadata = &metadata,
        };
    }

    fn consume(exchange: []const u8, queue: []const u8, comptime event_handler: anytype, comptime handler: anytype) Route {
        _ = event_handler;
        const metadata = comptime routeMetadata(handler, exchange, queue);
        return .{
            .method = .consume,
            .handlers = .{ .consume = consumeHandler(metadata, handler) },
            .metadata = &metadata,
        };
    }
};
