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

const log = std.log.scoped(.action);

const dep = @import("kw-core").deps;
const server = @import("kw-core");
const Event = @import("kw-core").event.Event;
const EventProperties = @import("kw-core").event.Properties;

const meta = @import("kw-core").meta;
const shared = @import("kw-core").shared;
const MPMCQueue = @import("kw-core").queue.StaticStrict;

pub const kind = .action;
const Root = @This();

pub const Driver = shared.DriverBuilder(DriverBuilder, false);

pub fn DriverBuilder(
    comptime driver_key: anytype,
    comptime listen: bool,
    comptime _jobs: comptime_int,
    comptime Routes: []const type,
    comptime ErrorHandler: type,
) *const fn (comptime u12) type {
    _ = listen;
    _ = ErrorHandler;
    const H = struct {
        pub fn ActionHandler(comptime block_start: u12) type {
            return struct {
                pub const jobs = _jobs;
                pub const kind = Root.kind;
                pub const key = driver_key;
                pub const RouteKeys = shared.EnumerateRoutes(Routes);
                pub const CallContext = shared.UniteCallContext(Routes);
                pub const Dependencies = shared.MergeDeps(Routes, &.{std.mem.Allocator});
                pub const map = shared.RouteMap(Routes);

                pub const EventType = enum(u12) {
                    call = block_start,
                };

                pub const EventValues = union(EventType) {
                    call: CallContext,
                };

                pub inline fn __block_end() u12 {
                    comptime {
                        return block_start + meta.count(EventType);
                    }
                }

                pub fn Yield(comptime ET: type, comptime EV: type) type {
                    const E = Event(ET, EV);
                    return struct {
                        const Self = @This();

                        queue: ?*MPMCQueue(E) = null,

                        pub const accepts = server.genAccepts(ET, EventType);

                        pub const Scheduler = struct {
                            parent: *Self,

                            pub fn call(self: @This(), data: CallContext, extra: struct { inj: ?*dep.DepCtx = null }) !void {
                                const value = @unionInit(
                                    EV,
                                    @tagName(key),
                                    .{
                                        .call = data,
                                    },
                                );

                                var ev = E{
                                    .event_data = value,
                                    // The GLOBAL event enum: driver-local
                                    // event names are prefixed with the
                                    // driver key at registration.
                                    .event_type = @field(ET, @tagName(key) ++ "_call"),
                                };

                                if (extra.inj) |inj| {
                                    const p = try inj.require(EventProperties);
                                    if (p.correlation_id.isUnset()) {
                                        log.err("scheduling an action from a handler without a correlation id (bug)", .{});
                                    }
                                    ev.properties.correlation_id = p.correlation_id;
                                }

                                _ = self.parent.queue.?.tryPush(
                                    ev,
                                    std.time.ns_per_ms * 1,
                                ) catch |e| switch (e) {
                                    error.WouldBlock => {
                                        @panic("Preemptive execution is not implemented!");
                                    },
                                    else => return e,
                                };
                            }

                            pub fn callLater(
                                self: @This(),
                                data: CallContext,
                                extra: struct { inj: ?*dep.DepCtx = null },
                            ) !E {
                                _ = self;
                                const value = @unionInit(
                                    EV,
                                    @tagName(key),
                                    .{
                                        .call = data,
                                    },
                                );

                                var ev = E{
                                    .event_data = value,
                                    .event_type = @field(ET, @tagName(key) ++ "_call"),
                                };

                                if (extra.inj) |inj| {
                                    const p = try inj.require(EventProperties);
                                    if (p.correlation_id.isUnset()) {
                                        log.err("scheduling an action from a handler without a correlation id (bug)", .{});
                                    }
                                    ev.properties.correlation_id = p.correlation_id;
                                }

                                return ev;
                            }

                            pub fn callImmediate(self: @This(), data: CallContext, inj: *dep.DepCtx) anyerror!void {
                                _ = self;
                                // Runs inside the CURRENT event's scope: no
                                // stamp — the event record can only carry
                                // one, and re-stamping here would orphan
                                // anything the outer route already scheduled.
                                return dispatch(data, inj, false);
                            }
                        };

                        fn dispatch(data: CallContext, inj: *dep.DepCtx, comptime stamp: bool) anyerror!void {
                            switch (data) {
                                inline else => |rctx, tag| {
                                    const R = comptime Routes[@intFromEnum(tag)];
                                    if (comptime stamp) {
                                        _ = try server.event.stampRoute(inj, R.id);
                                    }
                                    try R.call(inj, rctx);
                                },
                            }
                        }

                        pub fn init() @This() {
                            return .{};
                        }

                        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                            _ = self;
                            _ = allocator;
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
                            deps: anytype,
                            allocator: std.mem.Allocator,
                        ) anyerror!void {
                            _ = self;
                            _ = wg;
                            _ = pool;
                            _ = deps;
                            _ = allocator;
                            // The action driver never listens: it has no background loop.
                        }

                        pub fn stop(self: *@This()) void {
                            _ = self;
                        }

                        pub fn handle(self: *@This(), comptime ehint: ET, event: E, inj: *dep.DepCtx) anyerror!void {
                            const et: EventType = comptime @enumFromInt(@intFromEnum(ehint));
                            const ev: EventValues = @field(event.event_data, @tagName(key));
                            _ = self;

                            switch (et) {
                                inline .call => try dispatch(ev.call, inj, true),
                            }
                        }
                    };
                }
            };
        }
    };

    return H.ActionHandler;
}

pub fn From(comptime Container: type) []type {
    comptime {
        var rp = RouteParser(){ .routes = &.{} };
        for (std.meta.declarations(Container)) |d| {
            if (@typeInfo(@TypeOf(@field(Container, d.name))) != .@"fn") continue;
            rp = rp.parse(Container, d.name);
        }
        return rp.routes;
    }
}

pub const CapabilityType = enum { name };

pub const Capability = union(CapabilityType) {
    name: []const u8,
};

pub fn RouteBase(comptime HandlerFac: anytype, comptime parsed_id: []const u8) type {
    return struct {
        pub const Handler = HandlerFac(@This());
        pub const id = parsed_id;

        pub const CallContext = Handler.CallContext;
        pub const Dependencies = Handler.Dependencies;
        pub const call = Handler.call;
        pub const name = Handler.name;

        pub fn swap(comptime NextHandler: anytype) type {
            return RouteBase(NextHandler, parsed_id);
        }

        pub fn wrap(comptime NextHandlerFac: anytype) type {
            return RouteBase(NextHandlerFac(HandlerFac).make, parsed_id);
        }

        pub fn requires(comptime ct: anytype) void {
            if (comptime !meta.hasKey(CapabilityType, ct)) {
                @compileError(
                    "Required capability '" ++ @tagName(ct) ++ "' is not supported by ACTION routes.",
                );
            }
        }

        pub fn satisfies(comptime ct: anytype) bool {
            return meta.hasKey(CapabilityType, ct);
        }

        pub fn mod(
            comptime capability: Capability,
        ) type {
            return switch (capability) {
                inline .name => |n| RouteBase(HandlerFac, n),
            };
        }

        pub fn query(comptime ct: anytype) @FieldType(
            Capability,
            @tagName(ct),
        ) {
            requires(ct);
            return switch (ct) {
                .name => id,
                else => unreachable,
            };
        }
    };
}

pub fn RouteParser() type {
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

        pub fn parse(
            comptime self: @This(),
            comptime Container: type,
            comptime fnname: []const u8,
        ) @This() {
            comptime {
                const f = @field(Container, fnname);

                const fargs = @typeInfo(@TypeOf(f)).@"fn".params;
                const has_context = fargs.len > 0 and blk: {
                    const ti = @typeInfo(fargs[0].type.?);
                    switch (ti) {
                        .@"struct" => |s| break :blk s.is_tuple,
                        else => break :blk false,
                    }
                };

                const di_start_idx = if (has_context) 1 else 0;
                const __CallContext = if (has_context) fargs[0].type.? else struct {};

                const __Dependencies = blk: {
                    var deps: [fargs.len - di_start_idx]type = undefined;
                    for (fargs[di_start_idx..fargs.len], 0..) |a, i| {
                        deps[i] = a.type.?;
                    }
                    break :blk deps;
                };

                const H = struct {
                    pub fn make(comptime Base: type) type {
                        _ = Base;
                        return struct {
                            pub const CallContext = __CallContext;
                            pub const Dependencies = __Dependencies;

                            pub fn name(inj: *dep.DepCtx) ![]const u8 {
                                const allocator = try inj.require(std.mem.Allocator);
                                return std.fmt.allocPrint(allocator, "action: {s}", .{fnname});
                            }

                            pub fn call(inj: *dep.DepCtx, context: CallContext) anyerror!void {
                                var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;

                                inline for (0..di_start_idx) |i| {
                                    args[i] = context;
                                }

                                inline for (di_start_idx..args.len) |i| {
                                    args[i] = try inj.require(@TypeOf(args[i]));
                                }
                                const maybe_result = @call(.auto, f, args);

                                switch (comptime @typeInfo(klib.meta.Return(f))) {
                                    .error_union => try maybe_result,
                                    else => {},
                                }
                            }
                        };
                    }
                };

                const RB = RouteBase(H.make, fnname);

                return self.extend(RB);
            }
        }
    };
}

comptime {
    const Drv = Driver
        .new(.action)
        .listen(false)
        .jobs(0)
        .routes(&.{})
        .build();

    @import("kw-core").driver.AssertDriver(Drv, .action);
}

// Ref all decls
comptime {
    const core = @import("kw-core");

    const Rs = struct {
        pub fn simple() void {}
        pub fn emptyParams(param: struct {}) void {
            _ = param;
        }
        pub fn params(param: struct { i64, u64 }) void {
            _ = param;
        }
        pub fn withDI(param: struct { i64, u64 }, dependency: i64) void {
            _ = param;
            _ = dependency;
        }
        pub fn onlyDI(dependency: i64) void {
            _ = dependency;
        }
    };

    const Rts = From(Rs);

    const R1 = Rts[0];
    R1.requires(.name);
    if (R1.satisfies(.nothing)) @compileError("BUG: Incorrect constraint return");
    const R2 = R1.mod(.{ .name = "new" });
    if (!std.mem.eql(u8, R2.query(.name), "new")) @compileError("BUG: Wrong name - " ++ R2.query(.name));

    const Drv = Driver
        .new(.action)
        .listen(false)
        .jobs(0)
        .routes(Rts)
        .build();

    const Ds = core.driver.Drivers.new().registerHandler(Drv);

    const ET = Ds.EventList();
    const EV = Ds.EventValues();
    const E = Event(ET, EV);

    _ = Ds.Handlers(ET, EV)[0];
    const Sch = Ds.SchedulerMap();
    _ = Sch(.action);

    _ = E;
}

// The queued-path scheduler bodies are only compiled when instantiated; these
// tests exist so the `event_type` lookup against the GLOBAL event enum (the
// `<key>_call` prefixed form) can never silently rot again.
const TestRoutes = struct {
    pub fn ping(ctx: struct { i64 }) void {
        _ = ctx;
    }
};

const TestDriver = Driver
    .new(.action)
    .listen(false)
    .jobs(0)
    .routes(From(TestRoutes))
    .build();

const TestRegistry = @import("kw-core").driver.Drivers.new().registerHandler(TestDriver);
const TestET = TestRegistry.EventList();
const TestEV = TestRegistry.EventValues();
const TestHandler = TestRegistry.Handlers(TestET, TestEV)[1];
const TestEvent = Event(TestET, TestEV);

test "call pushes onto the bound queue with the driver-prefixed event type" {
    var h = TestHandler.init();
    defer h.deinit(std.testing.allocator);

    var buf: [4]TestEvent = undefined;
    var occ = [_]u1{0} ** 4;
    var q = MPMCQueue(TestEvent).init(&buf, &occ);
    h.bind(&q);

    try h.scheduler().call(.{ .ping = .{7} }, .{});
    const popped = q.tryPop(std.time.ns_per_ms).?;
    try std.testing.expectEqual(@field(TestET, "action_call"), popped.event_type);
    const data = @field(popped.event_data, "action");
    try std.testing.expectEqual(@as(i64, 7), data.call.ping[0]);
}

test "callLater builds the event without queueing" {
    var h = TestHandler.init();
    defer h.deinit(std.testing.allocator);

    const ev = try h.scheduler().callLater(.{ .ping = .{1} }, .{});
    try std.testing.expectEqual(@field(TestET, "action_call"), ev.event_type);
    const data = @field(ev.event_data, "action");
    try std.testing.expectEqual(@as(i64, 1), data.call.ping[0]);
}
