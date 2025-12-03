const std = @import("std");
const kwatcher = @import("kwatcher");

const Root = struct {
    allocator: std.mem.Allocator,
};

const Ctx = struct {
    const Config = kwatcher.cache.context.memory.Cache(
        usize,
        .{usize},
    ).key(.bench)
        .evict(.lru)
        .residency(.{ .count = 256 })
        .expiration(.{ .absolute = 5 });

    pub fn preconfigure(injector: ?*kwatcher.inject.Injector, persistent: std.mem.Allocator) !*kwatcher.inject.Injector {
        const withCache = try kwatcher.cache.context.memory.interdict(Config, injector, persistent);
        return withCache;
    }
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const nstr = args.next() orelse "256";
    const n = try std.fmt.parseUnsigned(usize, nstr, 10);

    var root = Root{ .allocator = allocator };
    var ctx = Ctx{};
    var root_inj = try kwatcher.inject.Injector.init(&root, null);
    var injector = try kwatcher.inject.Injector.init(&ctx, &root_inj);
    const cache = try injector.require(kwatcher.cache.Cache(usize));

    for (0..n) |i| {
        _ = try cache.push(i, .{i});
    }
}
