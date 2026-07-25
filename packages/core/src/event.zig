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
const klib = @import("klib");
const schema = @import("schema_companion.zig");
const DepCtx = @import("dep/ctx.zig").DepCtx;

pub const CorrelationID = @import("correlation.zig").CorrelationID;

/// Builds a predicate that tests whether an event id `e` falls within the
/// id-block bounds of event-type enum `T`.
pub fn genAccepts(comptime ET: type, comptime T: type) *const fn (ET) bool {
    const H = struct {
        pub fn accepts(e: ET) bool {
            const v = @intFromEnum(e);

            const bounds = comptime blk: {
                var min: u12 = std.math.maxInt(u12);
                var max: u12 = std.math.minInt(u12);
                for (@typeInfo(T).@"enum".fields) |f| {
                    if (min > f.value) min = f.value;
                    if (max < f.value) max = f.value;
                }

                break :blk .{ .min = min, .max = max };
            };

            return v >= bounds.min and v <= bounds.max;
        }
    };

    return &H.accepts;
}

pub const Base = enum(u12) {
    noop,
    shutdown,
    shutdownImminent,
};

pub const BaseValues = union(Base) {
    noop: struct {},
    shutdown: struct {},
    shutdownImminent: struct {},
};

pub const Properties = struct {
    attempts: u8 = 0,
    correlation_id: CorrelationID = .unset,
};

/// Stamp the current event's correlation id for the route about to handle
/// it: an unset id means this event is a trace root (cron fire, signal,
/// ingress without a wire id); a set id (scheduler copy or wire header) is
/// continued with a hop. Drivers call this exactly once per dispatch, at the
/// earliest moment the handling route is known; nothing else may write the
/// id afterwards. Returns the stamped properties.
pub fn stampRoute(inj: *DepCtx, comptime route_id: []const u8) !Properties {
    return stampOp(inj, comptime CorrelationID.hash(route_id));
}

/// `stampRoute` for the rare runtime-known operation (cron anonymous jobs):
/// takes a pre-hashed op id so no dispatch ever hashes at runtime.
pub fn stampOp(inj: *DepCtx, op_id: u32) !Properties {
    const props = try inj.require(*Properties);
    if (props.correlation_id.isUnset()) {
        const user: u32 = if (inj.require(*schema.UserInfo)) |u|
            CorrelationID.hash(u.id)
        else |_|
            0;
        props.correlation_id = .newRoot(user, op_id);
    } else {
        props.correlation_id = props.correlation_id.hop(op_id);
    }
    return props.*;
}

pub const ExtendedProperties = klib.meta.MergeStructs(
    Properties,
    struct {
        type: []const u8,
        driver: []const u8,
    },
);

pub fn Event(EventType: type, EventValues: type) type {
    return struct {
        pub const ET = EventType;
        pub const EV = EventValues;
        event_type: EventType,
        event_data: EventValues,
        properties: Properties = .{},
    };
}

// Ref all decls
comptime {
    std.testing.refAllDeclsRecursive(@This());
    std.testing.refAllDeclsRecursive(Event(Base, BaseValues));
    _ = genAccepts(Base, Base);
}
