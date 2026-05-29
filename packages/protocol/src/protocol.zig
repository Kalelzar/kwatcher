const std = @import("std");
const Drivers = @import("kw-core").driver.Drivers;

pub const client_registration = @import("client-registration/client_registration.zig");

pub const Kind = enum {
    client_registration,
};

const Self = @This();

pub fn use(
    comptime target: anytype,
    comptime protocols: []const Kind,
    comptime Context: type,
) []const type {
    var prots: []const type = &.{};
    var len = 0;
    inline for (protocols) |p| {
        const protocol = @field(Self, @tagName(p));
        if (comptime protocol.supports(target.kind)) {
            defer len = len + 1;
            prots = prots ++ protocol.forKind(Context, target.kind);
        }
    }

    return prots;
}

// NOTE: This assumes that category is the driver key.
// We should provide an overload for when that is not the case, though the rest of the system does too
// NOTE: Even though the above is true, we do not use Driver.DriverKeys for the type (even though it is correct),
// bacause DepHub is untyped and throws a hissy-fit because .all isn't a driver key.
// The solution is a custom type that just appends all to the keyset but meh.
pub fn deps(
    comptime drv: Drivers,
    comptime Context: type,
    comptime protocols: []const Kind,
) type {
    return struct {
        pub fn apply(
            dephub: anytype,
            comptime category: anytype,
            allocator: std.mem.Allocator,
            comptime Config: type,
        ) Return(category, Config, @TypeOf(dephub)) {
            const protocol = @field(Self, @tagName(protocols[0]));
            if (comptime protocols.len == 1) {
                return protocol.deps.default(drv, Context).value(category, dephub, Config, allocator);
            } else {
                const next = protocol.deps.default(drv, Context).value(category, dephub, Context, Config, allocator);
                return deps(drv, protocols[1..]).apply(next, category, allocator, Config);
            }
        }

        pub fn Return(
            comptime category: anytype,
            comptime Config: type,
            comptime DH: type,
        ) type {
            const protocol = @field(Self, @tagName(protocols[0]));
            if (comptime protocols.len == 1) {
                return protocol.deps.default(drv, Context).Return(category, Config, DH);
            } else {
                const next = protocol.deps.default(drv, Context).Return(category, Config, DH);
                return deps(drv, protocols[1..])
                    .Return(
                    category,
                    Config,
                    next,
                );
            }
        }
    };
}
