const std = @import("std");
const klib = @import("klib");
const cache = @import("cache.zig");
const serializer = @import("byte_serializer.zig");
const eviction = @import("eviction.zig");

pub fn Resolver(
    comptime Data: type,
    comptime Eviction: cache.EvictionStrategy,
    comptime Residency: cache.Residency,
    comptime Expiration: cache.Expiration,
) type {
    const WithExpiration = switch (Expiration) {
        .unlimited => Context,
        .absolute, .sliding => @compileError("File cache does not support TTL eviction yet."),
    };

    const WithEviction = switch (Eviction) {
        .none => WithExpiration,
        .lru => eviction.lru.Context(WithExpiration, Residency),
    };

    return WithEviction(Data);
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

/// A simple filesystem backed cache.
/// NOTE: This should be converted to a vtable so that the implementation can be swapped by the user.
pub fn Context(comptime Data: type) type {
    return struct {
        pub const id = "file";
        pub const data_ownership = .transient;
        name: []const u8,
        dir: std.fs.Dir,
        allocator: std.mem.Allocator,

        pub fn get(self: *@This(), key: []const u8) !?Data {
            const pre = key[0..2];
            const post = key[2..4];
            const rest = key[4..];
            var buf: [8]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}/{s}/", .{ pre, post });
            var low = try self.dir.makeOpenPath(path, .{});
            defer low.close();
            var file = low.openFile(rest, .{ .mode = .read_only }) catch |e| switch (e) {
                error.FileNotFound => return null,
                else => return e,
            };
            defer file.close();
            var rbuf: [@sizeOf(Data)]u8 = undefined;
            var r = file.reader(&rbuf);
            const reader = &r.interface;
            return try serializer.deserialize(reader, Data, self.allocator, 1);
        }

        pub fn put(self: *@This(), key: []const u8, data: Data) !void {
            const pre = key[0..2];
            const post = key[2..4];
            const rest = key[4..];
            var buf: [8]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}/{s}/", .{ pre, post });
            var low = try self.dir.makeOpenPath(path, .{});
            defer low.close();
            var file = try low.createFile(rest, .{});
            defer file.close();
            var wbuf: [@sizeOf(Data)]u8 = undefined;
            var w = file.writer(&wbuf);
            const writer = &w.interface;
            try serializer.serialize(writer, data, 1);
            try writer.flush();
        }

        pub const putBorrowed = put;

        pub fn remove(self: *@This(), key: []const u8) bool {
            const pre = key[0..2];
            const post = key[2..4];
            const rest = key[4..];
            var buf: [8]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/{s}/", .{ pre, post }) catch unreachable;
            var low = self.dir.makeOpenPath(path, .{}) catch unreachable;
            defer low.close();
            low.deleteFile(rest) catch return false;
            return true;
        }

        pub inline fn ensure(self: *@This(), max_size: usize) !void {
            // NOOP for this cache but the contract requires it.
            _ = self;
            _ = max_size;
            return;
        }

        pub fn init(allocator: std.mem.Allocator, name: []const u8) !@This() {
            const env = std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME") catch |e| blk: switch (e) {
                error.EnvironmentVariableNotFound => {
                    const home = try std.process.getEnvVarOwned(allocator, "HOME");
                    defer allocator.free(home);
                    break :blk try std.fs.path.join(allocator, &.{ home, ".cache" });
                },
                else => return e,
            };
            defer allocator.free(env);
            const dir = try std.fs.path.join(allocator, &.{ env, name });
            defer allocator.free(dir);

            return .{
                .name = name,
                .dir = try std.fs.cwd().makeOpenPath(dir, .{}),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.dir.close();
        }
    };
}

pub fn Cache(comptime Data: type, comptime Invariant: anytype) SetBuilder(Data, Invariant) {
    return .{
        .builder = .new(),
    };
}
