const std = @import("std");

pub const ChunkType = enum {
    header_a,
    drivers,
    event_type,
    link,
    event,
    eof,
};

pub const LinkType = enum {
    rel,
    abs,
    http,
    jump,
};

pub const Link = union(LinkType) {
    rel: []const u8,
    abs: []const u8,
    http: []const u8,
    jump: struct {
        offset: u64,
        name: [4]u8,
    },
};

pub const HeaderA = struct {
    version: u16,
    min_version: u16,
    conf_by: [4]u8,
    client_name: []const u8,
    client_version: u16,
    min_client_version: u16,
};

pub const Drivers = struct {
    drivers: []const Driver,

    pub const Driver = struct {
        name: []const u8,
        type: []const u8,
    };
};

pub const EventType = struct {
    driver_id: u16,
    mappings: []const Mapping,

    pub const Mapping = struct {
        value: u16,
        identifier: []const u8,
    };
};

pub const Event = struct {
    events: []const EventData,

    pub const EventData = struct {
        event_id: u16,
        data: []const u8,
        properties: []const u8,
    };
};

pub const ChunkData = union(ChunkType) {
    header_a: HeaderA,
    drivers: Drivers,
    event_type: EventType,
    link: Link,
    event: Event,
    eof: void,
};

pub const ChunkNames = std.EnumArray(ChunkType, []const u8).init(.{
    .header_a = "HDRA",
    .drivers = "DRVS",
    .event_type = "ETYP",
    .link = "LINK",
    .event = "EVNT",
    .eof = "EOF!",
});

pub const ChunkTypes = std.StaticStringMap(ChunkType).initComptime(&.{
    .{ "HDRA", .header_a },
    .{ "DRVS", .drivers },
    .{ "ETYP", .event_type },
    .{ "LINK", .link },
    .{ "EVNT", .event },
    .{ "EOF!", .eof },
});
