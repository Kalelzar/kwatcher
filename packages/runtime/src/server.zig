const builtin = @import("builtin");
const std = @import("std");
const klib = @import("klib");

const log = std.log.scoped(.server);

const core = @import("kw-core");
const Drivers = core.driver.Drivers;
const Event = core.event.Event;
const Props = core.event.Properties;
const ExProps = core.event.ExtendedProperties;
const dep = core.deps;

const shared = core.shared;
const arc = core.arc;
const MCMPQueue = core.queue.StaticStrict;

const kwev = @import("kw-kwev");
const recorder = kwev.recorder;

const ScopedAllocator = core.mem.ScopedAllocator;

pub const Root = @This();

const PropCtx = struct {
    props: Props,
};

pub fn Server(comptime _Deps: type, comptime D: Drivers) type {
    const EventType = D.EventList();
    const EventValues = D.EventValues();
    const E = Event(EventType, EventValues);
    const Handlers = D.Handlers(EventType, EventValues);
    const SchCtx = D.SchedulerCtx();
    // The internal driver is always seeded, so its scheduler is always available
    // to bridge into the type-erased shim that framework-level routes depend on.
    const InternalScheduler = D.Schedulers()[@intFromEnum(@as(D.DriverKeys(), .internal))];
    const ShimCtx = core.scheduler.BridgeShimCtx(InternalScheduler);
    const Deps = comptime blk: {
        var Dm = _Deps;
        for (SchCtx) |S| {
            Dm = Dm.Static(.all, *S);
        }
        Dm = Dm.Static(.all, *ShimCtx);
        break :blk Dm;
    };
    Deps.verify();
    return struct {
        const Self = @This();

        should_run: bool,
        consumers: u8,
        allocator: std.mem.Allocator,
        queue: MCMPQueue(E),
        handlers: std.meta.Tuple(&Handlers) = undefined,
        schedulers: std.meta.Tuple(&SchCtx) = std.mem.zeroInit(std.meta.Tuple(&SchCtx), .{}),
        shim_ctx: ShimCtx = .{},
        deps: Deps,
        rand: std.Random.Xoshiro256 = std.Random.DefaultPrng.init(0),

        pub fn init(alloc: std.mem.Allocator, context: _Deps, consumers: u8) !Self {
            var f = try kwev.KWEV.init("static.kwev", 512 * 1024);
            defer f.deinit();
            const fs = try kwev.inscribe(&f, D);
            try f.finalize(fs);

            const size = 1024;
            return .{
                .should_run = true,
                .allocator = alloc,
                .queue = .init(try alloc.alignedAlloc(
                    E,
                    std.mem.Alignment.@"16",
                    size,
                ), try alloc.alloc(u1, size)),
                .deps = context.become(Deps),
                .consumers = consumers,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.queue.buffer);
            self.allocator.free(self.queue.occupancy);
            self.deps.deinit(self.allocator);
            inline for (Handlers, 0..) |_, i| {
                self.handlers[i].deinit(self.allocator);
            }
            // TODO: deinit schedulers
        }

        fn bind(self: *Self) !void {
            var od = self.deps.become(_Deps);
            self.handlers = try D.initAll(self.allocator, &od, EventType, EventValues);
            inline for (Handlers, 0..) |_, i| {
                var h = &self.handlers[i];
                h.bind(&self.queue);
                self.schedulers[i].scheduler = h.scheduler();
                self.deps.staticAssumeRegistered(.all, &self.schedulers[i]);
            }
            self.deps.staticAssumeRegistered(.all, &self.shim_ctx);
        }

        fn watch(self: *Self) !void {
            const pool = try self.allocator.create(std.Thread.Pool);
            defer self.allocator.destroy(pool);
            const jobs = comptime blk: {
                var jobs: u8 = 0;
                for (D.drivers) |Dvs| {
                    jobs += Dvs.jobs;
                }
                break :blk jobs;
            };

            try std.Thread.Pool.init(pool, .{ .allocator = self.allocator, .n_jobs = jobs });
            defer pool.deinit();
            var wg = std.Thread.WaitGroup{};

            inline for (Handlers, 0..) |_, i| {
                var dep_ctx = try self.deps.compile(
                    D.drivers[i].key,
                    .scoped,
                    self.allocator,
                );
                const H = struct {
                    allocator: std.mem.Allocator,
                    pub fn deinit(this: *@This(), target: *dep.DepCtx) void {
                        Deps.deactualize(target, D.drivers[i].key, .scoped);
                        Deps.reset(target, D.drivers[i].key, .scoped, this.allocator);
                    }
                };

                try self.deps.prepare(
                    &dep_ctx,
                    D.drivers[i].key,
                    .scoped,
                    self.allocator,
                );
                try self.deps.actualize(D.drivers[i].key, .scoped, &dep_ctx);

                const scoped = try dep_ctx.require(ScopedAllocator);
                const arcctx = try arc.ArcCtx(dep.DepCtx, H).init(
                    scoped.value,
                    .{
                        .data = dep_ctx,
                        .ctx = .{
                            .allocator = self.allocator,
                        },
                    },
                );
                try self.handlers[i].watch(&wg, pool, arcctx);
            }

            pool.waitAndWork(&wg);
        }

        fn EventOf(comptime ev: EventType) ?struct { type, usize } {
            inline for (Handlers, 0..) |H, i| {
                if (comptime H.accepts(ev)) return .{ H, i };
            }
            return null;
        }

        fn begin(self: *Self) !void {
            const pool = try self.allocator.create(std.Thread.Pool);
            defer self.allocator.destroy(pool);
            try std.Thread.Pool.init(pool, .{ .allocator = self.allocator, .n_jobs = self.consumers });
            defer pool.deinit();
            var wg = std.Thread.WaitGroup{};

            for (0..self.consumers) |_| {
                pool.spawnWg(&wg, Self.run, .{self});
            }

            pool.waitAndWork(&wg);
        }

        pub fn stop(self: *Self) void {
            @atomicStore(bool, &self.should_run, false, .release);
            inline for (Handlers, 0..) |_, i| {
                self.handlers[i].stop();
            }
            for (0..self.consumers) |_| {
                log.debug("Poison", .{});
                _ = self.queue.push(.{
                    .event_type = .shutdownImminent,
                    .event_data = .{ .internal = .{ .shutdownImminent = .{} } },
                });
            }
        }

        fn run(self: *Self) void {
            var buffer: [D.drivers.len * 8 * 1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buffer);
            var driver_map: [D.drivers.len]dep.DepCtx = undefined;
            var rec: recorder.Recorder = undefined;
            recorder.Recorder.initPinned(
                &rec,
                std.Thread.getCurrentId(),
                256 * 1024,
            ) catch unreachable;
            defer rec.deinit();
            inline for (D.drivers, 0..) |Driver, i| {
                driver_map[i] = self.deps.compile(Driver.key, .scoped, fba.allocator()) catch unreachable;
                self.deps.prepare(&driver_map[i], Driver.key, .scoped, fba.allocator()) catch unreachable;
            }

            defer {
                inline for (D.drivers, 0..) |Driver, i| {
                    defer Deps.reset(&driver_map[i], Driver.key, .scoped, fba.allocator());
                }
            }

            while (@atomicLoad(bool, &self.should_run, .acquire) or !self.queue.empty()) {
                self.handle(false, &driver_map, &rec) catch |e| switch (e) {
                    error.ShutdownImminent => {
                        log.debug("T{d} will now drain", .{std.Thread.getCurrentId()});
                        self.drain(&driver_map, &rec) catch {};
                        log.debug("T{d} has exited", .{std.Thread.getCurrentId()});
                        return;
                    },
                    error.Shutdown => {
                        log.debug("T{d} has been shutdown", .{std.Thread.getCurrentId()});
                        return;
                    },
                    else => log.err("Failure: {t}", .{e}),
                };
            }
        }

        fn drain(self: *Self, injmap: []dep.DepCtx, rec: *recorder.Recorder) !void {
            while (true) {
                const front = self.queue.peek();
                if (front) |_| {
                    log.debug("T{d}: Trying", .{std.Thread.getCurrentId()});
                    self.handle(true, injmap, rec) catch |e| switch (e) {
                        error.Empty => {
                            log.info("Queue drained. Shutting thread {d} down.", .{std.Thread.getCurrentId()});
                            return;
                        },
                        error.Shutdown => {
                            log.info("Shutdown thread {d} successfully.", .{std.Thread.getCurrentId()});
                            return;
                        },
                        else => log.err("Caught error while draining: {s}", .{@errorName(e)}),
                    };
                    log.debug("T{d}: Drained 1", .{std.Thread.getCurrentId()});
                } else {
                    log.info("Queue drained. Shutting thread {d} down.", .{std.Thread.getCurrentId()});
                    return;
                }
            }
        }

        fn handle(
            self: *Self,
            is_draining: bool,
            injmap: []dep.DepCtx,
            rec: *recorder.Recorder,
        ) !void {
            var maybe_next = if (is_draining) self.queue.tryPop(std.time.ns_per_ms * 5) orelse return error.Empty else self.queue.pop();

            switch (maybe_next.event_type) {
                .noop => {
                    log.debug("Noop :)", .{});
                },
                .shutdown => {
                    self.stop();
                },
                .shutdownImminent => {
                    if (!is_draining) {
                        log.debug("Shutting down thread. :)", .{});
                        return error.ShutdownImminent;
                    } else {
                        log.debug("Draining. :)", .{});
                        _ = self.queue.push(maybe_next);
                        return error.Shutdown;
                    }
                },
                inline else => |ev| {
                    const err: anyerror!void = fail: {
                        const Handler = comptime EventOf(ev);
                        if (comptime Handler == null) {
                            @branchHint(.cold);
                            break :fail error.InvalidEvent;
                        } else {
                            @branchHint(.likely);
                            const H, const i = comptime Handler.?;
                            const handler = &self.handlers[i];
                            const Driver = comptime D.drivers[i];

                            const inj_ctx = &injmap[i];
                            self.deps.actualize(Driver.key, .scoped, inj_ctx) catch |e| break :fail e;
                            defer Deps.deactualize(inj_ctx, Driver.key, .scoped);

                            if (maybe_next.properties.correlation_id == 0) {
                                var buf: [16]u8 = undefined;
                                std.Random.bytes(self.rand.random(), &buf);
                                maybe_next.properties.correlation_id = std.mem.bytesToValue(u128, &buf);
                            }

                            var prop_ctx = PropCtx{ .props = maybe_next.properties };
                            const o = inj_ctx.require(ScopedAllocator) catch |e| break :fail e;
                            var v = dep.DependencyContainer(struct {}).newBlank(D, o.value).static(
                                .all,
                                &prop_ctx,
                            );
                            var cm = v.compile(Driver.key, .scoped, o.value) catch |e| break :fail e;
                            v.prepare(&cm, Driver.key, .scoped, o.value) catch |e| break :fail e;
                            v.actualize(Driver.key, .scoped, &cm) catch |e| break :fail e;
                            cm.parent = inj_ctx;
                            defer @TypeOf(v).deactualize(&cm, Driver.key, .scoped);

                            @call(.auto, H.handle, .{
                                handler,
                                ev,
                                maybe_next,
                                &cm,
                            }) catch |e| break :fail e;

                            try rec.append(maybe_next);
                        }
                    };

                    err catch |e| {
                        try rec.append(maybe_next);
                        return e;
                    };
                },
            }
        }

        pub fn start(self: *@This()) !void {
            try self.bind();

            const thread = try std.Thread.spawn(
                .{ .allocator = self.allocator },
                watch,
                .{self},
            );
            try self.begin();
            thread.join();
        }
    };
}
