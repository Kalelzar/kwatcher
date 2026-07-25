// This file is part of the kwatcher project.
//
// Copyright (C) 2025-2026 Borislav Atanasov
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, version 3 of the License only.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.

const klib = @import("klib");
const std = @import("std");
const metrics = @import("kw-core").metrics;
const cache = @import("cache.zig");

fn Node(comptime Data: type) type {
    return struct {
        prev: ?*Node(Data),
        next: ?*Node(Data),
        data: Data,
        key: u64,
        pub fn underlying(self: @This()) Data {
            return self.data;
        }
    };
}

pub fn Context(comptime StorageContextType: anytype, comptime Residency: cache.Residency) *const fn (type) type {
    const H = struct {
        pub fn f(comptime Data: type) type {
            const SCT = StorageContextType(Data);
            if (comptime SCT.data_ownership == .transient) {
                return IndexedContext(Data, StorageContextType, Residency);
            } else {
                return DirectContext(Data, StorageContextType, Residency);
            }
        }
    };

    return H.f;
}

/// A basic lru wrapper around a context with a built-in index for contexts that do not
/// keep an index in memory.
pub fn IndexedContext(
    comptime Data: type,
    comptime StorageContextType: anytype,
    comptime Residency: cache.Residency,
) type {
    return struct {
        pub const id = StorageContext.id ++ ":lru_indexed";
        pub const key_type = StorageContext.key_type; // We have to pay a double hashing penalty if this is .hash but it is what it is. This could be optimized by having the hash map not hash at all.
        const StorageContext = StorageContextType(Data);
        const Priority = struct { front: ?*Node(void) = null, back: ?*Node(void) = null };
        const max_size = switch (Residency) {
            .unlimited => @compileError("You cannot configure an LRU cache with unlimited residency."),
            .count => |c| c,
            .bytes => |b| blk: {
                const elementSize = 8 + @sizeOf(Node(void)) + @sizeOf(Data) + 64;
                break :blk @divFloor(b, elementSize);
            },
        };

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

        const MetaTable = if (key_type == .hash)
            std.ArrayHashMapUnmanaged(u64, *Node(void), RawHashContext, false)
        else
            std.AutoArrayHashMapUnmanaged(u64, *Node(void));

        name: []const u8,
        buf: StorageContext,
        metadata: MetaTable,
        allocator: std.mem.Allocator,
        prio: Priority,

        inline fn oldest(self: *@This()) ?*Node(void) {
            return self.prio.back;
        }

        inline fn recent(self: *@This()) ?*Node(void) {
            return self.prio.front;
        }

        inline fn touch(self: *@This(), node: *Node(void)) void {
            const b = node.prev;
            const f = node.next;
            if (b == null and f == null) {
                @branchHint(.cold);
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
                @branchHint(.cold);
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
                @branchHint(.likely);
                b.?.next = f;
                f.?.prev = b;
            }

            const r = self.recent().?;
            r.prev = node;
            node.next = r;
            node.prev = null;
            self.prio.front = node;
        }

        pub fn get(self: *@This(), key: u64) !?Data {
            const cached = try self.buf.get(key);
            if (cached == null) return null;

            const v = cached.?;

            if (self.metadata.get(key)) |node| {
                self.touch(node);
            } else {
                _ = try self.putMeta(key);
            }

            return v;
        }

        pub fn getPtr(self: *@This(), key: u64) !?*Data {
            const cached = try self.buf.getPtr(key);
            if (cached == null) return null;

            const v = cached.?;

            if (self.metadata.get(key)) |node| {
                self.touch(node);
            } else {
                _ = try self.putMeta(key);
            }

            return v;
        }

        fn putMeta(self: *@This(), key: u64) !u64 {
            const old = try self.evict();

            const ptr = old orelse try self.allocator.create(Node(void));
            ptr.* = .{
                .next = self.prio.front,
                .prev = null,
                .key = key,
                .data = {},
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

            try self.metadata.put(self.allocator, key, ptr);

            return key;
        }

        pub fn put(self: *@This(), key: u64, data: Data) !void {
            const owned_key = try self.putMeta(key);
            return self.buf.putBorrowed(
                owned_key,
                data,
            );
        }

        pub inline fn len(self: *@This()) usize {
            return self.metadata.entries.len;
        }

        fn evict(self: *@This()) !?*Node(void) {
            var last: ?*Node(void) = null;
            while (self.metadata.entries.len >= max_size) {
                last = self.prio.back;
                if (last) |l| {
                    defer if (self.metadata.entries.len > max_size) self.allocator.destroy(l);
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
                    l.next = null;
                    if (!self.buf.remove(l.key)) {
                        unreachable;
                    }
                    if (!self.metadata.swapRemove(l.key)) {
                        unreachable;
                    }
                    try metrics.cacheShrink(self.name, id);
                }
            }
            return last;
        }

        pub fn init(allocator: std.mem.Allocator, name: []const u8) !@This() {
            var buf: StorageContext =
                if (comptime klib.meta.canBeError(StorageContext.init))
                    try .init(allocator, name)
                else
                    .init(allocator, name);
            try buf.ensure(max_size);
            return .{
                .name = name,
                .buf = buf,
                .prio = .{},
                .metadata = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.buf.deinit();
            var n = self.recent();
            while (n) |e| {
                const next = e.next;
                self.allocator.destroy(e);
                n = next;
            }
            self.metadata.deinit(self.allocator);
        }
    };
}

/// A basic LRU eviction wrapper around a context.
pub fn DirectContext(
    comptime Data: type,
    comptime StorageContextType: anytype,
    comptime Residency: cache.Residency,
) type {
    return struct {
        pub const id = StorageContext.id ++ ":lru";
        pub const key_type = StorageContext.key_type; // We don't really care here.
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

        name: []const u8,
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
                @branchHint(.cold);
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
                @branchHint(.cold);
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
                @branchHint(.likely);
                b.?.next = f;
                f.?.prev = b;
            }

            const r = self.recent().?;
            r.prev = node;
            node.next = r;
            node.prev = null;
            self.prio.front = node;
        }

        pub fn get(self: *@This(), key: u64) !?Data {
            const cached = try self.buf.get(key);
            if (cached == null) return null;

            const v = cached.?;

            self.touch(v);

            return v.data;
        }

        pub fn getPtr(self: *@This(), key: u64) !?*Data {
            const cached = try self.buf.getPtr(key);
            if (cached == null) return null;

            const v = cached.?;

            self.touch(v);

            return &v.data;
        }

        pub fn put(self: *@This(), key: u64, data: Data) !void {
            const old = try self.evict();

            const ptr = old orelse try self.allocator.create(Node(Data));
            ptr.* = .{
                .next = self.prio.front,
                .prev = null,
                .key = key,
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
                key,
                ptr,
            );
        }

        pub inline fn len(self: *@This()) usize {
            return self.buf.len();
        }

        fn evict(self: *@This()) !?*Node(Data) {
            var last: ?*Node(Data) = null;
            while (self.buf.len() >= max_size) {
                last = self.prio.back;
                if (last) |l| {
                    defer if (self.buf.len() > max_size) self.allocator.destroy(l);
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
                    l.next = null;
                    if (!self.buf.remove(l.key)) {
                        unreachable;
                    }
                    try metrics.cacheShrink(self.name, id);
                }
            }
            return last;
        }

        pub fn init(allocator: std.mem.Allocator, name: []const u8) !@This() {
            var buf: StorageContext =
                if (comptime klib.meta.canBeError(StorageContext.init))
                    try .init(allocator, name)
                else
                    .init(allocator, name);

            try buf.ensure(max_size);
            return .{
                .name = name,
                .buf = buf,
                .prio = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.buf.deinit();
            var n = self.recent();
            while (n) |e| {
                const next = e.next;
                self.allocator.destroy(e);
                n = next;
            }
        }
    };
}
