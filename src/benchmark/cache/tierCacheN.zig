const std = @import("std");
const kwatcher = @import("kwatcher");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const cacheConfig = comptime kwatcher.cache.context.tiered.Cache(usize, .{usize}, .{
        .mem = kwatcher.cache.context.memory.Resolver,
        .file = kwatcher.cache.context.file.Resolver,
    }).key(.bench)
        .evict(.{
            .mem = .none,
            .file = .none,
        })
        .residency(.{
            .mem = kwatcher.cache.Residency{ .unlimited = {} },
            .file = kwatcher.cache.Residency{ .unlimited = {} },
        })
        .expiration(.{
            .mem = kwatcher.cache.Expiration{ .unlimited = {} },
            .file = kwatcher.cache.Expiration{ .unlimited = {} },
        })
        .intern();

    const nstr = args.next() orelse "256";
    const n = try std.fmt.parseUnsigned(usize, nstr, 10);

    _ = n;
    _ = cacheConfig;
    //TODO: Since initContext isn't possible here do a complete proper Cache init
    //
    //var ctx = cacheConfig.initContext(allocator, "bench");
    //defer ctx.deinit();

    //for (0..n) |i| {
    //    var buf: [16]u8 = undefined;
    //    const key = try std.fmt.bufPrint(&buf, "{d}", .{i});
    //    try ctx.put(key, i);
    //}
}
