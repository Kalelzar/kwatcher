const kwatcher = struct {
    const amqp_client = @import("client/amqp_client.zig");
    const Template = @import("route/template.zig");
    const InternFmtCache = @import("utils/intern_fmt_cache.zig");
    const injector = @import("utils/injector.zig");
    const handlers = @import("route/handlers.zig");
};
const Self = @This();

comptime {
    const r = @import("std").testing.refAllDeclsRecursive;
    r(kwatcher.Template);
    r(kwatcher.InternFmtCache);
    r(kwatcher.injector);
    r(kwatcher.handlers.HandlerCodeGen(struct {}));
}
