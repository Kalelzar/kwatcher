const Client = @import("../../client.zig");
const ClientRegistry = @This();
const RegistrationState = @import("schema.zig").RegistrationState;

state: RegistrationState = .unregistered,
assigned_id: ?[]const u8,

pub fn id(self: *const ClientRegistry, client: Client) []const u8 {
    if (self.assigned_id) |aid| {
        return aid;
    } else {
        return client.id();
    }
}
