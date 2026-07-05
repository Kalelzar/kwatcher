const std = @import("std");
const klib = @import("klib");

const log = std.log.scoped(.cron);

const core = @import("kw-core");

const dep = core.deps;
const server = core;
const Event = core.event.Event;

const CronTemplate = @import("Cron.zig");

const shared = core.shared;
const meta = core.meta;

const MPMCQueue = core.queue.StaticStrict;

pub const kind = .cron;
const Root = @This();

pub const Driver = shared.DriverBuilder(DriverBuilder, false);

pub const VMSchedule = CronTemplate.VM.Schedule;

pub const Meta = struct {
    raw: []const u8,
    expression: []const u8,
};

pub const TimingSource = union(enum) {
    schedule: CronTemplate.VM.Schedule,
    delay: i64,
};

pub const JobInfo = struct {
    oneshot: bool,
    scheduled_for: i64,
    kind: []const u8,
    id: []const u8,
    on_invoke_action: []const u8,
    source: TimingSource,
};

/// Type-erased job identity. `route` carries the RouteKeys tag name (== the
/// job's `R.id`); `anonymous` carries a dynamic timer id. Strings are borrowed
/// from the caller — the scheduler never owns or frees them.
pub const ShimId = union(enum) {
    route: []const u8,
    anonymous: []const u8,
};

/// Type-erased handle to a cron driver's scheduler.
///
/// The real `Yield(ET, EV).Scheduler` is parameterized by the app's event
/// union and route enum — types only known once the driver set is assembled —
/// so framework packages (e.g. the introspection UI) depend on this fixed
/// vtable instead. All surface types are file-scope (`JobInfo`, `TimingSource`,
/// `ShimId`), so unlike the AMQP shim no comptime parameter is needed.
///
/// Excluded from the erased surface: `once`/`after` (their payloads are the
/// app event union; exposing them requires full-route-set instantiation, the
/// way docgen sees the whole composition — future work) and `detach` (returns
/// the driver's generic `Schedule`).
pub const SchedulerShim = struct {
    _queryFn: *const fn (*anyopaque, ShimId, std.mem.Allocator) anyerror!?JobInfo,
    _listFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]JobInfo,
    _cancelFn: *const fn (*anyopaque, ShimId) ?void,
    _resurrectFn: *const fn (*anyopaque, []const u8) anyerror!void,
    _triggerFn: *const fn (*anyopaque, ShimId, ?*dep.DepCtx) anyerror!?void,
    _ctx: *anyopaque,

    pub fn query(self: @This(), id: ShimId, allocator: std.mem.Allocator) !?JobInfo {
        return self._queryFn(self._ctx, id, allocator);
    }

    pub fn list(self: @This(), allocator: std.mem.Allocator) ![]JobInfo {
        return self._listFn(self._ctx, allocator);
    }

    pub fn cancel(self: @This(), id: ShimId) ?void {
        return self._cancelFn(self._ctx, id);
    }

    pub fn resurrect(self: @This(), route_name: []const u8) !void {
        return self._resurrectFn(self._ctx, route_name);
    }

    /// Fire any job (route or dynamic) ahead of schedule; an extra run, the
    /// scheduled entry is untouched. Null = no such job. Pass the caller's
    /// injector so the triggered job continues the caller's trace.
    pub fn trigger(self: @This(), id: ShimId, inj: ?*dep.DepCtx) !?void {
        return self._triggerFn(self._ctx, id, inj);
    }
};

/// Adapts a concrete cron `Scheduler` to the type-erased `SchedulerShim`
/// vtable. Route names map to the driver's `RouteKeys` at runtime via
/// `stringToEnum` — deliberately not `inline else` expansion.
pub fn SchedulerBridge(comptime RealScheduler: type) type {
    // Extract the driver's nested per-app types from method signatures.
    const RouteKeys = @typeInfo(@TypeOf(RealScheduler.resurrect)).@"fn".params[1].type.?;
    const Id = @typeInfo(@TypeOf(RealScheduler.cancel)).@"fn".params[1].type.?;

    return struct {
        real: RealScheduler,

        fn toRealId(id: ShimId) ?Id {
            return switch (id) {
                .route => |name| .{ .route = std.meta.stringToEnum(RouteKeys, name) orelse return null },
                .anonymous => |name| .{ .anonymous = name },
            };
        }

        fn queryImpl(ctx: *anyopaque, id: ShimId, allocator: std.mem.Allocator) anyerror!?JobInfo {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.real.query(toRealId(id) orelse return null, allocator);
        }

        fn listImpl(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]JobInfo {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.real.list(allocator);
        }

        fn cancelImpl(ctx: *anyopaque, id: ShimId) ?void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.real.cancel(toRealId(id) orelse return null);
        }

        fn resurrectImpl(ctx: *anyopaque, name: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.real.resurrect(std.meta.stringToEnum(RouteKeys, name) orelse return error.UnknownRoute);
        }

        fn triggerImpl(ctx: *anyopaque, id: ShimId, inj: ?*dep.DepCtx) anyerror!?void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.real.trigger(toRealId(id) orelse return null, .{ .inj = inj });
        }

        pub fn toShim(self: *@This()) SchedulerShim {
            return .{
                ._queryFn = &queryImpl,
                ._listFn = &listImpl,
                ._cancelFn = &cancelImpl,
                ._resurrectFn = &resurrectImpl,
                ._triggerFn = &triggerImpl,
                ._ctx = @ptrCast(self),
            };
        }
    };
}

/// DI factory wrapper that lazily builds a `SchedulerBridge` on first request.
/// `shimSchedulerFac` depends on the concrete `RealScheduler`, which the DI
/// system resolves from the `SchedulerCtx` the Server registers in `bind()`.
pub fn BridgeShimCtx(comptime RealScheduler: type) type {
    const BridgeType = SchedulerBridge(RealScheduler);
    return struct {
        bridge: ?BridgeType = null,

        pub fn shimSchedulerFac(self: *@This(), real_sched: RealScheduler) SchedulerShim {
            if (self.bridge == null) {
                self.bridge = .{ .real = real_sched };
            }
            return self.bridge.?.toShim();
        }
    };
}

// NOTE: This assumes that category is the driver key, like amqp.defaultFor.
/// Dephub extension registering the type-erased cron scheduler shim under
/// `.all` (visible to every mount, including the private introspection UI).
/// Wire with `.with(.<cron driver key>, cron.defaultFor(<registry>), allocator)`.
pub fn defaultFor(comptime drv: core.DriverRegistry) type {
    return struct {
        pub fn apply(
            dephub: anytype,
            comptime category: anytype,
            allocator: std.mem.Allocator,
            comptime Config: type,
        ) Return(category, Config, @TypeOf(dephub)) {
            _ = allocator;
            const drk: drv.DriverKeys() = category;
            const Shim = BridgeShimCtx(drv.Schedulers()[@intFromEnum(drk)]);
            const H = struct {
                var shim = Shim{};
            };
            return dephub.static(.all, &H.shim);
        }

        pub fn Return(comptime category: anytype, comptime Config: type, comptime DH: type) type {
            _ = Config;
            const drk: drv.DriverKeys() = category;
            const Shim = BridgeShimCtx(drv.Schedulers()[@intFromEnum(drk)]);
            return DH.Static(.all, *Shim);
        }
    };
}

pub fn DriverBuilder(
    comptime driver_key: anytype,
    comptime listen: bool,
    comptime _jobs: comptime_int,
    comptime _Routes: []const type,
    comptime ErrorHandler: type,
) *const fn (comptime u12) type {
    _ = ErrorHandler;
    if (comptime _jobs > 1) @compileError("More than 1 watch job is useless for the cron driver.");
    const H = struct {
        pub fn CronHandler(comptime block_start: u12) type {
            return struct {
                pub const jobs = _jobs;
                pub const key = driver_key;
                pub const kind = Root.kind;
                pub const Routes = _Routes;
                pub const RouteKeys = shared.EnumerateRoutes(Routes);
                pub const CallContext = shared.UniteCallContext(Routes);
                pub const Dependencies = shared.MergeDeps(Routes, &.{std.mem.Allocator});
                pub const map = shared.RouteMap(Routes);
                pub const EventType = enum(u12) {
                    trigger_job = block_start,
                };

                const TriggerJobData = struct {
                    route: RouteKeys,
                };

                pub const EventValues = union(EventType) {
                    trigger_job: TriggerJobData,
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
                        pub const Scheduler = struct {
                            parent: *Self,

                            pub fn once(self: @This(), comptime schedule: []const u8, event: E) !Id {
                                const H = struct {
                                    var seq: u64 = 0;
                                };

                                const parsed = comptime CronTemplate.VM.Schedule.init(schedule);
                                const alloc = self.parent.schedules.allocator;
                                const id = try std.fmt.allocPrint(alloc, "{t}_{s}once_{d}", .{
                                    event.event_type,
                                    (if (parsed.name) |name| name ++ "_" else ""),
                                    @atomicRmw(u64, &H.seq, .Add, 1, .monotonic),
                                });

                                self.parent.mutex.lock();
                                defer self.parent.mutex.unlock();
                                const sch = Schedule{
                                    .id = .{ .anonymous = id },
                                    .oneshot = true,
                                    .target = .{
                                        .event = event,
                                    },
                                    .run_at = calcNext(std.time.timestamp() + 1, .{ .schedule = parsed }),
                                    .source = .{ .schedule = parsed },
                                };
                                try self.parent.schedules.add(sch);
                                self.parent.cond.broadcast();
                                return .{ .anonymous = id };
                            }

                            pub fn after(self: @This(), time_s: i64, event: E) !Id {
                                const H = struct {
                                    var seq: u64 = 0;
                                };
                                const alloc = self.parent.schedules.allocator;
                                const id = try std.fmt.allocPrint(alloc, "{t}_after_{d}", .{
                                    event.event_type,
                                    @atomicRmw(u64, &H.seq, .Add, 1, .monotonic),
                                });
                                self.parent.mutex.lock();
                                defer self.parent.mutex.unlock();
                                const sch = Schedule{
                                    .oneshot = true,
                                    .id = .{ .anonymous = id },
                                    .target = .{
                                        .event = event,
                                    },
                                    .run_at = std.time.timestamp() + time_s,
                                    .source = .{ .delay = time_s },
                                };
                                try self.parent.schedules.add(sch);
                                self.parent.cond.broadcast();
                                return .{ .anonymous = id };
                            }

                            fn findJob(self: @This(), target: Id) ?usize {
                                var it = self.parent.schedules.iterator();
                                while (it.next()) |n| {
                                    if (n.id.eql(target)) {
                                        return it.count - 1;
                                    }
                                }
                                return null;
                            }

                            pub fn cancel(self: @This(), target: Id) ?void {
                                var schedule = self.detach(target) orelse return null;
                                schedule.deinit(self.parent.schedules.allocator);
                                return {};
                            }

                            pub fn detach(self: @This(), target: Id) ?Schedule {
                                self.parent.mutex.lock();
                                defer self.parent.mutex.unlock();
                                const index = self.findJob(target) orelse return null;
                                const schedule = self.parent.schedules.removeIndex(index);
                                self.parent.cond.broadcast();
                                return schedule;
                            }

                            pub fn resurrect(self: @This(), route: RouteKeys) !void {
                                self.parent.mutex.lock();
                                defer self.parent.mutex.unlock();
                                const job = self.findJob(.{ .route = route });
                                if (job != null) return;

                                const now = std.time.timestamp();
                                const id, const schedule = blk: switch (route) {
                                    inline else => |r| {
                                        const R = Routes[@intFromEnum(r)];
                                        break :blk .{ R.id, R.schedule };
                                    },
                                };
                                const next = calcNext(now, .{ .schedule = schedule });
                                try self.parent.schedules.add(.{
                                    .id = .{ .route = route },
                                    .target = .{ .route = map.get(id).? },
                                    .run_at = next,
                                    .source = .{ .schedule = schedule },
                                });
                                self.parent.cond.broadcast();
                            }

                            pub fn query(self: @This(), job: Id, allocator: std.mem.Allocator) !?JobInfo {
                                self.parent.mutex.lock();
                                defer self.parent.mutex.unlock();
                                const index = self.findJob(job) orelse return null;
                                return try self.snapshotLocked(self.parent.schedules.items[index], allocator);
                            }

                            /// Project one queued schedule to a caller-owned JobInfo.
                            /// `parent.mutex` must be held by the caller.
                            fn snapshotLocked(self: @This(), schedule: Schedule, allocator: std.mem.Allocator) !JobInfo {
                                _ = self;
                                const on_invoke_action: []const u8 = try switch (schedule.target) {
                                    .route => |r| std.fmt.allocPrint(
                                        allocator,
                                        "route '{t}'",
                                        .{r},
                                    ),
                                    .event => |e| std.fmt.allocPrint(
                                        allocator,
                                        "trigger '{t}'", // TODO: Maybe include some event values?
                                        .{e.event_type},
                                    ),
                                };
                                errdefer allocator.free(on_invoke_action);
                                return .{
                                    .oneshot = schedule.oneshot,
                                    .scheduled_for = schedule.run_at,
                                    .kind = @tagName(schedule.id),
                                    .id = try std.fmt.allocPrint(
                                        allocator,
                                        "{s}",
                                        .{switch (schedule.id) {
                                            .route => |r| @tagName(r),
                                            .anonymous => |a| a,
                                        }},
                                    ),
                                    .on_invoke_action = on_invoke_action,
                                    .source = schedule.source,
                                };
                            }

                            /// Snapshot every pending job. The `id` and `on_invoke_action`
                            /// strings in the returned JobInfos are duped into `allocator`
                            /// and owned by the caller; `kind` is static memory. Order is
                            /// heap order, not fire order.
                            pub fn list(self: @This(), allocator: std.mem.Allocator) ![]JobInfo {
                                self.parent.mutex.lock();
                                defer self.parent.mutex.unlock();
                                const items = self.parent.schedules.items;
                                const out = try allocator.alloc(JobInfo, items.len);
                                var done: usize = 0;
                                errdefer {
                                    for (out[0..done]) |ji| {
                                        allocator.free(ji.id);
                                        allocator.free(ji.on_invoke_action);
                                    }
                                    allocator.free(out);
                                }
                                for (items) |sch| {
                                    out[done] = try self.snapshotLocked(sch, allocator);
                                    done += 1;
                                }
                                return out;
                            }

                            /// Fire a job ahead of schedule. This is always an *extra* run:
                            /// the scheduled entry is untouched, so a oneshot triggered early
                            /// still fires at its scheduled time as well. Null = no such job.
                            pub fn trigger(self: @This(), target: Id, extra: struct { inj: ?*dep.DepCtx = null }) !?void {
                                var ev: E = blk: {
                                    self.parent.mutex.lock();
                                    defer self.parent.mutex.unlock();
                                    const index = self.findJob(target) orelse return null;
                                    switch (self.parent.schedules.items[index].target) {
                                        .route => |route| break :blk .{
                                            .event_data = @unionInit(
                                                EV,
                                                @tagName(key),
                                                .{
                                                    .trigger_job = .{
                                                        .route = route,
                                                    },
                                                },
                                            ),
                                            .event_type = @field(ET, @tagName(key) ++ "_trigger_job"),
                                        },
                                        .event => |event| break :blk event,
                                    }
                                };

                                if (extra.inj) |inj| {
                                    const p = try inj.require(core.event.Properties);
                                    if (p.correlation_id.isUnset()) {
                                        log.err("triggering a job from a handler without a correlation id (bug)", .{});
                                    }
                                    ev.properties.correlation_id = p.correlation_id;
                                }

                                // Push outside the lock: the queue can block.
                                _ = self.parent.queue.?.tryPush(ev, 100) catch |e| switch (e) {
                                    error.WouldBlock => {
                                        // FIXME: Words
                                        // Ideally we would want to be able to do:
                                        // self.parent.handle(.trigger_job, ev, ???);
                                        // But we can't get an injector for our handler at the
                                        // moment.
                                        // We could accept an injector from outside but there
                                        // is no gurantee that it was built for our invariant.
                                        // The dependency system should allow us to request injectors for other uses.
                                        // That's the fix.
                                        @panic("Preemptive execution is not implemented!");
                                    },
                                    else => return e,
                                };
                                return {};
                            }
                        };

                        const Id = union(enum) {
                            route: RouteKeys,
                            anonymous: []const u8,

                            pub fn eql(self: Id, other: Id) bool {
                                if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
                                return switch (self) {
                                    .route => |r| r == other.route,
                                    .anonymous => |a| std.mem.eql(u8, a, other.anonymous),
                                };
                            }

                            pub fn deinit(self: *Id, allocator: std.mem.Allocator) void {
                                switch (self.*) {
                                    .route => {},
                                    .anonymous => |a| {
                                        allocator.free(a);
                                    },
                                }
                            }
                        };

                        const Schedule = struct {
                            id: Id,
                            oneshot: bool = false,
                            run_at: i64,
                            target: union(enum) {
                                route: RouteKeys,
                                event: E,
                            },
                            source: TimingSource,

                            pub fn deinit(self: *Schedule, allocator: std.mem.Allocator) void {
                                self.id.deinit(allocator);
                            }
                        };

                        const SchCtx = struct {};

                        queue: ?*MPMCQueue(E) = null,
                        schedules: std.PriorityQueue(Schedule, SchCtx, compareSchedule),
                        cond: std.Thread.Condition = .{},
                        mutex: std.Thread.Mutex = .{},
                        should_run: bool = true,
                        pub const accepts = server.genAccepts(ET, EventType);

                        fn compareSchedule(_: SchCtx, a: Schedule, b: Schedule) std.math.Order {
                            if (a.run_at == b.run_at) {
                                return .eq;
                            } else if (a.run_at < b.run_at) {
                                return .lt;
                            }
                            return .gt;
                        }

                        pub fn init(allocator: std.mem.Allocator) !@This() {
                            var q = std.PriorityQueue(Schedule, SchCtx, compareSchedule).init(allocator, .{});

                            const now = std.time.timestamp();
                            inline for (Routes, 0..) |R, i| {
                                const next = calcNext(now, .{ .schedule = R.schedule });
                                try q.add(.{
                                    .id = .{ .route = @enumFromInt(i) },
                                    .target = .{ .route = map.get(R.id).? },
                                    .run_at = next,
                                    .source = .{ .schedule = R.schedule },
                                });
                            }
                            return .{
                                .schedules = q,
                            };
                        }

                        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                            _ = allocator;
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            var iter = self.schedules.iterator();
                            while (iter.next()) |*n| {
                                // HACK: Const
                                @constCast(n).deinit(self.schedules.allocator);
                            }
                            self.schedules.deinit();
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
                            defer arc.deinit();
                            if (!listen) return;
                            if (comptime jobs > 1) @compileError("Cron is only allowed 1 watch job.");

                            for (0..jobs) |_| {
                                pool.spawnWg(wg, watch_inner, .{self});
                            }
                        }

                        fn watch_inner(self: *@This()) void {
                            while (@atomicLoad(bool, &self.should_run, .acquire)) {
                                self.watch_failing() catch |e| {
                                    log.err("Cron loop failed with: {t}", .{e});
                                };
                            }
                        }

                        fn jobName(sch: Schedule) []const u8 {
                            return switch (sch.id) {
                                .route => |r| @tagName(r),
                                .anonymous => |a| a,
                            };
                        }

                        fn watch_failing(self: *@This()) !void {
                            const fired: Schedule = blk: {
                                self.mutex.lock();
                                defer self.mutex.unlock();
                                while (true) {
                                    if (!@atomicLoad(bool, &self.should_run, .acquire)) return;
                                    const head = self.schedules.peek() orelse {
                                        self.cond.wait(&self.mutex);
                                        continue;
                                    };
                                    const now = std.time.timestamp();
                                    if (head.run_at <= now) {
                                        const sch = self.schedules.remove();
                                        if (!sch.oneshot) {
                                            var next = sch;
                                            next.run_at = calcNext(@max(now, sch.run_at), sch.source);
                                            log.info("Scheduling job '{s}' to fire in {d} seconds.", .{ jobName(sch), @max(0, next.run_at - now) });
                                            self.schedules.add(next) catch unreachable;
                                        }
                                        break :blk sch;
                                    }
                                    log.info("Job '{s}' to fire in {d} seconds.", .{ jobName(head), head.run_at - now });
                                    self.cond.timedWait(&self.mutex, @as(u64, @intCast(head.run_at - now)) * std.time.ns_per_s) catch {
                                        // We are using timeout to signal when we should run next rather than an error condition
                                    };
                                }
                            };

                            const name = jobName(fired);
                            defer if (fired.oneshot) {
                                var sch = fired;
                                sch.deinit(self.schedules.allocator);
                            };
                            switch (fired.target) {
                                .route => |route| {
                                    const data = @unionInit(EV, @tagName(key), .{
                                        .trigger_job = .{
                                            .route = route,
                                        },
                                    });
                                    _ = self.queue.?.push(.{
                                        .event_type = @field(ET, @tagName(key) ++ "_trigger_job"),
                                        .event_data = data,
                                    });
                                    log.info("Job {s} queued successfully.", .{name});
                                },
                                .event => |event| {
                                    _ = self.queue.?.push(event);
                                    log.info("Event {s} queued successfully.", .{name});
                                },
                            }
                        }

                        pub fn stop(self: *@This()) void {
                            @atomicStore(bool, &self.should_run, false, .release);
                            self.cond.broadcast();
                        }

                        pub fn handle(self: *@This(), comptime ehint: ET, event: E, inj: *dep.DepCtx) anyerror!void {
                            const et: EventType = comptime @enumFromInt(@intFromEnum(ehint));
                            const ev: EventValues = @field(event.event_data, @tagName(key));
                            _ = self;

                            switch (et) {
                                inline .trigger_job => {
                                    switch (ev.trigger_job.route) {
                                        inline else => |r| {
                                            const R = comptime Routes[@intFromEnum(r)];
                                            _ = try core.event.stampRoute(inj, R.id);
                                            try R.call(inj, .{});
                                        },
                                    }
                                },
                            }
                        }
                    };
                }
            };
        }
    };

    return H.CronHandler;
}

pub const CapabilityType = enum { name };

pub const Capability = union(CapabilityType) {
    name: []const u8,
};

pub fn From(comptime Container: type) []type {
    const routes = comptime blk: {
        var rp = RouteParser(){ .routes = &.{} };

        for (std.meta.declarations(Container)) |d| {
            if (@typeInfo(@TypeOf(@field(Container, d.name))) != .@"fn") continue;
            rp = rp.parse(Container, d.name);
        }

        break :blk rp.routes;
    };

    return routes;
}

pub fn RouteBase(
    comptime sched: CronTemplate.VM.Schedule,
    comptime HandlerFac: anytype,
    comptime parsed_id: []const u8,
    comptime route_meta: Meta,
) type {
    return struct {
        pub const Handler = HandlerFac(@This());
        pub const schedule = sched;
        pub const id = parsed_id;
        pub const meta = route_meta;

        pub const CallContext = Handler.CallContext;
        pub const Dependencies = Handler.Dependencies;
        pub const call = Handler.call;
        pub const name = Handler.name;

        pub fn swap(comptime NextHandler: anytype) type {
            return RouteBase(
                schedule,
                NextHandler,
                parsed_id,
                route_meta,
            );
        }

        pub fn wrap(comptime NextHandlerFac: anytype) type {
            return RouteBase(
                schedule,
                NextHandlerFac(HandlerFac).make,
                parsed_id,
                route_meta,
            );
        }

        pub fn requires(comptime ct: anytype) void {
            if (comptime !core.meta.hasKey(CapabilityType, ct)) {
                @compileError(
                    "Required capability '" ++ @tagName(ct) ++ "' is not supported by CRON routes.",
                );
            }
        }

        pub fn satisfies(comptime ct: anytype) bool {
            return core.meta.hasKey(CapabilityType, ct);
        }

        pub fn mod(
            comptime capability: Capability,
        ) type {
            return switch (capability) {
                inline .name => |n| RouteBase(
                    schedule,
                    HandlerFac,
                    n,
                    route_meta,
                ),
            };
        }

        pub fn query(comptime ct: anytype) @FieldType(
            Capability,
            @tagName(ct),
        ) {
            requires(ct);
            return switch (ct) {
                .name => parsed_id,
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
                @setEvalBranchQuota(10000);
                const tokens = CronTemplate.Lexer.lex(fnname);
                const ast = CronTemplate.Parser.parse(tokens);
                const schedule = CronTemplate.VM.evalToplevel(ast);
                const job_name = schedule.name orelse @compileError("Cron routes must have names.");
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
                                return std.fmt.allocPrint(allocator, "cron: {s}", .{job_name});
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

                const RB = RouteBase(schedule, H.make, job_name, .{
                    .raw = fnname,
                    .expression = std.mem.trim(u8, fnname[job_name.len..], " "),
                });

                return self.extend(RB);
            }
        }
    };
}

pub fn calcNext(timestamp: i64, source: TimingSource) i64 {
    switch (source) {
        .delay => |delay| return timestamp + delay,
        .schedule => |schedule| {
            var candidate = timestamp + 1; // Start checking from next second
            while (true) {
                const n = nextOffset(schedule, candidate);
                if (n == 0) {
                    return candidate;
                }
                candidate += n;
            }
        },
    }
}

test "Calculate next: 0 */5 * * * *" {
    const template = comptime CronTemplate.Lexer.lex("job 0 */5 * * * *");
    const ast = comptime CronTemplate.Parser.parse(template);

    const schedule = comptime CronTemplate.VM.evalToplevel(ast);

    try std.testing.expectEqual(
        300,
        calcNext(0, .{ .schedule = schedule }),
    );
    try std.testing.expectEqual(
        600,
        calcNext(300, .{ .schedule = schedule }),
    );

    try std.testing.expectEqual(
        300,
        calcNext(5, .{ .schedule = schedule }),
    );

    try std.testing.expectEqual(
        300,
        calcNext(299, .{ .schedule = schedule }),
    );

    try std.testing.expectEqual(
        3600,
        calcNext(3300, .{ .schedule = schedule }),
    );

    try std.testing.expectEqual(
        24 * 3600,
        calcNext(24 * 3600 - 300, .{ .schedule = schedule }),
    );

    try std.testing.expectEqual(
        31 * 24 * 3600,
        calcNext(31 * 24 * 3600 - 300, .{ .schedule = schedule }),
    );

    try std.testing.expectEqual(
        365 * 24 * 3600,
        calcNext(365 * 24 * 3600 - 300, .{ .schedule = schedule }),
    );
}

test "Calculate next: 30 */5 * * * * (second-level offset)" {
    const template = comptime CronTemplate.Lexer.lex("job 30 */5 * * * *");
    const ast = comptime CronTemplate.Parser.parse(template);
    const schedule = comptime CronTemplate.VM.evalToplevel(ast);

    // Second 30 of minute 0
    try std.testing.expectEqual(
        30,
        calcNext(0, .{ .schedule = schedule }),
    );

    // Second 30 of minute 5
    try std.testing.expectEqual(
        330,
        calcNext(30, .{ .schedule = schedule }),
    );

    // From middle of minute 5, still lands on second 30
    try std.testing.expectEqual(
        330,
        calcNext(300, .{ .schedule = schedule }),
    );

    // Second 30 of minute 10
    try std.testing.expectEqual(
        630,
        calcNext(330, .{ .schedule = schedule }),
    );
}

test "Calculate next: 0 0 0 1 * * (monthly on the 1st)" {
    const template = comptime CronTemplate.Lexer.lex("job 0 0 0 1 * *");
    const ast = comptime CronTemplate.Parser.parse(template);
    const schedule = comptime CronTemplate.VM.evalToplevel(ast);

    const jan1: i64 = 0;
    const feb1: i64 = 31 * 24 * 3600;
    const mar1: i64 = (31 + 28) * 24 * 3600;
    const apr1: i64 = (31 + 28 + 31) * 24 * 3600;

    // Jan 1 00:00:00 → Feb 1 00:00:00
    try std.testing.expectEqual(feb1, calcNext(jan1, .{ .schedule = schedule }));

    // Feb 1 00:00:00 → Mar 1 00:00:00
    try std.testing.expectEqual(mar1, calcNext(feb1, .{ .schedule = schedule }));

    // Mar 1 00:00:00 → Apr 1 00:00:00
    try std.testing.expectEqual(apr1, calcNext(mar1, .{ .schedule = schedule }));

    // Jan 31 23:59:59 → Feb 1 00:00:00
    try std.testing.expectEqual(feb1, calcNext(feb1 - 1, .{ .schedule = schedule }));
}

test "Calculate next: 0 0 12 * * * (daily at noon)" {
    const template = comptime CronTemplate.Lexer.lex("job 0 0 12 * * *");
    const ast = comptime CronTemplate.Parser.parse(template);
    const schedule = comptime CronTemplate.VM.evalToplevel(ast);

    const noon: i64 = 12 * 3600;

    // Midnight → same day noon
    try std.testing.expectEqual(noon, calcNext(0, .{ .schedule = schedule }));

    // Noon → next day noon
    try std.testing.expectEqual(noon + 24 * 3600, calcNext(noon, .{ .schedule = schedule }));

    // 1pm → next day noon
    try std.testing.expectEqual(noon + 24 * 3600, calcNext(13 * 3600, .{ .schedule = schedule }));
}

fn nextOffset(schedule: CronTemplate.VM.Schedule, timestamp: i64) i64 {
    // NOTE: This is probably incorrect. But my brain hurty.
    const epoch = std.time.epoch.EpochSeconds{
        .secs = @intCast(timestamp),
    };
    const second = epoch.getDaySeconds().getSecondsIntoMinute();
    const soffset = @ctz(schedule.seconds >> second);
    const minute = epoch.getDaySeconds().getMinutesIntoHour();
    const moffset = @ctz(schedule.minutes >> minute);
    const hour = epoch.getDaySeconds().getHoursIntoDay();
    const hoffset = @ctz(schedule.hours >> hour);
    const epoch_year = epoch.getEpochDay().calculateYearDay();
    const epoch_month = epoch_year.calculateMonthDay().month;
    const day = epoch_year.calculateMonthDay().day_index;
    const daysInMonth = std.time.epoch.getDaysInMonth(epoch_year.year, epoch_month);
    const doffset = @ctz(schedule.daysOfMonth >> day);
    const month = epoch_month.numeric() - 1;
    const mthoffset = @ctz(schedule.months >> month);

    if (soffset +| second < 59 and second != 59 and soffset != 0) {
        // There is still a next second that will match.
        return @as(i64, soffset);
    }
    // No seconds left that will match.

    if (moffset +| minute < 59 and minute != 59 and moffset != 0) {
        return @as(i64, moffset) * 60 - second;
    }

    if (hoffset +| hour < 23 and hour != 23 and hoffset != 0) {
        return @as(i64, hoffset) * 60 * 60 - @as(i64, minute) * 60 - second;
    }

    if (doffset != 0 and doffset +| day < daysInMonth) {
        return @as(i64, doffset) * 24 * 60 * 60 - @as(i64, hour) * 60 * 60 - @as(i64, minute) * 60 - second;
    }

    if (mthoffset != 0 and mthoffset +| month < 11 and month != 11) {
        // We calculate the minimum safe offset to jump by.
        // All months have at least 28 days so this is safe.
        // This lets us hone in on the correct date with the next iteration without
        // complex date calculations.
        const total = @as(i64, 28) * mthoffset * 24 * 60 * 60;

        return total - @as(i64, day) * 24 * 60 * 60 - @as(i64, hour) * 60 * 60 - @as(i64, minute) * 60 - @as(i64, second);
    }

    if (mthoffset >= 11) {
        return (12 - @as(i64, month)) * 28 * 24 * 60 * 60;
    }

    if (doffset >= daysInMonth) {
        return (@as(i64, daysInMonth) - day) * 24 * 60 * 60;
    }

    if (hoffset >= 23) {
        return (@as(i64, 24) - hour) * 60 * 60;
    }

    if (moffset >= 59) {
        return (@as(i64, 60) - minute) * 60;
    }

    if (soffset >= 59) {
        return @as(i64, 60) - second;
    }

    return 0;
}

comptime {
    const Drv = Driver
        .new(.cron)
        .listen(false)
        .jobs(0)
        .routes(&.{})
        .build();

    core.driver.AssertDriver(Drv, .cron);
}

// Ref all decls
comptime {
    const Rs = struct {
        pub fn @"simple 0 */5 * * * *"() void {}
        pub fn @"withDI 0 0 12 * * *"(dependency: i64) void {
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
        .new(.cron)
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
    _ = Sch(.cron);

    // Shim machinery: generics are lazily analyzed, so force instantiation
    // against the dummy driver's real scheduler type.
    const Bridge = SchedulerBridge(Sch(.cron));
    const Ctx = BridgeShimCtx(Sch(.cron));
    _ = &Bridge.toShim;
    _ = &Ctx.shimSchedulerFac;

    _ = E;
}

test "SchedulerShim: list/query/cancel/resurrect through the erased vtable" {
    const Rs = struct {
        pub fn @"simple 0 */5 * * * *"() void {}
        pub fn @"withDI 0 0 12 * * *"(dependency: i64) void {
            _ = dependency;
        }
    };

    const Drv = Driver
        .new(.cron)
        .listen(false)
        .jobs(0)
        .routes(From(Rs))
        .build();

    const Ds = core.driver.Drivers.new().registerHandler(Drv);
    // Index 0 is the auto-seeded internal driver; our cron handler is at 1.
    const Handler = Ds.Handlers(Ds.EventList(), Ds.EventValues())[1];
    const a = std.testing.allocator;

    var h = try Handler.init(a);
    defer h.deinit(a);

    var bridge = SchedulerBridge(@TypeOf(h.scheduler())){ .real = h.scheduler() };
    const shim = bridge.toShim();

    // Both static route jobs are visible through the erased list.
    {
        const jobs = try shim.list(a);
        defer {
            for (jobs) |ji| {
                a.free(ji.id);
                a.free(ji.on_invoke_action);
            }
            a.free(jobs);
        }
        try std.testing.expectEqual(@as(usize, 2), jobs.len);
        for (jobs) |ji| {
            try std.testing.expectEqualStrings("route", ji.kind);
            try std.testing.expect(std.mem.eql(u8, ji.id, "simple") or std.mem.eql(u8, ji.id, "withDI"));
            try std.testing.expect(!ji.oneshot);
        }
    }

    // Query by route name; unknown names are not-found, not errors.
    {
        const ji = (try shim.query(.{ .route = "simple" }, a)).?;
        defer {
            a.free(ji.id);
            a.free(ji.on_invoke_action);
        }
        try std.testing.expectEqualStrings("simple", ji.id);
    }
    try std.testing.expectEqual(@as(?JobInfo, null), try shim.query(.{ .route = "nonsense" }, a));
    try std.testing.expectEqual(@as(?JobInfo, null), try shim.query(.{ .anonymous = "nope" }, a));

    // Cancel a route job, confirm it is gone, resurrect it, confirm it is back.
    try std.testing.expect(shim.cancel(.{ .route = "simple" }) != null);
    try std.testing.expectEqual(@as(?JobInfo, null), try shim.query(.{ .route = "simple" }, a));
    try std.testing.expect(shim.cancel(.{ .route = "simple" }) == null);

    try shim.resurrect("simple");
    {
        const ji = (try shim.query(.{ .route = "simple" }, a)).?;
        defer {
            a.free(ji.id);
            a.free(ji.on_invoke_action);
        }
        try std.testing.expectEqualStrings("simple", ji.id);
    }
    try std.testing.expectError(error.UnknownRoute, shim.resurrect("nonsense"));

    // Trigger's not-found paths return before touching the (unbound) queue.
    try std.testing.expect((try shim.trigger(.{ .route = "nonsense" }, null)) == null);
    try std.testing.expect((try shim.trigger(.{ .anonymous = "nope" }, null)) == null);
}
