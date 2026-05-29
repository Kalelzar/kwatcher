const std = @import("std");
const klib = @import("klib");

pub const StaticBinder = struct {
    ptr: *anyopaque,
    tag: []const u8,
};

pub const Resolved = union(enum) {
    ctx: u8,
    static_ctx: u64,
    resolver: struct {
        ctx: u8,
        offset: usize,
    },
    static: struct {
        ctx: usize,
        offset: usize,
    },
    factory: struct {
        ctx: u8,
        fac: *const fn (*DepCtx, ?*anyopaque) anyerror!*anyopaque,
    },
    static_factory: struct {
        ctx: usize,
        fac: *const fn (*DepCtx, ?*anyopaque) anyerror!*anyopaque,
    },
};

pub const TidHashContext = struct {
    pub fn hash(self: @This(), key: klib.meta.TypeId) u32 {
        _ = self;
        const res: u32 = @truncate(@intFromPtr(key));
        return res;
    }

    pub fn eql(self: @This(), a: klib.meta.TypeId, b: klib.meta.TypeId) bool {
        _ = self;
        return a == b;
    }
};

pub const TidArrayHashContext = struct {
    pub fn hash(self: @This(), key: klib.meta.TypeId) u32 {
        _ = self;
        const res: u32 = @truncate(@intFromPtr(key));
        return res;
    }

    pub fn eql(self: @This(), a: klib.meta.TypeId, b: klib.meta.TypeId, _: usize) bool {
        _ = self;
        return a == b;
    }
};

pub const DepCtx = struct {
    parent: ?*DepCtx = null,
    cache: Cache,
    static: []StaticBinder,
    value: []*anyopaque,

    pub fn call_first(self: *DepCtx, comptime fun: anytype, extra_args: anytype) anyerror!klib.meta.Result(fun) {
        if (comptime @typeInfo(@TypeOf(extra_args)) != .@"struct") {
            @compileError("Expected a tuple of arguments");
        }

        const params = @typeInfo(klib.meta.Fn(@TypeOf(fun))).@"fn".params;

        const types = comptime brk: {
            var types: [params.len]type = undefined;
            for (0..extra_args.len) |i| types[i] = @TypeOf(extra_args[i]);
            for (extra_args.len..params.len) |i| types[i] = params[i].type orelse @compileError("reached anytype");
            break :brk &types;
        };

        var args: std.meta.Tuple(types) = undefined;
        inline for (0..args.len) |i| args[i] = if (i >= extra_args.len) try self.require(@TypeOf(args[i])) else extra_args[i];

        return @call(.auto, fun, args);
    }

    pub fn require(self: *DepCtx, comptime T: type) !T {
        // std.log.info("Getting {s}.", .{@typeName(T)});
        if (T == *DepCtx) return self;

        const tid = comptime klib.meta.typeId(T);
        const res = self.cache.get(tid);
        if (res == null) {
            if (self.parent) |p| {
                return try p.require(T);
            } else {
                return error.DependencyNotFound;
            }
        }

        return switch (res.?) {
            .ctx => |c| {
                if (comptime klib.meta.isValuePointer(T)) {
                    return @ptrCast(@alignCast(self.value[c]));
                } else {
                    return @as(*T, @ptrCast(@alignCast(self.value[c]))).*;
                }
            },
            .static_ctx => |c| {
                if (comptime klib.meta.isValuePointer(T)) {
                    return @ptrCast(@alignCast(self.static[c].ptr));
                } else {
                    return @as(*T, @ptrCast(@alignCast(self.static[c].ptr))).*;
                }
            },
            .resolver => |r| {
                if (comptime klib.meta.isValuePointer(T)) {
                    const v: T = @ptrFromInt(@intFromPtr(self.value[r.ctx]) + r.offset);
                    // std.log.info("{x}: Found resolver(*) at {x} (from {x}+{d}: {d})", .{
                    //     @intFromPtr(tid),
                    //     @intFromPtr(v),
                    //     @intFromPtr(self.value[r.ctx]),
                    //     r.offset,
                    //     r.ctx,
                    // });
                    return v;
                } else {
                    const v: *T = @ptrFromInt(@intFromPtr(self.value[r.ctx]) + r.offset);
                    // std.log.info("{x}: Found resolver at {x} (from {x}+{d}: {d})", .{
                    //     @intFromPtr(tid),
                    //     @intFromPtr(v),
                    //     @intFromPtr(self.value[r.ctx]),
                    //     r.offset,
                    //     r.ctx,
                    // });
                    return v.*;
                }
            },
            .static => |s| {
                if (comptime klib.meta.isValuePointer(T)) {
                    const v: T = @ptrFromInt(@intFromPtr(self.static[s.ctx].ptr) + s.offset);
                    // std.log.info("{x}: Found static(*) at {x} (from {x}+{d}: {d})", .{
                    //     @intFromPtr(tid),
                    //     @intFromPtr(v),
                    //     @intFromPtr(self.static[s.ctx].ptr),
                    //     s.offset,
                    //     s.ctx,
                    // });
                    return v;
                } else {
                    const v: *T = @ptrFromInt(@intFromPtr(self.static[s.ctx].ptr) + s.offset);
                    // std.log.info("{x}: Found static at {x} (from {x}+{d}: {d})", .{
                    //     @intFromPtr(tid),
                    //     @intFromPtr(v),
                    //     @intFromPtr(self.static[s.ctx].ptr),
                    //     s.offset,
                    //     s.ctx,
                    // });
                    return v.*;
                }
            },
            .factory => |f| {
                //TODO: If a cache is present we need to return that instead.
                if (comptime klib.meta.isValuePointer(T)) {
                    return @ptrCast(@alignCast(try f.fac(self, null)));
                } else {
                    var val: T = undefined;
                    _ = try f.fac(self, @ptrCast(@alignCast(&val)));
                    return val;
                }
            },
            .static_factory => |f| {
                //TODO: If a cache is present we need to return that instead.
                if (comptime klib.meta.isValuePointer(T)) {
                    return @ptrCast(@alignCast(try f.fac(self, null)));
                } else {
                    var val: T = undefined;
                    _ = try f.fac(self, @ptrCast(@alignCast(&val)));
                    return val;
                }
            },
        };
    }
};

pub const Cache = std.ArrayHashMapUnmanaged(klib.meta.TypeId, Resolved, TidArrayHashContext, false);
