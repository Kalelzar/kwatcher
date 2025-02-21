const std = @import("std");
const kwatcher = @import("kwatcher");

const ExtraConfig = struct {
    soup: bool,
};

const FullConfig = kwatcher.meta.MergeStructs(kwatcher.config.BaseConfig, ExtraConfig);

const TestProperties = struct {
    index: usize,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const config = try kwatcher.config.findConfigFileWithDefaults(ExtraConfig, allocator, "test");
    defer config.deinit();

    const clientInfo = kwatcher.schema.ClientInfo{
        .name = "test-watcher",
        .version = "0.0.1",
    };

    var watcher = try kwatcher.WatcherClient(FullConfig).init(allocator, config.value, clientInfo);
    defer watcher.deinit();
    try watcher.registerQueue("heartbeat", "amq.direct", "heartbeat.consumer");

    var factory = try watcher.factory("test");
    defer factory.deinit();

    for (0..5) |i| {
        const message = try factory.nextHeartbeat(TestProperties, .{
            .index = i,
        });
        try watcher.heartbeat(message);
        factory.reset();
        std.time.sleep(1 * std.time.ns_per_s);
    }
}
