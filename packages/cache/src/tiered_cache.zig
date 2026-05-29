const std = @import("std");
const klib = @import("klib");
const cache = @import("cache.zig");
const dep = @import("kw-core").deps;

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
        const ResolversStruct = Resolvers;

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
            const flds = @typeInfo(BuilderMap).@"struct".fields;
            for (flds) |fld| {
                @field(new_builder, fld.name) = @field(self.builder, fld.name).cold(f);
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

        pub fn intern(comptime self: Self, comptime index: comptime_int) struct {
            pub const Context = self.resolve()[index];
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

pub fn Dependencies(
    comptime Data: type,
    comptime Invariant: anytype,
    comptime Resolvers: anytype,
    comptime config: SetBuilder(Data, Invariant, Resolvers),
    comptime index: comptime_int,
) type {
    const __interned = config.intern(index);
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

        pub fn cacheFactory(inj: *dep.DepCtx, intf: Interface) cache.Cache(Data) {
            return .{ .config = intf.interface(), .inj = inj };
        }

        pub fn deconstruct(self: *@This()) void {
            if (self.context) |c| {
                const alloc = c.allocator;
                c.deinit();
                alloc.destroy(c);
            }
        }
    };
}

pub fn Container(comptime config: anytype, comptime index: comptime_int) type {
    const Data = @TypeOf(config).DataType;
    const Invariant = @TypeOf(config).InvariantType;
    const Resolvers = @TypeOf(config).ResolversStruct;

    return Dependencies(Data, Invariant, Resolvers, config, index);
}

pub fn Cache(
    comptime Data: type,
    comptime Invariant: anytype,
    comptime Tiers: anytype,
) SetBuilder(Data, Invariant, Tiers) {
    return .init();
}
