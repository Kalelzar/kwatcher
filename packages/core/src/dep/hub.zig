const std = @import("std");
const klib = @import("klib");
const meta = @import("../utils/meta.zig");
const DriverRegistry = @import("../driver.zig").Drivers;
const ctx_mod = @import("ctx.zig");
const DepCtx = ctx_mod.DepCtx;
const StaticBinder = ctx_mod.StaticBinder;

pub fn DepHub(comptime DM: type, comptime Statics: anytype, comptime Config: type) type {
    return struct {
        pub const DependencyMap = DM;
        pub const StaticMap = Statics;

        statics: std.ArrayList(StaticBinder),

        fn fac(comptime T: type, fun: anytype) *const fn (*DepCtx, ?*anyopaque) anyerror!*anyopaque {
            const H = struct {
                pub fn get(ctx: *DepCtx, receiver: ?*anyopaque) anyerror!*anyopaque {
                    var args: std.meta.ArgsTuple(@TypeOf(fun)) = undefined;
                    inline for (args, 0..) |t, i| {
                        args[i] = try ctx.require(@TypeOf(t));
                    }

                    if (comptime !klib.meta.isValuePointer(T)) {
                        std.debug.assert(receiver != null);
                        const tr: *T = @ptrCast(@alignCast(receiver.?));
                        tr.* = if (comptime klib.meta.canBeError(fun)) try @call(.auto, fun, args) else @call(.auto, fun, args);
                        return receiver.?;
                    } else {
                        return @ptrCast(@alignCast(if (comptime klib.meta.canBeError(fun)) try @call(.auto, fun, args) else @call(.auto, fun, args)));
                    }
                }
            };

            return H.get;
        }

        pub fn compile(self: *@This(), comptime category: anytype, comptime lifetime: DM.Lifetime, allocator: std.mem.Allocator) !DepCtx {
            var nextCtx: u8 = 0;
            var ctx = DepCtx{
                .cache = .{},
                .value = &.{},
                .static = self.statics.items,
            };
            inline for (DependencyMap.Categories, 0..) |C, idx| {
                _ = idx;
                if (comptime !std.mem.eql(u8, @tagName(C.Tag), @tagName(category)) or @intFromEnum(C.Lifetime) > @intFromEnum(lifetime)) continue;

                if (C.Lifetime != .static) {
                    inline for (C.ContextStack) |Ctx| {
                        defer nextCtx += 1;

                        try ctx.cache.put(
                            allocator,
                            klib.meta.typeId(*Ctx),
                            .{
                                .ctx = nextCtx,
                            },
                        );
                        inline for (std.meta.fields(Ctx)) |f| {
                            const ti = @typeInfo(f.type);
                            switch (ti) {
                                .optional => {},
                                else => {
                                    try ctx.cache.put(
                                        allocator,
                                        klib.meta.typeId(f.type),
                                        .{
                                            .resolver = .{
                                                .ctx = nextCtx,
                                                .offset = @offsetOf(Ctx, f.name),
                                            },
                                        },
                                    );
                                    if (!klib.meta.isValuePointer(f.type)) {
                                        try ctx.cache.put(
                                            allocator,
                                            klib.meta.typeId(*f.type),
                                            .{
                                                .resolver = .{
                                                    .ctx = nextCtx,
                                                    .offset = @offsetOf(Ctx, f.name),
                                                },
                                            },
                                        );
                                        try ctx.cache.put(
                                            allocator,
                                            klib.meta.typeId(*const f.type),
                                            .{
                                                .resolver = .{
                                                    .ctx = nextCtx,
                                                    .offset = @offsetOf(Ctx, f.name),
                                                },
                                            },
                                        );
                                    }
                                },
                            }
                        }

                        inline for (@typeInfo(Ctx).@"struct".decls) |f| {
                            const fun = @field(Ctx, f.name);
                            const RT = klib.meta.Result(fun);
                            if (comptime RT == void) continue;
                            try ctx.cache.put(
                                allocator,
                                klib.meta.typeId(RT),
                                .{
                                    .factory = .{
                                        .ctx = nextCtx,
                                        .fac = fac(RT, fun),
                                    },
                                },
                            );
                        }
                    }
                } else {
                    comptime var i: usize = 0;
                    inline for (C.ContextStack) |Ctx| {
                        if (comptime i >= Statics.len) break;
                        inline for (i..Statics.len) |j| {
                            const s = Statics[j];
                            if (comptime std.mem.eql(u8, @tagName(s.@"0"), "all")) break;
                            if (comptime std.mem.eql(u8, @tagName(s.@"0"), @tagName(C.Tag))) break;
                            i += 1;
                        }
                        i += 1;
                        // std.log.info("Found {s} at {d}.", .{ @typeName(Ctx), i });

                        try ctx.cache.put(
                            allocator,
                            klib.meta.typeId(*Ctx),
                            .{
                                .static_ctx = i - 1,
                            },
                        );

                        inline for (std.meta.fields(Ctx)) |f| {
                            const ti = @typeInfo(f.type);
                            switch (ti) {
                                .optional => {},
                                else => {
                                    try ctx.cache.put(
                                        allocator,
                                        klib.meta.typeId(f.type),
                                        .{
                                            .static = .{
                                                .ctx = i - 1,
                                                .offset = @offsetOf(Ctx, f.name),
                                            },
                                        },
                                    );

                                    if (!klib.meta.isValuePointer(f.type)) {
                                        try ctx.cache.put(
                                            allocator,
                                            klib.meta.typeId(*f.type),
                                            .{
                                                .static = .{
                                                    .ctx = i - 1,
                                                    .offset = @offsetOf(Ctx, f.name),
                                                },
                                            },
                                        );
                                        try ctx.cache.put(
                                            allocator,
                                            klib.meta.typeId(*const f.type),
                                            .{
                                                .static = .{
                                                    .ctx = i,
                                                    .offset = @offsetOf(Ctx, f.name),
                                                },
                                            },
                                        );
                                    }
                                },
                            }
                        }

                        inline for (@typeInfo(Ctx).@"struct".decls) |f| {
                            const fun = @field(Ctx, f.name);
                            const RT = klib.meta.Result(fun);
                            if (comptime RT == void) continue;
                            try ctx.cache.put(
                                allocator,
                                klib.meta.typeId(RT),
                                .{
                                    .static_factory = .{
                                        .ctx = i - 1,
                                        .fac = fac(RT, fun),
                                    },
                                },
                            );
                        }
                    }
                }
            }
            return ctx;
        }

        pub fn swap(comptime DMap: anytype) type {
            return DepHub(DMap, Static, Config);
        }

        pub fn become(self: @This(), comptime Other: type) Other {
            return .{
                .statics = self.statics,
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            inline for (DM.Categories) |C| {
                if (comptime Statics.len == 0) break;
                if (comptime C.Lifetime == .static) out: {
                    var cont = self.compile(C.Tag, C.Lifetime, allocator) catch break :out;
                    self.prepare(&cont, C.Tag, C.Lifetime, allocator) catch break :out;
                    defer reset(&cont, C.Tag, C.Lifetime, allocator);
                    self.actualize(C.Tag, C.Lifetime, &cont) catch break :out;
                    defer deactualize(&cont, C.Tag, C.Lifetime);

                    const Rd = meta.reverse(C.ContextStack);
                    inline for (Rd) |Ctx| {
                        comptime var i: usize = 0;
                        if (comptime i >= Statics.len - 1) break;
                        inline for (0..Statics.len) |rj| {
                            const j = Statics.len - rj - 1;
                            const s = Statics[j];
                            //@compileLog(Ctx, "at", j, meta.Bare(s.@"1"), s.@"0", C.Tag);
                            if (comptime std.mem.eql(u8, @tagName(s.@"0"), @tagName(C.Tag))) {
                                if (comptime meta.Bare(s.@"1") == Ctx) {
                                    break;
                                }
                            }
                            i += 1;
                        }
                        if (comptime i > Statics.len - 1) {
                            continue;
                        }
                        const ri = Statics.len - i - 1;

                        const ctx: *Ctx = @ptrCast(@alignCast(self.statics.items[ri].ptr));
                        if (comptime @hasDecl(Ctx, "deconstruct")) blk: {
                            const fun = @field(Ctx, "deconstruct");
                            if (@typeInfo(@TypeOf(fun)) != .@"fn") break :blk;
                            var args: std.meta.ArgsTuple(@TypeOf(fun)) = undefined;
                            const fields = std.meta.fields(std.meta.ArgsTuple(@TypeOf(fun)));
                            const n_deps = comptime fields.len;
                            if (n_deps < 1) {
                                @compileError("Deconstruct must accept self. Why else would you need it?");
                            }
                            args[0] = ctx;
                            inline for (1..n_deps) |j| {
                                args[j] = cont.require(@TypeOf(args[j])) catch @panic("Bad require");
                            }

                            @call(.auto, fun, args);
                        }
                    }
                }
            }

            self.statics.deinit(allocator);
        }

        fn next(
            self: @This(),
            comptime drivers: DriverRegistry,
            allocator: std.mem.Allocator,
            comptime i: comptime_int,
        ) Extended(@This(), drivers, i) {
            if (i >= drivers.drivers.len) {
                return self;
            } else {
                const D = drivers.drivers[i];
                if (comptime @hasDecl(D, "DependencyContext")) {
                    return D.DependencyContext.apply(self, .all, allocator, Config).next(
                        drivers,
                        allocator,
                        i + 1,
                    );
                } else {
                    return self.next(drivers, allocator, i + 1);
                }
            }
        }

        fn Extended(comptime DH: type, comptime drivers: DriverRegistry, comptime i: comptime_int) type {
            if (i >= drivers.drivers.len) {
                return DH;
            } else {
                const D = drivers.drivers[i];

                if (comptime @hasDecl(D, "DependencyContext")) {
                    return Extended(
                        D.DependencyContext.Return(.all, Config, DH),
                        drivers,
                        i + 1,
                    );
                } else {
                    return Extended(DH, drivers, i + 1);
                }
            }
        }

        pub fn newBlank(comptime drivers: DriverRegistry) Drivers(drivers) {
            return .{ .statics = .{} };
        }

        pub fn new(
            comptime drivers: DriverRegistry,
            alloc: std.mem.Allocator,
        ) Extended(Drivers(drivers), drivers, 0) {
            const dh: Drivers(drivers) = .{ .statics = .{} };
            return dh.next(drivers, alloc, 0);
        }

        pub fn verify() void {
            _ = DM.makeGraph();
        }

        pub fn static(
            self: @This(),
            comptime category: anytype,
            ctx: anytype,
            allocator: std.mem.Allocator,
        ) Static(category, @TypeOf(ctx)) {
            // std.log.info("Registering static (new) {s}: {s} {x}", .{ @typeName(@TypeOf(ctx)), @tagName(category), @intFromPtr(ctx) });
            var s = self.statics;
            s.append(allocator, .{
                .ptr = @ptrCast(@alignCast(ctx)),
                .tag = @tagName(category),
            }) catch unreachable; // YIKES!

            return .{ .statics = s };
        }

        pub fn staticAssumeRegistered(
            self: *@This(),
            comptime category: anytype,
            ctx: anytype,
            allocator: std.mem.Allocator,
        ) void {
            // std.log.info("Registering static {s}: {s} {x}", .{ @typeName(@TypeOf(ctx)), @tagName(category), @intFromPtr(ctx) });
            self.statics.append(allocator, .{
                .ptr = @ptrCast(@alignCast(ctx)),
                .tag = @tagName(category),
            }) catch unreachable; // YIKES!
        }

        pub fn deactualize(
            ctx: *DepCtx,
            comptime category: anytype,
            comptime lifetime: DM.Lifetime,
        ) void {
            var handles: u64 = 0;
            inline for (DM.Categories) |C| {
                if (comptime std.mem.eql(u8, @tagName(C.Tag), "all")) continue;
                if (comptime std.mem.eql(u8, @tagName(C.Tag), @tagName(category)) and @intFromEnum(C.Lifetime) <= @intFromEnum(lifetime)) {
                    if (comptime C.Lifetime != .static) {
                        inline for (C.ContextStack) |Ctx| {
                            const c: *Ctx = @ptrCast(@alignCast(ctx.value[handles]));
                            if (comptime @hasDecl(Ctx, "deconstruct")) blk: {
                                //FIXME: This needs to happen in inverse order! UB!
                                const fun = @field(Ctx, "deconstruct");
                                if (@typeInfo(@TypeOf(fun)) != .@"fn") break :blk;
                                var args: std.meta.ArgsTuple(@TypeOf(fun)) = undefined;
                                const fields = std.meta.fields(std.meta.ArgsTuple(@TypeOf(fun)));
                                const n_deps = comptime fields.len;
                                if (n_deps < 1) {
                                    @compileError("Deconstruct must accept self. Why else would you need it?");
                                }
                                args[0] = c;
                                inline for (1..n_deps) |j| {
                                    args[j] = ctx.require(@TypeOf(args[j])) catch unreachable;
                                }

                                @call(.auto, fun, args);
                            }
                            handles += 1;
                        }
                    } else {}
                }
            }
        }

        pub fn reset(
            ctx: *DepCtx,
            comptime category: anytype,
            comptime lifetime: DM.Lifetime,
            allocator: std.mem.Allocator,
        ) void {
            ctx.cache.deinit(allocator);
            var i: u64 = 0;
            inline for (DM.Categories) |C| {
                if (comptime std.mem.eql(u8, @tagName(C.Tag), "all")) continue;
                if (comptime std.mem.eql(u8, @tagName(C.Tag), @tagName(category)) and @intFromEnum(C.Lifetime) <= @intFromEnum(lifetime)) {
                    if (comptime C.Lifetime != .static) {
                        inline for (C.ContextStack) |Ctx| {
                            defer i += 1;
                            allocator.destroy(@as(*Ctx, @ptrCast(@alignCast(ctx.value[i]))));
                        }
                    } else {}
                }
            }
            allocator.free(ctx.value);
        }

        /// Expand the current container with an extension.
        pub fn with(
            self: @This(),
            comptime category: anytype,
            comptime extension: type,
            allocator: std.mem.Allocator,
        ) extension.Return(category, Config, @This()) {
            return extension.apply(self, category, allocator, Config);
        }

        pub fn prepare(
            _: @This(),
            to_ctx: *DepCtx,
            comptime category: anytype,
            comptime lifetime: DM.Lifetime,
            allocator: std.mem.Allocator,
        ) !void {
            var handles: std.ArrayList(*anyopaque) = .{};
            try handles.ensureUnusedCapacity(allocator, 1);
            inline for (DM.Categories) |C| {
                if (comptime std.mem.eql(u8, @tagName(C.Tag), "all")) continue;
                if (comptime std.mem.eql(u8, @tagName(C.Tag), @tagName(category)) and @intFromEnum(C.Lifetime) <= @intFromEnum(lifetime)) {
                    if (comptime C.Lifetime != .static) {
                        try handles.ensureUnusedCapacity(allocator, C.ContextStack.len);
                        inline for (C.ContextStack) |Ctx| {
                            const ctx = try allocator.create(Ctx);
                            handles.appendAssumeCapacity(@ptrCast(@alignCast(ctx)));
                            // std.log.info("={d}=> {s} {x}", .{ handles.items.len - 1, @typeName(Ctx), @intFromPtr(ctx) });
                        }
                    } else {}
                }
            }

            to_ctx.value = try handles.toOwnedSlice(allocator);
        }

        pub fn actualize(
            _: @This(),
            comptime category: anytype,
            comptime lifetime: DM.Lifetime,
            ctx: *DepCtx,
        ) !void {
            var nextCtx: u8 = 0;
            inline for (DM.Categories) |C| {
                if (comptime std.mem.eql(u8, @tagName(C.Tag), "all")) continue;
                if (comptime std.mem.eql(u8, @tagName(C.Tag), @tagName(category)) and @intFromEnum(C.Lifetime) <= @intFromEnum(lifetime)) {
                    if (comptime C.Lifetime != .static) {
                        inline for (C.ContextStack) |Ctx| {
                            const v: *Ctx = @ptrCast(@alignCast(ctx.value[nextCtx]));
                            v.* = std.mem.zeroInit(Ctx, .{});
                            if (comptime @hasDecl(Ctx, "construct")) blk: {
                                const fun = @field(Ctx, "construct");
                                if (@typeInfo(@TypeOf(fun)) != .@"fn") break :blk;
                                var args: std.meta.ArgsTuple(@TypeOf(fun)) = undefined;
                                const fields = std.meta.fields(std.meta.ArgsTuple(@TypeOf(fun)));
                                const n_deps = comptime fields.len;
                                if (n_deps < 1) {
                                    @compileError("Construct must accept self. Why else would you need it?");
                                }
                                args[0] = v;
                                inline for (1..n_deps) |i| {
                                    args[i] = try ctx.require(@TypeOf(args[i]));
                                }

                                switch (comptime @typeInfo(klib.meta.Return(fun))) {
                                    .error_union => try @call(.auto, fun, args),
                                    else => @call(.auto, fun, args),
                                }
                            }
                            nextCtx += 1;
                        }
                    }
                }
            }
        }

        pub fn scoped(self: @This(), comptime category: anytype, comptime T: type) Scoped(category, T) {
            return .{ .statics = self.statics };
        }

        pub fn Scoped(comptime category: anytype, comptime T: type) type {
            return DepHub(DM.augment(category, .scoped, T), Statics, Config);
        }

        pub fn Static(comptime category: anytype, comptime T: type) type {
            const ti = @typeInfo(T);
            if (ti != .pointer) @compileError("Expected context to be a pointer.");
            return DepHub(
                DM.augment(category, .static, ti.pointer.child),
                Statics ++ .{.{ category, T }},
                Config,
            );
        }

        fn Drivers(comptime drivers: DriverRegistry) type {
            var N = DM;
            inline for (drivers.drivers) |D| {
                N = N.cat(D.key);
                N = N.requires(D.key, .scoped, D.Dependencies);
            }
            return DepHub(N, Statics, Config);
        }
    };
}

comptime {
    std.testing.refAllDecls(@This());
}
