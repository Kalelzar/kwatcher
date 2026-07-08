const std = @import("std");
const Crc32c = @import("crc.zig").Crc32c;
const kwev = @import("structure.zig");

pub const Reader = struct {
    reader: *std.Io.Reader,

    const Error = std.Io.Reader.Error || error{ NotKWEV, UnknownChunk, CRCMismatch, FileCorrupt };

    pub fn readMagic(self: *Reader) Error!void {
        var buf: [4]u8 = undefined;
        try self.reader.readSliceAll(&buf);
        if (!std.mem.eql(u8, &buf, "KWEV")) {
            std.log.warn("Expected: KWEV, found: {s}", .{buf});
            return error.NotKWEV;
        }
    }

    pub fn readAll(self: *Reader, allocator: std.mem.Allocator) (Error || error{OutOfMemory})![]const kwev.ChunkData {
        try self.readMagic();
        var list = std.ArrayList(kwev.ChunkData){};
        errdefer list.deinit(allocator);
        var streaming = false;
        while (true) {
            const next = try list.addOne(allocator);
            try self.readChunk(next, allocator);
            switch (std.meta.activeTag(next.*)) {
                // SEVT is terminal and mutually exclusive with EOF!: after
                // the first one, only further SEVT chunks are valid.
                .eof => {
                    if (streaming) return error.FileCorrupt;
                    break;
                },
                .streamed_event => {
                    streaming = true;
                    // A torn chunk taints everything beyond it.
                    if (!next.streamed_event.sealed) break;
                    if (self.reader.bufferedLen() < 4) break;
                    // Only another SEVT chunk may follow. A different known
                    // chunk is corruption; anything else is a non-chunk tail
                    // (e.g. the zero-filled remainder of a mapping that was
                    // never truncated because the writer crashed) and ends
                    // the walk.
                    const peeked = try self.reader.peek(4);
                    if (kwev.ChunkTypes.get(peeked[0..4])) |t| {
                        if (t != .streamed_event) return error.FileCorrupt;
                    } else break;
                },
                else => if (streaming) return error.FileCorrupt,
            }
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn readChunk(self: *Reader, chunk: *kwev.ChunkData, allocator: std.mem.Allocator) (Error || error{OutOfMemory})!void {
        const name = try self.reader.takeArray(4);
        const ctype = kwev.ChunkTypes.get(name);
        if (ctype == null) {
            std.log.warn("Unrecognised chunk type: {s}", .{name});
            return error.UnknownChunk;
        }
        // SEVT does not use the common size/payload/CRC framing.
        if (ctype.? == .streamed_event) return self.readStreamedEvent(chunk, allocator);
        const size = try self.reader.takeInt(u64, .big);
        switch (ctype.?) {
            .eof => {
                const crc = try self.reader.takeInt(u32, .big);

                if (crc != 0xAAAAAAAA) {
                    std.log.warn("EOF! chunk has bad CRC: {d}", .{crc});
                    return error.CRCMismatch;
                }
                if (size != self.reader.seek) return error.FileCorrupt;

                chunk.* = .{ .eof = {} };
                return;
            },
            .header_a => try self.readHeaderA(chunk),
            .drivers => try self.readDrivers(chunk, allocator),
            .event => try self.readEvents(chunk, allocator),
            .event_type => try self.readEventTypes(chunk, allocator),
            .route_op_hash => try self.readRouteOpHashes(chunk, allocator),
            .dict => try self.readDict(chunk),
            .link => try self.readLink(chunk),
            .evnc => try self.readEvnc(chunk, size),
            .streamed_event => unreachable,
        }

        const end = self.reader.seek;
        if (end < size + 12) {
            std.log.warn("Expected to read at least {d}, actually {d}", .{ size + 12, end });
            return error.FileCorrupt;
        }
        const start = end - size - 12;
        var crc = Crc32c.init();
        // CRC includes chuck name (4 bytes) and the chunk length (8 bytes) in addition to
        // the actual data cotents (end - start) bytes so we need to offset by 12.
        crc.update(self.reader.buffer[start..end]);
        const actual = crc.final();
        const expected = try self.reader.takeInt(u32, .big);
        if (expected != actual) {
            std.log.warn("BAD CRC: {d:04}, expected {d:04}", .{ actual, expected });
            return error.CRCMismatch;
        }
    }

    pub fn readHeaderA(self: *Reader, chunk: *kwev.ChunkData) Error!void {
        var h = std.mem.zeroInit(kwev.HeaderA, .{});
        h.version = try self.reader.takeInt(u16, .big);
        h.min_version = try self.reader.takeInt(u16, .big);
        try self.reader.readSliceAll(&h.conf_by);
        const name_len = try self.reader.takeInt(u16, .big);
        h.client_name = try self.reader.take(name_len);
        h.client_version = try self.reader.takeInt(u16, .big);
        h.min_client_version = try self.reader.takeInt(u16, .big);

        chunk.* = .{ .header_a = h };
    }

    pub fn readDrivers(self: *Reader, chunk: *kwev.ChunkData, allocator: std.mem.Allocator) (Error || error{OutOfMemory})!void {
        var h = std.mem.zeroInit(kwev.Drivers, .{});
        var d = std.ArrayList(kwev.Drivers.Driver){};
        errdefer d.deinit(allocator);
        const size = try self.reader.takeInt(u16, .big);
        try d.ensureUnusedCapacity(allocator, size);
        for (0..size) |_| {
            var next = d.addOneAssumeCapacity();
            const name_len = try self.reader.takeInt(u16, .big);
            const type_len = try self.reader.takeInt(u16, .big);
            next.name = try self.reader.take(name_len);
            next.type = try self.reader.take(type_len);
            self.reader.toss(2); //FIXME: Maybe we want to actually read this id, eh?
        }

        h.drivers = try d.toOwnedSlice(allocator);

        chunk.* = .{ .drivers = h };
    }

    pub fn readEvents(
        self: *Reader,
        chunk: *kwev.ChunkData,
        allocator: std.mem.Allocator,
    ) (Error || error{OutOfMemory})!void {
        var h = std.mem.zeroInit(kwev.Event, .{});
        var d = std.ArrayList(kwev.Event.EventData){};
        errdefer d.deinit(allocator);
        const size = try self.reader.takeInt(u16, .big);
        try d.ensureUnusedCapacity(allocator, size);
        for (0..size) |_| {
            var next = d.addOneAssumeCapacity();
            next.event_id = try self.reader.takeInt(u16, .big);
            const data_len = try self.reader.takeInt(u16, .big);
            const prop_len = try self.reader.takeInt(u16, .big);
            next.data = try self.reader.take(data_len);
            next.properties = try self.reader.take(prop_len);
        }

        h.events = try d.toOwnedSlice(allocator);

        chunk.* = .{ .event = h };
    }

    pub fn readEventTypes(
        self: *Reader,
        chunk: *kwev.ChunkData,
        allocator: std.mem.Allocator,
    ) (Error || error{OutOfMemory})!void {
        var h = std.mem.zeroInit(kwev.EventType, .{});
        var d = std.ArrayList(kwev.EventType.Mapping){};
        errdefer d.deinit(allocator);
        h.driver_id = try self.reader.takeInt(u16, .big);
        const size = try self.reader.takeInt(u16, .big);
        try d.ensureUnusedCapacity(allocator, size);
        for (0..size) |_| {
            var next = d.addOneAssumeCapacity();
            next.value = try self.reader.takeInt(u16, .big);
            const identifier_len = try self.reader.takeInt(u16, .big);
            next.identifier = try self.reader.take(identifier_len);
        }

        h.mappings = try d.toOwnedSlice(allocator);

        chunk.* = .{ .event_type = h };
    }

    pub fn readRouteOpHashes(
        self: *Reader,
        chunk: *kwev.ChunkData,
        allocator: std.mem.Allocator,
    ) (Error || error{OutOfMemory})!void {
        var h = std.mem.zeroInit(kwev.RouteOpHash, .{});
        var d = std.ArrayList(kwev.RouteOpHash.Mapping){};
        errdefer d.deinit(allocator);
        h.driver_id = try self.reader.takeInt(u16, .big);
        const size = try self.reader.takeInt(u16, .big);
        try d.ensureUnusedCapacity(allocator, size);
        for (0..size) |_| {
            var next = d.addOneAssumeCapacity();
            next.hash = try self.reader.takeInt(u32, .big);
            const identifier_len = try self.reader.takeInt(u16, .big);
            next.identifier = try self.reader.take(identifier_len);
        }

        h.mappings = try d.toOwnedSlice(allocator);

        chunk.* = .{ .route_op_hash = h };
    }

    pub fn readDict(self: *Reader, chunk: *kwev.ChunkData) Error!void {
        const id = try self.reader.takeInt(u16, .big);
        const version = try self.reader.takeInt(u16, .big);
        const algorithm = try self.reader.takeInt(u8, .big);
        const size = try self.reader.takeInt(u32, .big);
        chunk.* = .{ .dict = .{
            .id = id,
            .version = version,
            .algorithm = std.meta.intToEnum(kwev.DictAlgorithm, algorithm) catch
                return error.FileCorrupt,
            .dictionary = try self.reader.take(size),
        } };
    }

    /// The compressed data runs to the end of the chunk, so this is the one
    /// payload reader that needs the chunk size.
    pub fn readEvnc(self: *Reader, chunk: *kwev.ChunkData, size: u64) Error!void {
        const envelope = 1 + 2 + 2 + 8;
        if (size < envelope) return error.FileCorrupt;
        const compression = try self.reader.takeInt(u8, .big);
        const dictionary_id = try self.reader.takeInt(u16, .big);
        const dictionary_version = try self.reader.takeInt(u16, .big);
        const uncompressed_size = try self.reader.takeInt(u64, .big);
        chunk.* = .{ .evnc = .{
            .compression = std.meta.intToEnum(kwev.CompressionType, compression) catch
                return error.FileCorrupt,
            .dictionary_id = dictionary_id,
            .dictionary_version = dictionary_version,
            .uncompressed_size = uncompressed_size,
            .compressed_data = try self.reader.take(@intCast(size - envelope)),
        } };
    }

    /// Walks a SEVT chunk record by record per the recovery procedure: a
    /// record with a valid CRC (over salt || size || body) is accepted, a
    /// zero size must be followed by a valid end marker for the chunk to
    /// count as sealed, and anything else tears the chunk — the records
    /// gathered so far are kept and `sealed` is left false.
    pub fn readStreamedEvent(
        self: *Reader,
        chunk: *kwev.ChunkData,
        allocator: std.mem.Allocator,
    ) (Error || error{OutOfMemory})!void {
        const salt = (try self.reader.takeArray(32)).*;
        if (std.mem.allEqual(u8, &salt, 0)) {
            std.log.warn("SEVT chunk has an all-zero salt", .{});
            return error.FileCorrupt;
        }

        var records = std.ArrayList(kwev.Event.EventData){};
        errdefer records.deinit(allocator);
        var sealed = false;

        walk: while (true) {
            if (self.reader.bufferedLen() < 4) break :walk; // torn
            const size = try self.reader.takeInt(u32, .big);
            if (size == 0) {
                // Validate the rest of the end marker: salt, name, CRC.
                if (self.reader.bufferedLen() < 40) break :walk; // torn
                const msalt = try self.reader.takeArray(32);
                const mname = try self.reader.takeArray(4);
                const mcrc = try self.reader.takeInt(u32, .big);
                var crc = Crc32c.init();
                crc.update(&[_]u8{ 0, 0, 0, 0 });
                crc.update(msalt);
                crc.update(mname);
                sealed = std.mem.eql(u8, msalt, &salt) and
                    std.mem.eql(u8, mname, "SEVT") and
                    crc.final() == mcrc;
                break :walk;
            }
            // Record: size bytes of body followed by its CRC.
            if (self.reader.bufferedLen() < @as(u64, size) + 4) break :walk; // torn
            const body = try self.reader.take(size);
            const rcrc = try self.reader.takeInt(u32, .big);
            var crc = Crc32c.init();
            crc.update(&salt);
            var size_be: [4]u8 = undefined;
            std.mem.writeInt(u32, &size_be, size, .big);
            crc.update(&size_be);
            crc.update(body);
            if (crc.final() != rcrc) break :walk; // torn
            const record = kwev.StreamedEvent.parseRecord(body) catch break :walk; // torn
            try records.append(allocator, record);
        }

        if (!sealed) {
            std.log.warn(
                "SEVT chunk is torn; keeping {d} valid records",
                .{records.items.len},
            );
        }

        chunk.* = .{ .streamed_event = .{
            .salt = salt,
            .records = try records.toOwnedSlice(allocator),
            .sealed = sealed,
        } };
    }

    pub fn readLink(self: *Reader, chunk: *kwev.ChunkData) (Error || error{OutOfMemory})!void {
        const ltype = try self.reader.takeInt(u16, .big);
        const l: kwev.LinkType = @enumFromInt(ltype);
        switch (l) {
            inline .http, .rel, .abs => |e| {
                const len = try self.reader.takeInt(u16, .big);
                chunk.* = .{ .link = @unionInit(
                    kwev.Link,
                    @tagName(e),
                    try self.reader.take(len),
                ) };
            },
            .jump => {
                const offs = try self.reader.takeInt(u64, .big);
                const buf = try self.reader.takeArray(4);
                chunk.* = .{
                    .link = .{
                        .jump = .{
                            .name = @splat(0),
                            .offset = offs,
                        },
                    },
                };
                @memcpy(&chunk.*.link.jump.name, buf);
            },
        }
    }
};

// Roundtrip tests: whatever the Writer produces, the Reader must parse back
// into the exact same chunks.

const Writer = @import("writer.zig").Writer;

fn expectChunkEql(expected: kwev.ChunkData, actual: kwev.ChunkData) !void {
    const t = std.testing;
    try t.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .header_a => |e| {
            const a = actual.header_a;
            try t.expectEqual(e.version, a.version);
            try t.expectEqual(e.min_version, a.min_version);
            try t.expectEqualSlices(u8, &e.conf_by, &a.conf_by);
            try t.expectEqualStrings(e.client_name, a.client_name);
            try t.expectEqual(e.client_version, a.client_version);
            try t.expectEqual(e.min_client_version, a.min_client_version);
        },
        .drivers => |e| {
            const a = actual.drivers;
            try t.expectEqual(e.drivers.len, a.drivers.len);
            for (e.drivers, a.drivers) |ed, ad| {
                try t.expectEqualStrings(ed.name, ad.name);
                try t.expectEqualStrings(ed.type, ad.type);
            }
        },
        .event_type => |e| {
            const a = actual.event_type;
            try t.expectEqual(e.driver_id, a.driver_id);
            try t.expectEqual(e.mappings.len, a.mappings.len);
            for (e.mappings, a.mappings) |em, am| {
                try t.expectEqual(em.value, am.value);
                try t.expectEqualStrings(em.identifier, am.identifier);
            }
        },
        .route_op_hash => |e| {
            const a = actual.route_op_hash;
            try t.expectEqual(e.driver_id, a.driver_id);
            try t.expectEqual(e.mappings.len, a.mappings.len);
            for (e.mappings, a.mappings) |em, am| {
                try t.expectEqual(em.hash, am.hash);
                try t.expectEqualStrings(em.identifier, am.identifier);
            }
        },
        .event => |e| {
            const a = actual.event;
            try t.expectEqual(e.events.len, a.events.len);
            for (e.events, a.events) |ee, ae| {
                try t.expectEqual(ee.event_id, ae.event_id);
                try t.expectEqualStrings(ee.data, ae.data);
                try t.expectEqualStrings(ee.properties, ae.properties);
            }
        },
        .link => |e| {
            const a = actual.link;
            try t.expectEqual(std.meta.activeTag(e), std.meta.activeTag(a));
            switch (e) {
                .rel => |path| try t.expectEqualStrings(path, a.rel),
                .abs => |path| try t.expectEqualStrings(path, a.abs),
                .http => |path| try t.expectEqualStrings(path, a.http),
                .jump => |j| {
                    try t.expectEqual(j.offset, a.jump.offset);
                    try t.expectEqualSlices(u8, &j.name, &a.jump.name);
                },
            }
        },
        .dict => |e| {
            const a = actual.dict;
            try t.expectEqual(e.id, a.id);
            try t.expectEqual(e.version, a.version);
            try t.expectEqual(e.algorithm, a.algorithm);
            try t.expectEqualSlices(u8, e.dictionary, a.dictionary);
        },
        .evnc => |e| {
            const a = actual.evnc;
            try t.expectEqual(e.compression, a.compression);
            try t.expectEqual(e.dictionary_id, a.dictionary_id);
            try t.expectEqual(e.dictionary_version, a.dictionary_version);
            try t.expectEqual(e.uncompressed_size, a.uncompressed_size);
            try t.expectEqualSlices(u8, e.compressed_data, a.compressed_data);
        },
        .streamed_event => |e| {
            const a = actual.streamed_event;
            try t.expectEqualSlices(u8, &e.salt, &a.salt);
            try t.expectEqual(e.sealed, a.sealed);
            try t.expectEqual(e.records.len, a.records.len);
            for (e.records, a.records) |er, ar| {
                try t.expectEqual(er.event_id, ar.event_id);
                try t.expectEqualStrings(er.data, ar.data);
                try t.expectEqualStrings(er.properties, ar.properties);
            }
        },
        .eof => {},
    }
}

fn expectRoundtrip(chunks: []const kwev.ChunkData) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var writer = Writer{ .writer = &w };
    const size = try writer.writeAll(chunks);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = std.Io.Reader.fixed(buf[0..size]);
    var reader = Reader{ .reader = &r };
    const read = try reader.readAll(arena.allocator());

    // A file ending in SEVT chunks has no EOF! chunk; anything else gets a
    // trailing EOF appended by the writer and returned by readAll.
    const streaming = chunks.len != 0 and
        std.meta.activeTag(chunks[chunks.len - 1]) == .streamed_event;
    try std.testing.expectEqual(chunks.len + @intFromBool(!streaming), read.len);
    for (chunks, read[0..chunks.len]) |expected, actual| {
        try expectChunkEql(expected, actual);
    }
    if (!streaming) {
        try std.testing.expectEqual(kwev.ChunkType.eof, std.meta.activeTag(read[read.len - 1]));
    }
}

test "roundtrip: empty file (magic + EOF only)" {
    try expectRoundtrip(&.{});
}

test "roundtrip: HDRA" {
    try expectRoundtrip(&.{
        .{ .header_a = .{
            .version = 1,
            .min_version = 1,
            .conf_by = "HDRA".*,
            .client_name = "test-client",
            .client_version = 3,
            .min_client_version = 2,
        } },
    });
}

test "roundtrip: DRVS" {
    try expectRoundtrip(&.{
        .{ .drivers = .{ .drivers = &.{
            .{ .name = "proc", .type = "ProcDriver" },
            .{ .name = "net", .type = "NetDriver" },
        } } },
    });
}

test "roundtrip: ETYP" {
    try expectRoundtrip(&.{
        .{ .event_type = .{
            .driver_id = 1,
            .mappings = &.{
                .{ .value = 0, .identifier = "started" },
                .{ .value = 1, .identifier = "stopped" },
            },
        } },
    });
}

test "roundtrip: ROPH" {
    try expectRoundtrip(&.{
        .{ .route_op_hash = .{
            .driver_id = 1,
            .mappings = &.{
                .{ .hash = 0x07CA1195, .identifier = "heartbeat_tick" },
                .{ .hash = 0xA79E4417, .identifier = "publish heartbeat" },
            },
        } },
    });
}

test "roundtrip: DICT" {
    try expectRoundtrip(&.{
        .{ .dict = .{
            .id = 3,
            .version = 2,
            .algorithm = .zstd,
            .dictionary = "raw dictionary bytes",
        } },
    });
}

test "roundtrip: EVNC (raw bytes carried opaquely)" {
    try expectRoundtrip(&.{
        .{ .evnc = .{
            .compression = .zstd,
            .dictionary_id = 3,
            .dictionary_version = 2,
            .uncompressed_size = 1234,
            .compressed_data = "opaque compressed payload",
        } },
    });
}

test "roundtrip: EVNT" {
    try expectRoundtrip(&.{
        .{ .event = .{ .events = &.{
            .{ .event_id = 0, .data = "hello", .properties = ".{}" },
            .{ .event_id = 1, .data = "world!", .properties = ".{.a=1}" },
        } } },
    });
}

test "roundtrip: LINK (all variants)" {
    try expectRoundtrip(&.{
        .{ .link = .{ .rel = "defs.kwev" } },
        .{ .link = .{ .abs = "/var/defs.kwev" } },
        .{ .link = .{ .http = "https://example.com/defs.kwev" } },
        .{ .link = .{ .jump = .{ .offset = 0x0102030405060708, .name = "DRVS".* } } },
    });
}

test "roundtrip: full file with every chunk type" {
    try expectRoundtrip(&.{
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
        .{ .event_type = .{
            .driver_id = 0,
            .mappings = &.{
                .{ .value = 0, .identifier = "started" },
            },
        } },
        .{ .link = .{ .rel = "defs.kwev" } },
        .{ .event = .{ .events = &.{
            .{ .event_id = 0, .data = "hello", .properties = ".{}" },
        } } },
    });
}

fn testSalt(seed: u8) [32]u8 {
    std.debug.assert(seed != 0);
    var salt: [32]u8 = undefined;
    for (&salt, 0..) |*b, i| b.* = seed +% @as(u8, @intCast(i));
    return salt;
}

// Two records totalling 22 and 27 bytes on the wire (u32 size + 6-byte
// event header + data + properties + u32 CRC); the recovery tests below
// rely on these sizes.
const test_records = [_]kwev.Event.EventData{
    .{ .event_id = 0, .data = "hello", .properties = ".{}" },
    .{ .event_id = 1, .data = "world!", .properties = ".{.a=1}" },
};

test "roundtrip: SEVT" {
    try expectRoundtrip(&.{
        .{ .streamed_event = .{
            .salt = testSalt(1),
            .records = &test_records,
        } },
    });
}

test "roundtrip: regular chunks then SEVT" {
    try expectRoundtrip(&.{
        .{ .header_a = .{
            .version = 1,
            .min_version = 1,
            .conf_by = "HDRA".*,
            .client_name = "test-client",
            .client_version = 3,
            .min_client_version = 2,
        } },
        .{ .link = .{ .rel = "defs.kwev" } },
        .{ .streamed_event = .{
            .salt = testSalt(1),
            .records = &.{test_records[0]},
        } },
    });
}

test "roundtrip: consecutive SEVT chunks" {
    try expectRoundtrip(&.{
        .{ .streamed_event = .{
            .salt = testSalt(1),
            .records = &test_records,
        } },
        .{ .streamed_event = .{
            .salt = testSalt(7),
            .records = &.{.{ .event_id = 2, .data = "three", .properties = ".{}" }},
        } },
    });
}

fn readBack(bytes: []const u8, allocator: std.mem.Allocator) ![]const kwev.ChunkData {
    var r = std.Io.Reader.fixed(bytes);
    var reader = Reader{ .reader = &r };
    return reader.readAll(allocator);
}

test "SEVT recovery: torn end marker keeps all records" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var writer = Writer{ .writer = &w };
    const size = try writer.writeAll(&.{
        .{ .streamed_event = .{
            .salt = testSalt(1),
            .records = &test_records,
        } },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Cut into the 44-byte end marker: both records stay valid.
    const read = try readBack(buf[0 .. size - 10], arena.allocator());
    try std.testing.expectEqual(1, read.len);
    const sevt = read[0].streamed_event;
    try std.testing.expect(!sevt.sealed);
    try std.testing.expectEqual(2, sevt.records.len);
    try std.testing.expectEqualStrings("hello", sevt.records[0].data);
    try std.testing.expectEqualStrings("world!", sevt.records[1].data);
}

test "SEVT recovery: truncation mid-record keeps the valid prefix" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var writer = Writer{ .writer = &w };
    _ = try writer.writeAll(&.{
        .{ .streamed_event = .{
            .salt = testSalt(1),
            .records = &test_records,
        } },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // magic (4) + name (4) + salt (32) + record 0 (22), then cut 5 bytes
    // into record 1.
    const read = try readBack(buf[0 .. 4 + 4 + 32 + 22 + 5], arena.allocator());
    try std.testing.expectEqual(1, read.len);
    const sevt = read[0].streamed_event;
    try std.testing.expect(!sevt.sealed);
    try std.testing.expectEqual(1, sevt.records.len);
    try std.testing.expectEqualStrings("hello", sevt.records[0].data);
}

test "SEVT recovery: corrupt record tears the chunk at that record" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var writer = Writer{ .writer = &w };
    const size = try writer.writeAll(&.{
        .{ .streamed_event = .{
            .salt = testSalt(1),
            .records = &test_records,
        } },
    });

    // Flip a byte in record 1's body: magic (4) + name (4) + salt (32) +
    // record 0 (22) + record 1 size (4) puts its body at offset 66.
    buf[66] ^= 0xFF;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const read = try readBack(buf[0..size], arena.allocator());
    try std.testing.expectEqual(1, read.len);
    const sevt = read[0].streamed_event;
    try std.testing.expect(!sevt.sealed);
    try std.testing.expectEqual(1, sevt.records.len);
    try std.testing.expectEqualStrings("hello", sevt.records[0].data);
}

test "SEVT recovery: record body that is not an event tears the chunk" {
    // A record whose CRC verifies but whose body is not one EVNT event
    // (here: lengths that disagree with the record size) is invalid.
    const salt = testSalt(1);
    const body = "\x00\x00" ++ "\x00\xFF" ++ "\x00\x03" ++ "hi" ++ ".{}";
    var crc = Crc32c.init();
    crc.update(&salt);
    crc.update("\x00\x00\x00\x0B"); // record size = 11
    crc.update(body);

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var writer = Writer{ .writer = &w };
    try writer.writeMagic();
    try w.writeAll("SEVT");
    try w.writeAll(&salt);
    try w.writeAll("\x00\x00\x00\x0B");
    try w.writeAll(body);
    try w.writeInt(u32, crc.final(), .big);
    try writer.writeStreamEndMarker(salt);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const read = try readBack(w.buffered(), arena.allocator());
    try std.testing.expectEqual(1, read.len);
    const sevt = read[0].streamed_event;
    try std.testing.expect(!sevt.sealed);
    try std.testing.expectEqual(0, sevt.records.len);
}

test "SEVT recovery: corrupt end marker tears the chunk" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var writer = Writer{ .writer = &w };
    const size = try writer.writeAll(&.{
        .{ .streamed_event = .{
            .salt = testSalt(1),
            .records = &.{test_records[0]},
        } },
    });

    // Flip a salt byte inside the end marker (marker starts at size - 44,
    // its salt 4 bytes after that).
    buf[size - 40] ^= 0xFF;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const read = try readBack(buf[0..size], arena.allocator());
    try std.testing.expectEqual(1, read.len);
    const sevt = read[0].streamed_event;
    try std.testing.expect(!sevt.sealed);
    try std.testing.expectEqual(1, sevt.records.len);
}

test "SEVT rejects an all-zero salt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bytes = "KWEV" ++ "SEVT" ++ ("\x00" ** 32);
    try std.testing.expectError(
        error.FileCorrupt,
        readBack(bytes, arena.allocator()),
    );
}

test "SEVT recovery: a zero tail after a sealed chunk is tolerated" {
    // A crashed writer leaves the rest of the file mapping zero-filled
    // because nothing truncated it; the sealed chunk must still read back.
    var buf: [512]u8 = @splat(0);
    var w = std.Io.Writer.fixed(&buf);
    var writer = Writer{ .writer = &w };
    _ = try writer.writeAll(&.{
        .{ .streamed_event = .{
            .salt = testSalt(1),
            .records = &test_records,
        } },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Read the whole buffer, zero tail included.
    const read = try readBack(&buf, arena.allocator());
    try std.testing.expectEqual(1, read.len);
    const sevt = read[0].streamed_event;
    try std.testing.expect(sevt.sealed);
    try std.testing.expectEqual(2, sevt.records.len);
}

test "no chunk may follow a SEVT chunk" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var writer = Writer{ .writer = &w };
    try writer.writeMagic();
    try writer.writeChunk(.{ .streamed_event = .{
        .salt = testSalt(1),
        .records = &.{test_records[0]},
    } });
    try writer.writeChunk(.{ .eof = {} });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.FileCorrupt,
        readBack(w.buffered(), arena.allocator()),
    );
}

test "reader rejects a bad magic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = std.Io.Reader.fixed("NOPE");
    var reader = Reader{ .reader = &r };
    try std.testing.expectError(error.NotKWEV, reader.readAll(arena.allocator()));
}

test "reader rejects a corrupted chunk payload" {
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
    });

    // Flip a byte inside the HDRA payload: the client name starts at offset 26
    // (4 magic + 4 name + 8 size + 2 version + 2 min version + 4 conf_by +
    // 2 name length), so this corrupts a name byte without breaking framing.
    buf[30] ^= 0xFF;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = std.Io.Reader.fixed(buf[0..size]);
    var reader = Reader{ .reader = &r };
    try std.testing.expectError(error.CRCMismatch, reader.readAll(arena.allocator()));
}
