const DepHub = @import("hub.zig").DepHub;
const DepMap = @import("map.zig").DepMap;

pub const DependencyLifetimes = enum { static, scoped };

pub fn DependencyContainer(comptime Config: type) type {
    return DepHub(DepMap(&.{}, DependencyLifetimes).cat(.all), .{}, Config);
}

comptime {
    @import("std").testing.refAllDeclsRecursive(DependencyContainer(struct {}));
}
