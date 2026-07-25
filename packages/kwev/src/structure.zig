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

pub const ChunkType = enum {
    header_a,
    drivers,
    event_type,
    route_op_hash,
    dict,
    link,
    event,
    evnc,
    streamed_event,
    eof,
};

pub const CompressionType = enum(u8) {
    none = 0,
    zstd = 1,
    xz = 2,
    lz4 = 3,
};

pub const DictAlgorithm = enum(u8) {
    zstd = 0,
    lz4 = 1,
};

/// A pre-trained compression dictionary (definition chunk). Referenced by
/// EVNC chunks via (id, version); version 0 in a reference means "latest".
pub const Dict = struct {
    id: u16,
    version: u16,
    algorithm: DictAlgorithm,
    dictionary: []const u8,
};

/// Compressed event chunks for archival storage. The compressed data, when
/// decompressed, is a stream of framed EVNT (later EMTA/EDAT) chunks — see
/// compress.expandEvnc; the bytes are kept raw here.
pub const Evnc = struct {
    compression: CompressionType,
    dictionary_id: u16,
    dictionary_version: u16,
    uncompressed_size: u64,
    compressed_data: []const u8,
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

/// Maps a driver's route operation hashes (FNV-1a-32 of the route id, as
/// carried in correlation ids) back to the route id strings. ETYP's sibling.
pub const RouteOpHash = struct {
    driver_id: u16,
    mappings: []const Mapping,

    pub const Mapping = struct {
        hash: u32,
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

/// A terminal chunk written by rolling recorders. It diverges from the
/// regular chunk framing: no size field and no trailing chunk CRC. Instead it
/// carries a per-chunk random salt, self-delimiting records (each with its own
/// CRC over salt || size || body), and a 44-byte end marker. Mutually
/// exclusive with EOF!; only further SEVT chunks may follow it.
pub const StreamedEvent = struct {
    salt: [32]u8,
    records: []const Event.EventData,
    /// False when the chunk was torn: `records` holds only the valid prefix
    /// and all bytes beyond it are untrusted.
    sealed: bool = true,

    /// A record body is one EVNT event on the wire: u16 event id, u16 data
    /// length, u16 properties length, data, properties.
    pub fn parseRecord(body: []const u8) error{Malformed}!Event.EventData {
        if (body.len < 6) return error.Malformed;
        const event_id = std.mem.readInt(u16, body[0..2], .big);
        const data_len = std.mem.readInt(u16, body[2..4], .big);
        const prop_len = std.mem.readInt(u16, body[4..6], .big);
        if (body.len != 6 + @as(usize, data_len) + prop_len) return error.Malformed;
        return .{
            .event_id = event_id,
            .data = body[6 .. 6 + data_len],
            .properties = body[6 + data_len ..],
        };
    }
};

pub const ChunkData = union(ChunkType) {
    header_a: HeaderA,
    drivers: Drivers,
    event_type: EventType,
    route_op_hash: RouteOpHash,
    dict: Dict,
    link: Link,
    event: Event,
    evnc: Evnc,
    streamed_event: StreamedEvent,
    eof: void,
};

pub const ChunkNames = std.EnumArray(ChunkType, []const u8).init(.{
    .header_a = "HDRA",
    .drivers = "DRVS",
    .event_type = "ETYP",
    .route_op_hash = "ROPH",
    .dict = "DICT",
    .link = "LINK",
    .event = "EVNT",
    .evnc = "EVNC",
    .streamed_event = "SEVT",
    .eof = "EOF!",
});

pub const ChunkTypes = std.StaticStringMap(ChunkType).initComptime(&.{
    .{ "HDRA", .header_a },
    .{ "DRVS", .drivers },
    .{ "ETYP", .event_type },
    .{ "ROPH", .route_op_hash },
    .{ "DICT", .dict },
    .{ "LINK", .link },
    .{ "EVNT", .event },
    .{ "EVNC", .evnc },
    .{ "SEVT", .streamed_event },
    .{ "EOF!", .eof },
});
