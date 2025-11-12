const std = @import("std");
const metrics = @import("../utils/metrics.zig");
const cache = @import("cache.zig");

pub fn MemoryContextResolver(comptime Data: type, comptime IType: type, comptime Residency: cache.Residency) type {
    const interface = cache.cacheInterfaceTypeMap(Data, IType);

    return switch (interface) {
        .hotcold => MemoryContext(Data),
        .hotcold_lru => LRUContext(Data, MemoryContext, Residency),
    };
}

pub fn MemorySetBuilder(comptime Data: type, comptime Invariant: anytype) type {
    return struct {
        const Self = @This();
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

        pub fn key(comptime self: Self, comptime k: anytype) Self {
            return .{
                .builder = self.builder.key(k),
            };
        }

        pub fn intern(comptime self: Self) struct {
            pub const Context = self.resolve();
            pub const Interface = self.builder.interface();
            interface: Interface,
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
            const Interim = self.builder.interface();
            const resident = self.builder.find(.residency) orelse cache.Residency{ .unlimited = {} };
            return MemoryContextResolver(Data, Interim, resident);
        }
    };
}

pub fn Memory(comptime Data: type, comptime Invariant: anytype) MemorySetBuilder(Data, Invariant) {
    return .{
        .builder = .new(),
    };
}

/// A simple hash map backed in-memory cache.
/// NOTE: This should be converted to a vtable so that the implementation can be swapped by the user.
pub fn MemoryContext(comptime Data: type) type {
    return struct {
        pub const id = "memory";
        buf: std.StringArrayHashMapUnmanaged(Data),
        allocator: std.mem.Allocator,

        pub fn get(self: *@This(), key: []const u8) !?Data {
            return self.buf.get(key);
        }

        pub fn getPtr(self: *@This(), key: []const u8) !?*Data {
            return self.buf.getPtr(key);
        }

        pub fn put(self: *@This(), key: []const u8, data: Data) !void {
            const k = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(k);
            return try self.putBorrowed(k, data);
        }

        pub fn putBorrowed(self: *@This(), key: []const u8, data: Data) !void {
            return self.buf.put(
                self.allocator,
                key,
                data,
            );
        }

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .buf = .{},
                .allocator = allocator,
            };
        }

        pub inline fn len(self: *@This()) usize {
            return self.buf.entries.len;
        }

        pub fn remove(self: *@This(), key: []const u8) bool {
            const res = self.buf.swapRemove(key);
            if (res) {
                self.allocator.free(key);
            }
            return res;
        }

        pub fn deinit(self: *@This()) void {
            var it = self.buf.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                if (comptime @hasDecl(Data, "deinit")) {
                    // FIXME: Call this function with an allocator if possible.
                    //e.value_ptr.deinit();
                }
            }

            self.buf.deinit(self.allocator);
        }
    };
}

fn Node(comptime Data: type) type {
    return struct {
        prev: ?*Node(Data),
        next: ?*Node(Data),
        data: Data,
        key: []const u8,
    };
}

/// A basic LRU eviction wrapper around a context.
/// TODO: Work in progress, currently does not accept maximum size configuration.
/// This will be exposed as an additional type argument.
pub fn LRUContext(
    comptime Data: type,
    comptime StorageContextType: anytype,
    comptime Residency: cache.Residency,
) type {
    return struct {
        pub const id = StorageContext.id ++ ":lru";
        const StorageContext = StorageContextType(DataType);
        const DataType = *Node(Data);
        const Priority = struct { front: ?DataType = null, back: ?DataType = null };
        const max_size = switch (Residency) {
            .unlimited => @compileError("You cannot configure an LRU cache with unlimited residency."),
            .count => |c| c,
            .bytes => |b| blk: {
                const elementSize = @sizeOf(DataType) + @sizeOf(Data) + 64;
                break :blk @divFloor(b, elementSize);
            },
        };

        buf: StorageContext,
        allocator: std.mem.Allocator,
        prio: Priority,

        inline fn oldest(self: *@This()) ?DataType {
            return self.prio.back;
        }

        inline fn recent(self: *@This()) ?DataType {
            return self.prio.front;
        }

        inline fn touch(self: *@This(), node: DataType) void {
            const b = node.prev;
            const f = node.next;
            if (b == null and f == null) {
                // EDGE: We are the sole node and should be the front.
                // TODO: sanity check only in debug mode

                // If there is no front something has gone terribly wrong.
                const us = self.recent() orelse unreachable;

                // And it has to be us. Else we are a very invalid node.
                std.debug.assert(@intFromPtr(us) == @intFromPtr(node));
                return;
            }

            if (b == null) {
                // EDGE: We are the front node.
                // We have nothing to do here and can just return.
                return;
            }

            if (f == null) {
                // EDGE: We are the last node.
                // If there is no back something has gone terribly wrong.
                const us = self.oldest() orelse unreachable;
                // And it has to be us. Else we are a very invalid node.
                std.debug.assert(@intFromPtr(us) == @intFromPtr(node));
                // If we made it to the back then we should by definition have a front
                // otherwise the node is invalid.
                self.prio.back = b;

                b.?.next = null; // Detach ourselves.
            } else {
                b.?.next = f;
                f.?.prev = b;
            }

            const r = self.recent().?;
            r.prev = node;
            node.next = r;
            node.prev = null;
            self.prio.front = node;
        }

        pub fn get(self: *@This(), key: []const u8) !?Data {
            const cached = try self.buf.get(key);
            if (cached == null) return null;

            const v = cached.?;

            self.touch(v);

            return v.data;
        }

        pub fn getPtr(self: *@This(), key: []const u8) !?*Data {
            const cached = try self.buf.getPtr(key);
            if (cached == null) return null;

            const v = cached.?;

            self.touch(v);

            return &v.data;
        }

        pub fn put(self: *@This(), key: []const u8, data: Data) !void {
            try self.evict();

            const owned_key = try self.allocator.dupe(u8, key);

            const ptr = try self.allocator.create(Node(Data));
            ptr.* = .{
                .next = self.prio.front,
                .prev = null,
                .key = owned_key,
                .data = data,
            };

            if (self.prio.front) |f| {
                if (self.prio.back == null) {
                    f.next = null;
                    self.prio.back = f;
                }
                ptr.next = f;
                f.prev = ptr;
            }

            self.prio.front = ptr;

            return self.buf.putBorrowed(
                owned_key,
                ptr,
            );
        }

        fn evict(self: *@This()) !void {
            while (self.buf.len() >= max_size) {
                const last = self.prio.back;
                if (last) |l| {
                    defer self.allocator.destroy(l);
                    defer self.allocator.free(l.key);
                    const p = l.prev;
                    if (p) |lp| {
                        if (lp != self.recent().?) {
                            self.prio.back = lp;
                        } else {
                            self.prio.back = null;
                        }
                        lp.next = null;
                    } else {
                        self.prio.back = null;
                    }
                    l.prev = null;
                    if (!self.buf.remove(l.key)) {
                        unreachable;
                    }
                    try metrics.cacheShrink("test", id);
                }
            }
        }

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .buf = .init(allocator),
                .prio = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.buf.deinit(self.allocator);
            var n = self.recent();
            while (n) |e| {
                const next = e.next;
                if (comptime @hasDecl(Data, "deinit")) {
                    //                    node.data.deinit();
                }
                self.allocator.destroy(e);
                n = next;
            }
        }
    };
}
