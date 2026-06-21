const std = @import("std");
const core = @import("kw-core");
const mem = core.mem;
const schema = core.schema;
const Resolver = core.resolver.Resolver;
const dep = core.deps;

pub fn Static(comptime Config: type, comptime clinfo: schema.Client.V1) type {
    return struct {
        persistent: std.mem.Allocator,
        pool: mem.PoolAllocator,
        user_info: ?schema.UserInfo = null,
        base_client_info: schema.Client.V1,
        config: Config,

        pub fn init(persistent: std.mem.Allocator, conf: Config, fba: std.mem.Allocator) @This() {
            return .{
                .persistent = persistent,
                .config = conf,
                .pool = .init(fba),
                .base_client_info = clinfo,
            };
        }

        pub fn clientInfoFac() schema.ClientInfo {
            return .{
                .id = "TODO",
                .name = clinfo.name,
                .version = clinfo.version,
            };
        }

        pub fn userInfoFac(self: *@This(), persistent: std.mem.Allocator) !*schema.UserInfo {
            if (self.user_info) |*u| {
                return u;
            }
            self.user_info = try .init(persistent, null);
            return &self.user_info.?;
        }

        pub fn deconstruct(self: *@This()) void {
            self.pool.deinit();
            if (self.user_info) |*u| {
                u.deinit();
            }
        }
    };
}

const Scoped = struct {
    scoped_alloc: mem.ScopedAllocator = undefined,
    pool_handle: ?*mem.PoolAllocator = null,

    pub fn construct(self: *Scoped, pool: *mem.PoolAllocator) !void {
        // std.log.info("Constructing {x} from {x}.", .{ @intFromPtr(self), @intFromPtr(pool) });
        self.scoped_alloc = .{ .value = try pool.suballocator() };
        self.pool_handle = pool;
    }

    pub fn deconstruct(self: *Scoped) void {
        if (self.pool_handle) |pool| {
            pool.reset(self.scoped_alloc.value) catch {};
        }
    }
};

pub fn default(
    comptime category: anytype,
    dephub: anytype,
    allocator: std.mem.Allocator,
    conf: anytype,
    comptime clinfo: schema.Client.V1,
) @TypeOf(dephub)
    .Static(category, *Static(@TypeOf(conf), clinfo))
    .Scoped(category, Scoped) {
    const H = struct {
        var buf: [64 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var fixme_move_elsewhere_cache: ?Static(@TypeOf(conf), clinfo) = null;
    };

    if (H.fixme_move_elsewhere_cache == null) {
        H.fixme_move_elsewhere_cache = .init(
            allocator,
            conf,
            H.fba.allocator(),
        );
    }

    return dephub
        .static(category, &H.fixme_move_elsewhere_cache.?)
        .scoped(category, Scoped);
}

// NOTE: This assumes that category is the driver key.
// We should provide an overload for when that is not the case, though the rest of the system does too
pub fn withDefault(
    conf: anytype,
    comptime clinfo: schema.Client.V1,
) type {
    return struct {
        pub fn apply(
            dephub: anytype,
            comptime category: anytype,
            allocator: std.mem.Allocator,
            comptime Config: type,
        ) Return(category, Config, @TypeOf(dephub)) {
            if (@TypeOf(conf) != *Config) {
                @compileError("Config mismatch! Expected " ++ @typeName(*Config) ++ " got " ++ @typeName(@TypeOf(config)));
            }
            return default(
                category,
                dephub,
                allocator,
                conf.*,
                clinfo,
            );
        }

        pub fn Return(
            comptime category: anytype,
            comptime Config: type,
            comptime DH: type,
        ) type {
            return DH.Static(category, *Static(Config, clinfo)).Scoped(category, Scoped);
        }
    };
}

pub fn ResolvedConfig(comptime Config: type, comptime config_path: []const u8) type {
    const OurConfig = Resolver(Config).resolveType(config_path);

    return struct {
        pub fn ourConfig(inj: *dep.DepCtx, conf: *Config) !*OurConfig {
            return Resolver(Config).resolveRef(inj, config_path, conf);
        }
    };
}

pub fn defaultConfig(
    comptime category: anytype,
    dephub: anytype,
    allocator: std.mem.Allocator,
    comptime Config: type,
    comptime subpath: []const u8,
) @TypeOf(dephub)
    .Static(category, *ResolvedConfig(Config, subpath)) {
    _ = allocator;
    const H = struct {
        var fixme_move_elsewhere_cache: ResolvedConfig(Config, subpath) = .{};
    };

    return dephub
        .static(category, &H.fixme_move_elsewhere_cache);
}

pub fn config(comptime OurConfig: type, comptime config_path: []const u8) type {
    return struct {
        pub fn apply(
            dephub: anytype,
            comptime category: anytype,
            allocator: std.mem.Allocator,
            comptime Config: type,
        ) Return(category, Config, @TypeOf(dephub)) {
            if (comptime Resolver(Config).resolveType(config_path) != OurConfig) {
                @compileError("Config mismatch");
            }
            return defaultConfig(
                category,
                dephub,
                allocator,
                Config,
                config_path,
            );
        }

        pub fn Return(comptime category: anytype, comptime Config: type, comptime DH: type) type {
            return DH.Static(category, *ResolvedConfig(Config, config_path));
        }
    };
}
