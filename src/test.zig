const kwatcher = struct {
    const amqp_client = @import("amqp_client.zig");
    const Template = @import("template.zig");
};
const Self = @This();

comptime {
    const r = @import("std").testing.refAllDeclsRecursive;
    r(kwatcher.Template);
}
