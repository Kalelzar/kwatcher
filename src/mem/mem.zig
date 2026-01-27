const std = @import("std");
const klib = @import("klib");

pub fn Keyed(comptime Data: type, comptime key: anytype) type {
    _ = key;
    return struct {
        value: Data,
    };
}

pub const InternalArena = klib.mem.InstrumentedArena;

pub const PoolAllocator = @import("pool_allocator.zig").PoolAllocator;
pub const ScopedAllocator = Keyed(std.mem.Allocator, .scoped);
