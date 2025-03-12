const std = @import("std");

pub const MemMetricsShim = struct {
    alloc: *const fn (bytes: usize) void,
    free: *const fn (bytes: usize) void,
};

pub const InstrumentedAllocator = struct {
    child_allocator: std.mem.Allocator,
    metrics_shim: MemMetricsShim,

    pub fn init(child_allocator: std.mem.Allocator, metrics_shim: MemMetricsShim) InstrumentedAllocator {
        return .{
            .child_allocator = child_allocator,
            .metrics_shim = metrics_shim,
        };
    }

    pub fn allocator(self: *InstrumentedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *InstrumentedAllocator = @ptrCast(@alignCast(ctx));
        self.metrics_shim.alloc(n);
        return self.child_allocator.rawAlloc(n, alignment, ra);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *InstrumentedAllocator = @ptrCast(@alignCast(ctx));

        if (buf.len < new_len) {
            self.metrics_shim.alloc(new_len - buf.len);
        } else {
            self.metrics_shim.free(buf.len - new_len);
        }

        return self.child_allocator.rawResize(buf, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *InstrumentedAllocator = @ptrCast(@alignCast(ctx));
        if (memory.len < new_len) {
            self.metrics_shim.alloc(new_len - memory.len);
        } else {
            self.metrics_shim.free(memory.len - new_len);
        }
        return self.child_allocator.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *InstrumentedAllocator = @ptrCast(@alignCast(ctx));
        self.metrics_shim.free(buf.len);
        return self.child_allocator.rawFree(buf, alignment, ret_addr);
    }
};
