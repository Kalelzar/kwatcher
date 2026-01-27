const std = @import("std");

const dep = @import("../../dep.zig");
const DriverRegistry = @import("../../driver.zig").Drivers;
const Client = @import("../../client/client.zig");
const Resolver = @import("../../utils/resolver.zig").Resolver;
const InternFmtCache = @import("../../utils/intern_fmt_cache.zig");

const Pool = @import("pool.zig").ClientPool;

pub fn Static(comptime Context: type, comptime Config: type, comptime subpath: []const u8) type {
    const OurConfig = Resolver(Config).resolveType(subpath);
    return struct {
        const Lock = struct { mutex: std.Thread.Mutex = .{} };
        lock: Lock = .{},
        client_pool: ?Pool = null,
        fmt: ?InternFmtCache = null,
        context: Context = .{},

        pub fn ourConfig(inj: *dep.DepCtx, config: *Config) !*OurConfig {
            return Resolver(Config).resolveRef(inj, subpath, config);
        }

        pub fn clientPool(self: *@This(), allocator: std.mem.Allocator, config: *OurConfig) !*Pool {
            if (self.client_pool) |*p| {
                @branchHint(.likely);
                return p;
            }

            self.lock.mutex.lock();
            defer self.lock.mutex.unlock();

            if (self.client_pool) |*p| {
                @branchHint(.cold);
                return p;
            }

            self.client_pool = try .init(
                allocator,
                config,
                4, //TODO: Read from config.
                1 * std.time.ns_per_ms, //TODO: Read from config.
            );

            return &self.client_pool.?;
        }

        pub fn fmtCache(self: *@This(), allocator: std.mem.Allocator) *InternFmtCache {
            if (self.fmt) |*p| {
                @branchHint(.likely);
                return p;
            }
            self.lock.mutex.lock();
            defer self.lock.mutex.unlock();

            if (self.fmt) |*p| {
                @branchHint(.cold);
                return p;
            }

            self.fmt = .init(
                allocator,
            );

            return &self.fmt.?;
        }

        pub fn deconstruct(self: *@This(), allocator: std.mem.Allocator) void {
            //self.lock.mutex.lock();
            //defer self.lock.mutex.unlock();
            if (self.client_pool) |*p| {
                p.deinit(allocator);
                self.client_pool = null;
            }

            if (self.fmt) |*f| {
                f.deinit();
                self.fmt = null;
            }
        }
    };
}

const Scoped = struct {
    client: Client = undefined,

    pub fn construct(self: *Scoped, pool: *Pool) !void {
        self.client = try pool.lease();
    }

    pub fn deconstruct(self: *Scoped, pool: *Pool) void {
        pool.release(self.client) catch {};
    }
};

pub fn default(
    comptime category: anytype,
    dephub: anytype,
    comptime Context: type,
    comptime Config: type,
    comptime subpath: []const u8,
    allocator: std.mem.Allocator,
) @TypeOf(dephub)
    .Static(category, *Static(Context, Config, subpath))
    .Scoped(category, Scoped) {
    const H = struct {
        var fixme_move_elsewhere_cache = Static(Context, Config, subpath){};
    };

    return dephub
        .static(category, &H.fixme_move_elsewhere_cache, allocator)
        .scoped(category, Scoped);
}

// NOTE: This assumes that category is the driver key.
// We should provide an overload for when that is not the case, though the rest of the system does too
pub fn defaultFor(comptime drv: DriverRegistry, comptime Context: type) type {
    return struct {
        pub fn apply(
            dephub: anytype,
            comptime category: anytype,
            allocator: std.mem.Allocator,
            comptime Config: type,
        ) Return(category, Config, @TypeOf(dephub)) {
            const Us = drv.get(category);
            const path = Us.config_path;
            return default(category, dephub, Context, Config, path, allocator);
        }

        pub fn Return(comptime category: anytype, comptime Config: type, comptime DH: type) type {
            const Us = drv.get(category);
            const path = Us.config_path;
            return DH.Static(category, *Static(Context, Config, path)).Scoped(category, Scoped);
        }
    };
}
