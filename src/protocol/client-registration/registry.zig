const ClientRegistry = @This();
const schema = @import("../../schema.zig");
const RegistrationState = @import("schema.zig").RegistrationState;

state: RegistrationState = .unregistered,
assigned_id: ?[]const u8,

pub fn id(self: *const ClientRegistry, client: schema.ClientInfo) []const u8 {
    if (self.assigned_id) |aid| {
        return aid;
    } else {
        return client.id;
    }
}
