const std = @import("std");
const klib = @import("klib");
const cache = @import("cache.zig");
const eviction = @import("eviction.zig");
const inject = @import("../utils/injector.zig");

pub fn Resolver(
    comptime Data: type,
    comptime Eviction: cache.EvictionStrategy,
    comptime Residency: cache.Residency,
    comptime Expiration: cache.Expiration,
) type {
    const WithExpiration = switch (Expiration) {
        .unlimited => Context,
        .absolute, .sliding => eviction.ttl.Context(Context, Expiration),
    };

    const WithEviction = switch (Eviction) {
        .none => WithExpiration,
        .lru => eviction.lru.Context(WithExpiration, Residency),
    };

    return WithEviction(Data);
}

pub fn Dependencies(
    comptime Data: type,
    comptime Invariant: anytype,
    comptime config: SetBuilder(Data, Invariant),
) type {
    const __interned = config.intern();
    const Interface = @TypeOf(__interned).Interface;
    const ContextType = @TypeOf(__interned).Context;
    return struct {
        interface: Interface = __interned.interface,
        context: ?*ContextType = null,

        pub fn contextFactory(self: *@This(), persistent: std.mem.Allocator) !*ContextType {
            if (self.context) |c| {
                @branchHint(.likely);
                return c;
            } else {
                @branchHint(.cold);

                const ptr = try persistent.create(ContextType);
                const key = self.interface.key;
                if (comptime klib.meta.canBeError(ContextType.init)) {
                    ptr.* = try .init(persistent, key);
                } else {
                    ptr.* = .init(persistent, key);
                }
                self.context = ptr;

                return ptr;
            }
        }

        pub fn cacheFactory(inj: *inject.Injector, intf: Interface) cache.Cache(Data) {
            return .{ .config = intf.interface(), .inj = inj };
        }
    };
}

pub fn interdict(
    comptime config: anytype,
    parent: ?*inject.Injector,
    persistent: std.mem.Allocator,
) !*inject.Injector {
    const Data = @TypeOf(config).DataType;
    const Invariant = @TypeOf(config).InvariantType;

    const inj = try persistent.create(inject.Injector);
    errdefer persistent.destroy(inj);
    const deps = Dependencies(Data, Invariant, config){};
    const ctx = try persistent.create(@TypeOf(deps));

    ctx.* = deps;
    inj.* = try .init(ctx, parent);

    return inj;
}

pub fn SetBuilder(comptime Data: type, comptime Invariant: anytype) type {
    return struct {
        const Self = @This();
        const DataType = Data;
        const InvariantType = Invariant;

        builder: cache.SetBuilder(Data, Invariant),

        pub fn cold(comptime self: Self, comptime f: anytype) Self {
            return .{
                .builder = self.builder.cold(f),
            };
        }

        pub fn evict(comptime self: Self, comptime e: cache.EvictionStrategy) Self {
            return .{
                .builder = self.builder.evict(e),
            };
        }

        pub fn residency(comptime self: Self, comptime r: cache.Residency) Self {
            return .{
                .builder = self.builder.residency(r),
            };
        }

        pub fn expiration(comptime self: Self, comptime r: cache.Expiration) Self {
            return .{
                .builder = self.builder.expiration(r),
            };
        }

        pub fn key(comptime self: Self, comptime k: anytype) Self {
            return .{
                .builder = self.builder.key(k),
            };
        }

        pub fn intern(comptime self: Self) struct {
            pub const Context = self.resolve();
            pub const Interface = self.builder.interface();
            interface: Interface,

            pub fn initContext(s: @This(), alloc: std.mem.Allocator, name: []const u8) klib.meta.Return(self.resolve().init) {
                _ = s;
                return self.resolve().init(alloc, name);
            }
        } {
            return .{
                .interface = self.build(),
            };
        }

        pub fn build(comptime self: Self) self.builder.interface() {
            const Ctx = self.resolve();
            const act = self.builder
                .hotRaw(cache.autoCacheWithContexts(
                    Data,
                    Invariant,
                    .{Ctx},
                ))
                .pushRaw(cache.autoPushWithContexts(
                    Data,
                    Invariant,
                    .{Ctx},
                ))
                .build();
            return act;
        }

        pub fn resolve(comptime self: Self) type {
            const eviction_strat = self.builder.find(.eviction) orelse .none;
            const resident = self.builder.find(.residency) orelse cache.Residency{ .unlimited = {} };
            const exp = self.builder.find(.expiration) orelse cache.Expiration{ .unlimited = {} };
            return Resolver(Data, eviction_strat, resident, exp);
        }
    };
}

pub fn Cache(comptime Data: type, comptime Invariant: anytype) SetBuilder(Data, Invariant) {
    return .{
        .builder = .new(),
    };
}

/// A simple hash map backed in-memory cache.
/// NOTE: This should be converted to a vtable so that the implementation can be swapped by the user.
pub fn Context(comptime Data: type) type {
    return struct {
        const RawHashContext = struct {
            pub fn hash(self: @This(), key: u64) u32 {
                _ = self;
                return @truncate(key);
            }

            pub fn eql(self: @This(), a: u64, b: u64, b_index: usize) bool {
                _ = self;
                _ = b_index;
                return a == b;
            }
        };

        pub const id = "memory";
        pub const data_ownership = .owned;
        pub const key_type = .raw;
        name: []const u8,
        buf: std.ArrayHashMapUnmanaged(u64, Data, RawHashContext, false),
        //buf: std.StringArrayHashMapUnmanaged(Data),
        allocator: std.mem.Allocator,

        pub fn get(self: *@This(), key: u64) !?Data {
            return self.buf.get(key);
        }

        pub fn getPtr(self: *@This(), key: u64) !?*Data {
            return self.buf.getPtr(key);
        }

        pub fn put(self: *@This(), key: u64, data: Data) !void {
            return try self.putBorrowed(key, data);
        }

        /// @deprecated Keys are no longer strings so this doesn't make sense
        pub fn putBorrowed(self: *@This(), key: u64, data: Data) !void {
            return self.buf.put(
                self.allocator,
                key,
                data,
            );
        }

        pub fn init(allocator: std.mem.Allocator, name: []const u8) @This() {
            return .{
                .buf = .{},
                .allocator = allocator,
                .name = name,
            };
        }

        pub inline fn len(self: *@This()) usize {
            return self.buf.entries.len;
        }

        pub fn remove(self: *@This(), key: u64) bool {
            const res = self.buf.swapRemove(key);
            return res;
        }

        pub fn ensure(self: *@This(), size: usize) !void {
            try self.buf.ensureTotalCapacity(self.allocator, size);
        }

        pub fn deinit(self: *@This()) void {
            var it = self.buf.iterator();
            while (it.next()) |e| {
                const ti = @typeInfo(Data);
                switch (ti) {
                    .@"struct" => {
                        if (comptime @hasDecl(Data, "deinit")) {
                            const dfn = @typeInfo(Data.deinit);
                            switch (dfn) {
                                .@"fn" => |f| {
                                    if (comptime f.params.len > 1 and f.params[2].type == std.mem.Allocator) {
                                        e.value_ptr.deinit(self.allocator);
                                    } else {
                                        e.value_ptr.deinit();
                                    }
                                },
                            }
                        }
                    },
                    else => {},
                }
            }

            self.buf.deinit(self.allocator);
        }
    };
}
