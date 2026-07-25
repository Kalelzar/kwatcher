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

const std = @import("std");
const Drivers = @import("kw-core").driver.Drivers;

pub const client_registration = @import("client-registration/client_registration.zig");
pub const secret = @import("secret/v0/secret.zig");

pub const Kind = enum {
    client_registration,
    secret,
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
                const next = protocol.deps.default(drv, Context).value(category, dephub, Config, allocator);
                return deps(drv, Context, protocols[1..]).apply(next, category, allocator, Config);
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
                return deps(drv, Context, protocols[1..])
                    .Return(
                    category,
                    Config,
                    next,
                );
            }
        }
    };
}

// Ref all decls — refAllDeclsRecursive reaches the client-registration submodule
// (schema/route/timers/registry/deps/Config + protocol_routes + Scheduler).
// `use` is the generic entry point; exercise it for both supported driver kinds.
// (`deps` is the deep DI entry point, exercised by the runtime/example build.)
comptime {
    std.testing.refAllDeclsRecursive(@This());

    const Ctx = client_registration.ProtocolContext;
    _ = use(struct {
        pub const kind = .amqp;
    }, &.{.client_registration}, Ctx);
    _ = use(struct {
        pub const kind = .cron;
    }, &.{.client_registration}, Ctx);

    // secret.ProtocolContext carries both the `client` and `secrets`
    // fields, so it doubles as the combined-protocol context here.
    const SecretCtx = secret.ProtocolContext;
    _ = use(struct {
        pub const kind = .amqp;
    }, &.{ .client_registration, .secret }, SecretCtx);
    _ = use(struct {
        pub const kind = .cron;
    }, &.{ .client_registration, .secret }, SecretCtx);
}
