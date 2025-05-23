const ClientRegistry = @import("protocol/client-registration/registry.zig");

pub fn Context(comptime Custom: type) type {
    return struct {
        client: ClientRegistry = .{
            .state = .unregistered,
            .assigned_id = null,
        },
        custom: Custom = .{},
    };
}
