const std = @import("std");
const meta = @import("utils/meta.zig");
const event = @import("event.zig");

pub const Drivers = struct {
    block_start: u12 = 100,
    drivers: []const type,

    pub fn new() Drivers {
        return .{
            .drivers = &.{},
        };
    }

    pub fn get(comptime self: Drivers, comptime key: DriverKeys(self)) type {
        return comptime self.drivers[@intFromEnum(key)];
    }

    pub fn registerHandler(comptime self: Drivers, comptime HT: anytype) Drivers {
        const T = HT(self.block_start);
        const next_start = T.__block_end();
        return .{
            .block_start = next_start,
            .drivers = self.drivers ++ .{T},
        };
    }

    pub inline fn last(comptime self: Drivers) u12 {
        return self.block_start;
    }

    pub fn EventList(comptime self: Drivers) type {
        comptime {
            var defs: [self.last() - 100 + meta.count(event.Base)]std.builtin.Type.EnumField = undefined;
            var i: u64 = 0;

            switch (@typeInfo(event.Base)) {
                .@"enum" => |e| {
                    if (!e.is_exhaustive) @compileError("EventType must be exhaustive!");
                    for (e.fields) |f| {
                        if (std.mem.eql(u8, f.name[0..f.name.len], "__end")) continue;
                        defs[i] = f;
                        i += 1;
                    }
                },
                else => @compileError("Base event is not an enum. How even?"),
            }

            for (self.drivers) |d| {
                const driver_block = d.EventType;
                const ti = @typeInfo(driver_block);
                switch (ti) {
                    .@"enum" => |e| {
                        if (!e.is_exhaustive) @compileError("EventType must be exhaustive!");
                        for (e.fields) |f| {
                            if (std.mem.eql(u8, f.name[0..f.name.len], "__end")) continue;
                            defs[i] = f;
                            i += 1;
                        }
                    },
                    else => @compileError("Expected EventType to be an enum. Odd that."),
                }
            }

            const list = @Type(.{
                .@"enum" = .{
                    .decls = &.{},
                    .fields = &defs,
                    .is_exhaustive = true,
                    .tag_type = meta.UIntShrink(self.last()),
                },
            });

            return list;
        }
    }

    pub fn EventValues(comptime self: Drivers) type {
        var value: [self.drivers.len + 1]std.builtin.Type.UnionField = undefined;
        value[0] = std.builtin.Type.UnionField{
            .alignment = @alignOf(event.BaseValues),
            .name = "internal",
            .type = event.BaseValues,
        };
        inline for (self.drivers, 1..) |D, i| {
            const name: [:0]const u8 = @tagName(D.key);
            value[i] = std.builtin.Type.UnionField{
                .alignment = @alignOf(D.EventValues),
                .name = name,
                .type = D.EventValues,
            };
        }

        const values = @Type(.{ .@"union" = .{
            .decls = &.{},
            .fields = &value,
            .layout = .auto,
            .tag_type = self.EventValueKeys(),
        } });

        return values;
    }

    fn SchedulerMapImpl(comptime DriverEnum: type, comptime Schs: []const type) *const fn (comptime DriverEnum) type {
        const H = struct {
            const SchedulerTypes = Schs;

            pub fn Get(comptime key: DriverEnum) type {
                return SchedulerTypes[@intFromEnum(key)];
            }
        };

        return H.Get;
    }

    pub fn SchedulerMap(comptime self: Drivers) *const fn (comptime self.DriverKeys()) type {
        return SchedulerMapImpl(self.DriverKeys(), &self.Schedulers());
    }

    pub fn SchedulerCtx(comptime self: Drivers) [self.drivers.len]type {
        const Ss = self.Schedulers();
        var res: [self.drivers.len]type = undefined;
        inline for (Ss, 0..) |S, i| {
            res[i] = struct {
                scheduler: ?S = null,
                pub fn schedulerFac(fac: *@This()) S {
                    return fac.scheduler.?;
                }
            };
        }
        return res;
    }

    pub fn DriverKeys(comptime self: Drivers) type {
        var value: [self.drivers.len]std.builtin.Type.EnumField = undefined;
        inline for (self.drivers, 0..) |D, i| {
            const name: [:0]const u8 = @tagName(D.key);
            value[i] = std.builtin.Type.EnumField{
                .name = name,
                .value = i,
            };
        }

        const values = @Type(.{
            .@"enum" = .{
                .decls = &.{},
                .fields = &value,
                .is_exhaustive = true,
                .tag_type = meta.UIntShrink(value.len - 1),
            },
        });

        return values;
    }

    pub fn EventValueKeys(comptime self: Drivers) type {
        var value: [self.drivers.len + 1]std.builtin.Type.EnumField = undefined;
        value[0] = std.builtin.Type.EnumField{
            .name = "internal",
            .value = 0,
        };

        inline for (self.drivers, 1..) |D, i| {
            const name: [:0]const u8 = @tagName(D.key);
            value[i] = std.builtin.Type.EnumField{
                .name = name,
                .value = i,
            };
        }

        const values = @Type(.{
            .@"enum" = .{
                .decls = &.{},
                .fields = &value,
                .is_exhaustive = true,
                .tag_type = meta.UIntShrink(value.len - 1),
            },
        });

        return values;
    }

    pub fn DriverConfig(comptime self: Drivers) type {
        var value: [self.drivers.len]std.builtin.Type.StructField = undefined;
        var added = 0;
        inline for (self.drivers) |D| {
            if (@hasDecl(D, "ConfigType")) {
                defer added = added + 1;
                const name: [:0]const u8 = @tagName(D.key);
                value[added] = std.builtin.Type.StructField{
                    .alignment = @alignOf(D.ConfigType),
                    .name = name,
                    .type = D.ConfigType,
                    .default_value_ptr = null,
                    .is_comptime = false,
                };
            }
        }

        const values = @Type(.{ .@"struct" = .{
            .decls = &.{},
            .fields = value[0..added],
            .layout = .auto,
            .is_tuple = false,
            .backing_integer = null,
        } });

        return values;
    }

    pub fn Schedulers(comptime self: Drivers) [self.drivers.len]type {
        var schedulers: [self.drivers.len]type = undefined;
        const hs = self.Handlers(self.EventList(), self.EventValues());
        for (hs, 0..) |H, i| {
            schedulers[i] = H.Scheduler;
        }
        return schedulers;
    }

    pub fn Handlers(comptime self: Drivers, comptime ET: type, comptime EV: type) [self.drivers.len]type {
        var handlers: [self.drivers.len]type = undefined;
        for (self.drivers, 0..) |D, i| {
            handlers[i] = D.Yield(ET, EV);
        }
        return handlers;
    }

    pub fn initAll(comptime self: Drivers, allocator: std.mem.Allocator, deps: anytype, comptime ET: type, comptime EV: type) !std.meta.Tuple(&self.Handlers(ET, EV)) {
        const Hs = self.Handlers(ET, EV);
        const Deps = @TypeOf(deps.*);

        var handlers: std.meta.Tuple(&Hs) = undefined;

        inline for (Hs, self.drivers, 0..) |H, D, i| {
            var inj_ctx = try deps.compile(D.key, .static, allocator);
            try deps.prepare(&inj_ctx, D.key, .static, allocator);
            try deps.actualize(D.key, .static, &inj_ctx);
            defer Deps.deactualize(&inj_ctx, D.key, .static);
            defer Deps.reset(&inj_ctx, D.key, .static, allocator);

            handlers[i] = try inj_ctx.call_first(H.init, .{});
        }

        return handlers;
    }
};

pub fn AssertDriver(comptime Drv: anytype, comptime expected_key: @Type(.enum_literal)) void {
    const DrvT = @TypeOf(Drv.*);
    const drv_ti: std.builtin.Type = @typeInfo(DrvT);
    switch (drv_ti) {
        .@"fn" => |f| {
            const first: std.builtin.Type.Fn.Param = f.params[0];
            if (comptime first.type != u12) {
                @compileError("Expected first parameter to be a comptime u12: Is " ++ @typeName(first.type.?));
            }
        },
        inline else => |_, t| @compileError("Expected driver builder to be a comptime function accepting a block as the first parameter. Got: " ++ @tagName(t)),
    }

    const Builder = Drv(0);

    if (comptime !@hasDecl(Builder, "__block_end")) {
        @compileError("Missing function declaration on builder: __block_end");
    }

    if (comptime !@hasDecl(Builder, "EventType")) {
        @compileError("Missing type declaration on builder: EventType");
    }

    const EType = Builder.EventType;
    if (comptime @typeInfo(EType) != .@"enum") {
        @compileError("Expected EventType to be an enum");
    }

    if (comptime !@hasField(EType, "__end")) {
        @compileError("EventType is missing the block-end sentinel field: __end");
    }

    if (comptime !@hasDecl(Builder, "EventValues")) {
        @compileError("Missing type declaration on builder: EventValues");
    }

    const EValues = Builder.EventValues;
    if (comptime @typeInfo(EValues) != .@"union") {
        @compileError("Expected EventValues to be a union");
    }

    if (comptime !@hasDecl(Builder, "key")) {
        @compileError("Missing const declaration on builder: key");
    }

    const driver_key = Builder.key;
    if (comptime driver_key != expected_key) {
        @compileError("Expected driver key to match the key from the builder");
    }

    if (comptime !@hasDecl(Builder, "jobs")) {
        @compileError("Missing const declaration on builder: jobs");
    }

    if (comptime !@hasDecl(Builder, "Yield")) {
        @compileError("Missing function declaration on builder: Yield");
    }

    if (comptime @hasDecl(Builder, "ConfigType")) {
        if (comptime @typeInfo(Builder.ConfigType) != .@"struct") {
            @compileError("Expected ConfigType to be a struct: Is " ++ @typeName(Builder.ConfigType));
        }
    }

    const Handler = Builder.Yield(Builder.EventType, Builder.EventValues);

    inline for (.{
        "Scheduler",
        "accepts",
        "init",
        "deinit",
        "bind",
        "scheduler",
        "watch",
        "stop",
        "handle",
    }) |decl| {
        if (comptime !@hasDecl(Handler, decl)) {
            @compileError("Missing declaration on handler: " ++ decl);
        }
    }

    if (comptime @TypeOf(Handler.Scheduler) != type) {
        @compileError("Expected Scheduler to be a type");
    }
}
