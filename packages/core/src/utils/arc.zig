const std = @import("std");
const queue = @import("queue.zig");

pub fn Arc(comptime Data: type) type {
    return struct {
        data: Data,
        refcount: usize,

        pub fn init(alloc: std.mem.Allocator, data: Data) !*Arc(Data) {
            const ptr = try alloc.create(Arc(Data));
            ptr.initPinned(data);
            return ptr;
        }

        pub fn initPinned(self: *Arc(Data), data: Data) void {
            self.* = .{
                .data = data,
                .refcount = 0,
            };
        }

        pub fn ref(self: *Arc(Data)) *Data {
            _ = @atomicRmw(usize, &self.refcount, .Add, 1, .seq_cst);

            return &self.data;
        }

        pub fn unref(self: *Arc(Data)) void {
            var v = @atomicLoad(usize, &self.refcount, .acquire);
            std.debug.assert(v > 0);

            v = @atomicRmw(usize, &self.refcount, .Sub, 1, .seq_cst);
            std.debug.assert(v > 0);
            if (v == 1) self.deinit();
        }

        pub fn deinit(self: *Arc(Data)) void {
            self.data.deinit();
        }
    };
}

pub fn ArcCtx(comptime Data: type, comptime Ctx: type) type {
    const D = struct {
        data: Data,
        ctx: Ctx,

        pub fn deinit(self: *@This()) void {
            self.ctx.deinit(&self.data);
        }
    };

    return Arc(D);
}

/// An atomic structure that keeps a reference alive and can swap it's value without invalidating old ones.
/// Note: This is thread-safe so long as you scale your grace buffer to such that
/// it is guaranteed that all readers will have transitioned to a new version until
/// the buffer overflows.
/// As such it is not suitable for rapidly changing data since it would require unreasonable
/// amounts of memory.
pub fn ArcSwap(comptime Data: type, comptime Ctx: type) type {
    return struct {
        const Self = @This();
        const DataRc = ArcCtx(Data, Ctx);
        allocator: std.mem.Allocator,
        debt: queue.StaticLenient(DataRc),

        pub fn init(allocator: std.mem.Allocator, grace: u8) !ArcSwap(Data, Ctx) {
            std.debug.assert(grace > 2);
            const location = try allocator.alloc(DataRc, grace);
            errdefer allocator.free(location);
            return .{
                .allocator = allocator,
                .debt = .init(location),
            };
        }

        pub fn get(self: *Self) ?*DataRc {
            return self.debt.peekEndPtr();
        }

        pub fn next(self: *Self, data: Data) void {
            var overflow = self.debt.push(
                .{
                    .data = .{ .data = data, .ctx = .{} },
                    .refcount = 1,
                },
            );

            if (overflow) |*o| {
                o.unref();
            }
        }

        pub fn deinit(self: *Self) void {
            var debt: *queue.StaticLenient(DataRc) = &self.debt;
            while (debt.drain()) |*p| {
                const mp: *DataRc = @constCast(p); //FIXME: Const cast
                mp.unref();
            }
            self.allocator.free(self.debt.buffer);
        }
    };
}

// Ref all decls
comptime {
    const Data = struct {
        pub fn deinit(_: *@This()) void {}
    };
    const Ctx = struct {
        pub fn deinit(_: *@This(), _: *u8) void {}
    };
    std.testing.refAllDeclsRecursive(Arc(Data));
    std.testing.refAllDeclsRecursive(ArcCtx(u8, Ctx));
    std.testing.refAllDeclsRecursive(ArcSwap(u8, Ctx));
}
