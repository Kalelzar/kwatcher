const std = @import("std");
const ProtocolConfig = @import("config.zig");
const Registry = @import("registry.zig");
const Scheduler = @import("secret.zig").Scheduler;

const Drivers = @import("kw-core").driver.Drivers;

const resolver = @import("kw-core").resolver;
const DepCtx = @import("kw-core").deps.DepCtx;

const amqp = @import("kw-amqp");

pub fn Static(comptime Context: type, comptime Config: type) type {
    const path = "protocols.secret";
    const ConfigResolver = resolver.Resolver(Config);
    const ContextResolver = resolver.Resolver(Context);
    return struct {
        pub fn protocolConfigFac(inj: *DepCtx, config: *Config) !*ProtocolConfig {
            return ConfigResolver.resolveRef(inj, path, config);
        }

        pub fn contextResolverFac(inj: *DepCtx, context: *Context) !*Registry {
            return ContextResolver.resolveRef(inj, "secrets", context);
        }
    };
}

pub fn default(comptime drv: Drivers, comptime Context: type) type {
    return struct {
        pub fn value(
            comptime category: anytype,
            dephub: anytype,
            comptime Config: type,
            allocator: std.mem.Allocator,
        ) Return(
            category,
            Config,
            @TypeOf(dephub),
        ) {
            _ = allocator;
            const drk: drv.DriverKeys() = category;
            const Shim = amqp.BridgeShimCtx(
                Scheduler,
                drv.Schedulers()[@intFromEnum(drk)],
            );
            const H = struct {
                var fixme_move_elsewhere_cache = Static(Context, Config){};
                var shim = Shim{};
            };

            // The registry statics go in `.all`, not the category: app
            // routes on other drivers (e.g. an action retrying a
            // `secret-get`) read the registry too. The category only
            // selects which driver's scheduler the bridge shim wraps.
            return dephub.static(.all, &H.fixme_move_elsewhere_cache)
                .static(.all, &H.shim);
        }

        pub fn Return(
            comptime category: anytype,
            comptime Config: type,
            comptime DH: type,
        ) type {
            const drk: drv.DriverKeys() = category;
            const Shim = amqp.BridgeShimCtx(
                Scheduler,
                drv.Schedulers()[@intFromEnum(drk)],
            );
            return DH.Static(.all, *Static(Context, Config))
                .Static(.all, *Shim);
        }
    };
}
