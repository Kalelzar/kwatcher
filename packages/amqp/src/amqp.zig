const std = @import("std");
const klib = @import("klib");
const core = @import("kw-core");

pub const Client = @import("client/client.zig");
const schema = core.schema;
const conftype = core.config.BaseConfig;
const cache = @import("kw-cache");
const mem = core.mem;
const InternFmtCache = core.InternFmtCache;
const AmqpTemplate = @import("Amqp.zig");

const meta = core.meta;
const dep = core.deps;
const shared = core.shared;
const server = core;
const EventProperties = core.event.Properties;
const EventPropertiesEx = core.event.ExtendedProperties;
const Event = core.event.Event;
const MPMCQueue = core.queue.StaticStrict;

pub const kind = .amqp;

pub const default = @import("amqp/default.zig").default;
pub const defaultFor = @import("amqp/default.zig").defaultFor;
pub const Pool = @import("amqp/pool.zig").ClientPool;

pub const clients = @import("client/client.zig");

pub const Method = enum {
    publish,
    consume,
    reply,
    provide,
    unrouted,
    rejected,
};

pub const Driver = shared.DriverBuilder(DriverBuilder, true);

pub fn Provided(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        value: T,

        pub fn init(value: T, allocator: std.mem.Allocator) @This() {
            return .{
                .value = value,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This(), pool: *mem.PoolAllocator) void {
            pool.reset(self.allocator) catch {};
        }
    };
}

fn FilterRoutes(comptime Rs: []const type, comptime method: anytype) []const type {
    const count = comptime blk: {
        var count = 0;
        for (Rs) |R| {
            if (R.method == method) count += 1;
        }
        break :blk count;
    };

    const Nrs = comptime blk: {
        var Nrs: [count]type = undefined;
        var i = 0;
        for (Rs) |R| {
            if (R.method == method) {
                Nrs[i] = R;
                i += 1;
            }
        }

        break :blk Nrs;
    };

    return &Nrs;
}

fn ConstructProviders(comptime Rs: []const type) []const struct { type, type } {
    const Ts = comptime blk: {
        var Ts: [Rs.len]struct { type, type } = undefined;
        for (Rs, 0..) |R, i| {
            Ts[i] = .{ R.CallContext, R.Handler.Invariant };
        }

        break :blk Ts;
    };

    return &Ts;
}

fn Unwrap(comptime I: type) []const type {
    switch (@typeInfo(I)) {
        .@"struct" => |s| {
            if (comptime !s.is_tuple) @compileError("Can only unwrap a tuple");
            const fields = s.fields;
            const res = comptime blk: {
                var res: [fields.len]type = undefined;
                for (fields, 0..) |field, i| {
                    res[i] = field.type;
                }
                break :blk res;
            };
            return &res;
        },
        else => @compileError("Can only unwrap a tuple"),
    }
}

fn EnsureProvider(comptime key: @Type(.enum_literal), comptime R: type, comptime I: type) type {
    return struct {
        const Static = cache.context.memory.Container(
            cache.context.memory.Cache(Provided(R), Unwrap(I))
                .key(key)
                .evict(.none)
                .residency(.{ .unlimited = {} })
                .expiration(.{ .unlimited = {} }),
        );

        pub fn apply(
            dephub: anytype,
            comptime category: anytype,
            allocator: std.mem.Allocator,
            comptime Config: type,
        ) Return(category, Config, @TypeOf(dephub)) {
            const H = struct {
                var fixme_move_elsewhere_cache = Static{};
            };

            return dephub.static(category, &H.fixme_move_elsewhere_cache, allocator);
        }

        pub fn Return(comptime category: anytype, comptime Config: type, comptime DH: type) type {
            _ = Config;
            return DH.Static(category, *Static);
        }
    };
}

fn ProvideAll(comptime Rs: []const struct { type, type }) type {
    return struct {
        fn applyNext(
            dephub: anytype,
            comptime category: anytype,
            allocator: std.mem.Allocator,
            comptime i: comptime_int,
        ) ReturnNext(category, @TypeOf(dephub), i) {
            if (comptime i >= Rs.len) {
                return dephub;
            } else {
                const Data, const Invariant = Rs[i];
                const C = EnsureProvider(.todo, Data, Invariant);
                return applyNext(
                    C.apply(dephub, category, allocator, void),
                    category,
                    allocator,
                    i + 1,
                );
            }
        }

        pub fn apply(
            dephub: anytype,
            comptime category: anytype,
            allocator: std.mem.Allocator,
            comptime Config: type,
        ) Return(category, Config, @TypeOf(dephub)) {
            return applyNext(dephub, category, allocator, 0);
        }

        fn ReturnNext(comptime category: anytype, comptime DH: type, comptime i: comptime_int) type {
            if (comptime i >= Rs.len) {
                return DH;
            } else {
                const Data, const Invariant = Rs[i];
                const C = EnsureProvider(.todo, Data, Invariant);
                return ReturnNext(category, C.Return(category, void, DH), i + 1);
            }
        }

        pub fn Return(comptime category: anytype, comptime Config: type, comptime DH: type) type {
            _ = Config;
            return ReturnNext(category, DH, 0);
        }
    };
}

pub fn DriverBuilder(
    comptime driver_key: @Type(.enum_literal),
    comptime config: []const u8,
    comptime listen: bool,
    comptime _jobs: comptime_int,
    comptime Routes: []const type,
    comptime ErrorHandler: type,
) *const fn (comptime u12) type {
    _ = ErrorHandler;
    const H = struct {
        pub fn AmqpHandler(comptime block_start: u12) type {
            return struct {
                pub const ConfigType = conftype;
                pub const config_path = config;
                pub const jobs = _jobs;
                pub const key = driver_key;
                pub const RouteKeys = shared.EnumerateRoutes(Routes);
                pub const PubRoutes = FilterRoutes(Routes, .publish);
                pub const PubRouteKeys = shared.EnumerateRoutes(PubRoutes);
                pub const PubCallContext = shared.UniteCallContext(PubRoutes);
                pub const UnroutedRoutes = FilterRoutes(Routes, .unrouted);
                pub const UnroutedRouteKeys = shared.EnumerateRoutes(UnroutedRoutes);
                pub const UnroutedCallContext = shared.UniteCallContext(UnroutedRoutes);
                pub const ConsRoutes = FilterRoutes(Routes, .consume) ++ FilterRoutes(Routes, .reply) ++ FilterRoutes(Routes, .provide);
                pub const ProviderRoutes = FilterRoutes(Routes, .provide);
                pub const ConsRouteKeys = shared.EnumerateRoutes(ConsRoutes);
                pub const ConsCallContext = shared.UniteCallContext(ConsRoutes);
                pub const Dependencies = shared.MergeDeps(
                    Routes,
                    &.{ Client, std.mem.Allocator },
                );

                pub const Provides = ConstructProviders(ProviderRoutes);
                pub const DependencyContext = ProvideAll(Provides);

                pub const map = shared.RouteMap(Routes);

                pub const EventType = enum(u12) {
                    send = block_start,
                    recv,
                    unrouted,
                    __end,
                };

                pub const PublishData = PubCallContext;

                const ConsumeData = struct {
                    consumer_tag: ConsRouteKeys,
                    body: []const u8,
                    internal: Client.Response,

                    pub fn write(self: ConsumeData, w: *std.Io.Writer) !void {
                        _ = self;
                        try w.writeAll(".{ .type = AmqpConsume }");
                    }
                };

                const UnroutedData = struct {
                    publisher_tag: UnroutedRouteKeys,
                    body: []const u8,
                    internal: Client.ReturnedMessage,

                    pub fn write(self: UnroutedData, w: *std.Io.Writer) !void {
                        _ = self;
                        try w.writeAll(".{ .type = AmqpUnrouted }");
                    }
                };

                pub const EventValues = union(EventType) {
                    send: PublishData,
                    recv: ConsumeData,
                    unrouted: UnroutedData,
                    __end: struct {},
                };

                pub inline fn __block_end() u12 {
                    comptime {
                        return @intFromEnum(@This().EventType.__end);
                    }
                }

                pub fn Yield(comptime ET: type, comptime EV: type) type {
                    const E = Event(ET, EV);
                    return struct {
                        queue: ?*MPMCQueue(E) = null,
                        cond: std.Thread.Condition = .{},
                        mutex: std.Thread.Mutex = .{},
                        should_run: bool = true,
                        const Self = @This();
                        pub const accepts = server.genAccepts(ET, EventType);
                        pub const Scheduler = struct {
                            parent: *Self,

                            pub fn publish(self: @This(), data: PublishData, extra: struct { inj: ?*dep.DepCtx = null }) !void {
                                const value = @unionInit(
                                    EV,
                                    @tagName(key),
                                    .{
                                        .send = data,
                                    },
                                );

                                var ev = E{
                                    .event_data = value,
                                    .event_type = .send,
                                };

                                if (extra.inj) |inj| {
                                    const p = try inj.require(EventProperties);
                                    ev.properties.correlation_id = p.correlation_id;
                                }

                                _ = self.parent.queue.?.tryPush(
                                    ev,
                                    std.time.ns_per_ms * 1,
                                ) catch |e| switch (e) {
                                    error.WouldBlock => {
                                        // FIXME: Words
                                        // Ideally we would want to be able to do:
                                        // But we can't get an injector for our handler at the
                                        // moment.
                                        // We could accept an injector from outside but there
                                        // is no gurantee that it was built for our invariant.
                                        // The dependency system should allow us to request injectors for other uses.
                                        // That's the fix.
                                        // self.parent.handle(.trigger_job, ev, ???);
                                        @panic("Preemptive execution is not implemented!");
                                    },
                                    else => return e,
                                };
                            }

                            pub fn publishLater(self: @This(), data: PublishData) E {
                                _ = self;
                                const value = @unionInit(
                                    EV,
                                    @tagName(key),
                                    .{
                                        .send = data,
                                    },
                                );

                                const ev = E{
                                    .event_data = value,
                                    .event_type = .send,
                                };

                                return ev;
                            }
                        };

                        pub fn init() @This() {
                            return .{};
                        }

                        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            _ = allocator;

                            inline for (ConsRoutes) |CR| {
                                const RRT = @TypeOf(CR.routing_key).TemplateType;
                                const RET = @TypeOf(CR.exchange).TemplateType;
                                if (comptime RRT == .dependant) {
                                    CR.routing_key.deinit();
                                }
                                if (comptime RET == .dependant) {
                                    CR.exchange.deinit();
                                }
                            }
                        }

                        fn dispatchPublish(
                            k: PubRouteKeys,
                            inj: *dep.DepCtx,
                            ctx: PubCallContext,
                            evprop: EventPropertiesEx,
                        ) anyerror!schema.SendMessage {
                            switch (k) {
                                inline else => |e| {
                                    const idx = comptime @intFromEnum(e);
                                    const R = comptime PubRoutes[idx];
                                    const rctx = @field(ctx, @tagName(e));
                                    return try @call(
                                        .auto,
                                        R.call,
                                        .{ inj, rctx, evprop },
                                    );
                                },
                            }
                        }

                        fn dispatchUnrouted(
                            k: UnroutedRouteKeys,
                            inj: *dep.DepCtx,
                            event: *const UnroutedData,
                            evprop: EventPropertiesEx,
                        ) anyerror!void {
                            if (comptime ConsRoutes.len == 0) return;
                            defer @constCast(event).internal.deinit();
                            switch (k) {
                                inline else => |e| {
                                    const idx = comptime @intFromEnum(e);
                                    const R = comptime UnroutedRoutes[idx];
                                    const RCtx = comptime @FieldType(UnroutedCallContext, @tagName(e));
                                    const allocator = try inj.require(std.mem.Allocator);
                                    const rctx = std.json.parseFromSlice(
                                        RCtx,
                                        allocator,
                                        event.body,
                                        .{},
                                    ) catch |er| blk: {
                                        std.log.warn("Error encountered while parsing schema: {}", .{er});
                                        break :blk try std.json.parseFromSlice(
                                            RCtx,
                                            allocator,
                                            event.body,
                                            .{
                                                .duplicate_field_behavior = .use_last,
                                                .ignore_unknown_fields = true,
                                            },
                                        );
                                    };
                                    defer rctx.deinit();
                                    return @call(
                                        .auto,
                                        R.call,
                                        .{ inj, rctx.value, evprop },
                                    );
                                },
                            }
                        }

                        fn dispatchConsume(
                            k: ConsRouteKeys,
                            inj: *dep.DepCtx,
                            ctx: []const u8,
                            evprop: EventPropertiesEx,
                            event: *const ConsumeData,
                            client: Client,
                        ) anyerror!void {
                            if (comptime ConsRoutes.len == 0) return;
                            switch (k) {
                                inline else => |e| {
                                    std.debug.assert(std.meta.activeTag(event.internal) == .incoming);
                                    const idx = comptime @intFromEnum(e);
                                    const R = comptime ConsRoutes[idx];
                                    const RCtx = comptime @FieldType(ConsCallContext, @tagName(e));
                                    const allocator = try inj.require(std.mem.Allocator);
                                    const rctx = std.json.parseFromSlice(
                                        RCtx,
                                        allocator,
                                        ctx,
                                        .{},
                                    ) catch |er| blk: {
                                        std.log.warn("Error encountered while parsing schema: {}", .{er});
                                        break :blk try std.json.parseFromSlice(
                                            RCtx,
                                            allocator,
                                            ctx,
                                            .{
                                                .duplicate_field_behavior = .use_last,
                                                .ignore_unknown_fields = true,
                                            },
                                        );
                                    };
                                    defer rctx.deinit();

                                    if (comptime R.method == .reply) {
                                        var h = try @call(.auto, R.call, .{ inj, rctx.value, evprop });

                                        const route = event.internal.incoming.message.basic_properties.reply_to;

                                        if (route) |r| {
                                            h.options.routing_key = r;
                                        } else {
                                            h.options.routing_key = event.internal.incoming.routing_key;
                                        }

                                        if (h.options.correlation_id == null) {
                                            var correlation_id: [128]u8 = undefined;
                                            const end = std.fmt.printInt(
                                                &correlation_id,
                                                evprop.correlation_id,
                                                10,
                                                .lower,
                                                .{},
                                            );
                                            h.options.correlation_id = correlation_id[0..end];
                                        }

                                        try client.publish(h, .{});
                                    } else {
                                        return @call(
                                            .auto,
                                            R.call,
                                            .{ inj, rctx.value, evprop },
                                        );
                                    }
                                },
                            }
                        }

                        pub fn bind(self: *@This(), queue: *MPMCQueue(E)) void {
                            self.queue = queue;
                        }

                        pub fn scheduler(self: *@This()) Scheduler {
                            return .{
                                .parent = self,
                            };
                        }

                        pub fn watch(
                            self: *@This(),
                            wg: *std.Thread.WaitGroup,
                            pool: *std.Thread.Pool,
                            arc: anytype,
                        ) anyerror!void {
                            if (!listen or jobs == 0) {
                                arc.deinit();
                                return;
                            }

                            for (0..jobs) |_| {
                                pool.spawnWg(wg, watch_inner, .{ self, arc });
                            }
                        }

                        pub fn watch_inner(self: *@This(), arc: anytype) void {
                            //FIXME: This is shared by all threads and subsequently the client is shared which causes binding errors. This should not happen.
                            const inj: *dep.DepCtx = &arc.ref().data;
                            defer arc.unref();

                            outer: while (@atomicLoad(bool, &self.should_run, .acquire)) {
                                const client = inj.require(Client) catch unreachable;
                                const alloc = inj.require(std.mem.Allocator) catch unreachable;
                                var dependant_bindings = std.ArrayList(*shared.DTValue){};
                                defer {
                                    for (dependant_bindings.items) |arcval| {
                                        arcval.unref();
                                    }
                                    dependant_bindings.deinit(alloc);
                                }
                                inline for (ConsRoutes, 0..) |CR, i| {
                                    const r = CR.routing_key.get(inj) catch unreachable;
                                    const rstr = if (@TypeOf(r) == *shared.DTValue) blk: {
                                        dependant_bindings.append(alloc, r) catch unreachable;
                                        break :blk r.ref().data.value;
                                    } else r;
                                    const e = CR.exchange.get(inj) catch unreachable;
                                    const estr = if (@TypeOf(e) == *shared.DTValue) blk: {
                                        dependant_bindings.append(alloc, e) catch unreachable;
                                        break :blk e.ref().data.value;
                                    } else e;

                                    const tag: ConsRouteKeys = comptime @enumFromInt(i);
                                    const static = comptime @tagName(tag);
                                    const dyn = alloc.dupe(u8, static) catch unreachable;
                                    std.log.info("[{d},{d}] Binding {s}({s}): {s},{s}", .{
                                        i,
                                        std.Thread.getCurrentId(),
                                        static,
                                        dyn,
                                        rstr,
                                        estr,
                                    });
                                    _ = client.bind(
                                        null,
                                        rstr,
                                        estr,
                                        .{
                                            .channel_name = null,
                                            .consumer_tag = dyn,
                                        },
                                    ) catch {
                                        client.disconnect() catch {};
                                        continue :outer;
                                    };
                                }
                                inner: while (@atomicLoad(bool, &self.should_run, .acquire)) {
                                    var u: usize = 0;
                                    inline for (ConsRoutes, 0..) |CR, i| {
                                        const r = CR.routing_key.get(inj) catch unreachable;
                                        const e = CR.exchange.get(inj) catch unreachable;
                                        const RRT = @TypeOf(r);
                                        const RET = @TypeOf(e);
                                        if (RRT == []const u8 and RET == []const u8) continue;
                                        var should_update_r = false;
                                        var should_update_e = false;
                                        const rstr = if (@TypeOf(r) == *shared.DTValue) blk: {
                                            defer u += 1;
                                            const exisiting = dependant_bindings.items[u];

                                            if (exisiting.data.data.invariant == r.data.data.invariant) {
                                                break :blk exisiting.data.data.value;
                                            }
                                            should_update_r = true;

                                            exisiting.unref();
                                            dependant_bindings.items[u] = r;

                                            break :blk r.ref().data.value;
                                        } else r;
                                        const estr = if (@TypeOf(e) == *shared.DTValue) blk: {
                                            defer u += 1;
                                            const exisiting = dependant_bindings.items[u];

                                            if (exisiting.data.data.invariant == e.data.data.invariant) {
                                                break :blk exisiting.data.data.value;
                                            }
                                            should_update_e = true;

                                            exisiting.unref();
                                            dependant_bindings.items[u] = e;

                                            break :blk e.ref().data.value;
                                        } else e;

                                        if (should_update_e or should_update_r) {
                                            const tag: ConsRouteKeys = comptime @enumFromInt(i);
                                            const static = comptime @tagName(tag);
                                            const dyn = alloc.dupe(u8, static) catch unreachable;
                                            client.unbind(dyn, .{ .channel_name = null }) catch {};
                                            _ = client.bind(
                                                null,
                                                rstr,
                                                estr,
                                                .{
                                                    .channel_name = null,
                                                    .consumer_tag = dyn,
                                                },
                                            ) catch {
                                                client.disconnect() catch {};
                                                continue :outer;
                                            };
                                        }
                                    }
                                    var msg = client.consume(500000) catch |e| {
                                        std.log.warn(
                                            "Encountered an error '{s}' while consuming from queue.",
                                            .{@errorName(e)},
                                        );
                                        continue :outer;
                                    };
                                    if (msg == null) continue;

                                    switch (msg.?) {
                                        .returned => |ret| {
                                            const headers = ret.message.basic_properties.headers;
                                            if (headers.get("x-publisher-key")) |pub_key| {
                                                std.log.info("Unrouted to: {s}", .{pub_key});
                                                const unroute_key = std.meta.stringToEnum(UnroutedRouteKeys, pub_key);
                                                //FIXME: Validate that the the context is the same as the output of the publisher. This feels like the wrong place for that though.
                                                if (unroute_key) |k| {
                                                    const data = UnroutedData{
                                                        .body = ret.message.body,
                                                        .publisher_tag = k,
                                                        .internal = ret,
                                                    };
                                                    const correlation_id = ret.message.basic_properties.correlation_id;
                                                    const val = @unionInit(
                                                        EV,
                                                        @tagName(key),
                                                        .{ .unrouted = data },
                                                    );

                                                    _ = self.queue.?.tryPush(.{
                                                        .event_type = .unrouted,
                                                        .event_data = val,
                                                        .properties = .{
                                                            .correlation_id = if (correlation_id) |c|
                                                                std.fmt.parseInt(u128, c, 10) catch 0
                                                            else
                                                                0,
                                                        },
                                                    }, std.time.ns_per_ms * 1) catch {};
                                                } else {
                                                    std.log.warn("Dropping unhandled unrouted message: {s}", .{pub_key});
                                                    continue :inner;
                                                }
                                            }
                                        },
                                        .incoming => |*in| {
                                            const consumer_tag = std.meta.stringToEnum(ConsRouteKeys, in.consumer_tag);
                                            if (consumer_tag == null) @panic("Unknown message");

                                            const data = ConsumeData{
                                                .body = in.message.body,
                                                .consumer_tag = consumer_tag.?,
                                                .internal = msg.?, // FIXME: Maybe this should just pass the MessageResponse so we avoid having to check again in the handler?
                                            };

                                            defer client.reset();

                                            const correlation_id = in.message.basic_properties.correlation_id;

                                            const val = @unionInit(
                                                EV,
                                                @tagName(key),
                                                .{ .recv = data },
                                            );

                                            _ = self.queue.?.tryPush(.{
                                                .event_type = .recv,
                                                .event_data = val,
                                                .properties = .{
                                                    .correlation_id = if (correlation_id) |c|
                                                        std.fmt.parseInt(u128, c, 10) catch 0
                                                    else
                                                        0,
                                                },
                                            }, std.time.ns_per_ms * 1) catch {
                                                client.reject(in.delivery_tag, true, .{}) catch |e| {
                                                    std.log.warn(
                                                        "Encountered an error '{s}' while rejecting a message.",
                                                        .{@errorName(e)},
                                                    );
                                                };
                                                in.deinit();
                                                continue;
                                            };

                                            //FIXME: This should happen after a successful publish/consume instead.
                                            client.ack(in.delivery_tag, .{}) catch |e| {
                                                std.log.warn(
                                                    "Encountered an error '{s}' while acking a message {d}.",
                                                    .{ @errorName(e), in.delivery_tag },
                                                );
                                                continue :outer;
                                            };
                                        },
                                    }
                                }
                            }
                        }

                        pub fn stop(self: *@This()) void {
                            @atomicStore(bool, &self.should_run, false, .release);
                            self.cond.broadcast();
                        }

                        pub fn handle(self: *@This(), comptime ehint: ET, event: E, inj: *dep.DepCtx) anyerror!void {
                            const et: EventType = comptime @enumFromInt(@intFromEnum(ehint));
                            const ev: EventValues = @field(event.event_data, @tagName(key));

                            const ep = EventPropertiesEx{
                                .attempts = event.properties.attempts,
                                .correlation_id = event.properties.correlation_id,
                                .type = comptime @tagName(ehint),
                                .driver = comptime @tagName(key),
                            };

                            try switch (et) {
                                inline .send => inj.call_first(publish, .{
                                    self,
                                    ev.send,
                                    ep,
                                }),
                                inline .recv => inj.call_first(consume, .{
                                    self,
                                    ev.recv,
                                    ep,
                                }),
                                inline .unrouted => inj.call_first(unrouted, .{
                                    self,
                                    ev.unrouted,
                                    ep,
                                }),
                                inline else => @compileError("Invalid handler mapping!"),
                            };
                        }

                        fn publish(
                            self: *@This(),
                            event: PublishData,
                            evprop: EventPropertiesEx,
                            inj: *dep.DepCtx,
                            client: Client,
                        ) anyerror!void {
                            const route = std.meta.activeTag(event);
                            var h = try dispatchPublish(
                                route,
                                inj,
                                event,
                                evprop,
                            );
                            if (h.options.correlation_id == null) {
                                var correlation_id: [128]u8 = undefined;
                                const end = std.fmt.printInt(
                                    &correlation_id,
                                    evprop.correlation_id,
                                    10,
                                    .lower,
                                    .{},
                                );
                                h.options.correlation_id = correlation_id[0..end];
                            }
                            // std.log.info("Publish: {t}", .{route});
                            try client.publish(h, .{});

                            const ret = try client.getReturns(0);

                            if (ret == null) return;

                            const headers = ret.?.message.basic_properties.headers;
                            if (headers.get("x-publisher-key")) |pub_key| {
                                std.log.info("Unrouted to: {s}", .{pub_key});
                                const unroute_key = std.meta.stringToEnum(UnroutedRouteKeys, pub_key);
                                //FIXME: Validate that the the context is the same as the output of the publisher. This feels like the wrong place for that though.
                                if (unroute_key) |k| {
                                    const data = UnroutedData{
                                        .body = ret.?.message.body,
                                        .publisher_tag = k,
                                        .internal = ret.?,
                                    };
                                    const correlation_id = ret.?.message.basic_properties.correlation_id;
                                    const val = @unionInit(
                                        EV,
                                        @tagName(key),
                                        .{ .unrouted = data },
                                    );

                                    _ = self.queue.?.tryPush(.{
                                        .event_type = .unrouted,
                                        .event_data = val,
                                        .properties = .{
                                            .correlation_id = if (correlation_id) |c|
                                                std.fmt.parseInt(u128, c, 10) catch 0
                                            else
                                                0,
                                        },
                                    }, std.time.ns_per_ms * 1) catch unreachable;
                                } else {
                                    std.log.warn("Dropping unhandled unrouted message: {s}", .{pub_key});
                                }
                            }
                        }

                        fn unrouted(
                            self: *@This(),
                            event: UnroutedData,
                            evprop: EventPropertiesEx,
                            injector: *dep.DepCtx,
                        ) anyerror!void {
                            _ = self;
                            try dispatchUnrouted(
                                event.publisher_tag,
                                injector,
                                &event,
                                evprop,
                            );
                        }

                        fn consume(
                            self: *@This(),
                            event: ConsumeData,
                            evprop: EventPropertiesEx,
                            injector: *dep.DepCtx,
                            client: Client,
                        ) anyerror!void {
                            _ = self;
                            defer @constCast(&event.internal).deinit();
                            const route = event.consumer_tag;
                            try dispatchConsume(
                                route,
                                injector,
                                event.body,
                                evprop,
                                &event,
                                client,
                            );
                        }
                    };
                }
            };
        }
    };

    return H.AmqpHandler;
}

pub const CapabilityType = enum {
    method,
    routing_key,
    exchange,
};

pub fn Capability(comptime ET: type, comptime RT: type) type {
    return union(CapabilityType) {
        method: Method,
        routing_key: RT,
        exchange: ET,
    };
}

pub fn From(comptime Container: type, comptime Context: type) []type {
    const routes = comptime blk: {
        var rp = RouteParser(Context){ .routes = &.{} };

        for (std.meta.declarations(Container)) |d| {
            if (@typeInfo(@TypeOf(@field(Container, d.name))) != .@"fn") continue;
            rp = rp.parse(Container, d.name);
        }

        break :blk rp.routes;
    };

    return routes;
}

pub fn RouteBase(
    comptime m: Method,
    comptime exchange_template: anytype,
    comptime routing_key_template: anytype,
    comptime HandlerFac: anytype,
    comptime parsed_id: []const u8,
    comptime ev_id: @Type(.enum_literal),
) type {
    const ET = @TypeOf(exchange_template);
    const RT = @TypeOf(routing_key_template);
    return struct {
        pub const Handler = HandlerFac(@This());
        pub const event_id = ev_id;
        pub const method = m;
        pub var exchange = exchange_template;
        pub var routing_key = routing_key_template;
        pub const id = parsed_id;

        pub const CallContext = Handler.CallContext;
        pub const Dependencies = Handler.Dependencies;
        pub const call = Handler.call;
        pub const name = Handler.name;

        pub fn swap(comptime NextHandler: anytype) type {
            return RouteBase(
                m,
                exchange_template,
                routing_key_template,
                NextHandler,
                parsed_id,
                event_id,
            );
        }

        pub fn wrap(comptime NextHandlerFac: anytype) type {
            return RouteBase(
                m,
                exchange_template,
                routing_key_template,
                NextHandlerFac(HandlerFac).make, // FIXME: This is very gross.
                parsed_id,
                event_id,
            );
        }

        pub fn requires(comptime ct: anytype) void {
            if (comptime !meta.hasKey(CapabilityType, ct)) {
                @compileError(
                    "Required capability '" ++ @tagName(ct) ++ "' is not supported by AMQP routes.",
                );
            }
        }

        pub fn satisfies(comptime ct: anytype) bool {
            return meta.hasKey(CapabilityType, ct);
        }

        pub fn mod(
            comptime capability: Capability(ET, RT),
        ) type {
            return switch (capability) {
                inline .method => |mt| RouteBase(
                    mt,
                    exchange_template,
                    routing_key_template,
                    HandlerFac,
                    parsed_id,
                    ev_id,
                ),
                inline .exchange => |ex| RouteBase(
                    m,
                    ex,
                    routing_key_template,
                    HandlerFac,
                    parsed_id,
                    ev_id,
                ),
                inline .routing_key => |rk| RouteBase(
                    m,
                    exchange_template,
                    rk,
                    HandlerFac,
                    parsed_id,
                    ev_id,
                ),
            };
        }

        pub fn query(comptime ct: anytype) @FieldType(
            Capability(ET, RT),
            @tagName(ct),
        ) {
            requires(ct);
            return switch (ct) {
                .method => m,
                .exchange => exchange_template,
                .routing_key => routing_key_template,
                else => unreachable,
            };
        }
    };
}

pub fn RouteParser(comptime Context: type) type {
    return struct {
        routes: []type,

        fn extend(comptime self: @This(), comptime Other: type) @This() {
            comptime {
                const routes = blk: {
                    var routes: [self.routes.len + 1]type = undefined;
                    for (self.routes, 0..) |o, i| {
                        routes[i] = o;
                    }
                    routes[self.routes.len] = Other;
                    break :blk routes;
                };
                return .{
                    .routes = @constCast(&routes),
                };
            }
        }

        fn handlePublish(
            comptime ResultType: type,
            result: anytype,
            alloc: std.mem.Allocator,
            exchange: []const u8,
            route: []const u8,
            comptime norecord: bool,
            comptime pub_key: []const u8,
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
                const fmt = std.json.fmt(actual_result.schema, .{});
                var writer = std.io.Writer.Allocating.init(alloc);
                defer writer.deinit();
                const interface = &writer.writer;
                try fmt.format(interface);
                return .{
                    .body = try writer.toOwnedSlice(),
                    .options = .{
                        .exchange = exchange,
                        .routing_key = route,
                        .reply_to = opts.reply_to,
                        .correlation_id = opts.correlation_id,
                        .expiration = opts.expiration,
                        .norecord = norecord,
                        .publisher_key = pub_key,
                    },
                };
            } else {
                const fmt = std.json.fmt(actual_result, .{});
                var writer = std.io.Writer.Allocating.init(alloc);
                defer writer.deinit();
                const interface = &writer.writer;
                try fmt.format(interface);

                return .{
                    .body = try writer.toOwnedSlice(),
                    .options = .{
                        .exchange = exchange,
                        .routing_key = route,
                        .norecord = norecord,
                        .publisher_key = pub_key,
                    },
                };
            }
        }

        fn withPublish(
            comptime self: @This(),
            comptime pubexpr: AmqpTemplate.PublishExpr,
            comptime f: anytype,
        ) @This() {
            const exch = pubexpr.exchange;
            const exch_is_dynamically_bound = exch.params.len != 0;
            const ExType = if (exch_is_dynamically_bound)
                shared.FreeTemplate(Context, exch.raw, exch.fmt, exch.params)
            else
                shared.ComptimeTemplate(exch.raw);
            const ex_value: ExType = .{};
            const parsed_routing_key = pubexpr.route;
            const route_is_dynamically_bound = parsed_routing_key.params.len != 0;
            const RtType = if (route_is_dynamically_bound)
                shared.FreeTemplate(
                    Context,
                    parsed_routing_key.raw,
                    parsed_routing_key.fmt,
                    parsed_routing_key.params,
                )
            else
                shared.ComptimeTemplate(parsed_routing_key.raw);
            const rt_value: RtType = .{};

            const fargs = @typeInfo(@TypeOf(f)).@"fn".params;
            const has_context = comptime fargs.len > 0 and blk: {
                const ti = @typeInfo(fargs[0].type.?);
                switch (ti) {
                    .@"struct" => |s| break :blk s.is_tuple,
                    else => break :blk false,
                }
            };

            const di_start_idx = if (has_context) 1 else 0;
            const __CallContext = if (has_context) fargs[0].type.? else struct {};

            const __Dependencies = comptime blk: {
                var deps: [fargs.len - di_start_idx]type = undefined;
                for (fargs[di_start_idx..fargs.len], 0..) |a, i| {
                    deps[i] = a.type.?; // TODO: check when this could ever be null. How even?
                }
                break :blk deps;
            };

            const H = struct {
                pub fn make(comptime Base: type) type {
                    return struct {
                        pub const CallContext = __CallContext;
                        pub const Dependencies = __Dependencies ++ .{mem.ScopedAllocator} ++ if (exch_is_dynamically_bound or route_is_dynamically_bound) .{ *InternFmtCache, Context } else .{};

                        pub fn name(inj: *dep.DepCtx) ![]const u8 {
                            const allocator = try inj.require(std.mem.Allocator);
                            return std.fmt.allocPrint(
                                allocator,
                                "ampq: {t} {s}/{s}",
                                .{
                                    Base.method,
                                    try Base.exchange.get(inj),
                                    try Base.routing_key.get(inj),
                                },
                            );
                        }

                        pub fn call(
                            inj: *dep.DepCtx,
                            context: CallContext,
                            evprop: EventPropertiesEx,
                        ) anyerror!schema.SendMessage {
                            // TODO: If any of the requested types for injection are
                            // EventProperties we should inject this instead of pushing it to the
                            // injector.
                            _ = evprop;
                            var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
                            const ReturnType = klib.meta.Result(f);

                            inline for (0..di_start_idx) |i| {
                                args[i] = context;
                            }

                            inline for (di_start_idx..args.len) |i| {
                                args[i] = try inj.require(@TypeOf(args[i]));
                            }

                            const maybe_result = @call(.auto, f, args);

                            const result =
                                switch (comptime @typeInfo(klib.meta.Return(f))) {
                                    .error_union => try maybe_result,
                                    else => maybe_result,
                                };

                            switch (comptime @typeInfo(ReturnType)) {
                                .optional => {
                                    if (result == null) return error.Cancelled;
                                },
                                else => {},
                            }

                            // FIXME: Ideally we don't need this
                            const arena = try inj.require(mem.ScopedAllocator);
                            const alloc = arena.value;
                            return handlePublish(
                                ReturnType,
                                result,
                                alloc,
                                try Base.exchange.get(inj),
                                try Base.routing_key.get(inj),
                                pubexpr.norecord,
                                pubexpr.event.raw,
                            );
                        }
                    };
                }
            };

            const RB = RouteBase(
                .publish,
                ex_value,
                rt_value,
                H.make,
                pubexpr.event.raw,
                .send,
            );

            return self.extend(RB);
        }

        fn withConsume(
            comptime self: @This(),
            comptime consexpr: AmqpTemplate.ConsumeExpr,
            comptime f: anytype,
        ) @This() {
            const exch = consexpr.exchange;
            const exch_is_dynamically_bound = exch.params.len != 0;
            const ExType = if (exch_is_dynamically_bound)
                shared.DependantTemplate(Context, exch.raw, exch.fmt, exch.params)
            else
                shared.ComptimeTemplate(exch.raw);
            const ex_value: ExType = .{};
            const parsed_routing_key = consexpr.route;
            const route_is_dynamically_bound = parsed_routing_key.params.len != 0;
            const RtType = if (route_is_dynamically_bound)
                shared.DependantTemplate(
                    Context,
                    parsed_routing_key.raw,
                    parsed_routing_key.fmt,
                    parsed_routing_key.params,
                )
            else
                shared.ComptimeTemplate(parsed_routing_key.raw);
            const rt_value: RtType = .{};

            const fargs = @typeInfo(@TypeOf(f)).@"fn".params;

            const __CallContext = fargs[0].type.?;

            const __Dependencies = comptime blk: {
                var deps: [fargs.len - 1]type = undefined;
                for (fargs[1..fargs.len], 0..) |a, i| {
                    deps[i] = a.type.?; // TODO: check when this could ever be null. How even?
                }
                break :blk deps;
            };

            const H = struct {
                pub fn make(comptime Base: type) type {
                    return struct {
                        pub const CallContext = __CallContext;
                        pub const Dependencies = __Dependencies ++ if (exch_is_dynamically_bound or route_is_dynamically_bound) .{ std.mem.Allocator, Context } else .{};

                        pub fn name(inj: *dep.DepCtx) ![]const u8 {
                            const allocator = try inj.require(std.mem.Allocator);
                            return std.fmt.allocPrint(
                                allocator,
                                "ampq: {t} {s}/{s}",
                                .{
                                    Base.method,
                                    try Base.exchange.get(inj),
                                    try Base.routing_key.get(inj),
                                },
                            );
                        }

                        pub fn call(
                            inj: *dep.DepCtx,
                            context: CallContext,
                            evprop: EventPropertiesEx,
                        ) anyerror!void {
                            // TODO: If any of the requested types for injection are
                            // EventProperties we should inject this instead of pushing it to the
                            // injector.
                            _ = evprop;
                            var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
                            if (comptime std.meta.fields(@TypeOf(args)).len == 0) {
                                @compileError("Consumer routes need at least one parameter for the incoming message");
                            }

                            if (comptime !@hasField(@TypeOf(args[0]), "schema_name") or
                                !@hasField(@TypeOf(args[0]), "schema_version"))
                            {
                                @compileError("The first parameter of a consumer route has to be a schema.");
                            }

                            args[0] = context;

                            inline for (1..args.len) |i| {
                                args[i] = try inj.require(@TypeOf(args[i]));
                            }

                            if (comptime klib.meta.canBeError(f)) {
                                try @call(.auto, f, args);
                            } else {
                                @call(.auto, f, args);
                            }
                        }
                    };
                }
            };

            const RB = RouteBase(
                .consume,
                ex_value,
                rt_value,
                H.make,
                consexpr.event.raw,
                .recv,
            );

            return self.extend(RB);
        }

        fn withUnrouted(
            comptime self: @This(),
            comptime expr: AmqpTemplate.UnroutedExpr,
            comptime f: anytype,
        ) @This() {
            const fargs = @typeInfo(@TypeOf(f)).@"fn".params;

            const __CallContext = fargs[0].type.?;

            const __Dependencies = comptime blk: {
                var deps: [fargs.len - 1]type = undefined;
                for (fargs[1..fargs.len], 0..) |a, i| {
                    deps[i] = a.type.?; // TODO: check when this could ever be null. How even?
                }
                break :blk deps;
            };

            const H = struct {
                pub fn make(comptime Base: type) type {
                    return struct {
                        pub const CallContext = __CallContext;
                        pub const Dependencies = __Dependencies;

                        pub fn name(inj: *dep.DepCtx) ![]const u8 {
                            const allocator = try inj.require(std.mem.Allocator);
                            return std.fmt.allocPrint(
                                allocator,
                                "ampq: {t} depends on {s},{s}",
                                .{
                                    Base.method,
                                    try Base.exchange.get(inj),
                                    try Base.routing_key.get(inj),
                                },
                            );
                        }

                        pub fn call(
                            inj: *dep.DepCtx,
                            context: CallContext,
                            evprop: EventPropertiesEx,
                        ) anyerror!void {
                            // TODO: If any of the requested types for injection are
                            // EventProperties we should inject this instead of pushing it to the
                            // injector.
                            _ = evprop;
                            var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
                            if (comptime std.meta.fields(@TypeOf(args)).len == 0) {
                                @compileError("Unrouted routes need at least one parameter for the unrouted message");
                            }

                            if (comptime !@hasField(@TypeOf(args[0]), "schema_name") or
                                !@hasField(@TypeOf(args[0]), "schema_version"))
                            {
                                @compileError("The first parameter of an unrouted route has to be a schema.");
                            }

                            args[0] = context;

                            inline for (1..args.len) |i| {
                                args[i] = try inj.require(@TypeOf(args[i]));
                            }

                            if (comptime klib.meta.canBeError(f)) {
                                try @call(.auto, f, args);
                            } else {
                                @call(.auto, f, args);
                            }
                        }
                    };
                }
            };

            const RB = RouteBase(
                .unrouted,
                shared.LinkedTemplate(expr.event.raw){},
                shared.LinkedTemplate(expr.event.raw){},
                H.make,
                expr.event.raw,
                .unrouted,
            );

            return self.extend(RB);
        }

        fn withProvide(
            comptime self: @This(),
            comptime consexpr: AmqpTemplate.ProvideExpr,
            comptime f: anytype,
        ) @This() {
            const exch = consexpr.exchange;
            const exch_is_dynamically_bound = exch.params.len != 0;
            const ExType = if (exch_is_dynamically_bound)
                shared.DependantTemplate(Context, exch.raw, exch.fmt, exch.params)
            else
                shared.ComptimeTemplate(exch.raw);
            const ex_value: ExType = .{};
            const parsed_routing_key = consexpr.route;
            const route_is_dynamically_bound = parsed_routing_key.params.len != 0;
            const RtType = if (route_is_dynamically_bound)
                shared.DependantTemplate(
                    Context,
                    parsed_routing_key.raw,
                    parsed_routing_key.fmt,
                    parsed_routing_key.params,
                )
            else
                shared.ComptimeTemplate(parsed_routing_key.raw);
            const rt_value: RtType = .{};

            const fargs = @typeInfo(@TypeOf(f)).@"fn".params;

            const __CallContext = fargs[0].type.?;

            const __Dependencies = comptime blk: {
                var deps: [fargs.len - 1]type = undefined;
                for (fargs[1..fargs.len], 0..) |a, i| {
                    deps[i] = a.type.?; // TODO: check when this could ever be null. How even?
                }
                break :blk deps;
            };

            const H = struct {
                pub fn make(comptime Base: type) type {
                    return struct {
                        pub const CallContext = __CallContext;
                        pub const Invariant = klib.meta.Result(f);
                        pub const Dependencies = __Dependencies ++ .{cache.Cache(Provided(CallContext))} ++ if (exch_is_dynamically_bound or route_is_dynamically_bound) .{ std.mem.Allocator, Context } else .{};

                        pub fn name(inj: *dep.DepCtx) ![]const u8 {
                            const allocator = try inj.require(std.mem.Allocator);
                            return std.fmt.allocPrint(
                                allocator,
                                "ampq: {t} {s}/{s}",
                                .{
                                    Base.method,
                                    try Base.exchange.get(inj),
                                    try Base.routing_key.get(inj),
                                },
                            );
                        }

                        pub fn call(
                            inj: *dep.DepCtx,
                            context: CallContext,
                            evprop: EventPropertiesEx,
                        ) anyerror!void {
                            // TODO: If any of the requested types for injection are
                            // EventProperties we should inject this instead of pushing it to the
                            // injector.
                            _ = evprop;
                            var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
                            if (comptime std.meta.fields(@TypeOf(args)).len == 0) {
                                @compileError("Provider routes need at least one parameter for the incoming message");
                            }

                            if (comptime !@hasField(@TypeOf(args[0]), "schema_name") or
                                !@hasField(@TypeOf(args[0]), "schema_version"))
                            {
                                @compileError("The first parameter of a provider route has to be a schema.");
                            }

                            const cch = try inj.require(cache.Cache(Provided(CallContext)));
                            const palloc = try inj.require(*mem.PoolAllocator);

                            args[0] = context;

                            inline for (1..args.len) |i| {
                                args[i] = try inj.require(@TypeOf(args[i]));
                            }

                            const inv = if (comptime klib.meta.canBeError(f))
                                try @call(.auto, f, args)
                            else
                                @call(.auto, f, args);

                            // FIXME: There has to be a better way
                            var buf: [4096]u8 = undefined;
                            var fba = std.heap.FixedBufferAllocator.init(&buf);
                            var wr = std.Io.Writer.Allocating.init(fba.allocator());
                            try std.zon.stringify.serialize(context, .{}, &wr.writer);

                            // FIXME: Since we are already going to deinit the old one anyway we might as well
                            // reuse it's allocator instead of taking out a new lease.

                            const tiny_allocator = try palloc.suballocator();
                            const copy = try std.zon.parse.fromSlice(
                                CallContext,
                                tiny_allocator,
                                try wr.toOwnedSliceSentinel(0),
                                null,
                                .{},
                            );

                            const old = try cch.push(.init(copy, tiny_allocator), inv);
                            if (old) |*o| {
                                @constCast(o).deinit(palloc);
                            }
                        }
                    };
                }
            };

            const RB = RouteBase(
                .provide,
                ex_value,
                rt_value,
                H.make,
                consexpr.event.raw,
                .recv,
            );

            return self.extend(RB);
        }

        fn withReply(
            comptime self: @This(),
            comptime consexpr: AmqpTemplate.ReplyExpr,
            comptime f: anytype,
        ) @This() {
            const exch = consexpr.exchange;
            const exch_is_dynamically_bound = exch.params.len != 0;
            const ExType = if (exch_is_dynamically_bound)
                shared.DependantTemplate(Context, exch.raw, exch.fmt, exch.params)
            else
                shared.ComptimeTemplate(exch.raw);
            const ex_value: ExType = .{};
            const parsed_routing_key = consexpr.route;
            const route_is_dynamically_bound = parsed_routing_key.params.len != 0;
            const RtType = if (route_is_dynamically_bound)
                shared.DependantTemplate(
                    Context,
                    parsed_routing_key.raw,
                    parsed_routing_key.fmt,
                    parsed_routing_key.params,
                )
            else
                shared.ComptimeTemplate(parsed_routing_key.raw);
            const rt_value: RtType = .{};

            const fargs = @typeInfo(@TypeOf(f)).@"fn".params;

            const __CallContext = fargs[0].type.?;

            const __Dependencies = comptime blk: {
                var deps: [fargs.len - 1]type = undefined;
                for (fargs[1..fargs.len], 0..) |a, i| {
                    deps[i] = a.type.?; // TODO: check when this could ever be null. How even?
                }
                break :blk deps;
            };

            const H = struct {
                pub fn make(comptime Base: type) type {
                    return struct {
                        pub const CallContext = __CallContext;
                        pub const Dependencies = __Dependencies ++ if (exch_is_dynamically_bound or route_is_dynamically_bound) .{ std.mem.Allocator, Context } else .{};

                        pub fn name(inj: *dep.DepCtx) ![]const u8 {
                            const allocator = try inj.require(std.mem.Allocator);
                            return std.fmt.allocPrint(
                                allocator,
                                "ampq: {t} {s}/{s}",
                                .{
                                    Base.method,
                                    try Base.exchange.get(inj),
                                    try Base.routing_key.get(inj),
                                },
                            );
                        }

                        pub fn call(
                            inj: *dep.DepCtx,
                            context: CallContext,
                            evprop: EventPropertiesEx,
                        ) anyerror!schema.SendMessage {
                            // TODO: If any of the requested types for injection are
                            // EventProperties we should inject this instead of pushing it to the
                            // injector.
                            _ = evprop;
                            var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
                            const ReturnType = klib.meta.Result(f);
                            if (comptime std.meta.fields(@TypeOf(args)).len == 0) {
                                @compileError("Reply routes need at least one parameter for the incoming message");
                            }

                            if (comptime !@hasField(@TypeOf(args[0]), "schema_name") or
                                !@hasField(@TypeOf(args[0]), "schema_version"))
                            {
                                @compileError("The first parameter of a reply route has to be a schema.");
                            }

                            args[0] = context;

                            inline for (1..args.len) |i| {
                                args[i] = try inj.require(@TypeOf(args[i]));
                            }

                            const maybe_result = @call(.auto, f, args);

                            const result =
                                switch (comptime @typeInfo(klib.meta.Return(f))) {
                                    .error_union => try maybe_result,
                                    else => maybe_result,
                                };

                            // FIXME: Ideally we don't need this
                            const arena = try inj.require(mem.ScopedAllocator);
                            const alloc = arena.value;
                            return handlePublish(
                                ReturnType,
                                result,
                                alloc,
                                try Base.exchange.get(inj),
                                "__placeholder__",
                                false,
                                consexpr.event.raw,
                            );
                        }
                    };
                }
            };

            const RB = RouteBase(
                .reply,
                ex_value,
                rt_value,
                H.make,
                consexpr.event.raw,
                .recv,
            );

            return self.extend(RB);
        }

        pub fn parse(
            comptime self: @This(),
            comptime Container: type,
            comptime fnname: []const u8,
        ) @This() {
            comptime {
                @setEvalBranchQuota(100000);
                var tmpl = AmqpTemplate.Template(Context).init(fnname);
                const expression = tmpl.parseTokens();
                const f = @field(Container, fnname);

                switch (expression.method) {
                    .provide => {
                        return self.withProvide(expression, f);
                    },
                    .publish => {
                        return self.withPublish(expression, f);
                    },
                    .consume => {
                        return self.withConsume(expression, f);
                    },
                    .reply => {
                        return self.withReply(expression, f);
                    },
                    .rejected => {
                        unreachable;
                        //return self.withRejected(expression, f);
                    },
                    .unrouted => {
                        return self.withUnrouted(expression, f);
                    },
                }
            }
        }
    };
}

/// Given pre-parsed routes (output of `From()`), filters for publish routes
/// and builds a type-erased scheduler whose `PublishData` is a union of only
/// those routes' CallContexts. The resulting type is deterministic from the
/// routes alone — no consumer types needed.
pub fn AmqpSchedulerShim(comptime Routes: []const type) type {
    const PubRoutes = FilterRoutes(Routes, .publish);
    const ShimPD = shared.UniteCallContext(PubRoutes);

    return struct {
        pub const PublishData = ShimPD;
        pub const PublishExtra = struct { inj: ?*dep.DepCtx = null };

        _publishFn: *const fn (*anyopaque, ShimPD, PublishExtra) anyerror!void,
        _ctx: *anyopaque,

        pub fn publish(self: @This(), data: ShimPD, extra: PublishExtra) !void {
            return self._publishFn(self._ctx, data, extra);
        }
    };
}

/// Adapts a shim scheduler's PublishData to a real Scheduler's PublishData
/// by mapping union fields by name. Works because protocol routes are always
/// included in the real driver (via `kw.protocol.use()`), so the real
/// PublishData union has fields with the same names and types.
pub fn SchedulerBridge(comptime Shim: type, comptime RealScheduler: type) type {
    // Extract the real PublishData type from the Scheduler's publish method signature.
    const RealPublishData = @typeInfo(@TypeOf(RealScheduler.publish)).@"fn".params[1].type.?;

    return struct {
        real: RealScheduler,

        fn publishImpl(ctx: *anyopaque, data: Shim.PublishData, extra: Shim.PublishExtra) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (data) {
                inline else => |val, tag| {
                    try self.real.publish(
                        @unionInit(RealPublishData, @tagName(tag), val),
                        .{ .inj = extra.inj },
                    );
                },
            }
        }

        pub fn toShim(self: *@This()) Shim {
            return .{ ._publishFn = &publishImpl, ._ctx = @ptrCast(self) };
        }
    };
}

/// DI factory wrapper that lazily creates a `SchedulerBridge` on first
/// request. The factory method depends on `RealScheduler`, which the DI
/// system resolves from the `SchedulerCtx.schedulerFac` registered by the
/// Server in `bind()`.
pub fn BridgeShimCtx(comptime Shim: type, comptime RealScheduler: type) type {
    const BridgeType = SchedulerBridge(Shim, RealScheduler);
    return struct {
        bridge: ?BridgeType = null,

        pub fn shimSchedulerFac(self: *@This(), real_sched: RealScheduler) Shim {
            if (self.bridge == null) {
                self.bridge = .{ .real = real_sched };
            }
            return self.bridge.?.toShim();
        }
    };
}

comptime {
    const Drv = Driver
        .new(.amqp)
        .config("null")
        .listen(false)
        .jobs(0)
        .routes(&.{})
        .build();

    core.driver.AssertDriver(Drv, .amqp);
}

// Ref all decls
comptime {
    const Context = struct { client_id: []const u8 = "" };

    const Schema = struct {
        pub const schema_name = "ref";
        pub const schema_version = 1;
        value: u64,
    };

    const Rs = struct {
        pub fn @"publish:refpub amq.direct/refkey"(ctx: struct { i64 }) Schema {
            return .{ .value = @intCast(ctx.@"0") };
        }
        pub fn @"consume:refcons amq.direct/refkey"(msg: Schema) void {
            _ = msg;
        }
        pub fn @"reply:refrep amq.direct/refkey"(msg: Schema) Schema {
            return msg;
        }
        pub fn @"provide:refprov amq.direct/refkey"(msg: Schema) u64 {
            return msg.value;
        }
        pub fn @"unrouted:refother"(msg: Schema) void {
            _ = msg;
        }
    };

    const Rts = From(Rs, Context);

    // Driver + registry plumbing.
    const Drv = Driver
        .new(.amqp)
        .config("null")
        .listen(false)
        .jobs(0)
        .routes(Rts)
        .build();

    const Ds = core.driver.Drivers.new().registerHandler(Drv);

    const ET = Ds.EventList();
    const EV = Ds.EventValues();
    const E = Event(ET, EV);
    _ = E;

    _ = Ds.Handlers(ET, EV)[0];
    const Sch = Ds.SchedulerMap();
    const RealSched = Sch(.amqp);

    // Force the amqp-specific (otherwise lazy) handler decls, incl. the provider machinery.
    const AmqpH = Drv(100);
    _ = AmqpH.PubRoutes;
    _ = AmqpH.ConsRoutes;
    _ = AmqpH.UnroutedRoutes;
    _ = AmqpH.ProviderRoutes;
    _ = AmqpH.Provides;
    _ = AmqpH.DependencyContext;

    // Helper generics.
    _ = FilterRoutes(Rts, .publish);
    const P = Provided(u8);
    _ = &P.init;
    _ = &P.deinit;

    // Scheduler shim/bridge.
    const Shim = AmqpSchedulerShim(Rts);
    _ = &Shim.publish;
    const Bridge = SchedulerBridge(Shim, RealSched);
    _ = &Bridge.publishImpl;
    _ = &Bridge.toShim;
    const BSC = BridgeShimCtx(Shim, RealSched);
    _ = &BSC.shimSchedulerFac;

    const R1 = Rts[0];
    R1.requires(.method);
    R1.requires(.exchange);
    R1.requires(.routing_key);
    if (R1.satisfies(.nothing)) @compileError("BUG: Incorrect constraint return");

    _ = R1.mod(.{ .method = .reply });
    _ = R1.query(.method);
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
