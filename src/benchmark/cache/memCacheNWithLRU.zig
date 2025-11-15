const std = @import("std");
const kwatcher = @import("kwatcher");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const cacheConfig = comptime kwatcher.cache.context.memory.Cache(usize, .{usize})
        .key(.bench)
        .evict(.lru)
        .residency(.{ .count = 256 })
        .expiration(.{ .unlimited = {} })
        .intern();

    const nstr = args.next() orelse "256";
    const n = try std.fmt.parseUnsigned(usize, nstr, 10);

    var ctx = try cacheConfig.initContext(allocator, "bench");
    defer ctx.deinit();

    for (0..n) |i| {
        var buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "{d}", .{i});
        try ctx.put(key, i);
    }
}
