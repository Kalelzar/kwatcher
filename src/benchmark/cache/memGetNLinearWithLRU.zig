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

    const nstr2 = args.next() orelse "256";
    const n2 = try std.fmt.parseUnsigned(usize, nstr2, 10);

    var ctx = try cacheConfig.initContext(allocator, "bench");
    defer ctx.deinit();

    for (0..n) |i| {
        try ctx.put(i, i);
    }

    for (0..n2) |j| {
        const i = j % n;
        const v = try ctx.get(i);
        std.mem.doNotOptimizeAway(v);
    }
}
