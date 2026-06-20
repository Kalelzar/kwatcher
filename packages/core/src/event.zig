const std = @import("std");
const klib = @import("klib");

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

                break :blk .{ .min = min, .max = max - 1 };
            };

            return v >= bounds.min and v <= bounds.max;
        }
    };

    return &H.accepts;
}

pub const Base = enum(u12) {
    noop,
    shutdown,
};

pub const BaseValues = union(Base) {
    noop: struct {},
    shutdown: struct {},
};

pub const Properties = struct {
    attempts: u8 = 0,
    correlation_id: u128 = 0,
};

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
