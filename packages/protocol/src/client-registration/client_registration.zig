pub const schema = @import("kw-cr-schema").kwatcher.protocol.client_registration;
pub const route = @import("route.zig");
pub const timers = @import("timers.zig");
pub const registry = @import("registry.zig");
pub const deps = @import("deps.zig");
pub const Config = @import("config.zig");

const amqp = @import("kw-amqp");
const cron = @import("kw-cron");

/// Minimal context with just the fields our route templates reference.
/// The consume route `client.ack.{client.id}` resolves `client.id` against
/// this context via the Resolver.
pub const ProtocolContext = struct {
    client: registry = .{ .assigned_id = null, .state = .unregistered },
};

/// Protocol routes parsed with our minimal context — enough for template
/// resolution without needing the consumer's full Context.
const protocol_routes = amqp.From(route, ProtocolContext);

/// Type-erased scheduler built from only this protocol's publish routes.
/// Protocol route handlers can inject this type via DI.
pub const Scheduler = amqp.AmqpSchedulerShim(protocol_routes);

pub const SupportedKinds = enum {
    amqp,
    cron,
};

pub fn supports(comptime kind: SupportedKinds) bool {
    return comptime kind == .amqp or kind == .cron;
}

pub fn forKind(comptime Context: type, comptime kind: SupportedKinds) []const type {
    switch (kind) {
        .amqp => return amqp.From(route, Context),
        .cron => return cron.From(timers),
    }
}
