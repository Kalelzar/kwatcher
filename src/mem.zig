const std = @import("std");

pub const InternalArena = struct {
    alloc: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,

    pub fn init(alloc: std.mem.Allocator) !InternalArena {
        const result = InternalArena{
            .alloc = alloc,
            .arena = try alloc.create(std.heap.ArenaAllocator),
        };
        result.arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        return result;
    }

    pub fn allocator(self: *InternalArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn reset(self: *InternalArena) void {
        // We should probably do something with this.
        // But for now. I do not care.
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn deinit(self: *InternalArena) void {
        self.arena.deinit();
        self.alloc.destroy(self.arena);
    }
};
