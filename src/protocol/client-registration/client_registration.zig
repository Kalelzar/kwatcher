pub const schema = @import("schema.zig");
pub const route = @import("route.zig");
pub const registry = @import("registry.zig");
pub const deps = @import("deps.zig");
pub const Config = @import("config.zig");

pub const SupportedKinds = enum {
    amqp,
};

pub fn supports(comptime kind: SupportedKinds) bool {
    return comptime kind == .amqp;
}

pub fn forKind(comptime Context: type, comptime kind: SupportedKinds) []const type {
    switch (kind) {
        .amqp => return @import("../../v2/amqp.zig").From(route, Context),
    }
}
