const klib = @import("klib");

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
