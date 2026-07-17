const std = @import("std");

const dep = @import("kw-core").deps;
const DriverRegistry = @import("kw-core").driver.Drivers;
const Client = @import("../client/client.zig");
const LoggingClient = @import("../client/logging_client.zig");
const BreakerRegistry = @import("../client/breaker_registry.zig");
const Resolver = @import("kw-core").resolver.Resolver;
const InternFmtCache = @import("kw-core").InternFmtCache;

const Pool = @import("pool.zig").ClientPool;

pub fn Static(comptime Context: type, comptime Config: type, comptime subpath: []const u8) type {
    const OurConfig = Resolver(Config).resolveType(subpath);
    return struct {
        const Lock = struct { mutex: std.Thread.Mutex = .{} };
        lock: Lock = .{},
        client_pool: ?Pool = null,
        fmt: ?InternFmtCache = null,
        breakers: ?BreakerRegistry = null,
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

        pub fn breakerRegistry(self: *@This(), allocator: std.mem.Allocator) *BreakerRegistry {
            if (self.breakers) |*b| {
                @branchHint(.likely);
                return b;
            }

            self.lock.mutex.lock();
            defer self.lock.mutex.unlock();

            if (self.breakers) |*b| {
                @branchHint(.cold);
                return b;
            }

            self.breakers = .init(allocator);

            return &self.breakers.?;
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
            if (self.breakers) |*b| {
                b.deinit();
                self.breakers = null;
            }

            if (self.client_pool) |*p| {
                p.deinit(allocator);
                self.client_pool = null;
            }

            if (self.fmt) |*f| {
                f.deinit();
                self.fmt = null;
            }

            if (comptime @hasDecl(Context, "deinit")) {
                self.context.deinit(allocator);
            }
        }
    };
}

const Scoped = struct {
    /// The injectable Client: the leased pool client tied to the logging
    /// fallback through the persistent circuit breaker.
    client: Client = undefined,
    fallback: LoggingClient = undefined,
    writer: std.fs.File.Writer = undefined,
    buffer: [4096]u8 = undefined,
    /// Optional so compile() skips it: a second Client-typed field would
    /// steal the injection slot from `client`.
    lease: ?Client = null,

    pub fn construct(self: *Scoped, pool: *Pool, breakers: *BreakerRegistry) !void {
        const lease = try pool.leaseNow();
        errdefer pool.release(lease) catch {};
        self.lease = lease;
        // Streaming mode: plain writer() does positional I/O from pos 0,
        // which overwrites the start of a redirected stderr on every flush.
        self.writer = std.fs.File.stderr().writerStreaming(&self.buffer);
        self.fallback = .init(&self.writer.interface);
        self.client = try breakers.wrap(lease, self.fallback.client());
        // Fault through the breaker: if the broker is unreachable this
        // engages the fallback now, so the injected Client is already
        // routed correctly by the time it reaches a user.
        try self.client.connect();
    }

    pub fn deconstruct(self: *Scoped, pool: *Pool) void {
        self.fallback.deinit();
        if (self.lease) |lease| pool.release(lease) catch {};
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
    _ = allocator;
    const H = struct {
        var fixme_move_elsewhere_cache = Static(Context, Config, subpath){};
    };

    return dephub
        .static(category, &H.fixme_move_elsewhere_cache)
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
