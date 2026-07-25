const std = @import("std");

pub const PoolAllocator = struct {
    underlying: std.mem.Allocator,
    free: std.ArrayList(*Block),
    used: std.ArrayList(*Block),
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) PoolAllocator {
        return .{
            .underlying = allocator,
            .free = .{},
            .used = .{},
        };
    }

    pub fn suballocator(self: *PoolAllocator) !std.mem.Allocator {
        self.mutex.lock();
        defer self.mutex.unlock();

        const next = self.free.pop();
        if (next) |b| {
            self.used.appendAssumeCapacity(b);
            return b.allocator();
        }

        const new_block = try self.underlying.create(Block);
        errdefer self.underlying.destroy(new_block);
        new_block.* = .{
            .len = 0,
            .page = try self.underlying.alloc(u8, 2 * std.heap.page_size_max),
        };
        errdefer self.underlying.free(new_block.page);
        try self.used.append(self.underlying, new_block);
        try self.free.ensureTotalCapacity(self.underlying, self.used.capacity);
        return new_block.allocator();
    }

    pub fn suballocatorCustom(self: *PoolAllocator, size: usize) !std.mem.Allocator {
        self.mutex.lock();
        defer self.mutex.unlock();

        const next = self.free.pop();
        if (next) |b| {
            self.used.appendAssumeCapacity(b);
            return b.allocator();
        }

        const new_block = try self.underlying.create(Block);
        errdefer self.underlying.destroy(new_block);
        new_block.* = .{
            .len = 0,
            .page = try self.underlying.alloc(u8, size),
        };
        errdefer self.underlying.free(new_block.page);
        try self.used.append(self.underlying, new_block);
        try self.free.ensureTotalCapacity(self.underlying, self.used.capacity);
        return new_block.allocator();
    }

    /// Rewinds a leased suballocator for reuse without returning it to the pool.
    /// The caller keeps the lease; everything allocated from it so far is invalidated.
    pub fn recycle(self: *PoolAllocator, alloc: std.mem.Allocator) !std.mem.Allocator {
        self.mutex.lock();
        defer self.mutex.unlock();

        const block: *Block = @ptrCast(@alignCast(alloc.ptr));

        for (self.used.items) |item| {
            if (item == block) {
                block.len = 0;
                return alloc;
            }
        }

        return error.InvalidAllocator;
    }

    pub fn reset(self: *PoolAllocator, alloc: std.mem.Allocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const block: *Block = @ptrCast(@alignCast(alloc.ptr));

        for (self.used.items, 0..) |item, i| {
            if (item == block) {
                const b = self.used.swapRemove(i);
                b.len = 0;
                self.free.appendAssumeCapacity(b);
                return;
            }
        }

        return error.InvalidAllocator;
    }

    pub fn deinit(self: *PoolAllocator) void {
        // WARNING: This does not wait for users to be done with their allocator before freeing
        // This can and will segfault in multithreaded scenarios at shutdown.
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.free.items) |b| {
            self.underlying.free(b.page);
            self.underlying.destroy(b);
        }
        self.free.deinit(self.underlying);

        for (self.used.items) |b| {
            self.underlying.free(b.page);
            self.underlying.destroy(b);
        }
        self.used.deinit(self.underlying);
    }

    const Block = struct {
        page: []u8,
        len: usize = 0,

        pub fn allocator(self: *Block) std.mem.Allocator {
            return .{
                .ptr = @ptrCast(@alignCast(self)),
                .vtable = &.{
                    .alloc = Block.alloc,
                    .resize = Block.resize,
                    .remap = Block.remap,
                    .free = Block.free,
                },
            };
        }

        pub fn alloc(
            ptr: *anyopaque,
            len: usize,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) ?[*]u8 {
            _ = ret_addr;
            const self: *Block = @ptrCast(@alignCast(ptr));
            const available = alignment.forward(@intFromPtr(self.page.ptr) + self.len);
            const offset = available - @intFromPtr(self.page.ptr);
            if (offset + len > self.page.len) return null;
            self.len = offset + len;
            return self.page[offset .. offset + len].ptr;
        }

        pub fn resize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
            return memory.len >= new_len;
        }

        pub fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            if (memory.len >= new_len) return memory.ptr;
            const self: *Block = @ptrCast(@alignCast(ptr));

            const addr = @intFromPtr(self.page.ptr) + self.len - memory.len;
            if (addr == @intFromPtr(memory.ptr)) {
                // Expand in-place.
                const extra = new_len - memory.len;
                if (self.len + extra > self.page.len) return null;
                self.len += extra;
                return memory.ptr;
            } else {
                const buffer = alloc(ptr, new_len, alignment, ret_addr);
                if (buffer != null) {
                    @memmove(buffer.?, memory);
                }
                return buffer;
            }
        }

        pub fn free(ptr: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
            const self: *Block = @ptrCast(@alignCast(ptr));
            const addr = @intFromPtr(self.page.ptr) + self.len - memory.len;
            if (addr == @intFromPtr(memory.ptr)) {
                // Shrink in-place
                self.len -= memory.len;
            }
        }
    };
};

test "recycle rewinds the block but keeps the lease" {
    var pool = PoolAllocator.init(std.testing.allocator);
    defer pool.deinit();

    const lease = try pool.suballocator();
    _ = try lease.alloc(u8, 128);

    const recycled = try pool.recycle(lease);
    try std.testing.expectEqual(@intFromPtr(lease.ptr), @intFromPtr(recycled.ptr));
    try std.testing.expectEqual(1, pool.used.items.len);
    try std.testing.expectEqual(0, pool.free.items.len);

    const block: *PoolAllocator.Block = @ptrCast(@alignCast(recycled.ptr));
    try std.testing.expectEqual(0, block.len);

    // The lease is still valid and still ours: returning it hands the block back.
    try pool.reset(recycled);
    try std.testing.expectEqual(0, pool.used.items.len);
    try std.testing.expectEqual(1, pool.free.items.len);
}

test "recycle rejects an allocator that is not a live lease" {
    var pool = PoolAllocator.init(std.testing.allocator);
    defer pool.deinit();

    const lease = try pool.suballocator();
    try pool.reset(lease);

    try std.testing.expectError(error.InvalidAllocator, pool.recycle(lease));
}
