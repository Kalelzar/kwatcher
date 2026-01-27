const std = @import("std");
const kwev = @import("structure.zig");

pub const Writer = struct {
    writer: *std.Io.Writer,

    pub fn writeMagic(self: *Writer) !void {
        try self.writer.writeAll("KWEV");
    }

    pub fn writeAll(self: *Writer, chunks: []const kwev.ChunkData) !usize {
        try self.writeMagic();
        for (chunks) |chunk| {
            std.debug.assert(std.meta.activeTag(chunk) != .eof);
            try self.writeChunk(chunk);
        }
        try self.writeChunk(.{ .eof = {} });

        return self.writer.end;
    }

    pub fn writeChunk(self: *Writer, chunk: kwev.ChunkData) !void {
        try self.writer.writeAll(kwev.ChunkNames.get(std.meta.activeTag(chunk)));
        const size_target = try self.writer.writableArray(8);
        const start = self.writer.end;

        switch (chunk) {
            .header_a => |a| try self.writeHeaderA(a),
            .drivers => |d| try self.writeDrivers(d),
            .event_type => |e| try self.writeEventTypes(e),
            .link => |l| try self.writeLink(l),
            .event => |e| try self.writeEvent(e),
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
};
