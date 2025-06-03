const kwatcher = struct {
    const amqp_client = @import("amqp_client.zig");
    const Template = @import("template.zig");
    const InternFmtCache = @import("intern_fmt_cache.zig");
    const injector = @import("injector.zig");
    const handlers = @import("handlers.zig");
};
const Self = @This();

comptime {
    const r = @import("std").testing.refAllDeclsRecursive;
    r(kwatcher.Template);
    r(kwatcher.InternFmtCache);
    r(kwatcher.injector);
    r(kwatcher.handlers.HandlerCodeGen(struct {}));
}
