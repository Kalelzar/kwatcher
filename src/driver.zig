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
