const builtin = @import("builtin");
const std = @import("std");
const klib = @import("klib");

const log = std.log.scoped(.server);

const Drivers = @import("driver.zig").Drivers;
const Event = @import("event.zig").Event;
const Props = @import("event.zig").Properties;
const ExProps = @import("event.zig").ExtendedProperties;
const dep = @import("dep.zig");

const shared = @import("utils/shared.zig");
const arc = @import("utils/arc.zig");
const MCMPQueue = @import("utils/queue.zig").StaticStrict;

const kwev = @import("kwev/kwev.zig");
const recorder = @import("kwev/recorder.zig");

const ScopedAllocator = @import("mem/mem.zig").ScopedAllocator;

pub const Root = @This();

pub fn genAccepts(comptime ET: type, comptime T: type) *const fn (ET) bool {
    const H = struct {
        pub fn accepts(e: ET) bool {
            const v = @intFromEnum(e);

            const bounds = comptime blk: {
                var min: u12 = std.math.maxInt(u12);
                var max: u12 = std.math.minInt(u12);
                for (@typeInfo(T).@"enum".fields) |f| {
                    if (min > f.value) min = f.value;
                    if (max < f.value) max = f.value;
                }

                break :blk .{ .min = min, .max = max - 1 };
            };

            return v >= bounds.min and v <= bounds.max;
        }
    };

    return &H.accepts;
}

const PropCtx = struct {
    props: Props,
};

pub fn Server(comptime _Deps: type, comptime D: Drivers) type {
    const EventType = D.EventList();
    const EventValues = D.EventValues();
    const E = Event(EventType, EventValues);
    const Handlers = D.Handlers(EventType, EventValues);
    const SchCtx = D.SchedulerCtx();
    const Deps = comptime blk: {
        var Dm = _Deps;
        for (SchCtx) |S| {
            Dm = Dm.Static(.all, *S);
        }
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
        deps: Deps,
        rand: std.Random.Xoshiro256 = std.Random.DefaultPrng.init(0),

        pub fn init(alloc: std.mem.Allocator, context: _Deps, consumers: u8) !Self {
            var f = try kwev.KWEV.init("static.kwev", 512 * 1024);
            defer f.deinit();
            const fs = try kwev.inscribe(&f, D);
            try f.finalize(fs);

            return .{
                .should_run = true,
                .allocator = alloc,
                .queue = .init(try alloc.alignedAlloc(
                    E,
                    std.mem.Alignment.@"16",
                    1024,
                )),
                .deps = context.become(Deps),
                .consumers = consumers,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.queue.buffer);
            self.deps.deinit(self.allocator);
            inline for (Handlers, 0..) |_, i| {
                self.handlers[i].deinit(self.allocator);
            }
            // TODO: deinit schedulers
        }

        pub fn bind(self: *Self) !void {
            var od = self.deps.become(_Deps);
            self.handlers = try D.initAll(self.allocator, &od, EventType, EventValues);
            inline for (Handlers, 0..) |_, i| {
                var h = &self.handlers[i];
                h.bind(&self.queue);
                self.schedulers[i].scheduler = h.scheduler();
                self.deps.staticAssumeRegistered(.all, &self.schedulers[i], self.allocator);
            }
        }

        pub fn watch(self: *Self) !void {
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

        pub fn EventOf(comptime ev: EventType) ?struct { type, usize } {
            inline for (Handlers, 0..) |H, i| {
                if (comptime H.accepts(ev)) return .{ H, i };
            }
            return null;
        }

        pub fn begin(self: *Self) !void {
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
                self.queue.push(.{
                    .event_type = .shutdown,
                    .event_data = .{ .internal = .{ .shutdown = .{} } },
                });
            }
        }

        pub fn stopHandler(self: *Self, comptime addr: **anyopaque) std.posix.Sigaction.handler_fn {
            const H = struct {
                pub fn shutdown(_: c_int) callconv(.c) void {
                    const s: *Self = @ptrCast(@alignCast(addr.*));
                    s.stop();
                }
            };

            addr.* = @ptrCast(@alignCast(self));

            return H.shutdown;
        }

        fn run(self: *Self) void {
            var buffer: [16 * 1024]u8 = undefined;
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
                    else => log.err("Failure: {t}", .{e}),
                };
            }
        }

        fn drain(self: *Self, injmap: []dep.DepCtx, rec: *recorder.Recorder) !void {
            while (true) {
                const front = self.queue.peek();
                if (front) |_| {
                    log.debug("T{d}: Trying", .{std.Thread.getCurrentId()});
                    self.handle(true, injmap, rec) catch |e| {
                        log.err("Caught error while draining: {s}", .{@errorName(e)});
                    };
                    log.debug("T{d}: Drained 1", .{std.Thread.getCurrentId()});
                }
                return;
            }
        }

        fn handle(
            self: *Self,
            is_draining: bool,
            injmap: []dep.DepCtx,
            rec: *recorder.Recorder,
        ) !void {
            var maybe_next = if (is_draining) self.queue.tryPop(std.time.ns_per_ms * 5) orelse return else self.queue.pop();

            handle: switch (maybe_next.event_type) {
                .noop => {
                    log.debug("Noop :)", .{});
                },
                .shutdown => {
                    if (!is_draining) {
                        log.debug("Shutting down thread. :)", .{});
                        return error.ShutdownImminent;
                    } else {
                        log.debug("Draining. :)", .{});
                        self.queue.push(maybe_next);
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
                            var v = dep.DependencyContainer(struct {}).newBlank(D).static(
                                .all,
                                &prop_ctx,
                                o.value,
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
                        if (maybe_next.properties.attempts >= 3 or (e == error.Cancelled or e == error.Reject)) {
                            try rec.append(maybe_next);
                            return e;
                        }

                        log.warn(
                            "[{d}/3] Route {s} failed with error '{}'. Retrying...",
                            .{ maybe_next.properties.attempts + 1, @tagName(ev), e },
                        );

                        maybe_next.properties.attempts += 1;
                        self.queue.tryPush(
                            maybe_next,
                            std.time.ns_per_ms * 1,
                        ) catch |e2| switch (e2) {
                            error.WouldBlock => {
                                continue :handle ev;
                            },
                            else => return e,
                        };
                    };
                },
            }
        }

        pub fn start(self: *@This()) !void {
            const H = struct {
                var slot: *anyopaque = undefined;
            };

            if (comptime builtin.os.tag == .linux) {
                // call our shutdown function (below) when
                // SIGINT or SIGTERM are received
                std.posix.sigaction(std.posix.SIG.INT, &.{
                    .handler = .{
                        .handler = self.stopHandler(&H.slot),
                    },
                    .mask = std.posix.sigemptyset(),
                    .flags = 0,
                }, null);
                std.posix.sigaction(std.posix.SIG.TERM, &.{
                    .handler = .{ .handler = self.stopHandler(&H.slot) },
                    .mask = std.posix.sigemptyset(),
                    .flags = 0,
                }, null);
            }

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
