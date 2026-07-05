const std = @import("std");
const kwev = @import("structure.zig");

// TODO: Add a streaming writer that does not require the whole output to sit
// in one fixed buffer. The current design leans on that assumption twice:
// chunk sizes are patched into the buffer after the payload is written
// (writableArray + mem.writeInt), and CRCs are computed over
// `writer.buffer[start..end]`. A streaming variant needs to either buffer
// per chunk (sizes and CRCs are then known before flushing downstream) or
// compute sizes up front like writeStreamRecord already does. Consumers that
// outgrow the in-memory buffer today: `kwev consolidate` (allocates
// sum-of-inputs) and any future archival/compression pipeline.
pub const Writer = struct {
    writer: *std.Io.Writer,

    pub fn writeMagic(self: *Writer) !void {
        try self.writer.writeAll("KWEV");
    }

    pub fn writeAll(self: *Writer, chunks: []const kwev.ChunkData) !usize {
        try self.writeMagic();
        var streaming = false;
        for (chunks) |chunk| {
            const tag = std.meta.activeTag(chunk);
            std.debug.assert(tag != .eof);
            // SEVT is terminal: once one is written only more SEVT chunks
            // may follow, and the file must not end in an EOF! chunk.
            if (streaming) std.debug.assert(tag == .streamed_event);
            if (tag == .streamed_event) streaming = true;
            try self.writeChunk(chunk);
        }
        if (!streaming) try self.writeChunk(.{ .eof = {} });

        return self.writer.end;
    }

    pub fn writeChunk(self: *Writer, chunk: kwev.ChunkData) !void {
        // SEVT does not use the common name/size/payload/CRC framing.
        if (std.meta.activeTag(chunk) == .streamed_event) {
            return self.writeStreamedEvent(chunk.streamed_event);
        }

        try self.writer.writeAll(kwev.ChunkNames.get(std.meta.activeTag(chunk)));
        const size_target = try self.writer.writableArray(8);
        const start = self.writer.end;

        switch (chunk) {
            .header_a => |a| try self.writeHeaderA(a),
            .drivers => |d| try self.writeDrivers(d),
            .event_type => |e| try self.writeEventTypes(e),
            .route_op_hash => |r| try self.writeRouteOpHashes(r),
            .dict => |d| try self.writeDict(d),
            .link => |l| try self.writeLink(l),
            .event => |e| try self.writeEvent(e),
            .evnc => |e| try self.writeEvnc(e),
            .streamed_event => unreachable,
            .eof => {
                try self.writer.writeInt(u32, 0xAAAAAAAA, .big);
                const end = self.writer.end;
                std.mem.writeInt(u64, size_target, end, .big);
                return;
            },
        }

        const end = self.writer.end;
        std.mem.writeInt(u64, size_target, end - start, .big);
        var crc = std.hash.crc.Crc32Iscsi.init();
        // CRC includes chuck name (4 bytes) and the chunk length (8 bytes) in addition to
        // the actual data cotents (end - start) bytes so we need to offset by 12.
        crc.update(self.writer.buffer[start - 12 .. end]);
        try self.writer.writeInt(u32, crc.final(), .big);
    }

    pub fn writeHeaderA(self: *Writer, a: kwev.HeaderA) !void {
        try self.writer.writeInt(u16, a.version, .big);
        try self.writer.writeInt(u16, a.min_version, .big);
        try self.writer.writeAll(&a.conf_by);
        try self.writer.writeInt(u16, @truncate(a.client_name.len), .big);
        try self.writer.writeAll(a.client_name);
        try self.writer.writeInt(u16, a.client_version, .big);
        try self.writer.writeInt(u16, a.min_client_version, .big);
    }

    pub fn writeDrivers(self: *Writer, d: kwev.Drivers) !void {
        try self.writer.writeInt(u16, @truncate(d.drivers.len), .big);
        for (d.drivers, 0..) |drv, i| {
            try self.writer.writeInt(u16, @intCast(drv.name.len), .big);
            try self.writer.writeInt(u16, @intCast(drv.type.len), .big);
            try self.writer.writeAll(drv.name);
            try self.writer.writeAll(drv.type);
            try self.writer.writeInt(u16, @intCast(i), .big);
        }
    }

    pub fn writeEvent(self: *Writer, d: kwev.Event) !void {
        try self.writer.writeInt(u16, @truncate(d.events.len), .big);
        for (d.events) |evt| {
            try self.writer.writeInt(u16, evt.event_id, .big);
            try self.writer.writeInt(u16, @intCast(evt.data.len), .big);
            try self.writer.writeInt(u16, @intCast(evt.properties.len), .big);
            try self.writer.writeAll(evt.data);
            try self.writer.writeAll(evt.properties);
        }
    }

    pub fn writeEventTypes(self: *Writer, d: kwev.EventType) !void {
        try self.writer.writeInt(u16, @intCast(d.driver_id), .big);
        try self.writer.writeInt(u16, @truncate(d.mappings.len), .big);
        for (d.mappings) |m| {
            try self.writer.writeInt(u16, @intCast(m.value), .big);
            try self.writer.writeInt(u16, @intCast(m.identifier.len), .big);
            try self.writer.writeAll(m.identifier);
        }
    }

    pub fn writeRouteOpHashes(self: *Writer, d: kwev.RouteOpHash) !void {
        try self.writer.writeInt(u16, @intCast(d.driver_id), .big);
        try self.writer.writeInt(u16, @truncate(d.mappings.len), .big);
        for (d.mappings) |m| {
            try self.writer.writeInt(u32, m.hash, .big);
            try self.writer.writeInt(u16, @intCast(m.identifier.len), .big);
            try self.writer.writeAll(m.identifier);
        }
    }

    pub fn writeDict(self: *Writer, d: kwev.Dict) !void {
        try self.writer.writeInt(u16, d.id, .big);
        try self.writer.writeInt(u16, d.version, .big);
        try self.writer.writeInt(u8, @intFromEnum(d.algorithm), .big);
        try self.writer.writeInt(u32, @intCast(d.dictionary.len), .big);
        try self.writer.writeAll(d.dictionary);
    }

    /// The compressed data has no inner length field: it runs to the end of
    /// the chunk (the chunk size delimits it).
    pub fn writeEvnc(self: *Writer, e: kwev.Evnc) !void {
        try self.writer.writeInt(u8, @intFromEnum(e.compression), .big);
        try self.writer.writeInt(u16, e.dictionary_id, .big);
        try self.writer.writeInt(u16, e.dictionary_version, .big);
        try self.writer.writeInt(u64, e.uncompressed_size, .big);
        try self.writer.writeAll(e.compressed_data);
    }

    pub fn writeLink(self: *Writer, d: kwev.Link) !void {
        try self.writer.writeInt(u16, @intFromEnum(std.meta.activeTag(d)), .big);
        switch (d) {
            .rel, .abs, .http => |str| {
                try self.writer.writeInt(u16, @truncate(str.len), .big);
                try self.writer.writeAll(str);
            },
            .jump => |jmp| {
                try self.writer.writeInt(u64, jmp.offset, .big);
                try self.writer.writeAll(&jmp.name);
            },
        }
    }

    pub fn writeStreamedEvent(self: *Writer, s: kwev.StreamedEvent) !void {
        // An all-zero salt is invalid per spec; readers reject it.
        std.debug.assert(!std.mem.allEqual(u8, &s.salt, 0));
        try self.writer.writeAll("SEVT");
        try self.writer.writeAll(&s.salt);
        for (s.records) |record| {
            try self.writeStreamRecord(s.salt, record);
        }
        try self.writeStreamEndMarker(s.salt);
    }

    /// The record body shares the structure of one EVNT event; see
    /// StreamedEvent.parseRecord for the inverse.
    pub fn writeStreamRecord(self: *Writer, salt: [32]u8, record: kwev.Event.EventData) !void {
        // u32 record size followed by the body header: u16 event id,
        // u16 data length, u16 properties length.
        var header: [10]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(6 + record.data.len + record.properties.len), .big);
        std.mem.writeInt(u16, header[4..6], record.event_id, .big);
        std.mem.writeInt(u16, header[6..8], @intCast(record.data.len), .big);
        std.mem.writeInt(u16, header[8..10], @intCast(record.properties.len), .big);
        try self.writer.writeAll(&header);
        try self.writer.writeAll(record.data);
        try self.writer.writeAll(record.properties);
        var crc = std.hash.crc.Crc32Iscsi.init();
        crc.update(&salt);
        crc.update(&header);
        crc.update(record.data);
        crc.update(record.properties);
        try self.writer.writeInt(u32, crc.final(), .big);
    }

    /// 44 bytes: u32 of zeroes, the chunk salt, the chunk name, and a CRC
    /// over those 40 bytes.
    pub fn writeStreamEndMarker(self: *Writer, salt: [32]u8) !void {
        const zeroes = [_]u8{ 0, 0, 0, 0 };
        try self.writer.writeAll(&zeroes);
        try self.writer.writeAll(&salt);
        try self.writer.writeAll("SEVT");
        var crc = std.hash.crc.Crc32Iscsi.init();
        crc.update(&zeroes);
        crc.update(&salt);
        crc.update("SEVT");
        try self.writer.writeInt(u32, crc.final(), .big);
    }
};

// Golden tests: the expected byte sequences below pin the current on-disk
// format. Every chunk is: 4-byte name, u64 payload size (big-endian), the
// payload, then a CRC32-iSCSI over name+size+payload — except EOF!, whose
// size field holds the absolute end-of-file offset and whose CRC slot holds
// the 0xAAAAAAAA sentinel.

fn writeChunkToBuf(buf: []u8, chunk: kwev.ChunkData) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    var writer = Writer{ .writer = &w };
    try writer.writeChunk(chunk);
    return w.buffered();
}

test "writeMagic: golden bytes" {
    var buf: [4]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var writer = Writer{ .writer = &w };
    try writer.writeMagic();
    try std.testing.expectEqualStrings("KWEV", w.buffered());
}

test "writeChunk: HDRA golden bytes" {
    var buf: [64]u8 = undefined;
    const actual = try writeChunkToBuf(&buf, .{ .header_a = .{
        .version = 1,
        .min_version = 1,
        .conf_by = "HDRA".*,
        .client_name = "test-client",
        .client_version = 3,
        .min_client_version = 2,
    } });

    const expected = "HDRA" ++ // chunk name
        "\x00\x00\x00\x00\x00\x00\x00\x19" ++ // payload size = 25
        "\x00\x01" ++ // version = 1
        "\x00\x01" ++ // min version = 1
        "HDRA" ++ // configured by
        "\x00\x0B" ++ // client name length = 11
        "test-client" ++ // client name
        "\x00\x03" ++ // client version = 3
        "\x00\x02" ++ // min client version = 2
        "\x3E\x77\xEB\xDE"; // CRC32-iSCSI(name ++ size ++ payload)
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "writeChunk: DRVS golden bytes" {
    // Per driver: both length fields precede the two strings, and the
    // driver id is the array index. No separate reserved field is emitted.
    var buf: [64]u8 = undefined;
    const actual = try writeChunkToBuf(&buf, .{ .drivers = .{ .drivers = &.{
        .{ .name = "proc", .type = "ProcDriver" },
        .{ .name = "net", .type = "NetDriver" },
    } } });

    const expected = "DRVS" ++ // chunk name
        "\x00\x00\x00\x00\x00\x00\x00\x28" ++ // payload size = 40
        "\x00\x02" ++ // driver count = 2
        "\x00\x04" ++ // driver 0: name length = 4
        "\x00\x0A" ++ // driver 0: type length = 10
        "proc" ++ // driver 0: name
        "ProcDriver" ++ // driver 0: type
        "\x00\x00" ++ // driver 0: driver id = 0 (index)
        "\x00\x03" ++ // driver 1: name length = 3
        "\x00\x09" ++ // driver 1: type length = 9
        "net" ++ // driver 1: name
        "NetDriver" ++ // driver 1: type
        "\x00\x01" ++ // driver 1: driver id = 1 (index)
        "\x25\x34\x25\xDA"; // CRC32-iSCSI(name ++ size ++ payload)
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "writeChunk: ETYP golden bytes" {
    var buf: [64]u8 = undefined;
    const actual = try writeChunkToBuf(&buf, .{ .event_type = .{
        .driver_id = 1,
        .mappings = &.{
            .{ .value = 0, .identifier = "started" },
            .{ .value = 1, .identifier = "stopped" },
        },
    } });

    const expected = "ETYP" ++ // chunk name
        "\x00\x00\x00\x00\x00\x00\x00\x1A" ++ // payload size = 26
        "\x00\x01" ++ // driver id = 1
        "\x00\x02" ++ // mapping count = 2
        "\x00\x00" ++ // mapping 0: value = 0
        "\x00\x07" ++ // mapping 0: identifier length = 7
        "started" ++ // mapping 0: identifier
        "\x00\x01" ++ // mapping 1: value = 1
        "\x00\x07" ++ // mapping 1: identifier length = 7
        "stopped" ++ // mapping 1: identifier
        "\xE1\x5B\x63\xE7"; // CRC32-iSCSI(name ++ size ++ payload)
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "writeChunk: ROPH golden bytes" {
    var buf: [64]u8 = undefined;
    const actual = try writeChunkToBuf(&buf, .{ .route_op_hash = .{
        .driver_id = 1,
        .mappings = &.{
            .{ .hash = 0x07CA1195, .identifier = "heartbeat" },
            .{ .hash = 0xA79E4417, .identifier = "publish tick" },
        },
    } });

    const expected = "ROPH" ++ // chunk name
        "\x00\x00\x00\x00\x00\x00\x00\x25" ++ // payload size = 37
        "\x00\x01" ++ // driver id = 1
        "\x00\x02" ++ // mapping count = 2
        "\x07\xCA\x11\x95" ++ // mapping 0: hash
        "\x00\x09" ++ // mapping 0: identifier length = 9
        "heartbeat" ++ // mapping 0: identifier
        "\xA7\x9E\x44\x17" ++ // mapping 1: hash
        "\x00\x0C" ++ // mapping 1: identifier length = 12
        "publish tick" ++ // mapping 1: identifier
        "\x35\x3A\xE3\x65"; // CRC32-iSCSI(name ++ size ++ payload)
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "writeChunk: DICT golden bytes" {
    var buf: [64]u8 = undefined;
    const actual = try writeChunkToBuf(&buf, .{ .dict = .{
        .id = 3,
        .version = 2,
        .algorithm = .zstd,
        .dictionary = "dictionary",
    } });

    const expected = "DICT" ++ // chunk name
        "\x00\x00\x00\x00\x00\x00\x00\x13" ++ // payload size = 19
        "\x00\x03" ++ // dictionary id = 3
        "\x00\x02" ++ // dictionary version = 2
        "\x00" ++ // algorithm = zstd (0)
        "\x00\x00\x00\x0A" ++ // dictionary size = 10
        "dictionary" ++ // dictionary bytes
        "\x55\x99\xA7\x81"; // CRC32-iSCSI(name ++ size ++ payload)
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "writeChunk: EVNC golden bytes" {
    // Compression 'none' so the payload bytes are deterministic; zstd output
    // varies by library version and never belongs in a golden test.
    var buf: [64]u8 = undefined;
    const actual = try writeChunkToBuf(&buf, .{ .evnc = .{
        .compression = .none,
        .dictionary_id = 3,
        .dictionary_version = 2,
        .uncompressed_size = 7,
        .compressed_data = "payload",
    } });

    const expected = "EVNC" ++ // chunk name
        "\x00\x00\x00\x00\x00\x00\x00\x14" ++ // payload size = 20
        "\x00" ++ // compression = none (0)
        "\x00\x03" ++ // dictionary id = 3
        "\x00\x02" ++ // dictionary version = 2
        "\x00\x00\x00\x00\x00\x00\x00\x07" ++ // uncompressed size = 7
        "payload" ++ // compressed data (runs to end of chunk)
        "\xE7\xAB\xBC\xA1"; // CRC32-iSCSI(name ++ size ++ payload)
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "writeChunk: EVNT golden bytes" {
    var buf: [64]u8 = undefined;
    const actual = try writeChunkToBuf(&buf, .{ .event = .{ .events = &.{
        .{ .event_id = 0, .data = "hello", .properties = ".{}" },
        .{ .event_id = 1, .data = "world!", .properties = ".{.a=1}" },
    } } });

    const expected = "EVNT" ++ // chunk name
        "\x00\x00\x00\x00\x00\x00\x00\x23" ++ // payload size = 35
        "\x00\x02" ++ // event count = 2
        "\x00\x00" ++ // event 0: event id = 0
        "\x00\x05" ++ // event 0: data length = 5
        "\x00\x03" ++ // event 0: properties length = 3
        "hello" ++ // event 0: data
        ".{}" ++ // event 0: properties
        "\x00\x01" ++ // event 1: event id = 1
        "\x00\x06" ++ // event 1: data length = 6
        "\x00\x07" ++ // event 1: properties length = 7
        "world!" ++ // event 1: data
        ".{.a=1}" ++ // event 1: properties
        "\x67\x4D\x65\x21"; // CRC32-iSCSI(name ++ size ++ payload)
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "writeChunk: LINK golden bytes (rel)" {
    var buf: [64]u8 = undefined;
    const actual = try writeChunkToBuf(&buf, .{ .link = .{ .rel = "defs.kwev" } });

    const expected = "LINK" ++ // chunk name
        "\x00\x00\x00\x00\x00\x00\x00\x0D" ++ // payload size = 13
        "\x00\x00" ++ // link type = rel (0)
        "\x00\x09" ++ // path length = 9
        "defs.kwev" ++ // path
        "\x27\xD5\x18\x7D"; // CRC32-iSCSI(name ++ size ++ payload)
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "writeChunk: LINK golden bytes (abs)" {
    var buf: [64]u8 = undefined;
    const actual = try writeChunkToBuf(&buf, .{ .link = .{ .abs = "/var/defs.kwev" } });

    const expected = "LINK" ++ // chunk name
        "\x00\x00\x00\x00\x00\x00\x00\x12" ++ // payload size = 18
        "\x00\x01" ++ // link type = abs (1)
        "\x00\x0E" ++ // path length = 14
        "/var/defs.kwev" ++ // path
        "\xC2\xAA\x11\x8C"; // CRC32-iSCSI(name ++ size ++ payload)
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "writeChunk: LINK golden bytes (http)" {
    var buf: [64]u8 = undefined;
    const actual = try writeChunkToBuf(&buf, .{ .link = .{ .http = "https://example.com/defs.kwev" } });

    const expected = "LINK" ++ // chunk name
        "\x00\x00\x00\x00\x00\x00\x00\x21" ++ // payload size = 33
        "\x00\x02" ++ // link type = http (2)
        "\x00\x1D" ++ // path length = 29
        "https://example.com/defs.kwev" ++ // path
        "\xD0\x42\xC5\xBE"; // CRC32-iSCSI(name ++ size ++ payload)
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "writeChunk: LINK golden bytes (jump)" {
    var buf: [64]u8 = undefined;
    const actual = try writeChunkToBuf(&buf, .{ .link = .{ .jump = .{
        .offset = 0x0102030405060708,
        .name = "DRVS".*,
    } } });

    const expected = "LINK" ++ // chunk name
        "\x00\x00\x00\x00\x00\x00\x00\x0E" ++ // payload size = 14
        "\x00\x03" ++ // link type = jump (3)
        "\x01\x02\x03\x04\x05\x06\x07\x08" ++ // target offset
        "DRVS" ++ // target chunk name
        "\xE3\xB5\x96\xAD"; // CRC32-iSCSI(name ++ size ++ payload)
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "writeChunk: SEVT golden bytes" {
    var buf: [256]u8 = undefined;
    var salt: [32]u8 = undefined;
    for (&salt, 1..) |*b, i| b.* = @intCast(i);
    const actual = try writeChunkToBuf(&buf, .{ .streamed_event = .{
        .salt = salt,
        .records = &.{
            .{ .event_id = 0, .data = "hello", .properties = ".{}" },
            .{ .event_id = 1, .data = "world!", .properties = ".{.a=1}" },
        },
    } });

    const salt_bytes = "\x01\x02\x03\x04\x05\x06\x07\x08" ++
        "\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10" ++
        "\x11\x12\x13\x14\x15\x16\x17\x18" ++
        "\x19\x1A\x1B\x1C\x1D\x1E\x1F\x20";
    const expected = "SEVT" ++ // chunk name (no size field, no chunk CRC)
        salt_bytes ++ // 32-byte per-chunk salt
        "\x00\x00\x00\x0E" ++ // record 0: size = 14
        "\x00\x00" ++ // record 0: event id = 0
        "\x00\x05" ++ // record 0: data length = 5
        "\x00\x03" ++ // record 0: properties length = 3
        "hello" ++ // record 0: data
        ".{}" ++ // record 0: properties
        "\x52\x39\xDC\x58" ++ // record 0: CRC32-iSCSI(salt ++ size ++ body)
        "\x00\x00\x00\x13" ++ // record 1: size = 19
        "\x00\x01" ++ // record 1: event id = 1
        "\x00\x06" ++ // record 1: data length = 6
        "\x00\x07" ++ // record 1: properties length = 7
        "world!" ++ // record 1: data
        ".{.a=1}" ++ // record 1: properties
        "\xE1\x6E\x3E\xBB" ++ // record 1: CRC32-iSCSI(salt ++ size ++ body)
        "\x00\x00\x00\x00" ++ // end marker: u32 of zeroes
        salt_bytes ++ // end marker: salt (must match header)
        "SEVT" ++ // end marker: chunk name
        "\xF1\x13\x4C\xEE"; // end marker: CRC32-iSCSI(zeroes ++ salt ++ name)
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "writeChunk: EOF golden bytes" {
    var buf: [16]u8 = undefined;
    const actual = try writeChunkToBuf(&buf, .{ .eof = {} });

    const expected = "EOF!" ++ // chunk name
        "\x00\x00\x00\x00\x00\x00\x00\x10" ++ // absolute end-of-file offset = 16
        "\xAA\xAA\xAA\xAA"; // sentinel in place of a CRC
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "writeAll: golden bytes for a whole file" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var writer = Writer{ .writer = &w };
    const size = try writer.writeAll(&.{
        .{ .header_a = .{
            .version = 1,
            .min_version = 1,
            .conf_by = "HDRA".*,
            .client_name = "test-client",
            .client_version = 3,
            .min_client_version = 2,
        } },
        .{ .drivers = .{ .drivers = &.{
            .{ .name = "proc", .type = "ProcDriver" },
        } } },
        .{ .event = .{ .events = &.{
            .{ .event_id = 0, .data = "hello", .properties = ".{}" },
        } } },
    });

    const expected = "KWEV" ++ // magic
        // HDRA
        "HDRA" ++ "\x00\x00\x00\x00\x00\x00\x00\x19" ++
        "\x00\x01" ++ "\x00\x01" ++ "HDRA" ++
        "\x00\x0B" ++ "test-client" ++ "\x00\x03" ++ "\x00\x02" ++
        "\x3E\x77\xEB\xDE" ++
        // DRVS
        "DRVS" ++ "\x00\x00\x00\x00\x00\x00\x00\x16" ++
        "\x00\x01" ++ "\x00\x04" ++ "\x00\x0A" ++ "proc" ++ "ProcDriver" ++ "\x00\x00" ++
        "\xAB\xBA\xAD\x6B" ++
        // EVNT
        "EVNT" ++ "\x00\x00\x00\x00\x00\x00\x00\x10" ++
        "\x00\x01" ++ "\x00\x00" ++ "\x00\x05" ++ "\x00\x03" ++ "hello" ++ ".{}" ++
        "\x95\x85\x77\x24" ++
        // EOF (size field = absolute end-of-file offset = 131)
        "EOF!" ++ "\x00\x00\x00\x00\x00\x00\x00\x83" ++ "\xAA\xAA\xAA\xAA";
    try std.testing.expectEqual(expected.len, size);
    try std.testing.expectEqualSlices(u8, expected, w.buffered());
}
