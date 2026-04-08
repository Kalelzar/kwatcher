const std = @import("std");
const ProtocolConfig = @import("config.zig");
const Registry = @import("registry.zig");

const resolver = @import("../../utils/resolver.zig");
const DepCtx = @import("../../dep.zig").DepCtx;

pub fn Static(comptime Context: type, comptime Config: type) type {
    const path = "protocols.client_registration";
    const ConfigResolver = resolver.Resolver(Config);
    const ContextResolver = resolver.Resolver(Context);
    return struct {
        pub fn protocolConfigFac(inj: *DepCtx, config: *Config) !*ProtocolConfig {
            return ConfigResolver.resolveRef(inj, path, config);
        }

        pub fn contextResolverFac(inj: *DepCtx, context: *Context) !*Registry {
            return ContextResolver.resolveRef(inj, "client", context);
        }
    };
}

pub fn default(comptime Context: type) type {
    return struct {
        pub fn value(
            comptime category: anytype,
            dephub: anytype,
            comptime Config: type,
            driver: type,
            allocator: std.mem.Allocator,
        ) Return(category, Config, @TypeOf(dephub)) {
            _ = driver;
            const H = struct {
                var fixme_move_elsewhere_cache = Static(Context, Config){};
            };

            return dephub.static(category, &H.fixme_move_elsewhere_cache, allocator);
        }

        pub fn Return(comptime category: anytype, comptime Config: type, comptime DH: type) type {
            return DH.Static(category, *Static(Context, Config));
        }
    };
}
