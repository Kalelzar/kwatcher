const std = @import("std");
const cache = @import("cache.zig");

pub fn Memory(comptime Data: type, comptime Invariant: anytype) cache.SetBuilder(Data, Invariant) {
    return cache.SetBuilder(Data, Invariant)
        .new()
        .hotRaw(cache.autoCacheWithContexts(Data, Invariant, .{MemoryContext(Data)}));
}

/// A simple hash map backed in-memory cache.
/// NOTE: This should be converted to a vtable so that the implementation can be swapped by the user.
pub fn MemoryContext(comptime Data: type) type {
    return struct {
        pub const id = "memory";
        buf: std.StringArrayHashMapUnmanaged(Data),
        allocator: std.mem.Allocator,

        pub fn get(self: *@This(), key: []const u8) !?Data {
            return self.buf.get(key);
        }

        pub fn put(self: *@This(), key: []const u8, data: Data) !void {
            return self.buf.put(
                self.allocator,
                try self.allocator.dupe(u8, key),
                data,
            );
        }

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .buf = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            var it = self.buf.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                if (comptime @hasDecl(Data, "deinit")) {
                    // FIXME: Call this function with an allocator if possible.
                    //e.value_ptr.deinit();
                }
            }

            self.buf.deinit(self.allocator);
        }
    };
}
