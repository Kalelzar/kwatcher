const std = @import("std");
const kwatcher = @import("kwatcher");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const cacheConfig = comptime kwatcher.cache.context.memory.Cache(usize, .{usize})
        .key(.bench)
        .evict(.none)
        .residency(.{ .unlimited = {} })
        .expiration(.{ .absolute = 5 })
        .intern();

    const nstr = args.next() orelse "256";
    const n = try std.fmt.parseUnsigned(usize, nstr, 10);

    var ctx = cacheConfig.initContext(allocator, "bench");
    defer ctx.deinit();

    for (0..n) |i| {
        try ctx.put(i, i);
    }
}
