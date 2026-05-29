pub const std = @import("std");
pub const klib = @import("klib");
pub const dep = @import("kw-core").deps;
const EventPropertiesEx = @import("kw-core").event.ExtendedProperties;

pub fn WithLatency(comptime routes: []const type) []type {
    if (comptime routes.len == 0) return routes;
    const H = struct {
        pub fn LatencyHandler(comptime HandlerFac: anytype) type {
            return struct {
                pub fn make(comptime Base: type) type {
                    const Handler = HandlerFac(Base);
                    return struct {
                        pub const CallContext = Handler.CallContext;
                        pub const Dependencies = Handler.Dependencies ++ .{std.mem.Allocator};

                        pub fn call(
                            inj: *dep.DepCtx,
                            ctx: CallContext,
                            evprop: EventPropertiesEx,
                        ) klib.meta.Return(Handler.call) {
                            const start = std.time.microTimestamp();
                            const alloc = try inj.require(std.mem.Allocator);
                            const rname = try Handler.name(inj);
                            defer alloc.free(rname);
                            _ = start;
                            // defer metrics.latency(name, std.time.microTimestamp() - start) catch {};
                            return @call(.auto, Handler.call, .{ inj, ctx, evprop });
                        }

                        pub inline fn name(inj: *dep.DepCtx) ![]const u8 {
                            return @call(.auto, Handler.name, .{inj});
                        }
                    };
                }
            };
        }
    };

    var nroutes: [routes.len]type = undefined;

    inline for (routes, 0..) |R, i| {
        nroutes[i] = R.wrap(H.LatencyHandler);
    }

    return &nroutes;
}
