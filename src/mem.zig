const std = @import("std");
const metrics = @import("metrics.zig");

pub const InternalArena = struct {
    alloc: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    instrumented: *InstrumentedAllocator,

    pub fn init(alloc: std.mem.Allocator) !InternalArena {
        const result = InternalArena{
            .alloc = alloc,
            .arena = try alloc.create(std.heap.ArenaAllocator),
            .instrumented = try alloc.create(InstrumentedAllocator),
        };
        result.instrumented.* = metrics.instrumentAllocator(std.heap.page_allocator);
        result.arena.* = std.heap.ArenaAllocator.init(result.instrumented.allocator());
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
        self.alloc.destroy(self.instrumented);
    }
};

pub const InstrumentedAllocator = @import("allocator.zig").InstrumentedAllocator;
pub const MemMetricsShim = @import("allocator.zig").MemMetricsShim;
