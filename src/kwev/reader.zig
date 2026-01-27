const std = @import("std");
const kwev = @import("structure.zig");

pub const Reader = struct {
    reader: *std.Io.Reader,

    const Error = std.Io.Reader.Error || error{ NotKWEV, UnknownChunk, CRCMismatch, FileCorrupt };

    pub fn readMagic(self: *Reader) Error!void {
        var buf: [4]u8 = undefined;
        try self.reader.readSliceAll(&buf);
        if (!std.mem.eql(u8, &buf, "KWEV")) return error.NotKWEV;
    }

    pub fn readAll(self: *Reader, allocator: std.mem.Allocator) (Error || error{OutOfMemory})![]const kwev.ChunkData {
        try self.readMagic();
        var list = std.ArrayList(kwev.ChunkData){};
        errdefer list.deinit(allocator);
        while (true) {
            const next = try list.addOne(allocator);
            try self.readChunk(next, allocator);
            if (std.meta.activeTag(next.*) == .eof) break;
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn readChunk(self: *Reader, chunk: *kwev.ChunkData, allocator: std.mem.Allocator) (Error || error{OutOfMemory})!void {
        const name = try self.reader.takeArray(4);
        const ctype = kwev.ChunkTypes.get(name);
        if (ctype == null) {
            std.log.err("Unrecognised chunk type: {s}", .{name});
            return error.UnknownChunk;
        }
        const size = try self.reader.takeInt(u64, .big);
        switch (ctype.?) {
            .eof => {
                const crc = try self.reader.takeInt(u32, .big);

                if (crc != 0xAAAAAAAA) return error.CRCMismatch;
                if (size != self.reader.seek) return error.FileCorrupt;

                chunk.* = .{ .eof = {} };
                return;
            },
            .header_a => try self.readHeaderA(chunk),
            .drivers => try self.readDrivers(chunk, allocator),
            .event => try self.readEvents(chunk, allocator),
            .event_type => try self.readEventTypes(chunk, allocator),
            .link => try self.readLink(chunk),
        }
        const end = self.reader.seek;
        const start = end - size - 12;
        var crc = std.hash.crc.Crc32Iscsi.init();
        // CRC includes chuck name (4 bytes) and the chunk length (8 bytes) in addition to
        // the actual data cotents (end - start) bytes so we need to offset by 12.
        crc.update(self.reader.buffer[start..end]);
        const actual = crc.final();
        const expected = try self.reader.takeInt(u32, .big);
        if (expected != actual) return error.CRCMismatch;
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
