const std = @import("std");
const kwatcher = @import("kwatcher");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const cacheConfig = comptime kwatcher.cache.context.file.Cache(usize, .{usize})
        .key(.bench)
        .evict(.lru)
        .residency(.{ .count = 256 })
        .expiration(.{ .unlimited = {} })
        .intern();

    const nstr = args.next() orelse "256";
    const n = try std.fmt.parseUnsigned(usize, nstr, 10);

    var ctx = try cacheConfig.initContext(allocator, "bench/lru");
    defer ctx.deinit();

    for (0..n) |i| {
        var hasher = std.crypto.hash.Blake3.init(.{ .key = null });
        std.hash.autoHashStrat(&hasher, i, .Shallow);
        var hashBytes: [32]u8 = undefined;
        hasher.final(&hashBytes);
        const hash = std.fmt.bytesToHex(&hashBytes, .upper);
        try ctx.put(&hash, i);
    }
}
