pub const schema = @import("schema.zig");
pub const route = @import("route.zig");
pub const timers = @import("timers.zig");
pub const registry = @import("registry.zig");
pub const crypto = @import("crypto.zig");
pub const deps = @import("deps.zig");
pub const Config = @import("config.zig");

const amqp = @import("kw-amqp");
const cron = @import("kw-cron");
const client_registry = @import("../../client-registration/registry.zig");

/// Minimal context with just the fields our route templates reference.
/// The response route `secret.v0.{client.id}` resolves `client.id` against
/// the client-registration registry, so apps using the secret protocol
/// must also carry the client registration context field — in practice,
/// use both protocols.
pub const ProtocolContext = struct {
    client: client_registry = .{ .assigned_id = null, .state = .unregistered },
    secrets: registry = .{},
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
