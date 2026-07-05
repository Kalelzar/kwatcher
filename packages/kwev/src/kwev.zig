const std = @import("std");
pub const Writer = @import("writer.zig").Writer;
pub const Reader = @import("reader.zig").Reader;
pub const MappedFile = @import("mapped_file.zig").MappedFile;
pub const structures = @import("structure.zig");
pub const recorder = @import("recorder.zig");
pub const compress = @import("compress.zig");
const drivers = @import("kw-core").driver;
const correlation = @import("kw-core").correlation;

pub const KWEV = struct {
    file: MappedFile,

    pub fn init(rel: []const u8, max_len: isize) !KWEV {
        return .{
            .file = try .init(
                rel,
                max_len,
            ),
        };
    }

    pub fn finalize(self: *KWEV, final_size: usize) !void {
        try self.file.truncate(final_size);
    }

    pub fn deinit(self: *KWEV) void {
        self.file.deinit(true);
    }
};

/// Size of a SEVT end marker: u32 of zeroes + 32-byte salt + 4-byte name +
/// 4-byte CRC.
pub const stream_marker_len = 44;

/// Starts a rolling recorder file: magic, a LINK to the definitions file,
/// and an open SEVT chunk that is immediately sealed with an end marker so
/// the file is valid from the first byte. `append` re-opens it by
/// overwriting the marker.
pub fn next(w: *std.Io.Writer, header: []const u8, salt: [32]u8) !void {
    var writer = Writer{ .writer = w };
    try writer.writeMagic();
    try writer.writeChunk(.{ .link = .{ .rel = header } });
    try w.writeAll("SEVT");
    try w.writeAll(&salt);
    try writer.writeStreamEndMarker(salt);
}

/// Appends one record to the open SEVT chunk: the end marker is reclaimed,
/// the record (u32 size, body, CRC over salt || size || body) is written,
/// and a fresh end marker follows it so a quiescent file always ends in a
/// valid marker. On overflow the record is rolled back, the marker is
/// restored, and error.Full is returned so the caller can rotate.
pub fn append(w: *std.Io.Writer, salt: [32]u8, evt: anytype) !void {
    var writer = Writer{ .writer = w };
    w.undo(stream_marker_len);
    const start = w.end;
    blk: {
        appendRecord(w, salt, evt) catch break :blk;
        writer.writeStreamEndMarker(salt) catch break :blk;
        return;
    }
    w.undo(w.end - start);
    // The marker's bytes were reclaimed above, so this cannot overflow.
    writer.writeStreamEndMarker(salt) catch unreachable;
    return error.Full;
}

// The record body has the same structure as one EVNT event: u16 event id,
// u16 data length, u16 properties length, data, properties. See
// structures.StreamedEvent.parseRecord for the inverse.
fn appendRecord(w: *std.Io.Writer, salt: [32]u8, evt: anytype) !void {
    const size_target = try w.writableArray(4);
    const body_start = w.end;
    try w.writeInt(u16, @intFromEnum(evt.event_type), .big);
    const data_len_target = try w.writableArray(2);
    const prop_len_target = try w.writableArray(2);
    const data_start = w.end;
    switch (evt.event_data) {
        inline else => |driver| {
            switch (driver) {
                inline else => |payload| {
                    if (comptime @hasDecl(@TypeOf(payload), "write")) {
                        try payload.write(w);
                    } else {
                        try std.zon.stringify.serializeArbitraryDepth(
                            payload,
                            .{ .whitespace = false, .emit_default_optional_fields = false },
                            w,
                        );
                    }
                },
            }
        },
    }
    std.mem.writeInt(u16, data_len_target, @intCast(w.end - data_start), .big);
    const prop_start = w.end;
    try std.zon.stringify.serialize(
        evt.properties,
        .{ .whitespace = false, .emit_default_optional_fields = false },
        w,
    );
    std.mem.writeInt(u16, prop_len_target, @intCast(w.end - prop_start), .big);
    std.mem.writeInt(u32, size_target, @intCast(w.end - body_start), .big);
    var crc = std.hash.crc.Crc32Iscsi.init();
    crc.update(&salt);
    crc.update(size_target);
    crc.update(w.buffer[body_start..w.end]);
    try w.writeInt(u32, crc.final(), .big);
}

pub fn inscribe(kwev: *KWEV, driver: drivers.Drivers) !usize {
    var io_writer = kwev.file.writer();
    var writer = Writer{ .writer = &io_writer };
    const chunks = comptime blk: {
        var chunks: []const structures.ChunkData = &.{};
        chunks = chunks ++ .{structures.ChunkData{
            .header_a = .{
                .version = 0,
                .min_version = 0,
                .conf_by = .{ 'H', 'D', 'R', 'A' },
                .client_name = "test",
                .client_version = 0,
                .min_client_version = 0,
            },
        }};

        var drvs: []const structures.Drivers.Driver = &.{};
        for (driver.drivers, 0..) |drv, i| {
            drvs = drvs ++ .{structures.Drivers.Driver{
                .name = @tagName(drv.key),
                .type = @tagName(drv.kind),
            }};

            const ET = drv.EventType;
            const ti = @typeInfo(ET);
            var ev: []const structures.EventType.Mapping = &.{};
            switch (ti) {
                .@"enum" => |e| {
                    if (!e.is_exhaustive) @compileError("EventType must be exhaustive!");
                    for (e.fields) |f| {
                        ev = ev ++ .{structures.EventType.Mapping{
                            .identifier = f.name,
                            .value = f.value,
                        }};
                    }
                },
                else => @compileError("Expected EventType to be an enum. Odd that."),
            }
            chunks = chunks ++ .{structures.ChunkData{ .event_type = .{
                .driver_id = i,
                .mappings = ev,
            } }};

            // Route op hashes: RouteKeys' enum field names ARE the route ids
            // stampRoute hashes into correlation ids, so mapping and stamp
            // cannot disagree. The internal driver has no routes.
            if (@hasDecl(drv, "RouteKeys")) {
                var ops: []const structures.RouteOpHash.Mapping = &.{};
                for (@typeInfo(drv.RouteKeys).@"enum".fields) |f| {
                    ops = ops ++ .{structures.RouteOpHash.Mapping{
                        .hash = correlation.CorrelationID.hash(f.name),
                        .identifier = f.name,
                    }};
                }
                if (ops.len != 0) {
                    chunks = chunks ++ .{structures.ChunkData{ .route_op_hash = .{
                        .driver_id = i,
                        .mappings = ops,
                    } }};
                }
            }
        }

        chunks = chunks ++ .{structures.ChunkData{
            .drivers = .{ .drivers = drvs },
        }};

        break :blk chunks;
    };
    const fsize = try writer.writeAll(chunks);
    try io_writer.flush();
    return fsize;
}

const TestEvent = struct {
    event_type: enum(u16) { ping = 100 },
    event_data: union(enum) {
        fake: union(enum) { ping: struct { a: u32 } },
    },
    properties: struct { correlation_id: u64 },
};

const test_event = TestEvent{
    .event_type = .ping,
    .event_data = .{ .fake = .{ .ping = .{ .a = 1 } } },
    .properties = .{ .correlation_id = 7 },
};

// What test_event serializes to: the record body shares the structure of one
// EVNT event, so it reads back as an Event.EventData with zon contents.
fn expectTestEventRecord(record: structures.Event.EventData) !void {
    try std.testing.expectEqual(100, record.event_id);
    try std.testing.expectEqualStrings(".{.a=1}", record.data);
    try std.testing.expectEqualStrings(".{.correlation_id=7}", record.properties);
}

fn readStream(bytes: []const u8, allocator: std.mem.Allocator) !structures.StreamedEvent {
    var r = std.Io.Reader.fixed(bytes);
    var reader = Reader{ .reader = &r };
    const chunks = try reader.readAll(allocator);
    try std.testing.expectEqual(2, chunks.len);
    try std.testing.expectEqualStrings("static.kwev", chunks[0].link.rel);
    return chunks[1].streamed_event;
}

test "next/append: the file parses sealed after every append" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const salt = @as([32]u8, @splat(0xAB));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try next(&w, "static.kwev", salt);
    for (0..3) |i| {
        const sevt = try readStream(w.buffered(), arena.allocator());
        try std.testing.expect(sevt.sealed);
        try std.testing.expectEqualSlices(u8, &salt, &sevt.salt);
        try std.testing.expectEqual(i, sevt.records.len);
        for (sevt.records) |record| {
            try expectTestEventRecord(record);
        }
        try append(&w, salt, test_event);
    }
}

test "append: rolls back the record and reseals the file when full" {
    // next() needs 115 bytes and each append 41 more, so the second
    // append overflows and must leave the first file state intact.
    var buf: [160]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const salt = @as([32]u8, @splat(0xAB));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try next(&w, "static.kwev", salt);
    try append(&w, salt, test_event);
    try std.testing.expectError(error.Full, append(&w, salt, test_event));

    const sevt = try readStream(w.buffered(), arena.allocator());
    try std.testing.expect(sevt.sealed);
    try std.testing.expectEqual(1, sevt.records.len);
    try expectTestEventRecord(sevt.records[0]);
}

// Ref all decls — kwev is generic-free, so this reaches the whole package
// (KWEV, Writer, Reader, MappedFile, structures, recorder, and the free fns).
comptime {
    std.testing.refAllDeclsRecursive(@This());
}
