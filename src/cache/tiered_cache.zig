const std = @import("std");
const klib = @import("klib");
const cache = @import("cache.zig");

pub fn SetBuilder(
    comptime Data: type,
    comptime Invariant: anytype,
    comptime Resolvers: anytype,
) type {
    const ti = @typeInfo(@TypeOf(Resolvers));
    if (ti != .@"struct") @compileError("Expected resolvers to be a struct of resolver functions.");
    const resolver_count = ti.@"struct".fields.len;

    var builder_fields: [resolver_count]std.builtin.Type.StructField = undefined;
    for (ti.@"struct".fields, 0..) |f, i| {
        builder_fields[i] = .{
            .alignment = f.alignment,
            .default_value_ptr = null,
            .is_comptime = false,
            .name = f.name,
            .type = cache.SetBuilder(Data, Invariant),
        };
    }

    const builder_map: std.builtin.Type = .{ .@"struct" = .{
        .decls = &.{},
        .fields = &builder_fields,
        .is_tuple = false,
        .layout = .auto,
    } };

    const BuilderMap = @Type(builder_map);

    return struct {
        const Self = @This();
        const DataType = Data;
        const InvariantType = Invariant;

        builder: BuilderMap,

        pub fn init() Self {
            var new_builder: BuilderMap = undefined;
            for (@typeInfo(BuilderMap).@"struct".fields) |fld| {
                @field(new_builder, fld.name) = .new();
            }

            return .{
                .builder = new_builder,
            };
        }

        pub fn cold(comptime self: Self, comptime f: anytype) Self {
            var new_builder: BuilderMap = undefined;
            const flds = @typeInfo(@TypeOf(f)).@"struct".fields;
            for (flds) |fld| {
                @field(new_builder, fld.name) = @field(self.builder, fld.name).cold(@field(f, fld.name));
            }

            return .{
                .builder = new_builder,
            };
        }

        pub fn evict(comptime self: Self, comptime e: anytype) Self {
            var new_builder: BuilderMap = undefined;
            const flds = @typeInfo(@TypeOf(e)).@"struct".fields;
            for (flds) |fld| {
                @field(new_builder, fld.name) = @field(self.builder, fld.name).evict(@field(e, fld.name));
            }

            return .{
                .builder = new_builder,
            };
        }

        pub fn residency(comptime self: Self, comptime r: anytype) Self {
            var new_builder: BuilderMap = undefined;
            const flds = @typeInfo(@TypeOf(r)).@"struct".fields;
            for (flds) |fld| {
                @field(new_builder, fld.name) = @field(self.builder, fld.name).residency(@field(r, fld.name));
            }

            return .{
                .builder = new_builder,
            };
        }

        pub fn expiration(comptime self: Self, comptime r: anytype) Self {
            var new_builder: BuilderMap = undefined;
            const flds = @typeInfo(@TypeOf(r)).@"struct".fields;
            for (flds) |fld| {
                @field(new_builder, fld.name) = @field(self.builder, fld.name).expiration(@field(r, fld.name));
            }

            return .{
                .builder = new_builder,
            };
        }

        pub fn key(comptime self: Self, comptime k: anytype) Self {
            var new_builder: BuilderMap = undefined;
            const flds = @typeInfo(BuilderMap).@"struct".fields;
            for (flds) |fld| {
                @field(new_builder, fld.name) = @field(self.builder, fld.name).key(k);
            }

            return .{
                .builder = new_builder,
            };
        }

        pub fn interface(comptime self: Self) type {
            for (@typeInfo(BuilderMap).@"struct".fields) |f| {
                return @field(self.builder, f.name).interface();
            }
        }

        pub fn intern(comptime self: Self) struct {
            pub const Context = self.resolve();
            pub const Interface = self.interface();
            interface: Interface,
        } {
            return .{
                .interface = self.build(),
            };
        }

        pub fn build(comptime self: Self) self.interface() {
            const Ctx = self.resolve();

            const head = @typeInfo(BuilderMap).@"struct".fields[0];

            const act = @field(self.builder, head.name)
                .hotRaw(cache.autoCacheWithContexts(
                    Data,
                    Invariant,
                    Ctx,
                ))
                .pushRaw(cache.autoPushWithContexts(
                    Data,
                    Invariant,
                    Ctx,
                ))
                .build();
            return act;
        }

        pub fn resolve(comptime self: Self) []type {
            comptime {
                const resolvers = blk: {
                    var resolvers: [resolver_count]type = undefined;
                    for (@typeInfo(BuilderMap).@"struct".fields, 0..) |f, i| {
                        const set = @field(self.builder, f.name);
                        const eviction_strat = set.find(.eviction) orelse .none;
                        const resident = set.find(.residency) orelse cache.Residency{ .unlimited = {} };
                        const exp = set.find(.expiration) orelse cache.Expiration{ .unlimited = {} };
                        resolvers[i] = @field(Resolvers, f.name)(Data, eviction_strat, resident, exp);
                    }
                    break :blk resolvers;
                };
                return @constCast(&resolvers);
            }
        }
    };
}

pub fn Cache(
    comptime Data: type,
    comptime Invariant: anytype,
    comptime Tiers: anytype,
) SetBuilder(Data, Invariant, Tiers) {
    return .init();
}
