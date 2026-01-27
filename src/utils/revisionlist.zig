const std = @import("std");

pub fn Arc(comptime Data: type, comptime Ctx: type) type {
    return struct {
        data: *Data,
        refcount: usize,
        ctx: Ctx,

        pub fn ref(self: *Arc(Data, Ctx)) *Data {
            _ = @atomicRmw(usize, &self.refcount, .Add, 1, .seq_cst);
            return self.data;
        }

        pub fn unref(self: *Arc(Data, Ctx), d: *Data) void {
            if (d != self.data) return;
            var v = @atomicLoad(usize, &self.refcount, .acquire);

            while (@cmpxchgWeak(usize, &self.refcount, v, v - 1, .acq_rel, .seq_cst)) {
                v = @atomicLoad(usize, &self.refcount, .acquire);
                if (v == 0) {
                    return;
                }
            }

            if (v == 1) self.deinit();
        }

        pub fn deinit(self: *Arc(Data, Ctx)) void {
            self.ctx.deinit(self.data);
        }
    };
}

pub fn Revision(comptime Data: type, comptime Ctx: type) type {
    return struct {
        const R = struct {
            data: *Arc(Data, InCtx),
            revision: u64,
        };

        const InCtx = struct {
            revision: u64,
            parent: *Revision(Data, Ctx),
            pub fn deinit(self: *InCtx, arc: *Arc(Data, InCtx)) void {
                self.parent.mut.lock();
                defer self.parent.mut.unlock();
                var it = self.parent.queue.iterator();
                var i: usize = 0;
                while (it.next()) |n| : (i += 1) {
                    if (n.revision == self.revision and arc == n.data) {
                        if (i == 0) return;
                        _ = self.parent.queue.removeIndex(i);
                        break;
                    }
                }
                Ctx.deinit(arc.data);
                self.parent.allocator.destroy(arc);
            }
        };

        pub const Handle = struct {
            data: *Data,
            arc: *Arc(Data, InCtx),
            pub fn deinit(self: Handle) void {
                self.arc.unref(self.data);
            }
        };

        const PrioCtx = struct {};
        fn compareRevisions(_: PrioCtx, a: R, b: R) std.math.Order {
            return std.math.order(b.revision, a.revision);
        }

        queue: std.PriorityQueue(R, PrioCtx, compareRevisions),
        mut: std.Thread.Mutex = .{},
        allocator: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{
                .allocator = alloc,
                .queue = .init(alloc, .{}),
            };
        }

        pub fn getActive(self: *@This()) ?Handle {
            self.mut.lock();
            defer self.mut.unlock();
            if (self.queue.peek()) |r| {
                const arc = r.data;
                return .{
                    .data = arc.ref(),
                    .arc = arc,
                };
            }

            return null;
        }

        pub fn upgrade(self: *@This(), h: Handle) Handle {
            self.mut.lock();
            defer self.mut.unlock();
            if (self.queue.peek()) |r| {
                const arc = r.data;
                if (arc.data == h.data) return h;
                h.deinit();
                return .{
                    .data = arc.ref(),
                    .arc = arc,
                };
            }

            return h;
        }

        pub fn revision(self: *@This()) u64 {
            self.mut.lock();
            defer self.mut.unlock();
            return self.revisionUnsynch();
        }

        fn revisionUnsynch(self: *@This()) u64 {
            if (self.queue.peek()) |r| {
                return r.revision;
            }

            return 0;
        }

        pub fn revise(self: *@This(), data: *Data) !void {
            const arc = try self.allocator.create(Arc(Data, InCtx));
            self.mut.lock();
            defer self.mut.unlock();
            const r = R{
                .data = arc,
                .revision = self.revisionUnsynch() + 1,
            };

            arc.* = .{
                .data = data,
                .refcount = 0,
                .ctx = .{
                    .parent = self,
                    .revision = r.revision,
                },
            };

            try self.queue.add(r);
        }
    };
}
