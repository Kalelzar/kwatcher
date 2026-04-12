const std = @import("std");
pub const Writer = @import("writer.zig").Writer;
pub const Reader = @import("reader.zig").Reader;
pub const MappedFile = @import("mapped_file.zig").MappedFile;
pub const structures = @import("structure.zig");
const drivers = @import("../driver.zig");

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

pub fn next(w: *std.Io.Writer, header: []const u8) ![]u8 {
    var writer = Writer{ .writer = w };
    try writer.writeMagic();
    try writer.writeChunk(.{ .link = .{ .rel = header } });
    const store = writer.writer.end + 4;
    try writer.writeChunk(.{ .event = .{ .events = &.{} } });
    try writer.writeChunk(.{ .eof = {} });
    return writer.writer.buffer[store .. store + 8];
}

pub fn append(w: *std.Io.Writer, target: []u8, evt: anytype) !void {
    const size = std.mem.readInt(u64, @ptrCast(target.ptr), .big);
    w.undo(20);
    const start = w.end;
    const res: anyerror!u1 = blk: {
        w.writeInt(u16, @intFromEnum(evt.event_type), .big) catch |e| break :blk e;
        switch (evt.event_data) {
            inline else => |driver| {
                switch (driver) {
                    inline else => |payload| {
                        if (comptime @hasDecl(@TypeOf(payload), "write")) {
                            payload.write(w) catch |e| break :blk e;
                        } else {
                            std.zon.stringify.serializeArbitraryDepth(
                                payload,
                                .{ .whitespace = false, .emit_default_optional_fields = false },
                                w,
                            ) catch |e| break :blk e;
                        }
                    },
                }
            },
        }
        std.zon.stringify.serialize(
            evt.properties,
            .{ .whitespace = false, .emit_default_optional_fields = false },
            w,
        ) catch |e| break :blk e;
        w.writeAll("NONE") catch |e| break :blk e;
        w.writeAll("EOF!") catch |e| break :blk e;
        w.writeInt(u64, w.end + 4, .big) catch |e| break :blk e;
        w.writeInt(u32, 0xAAAAAAAA, .big) catch |e| break :blk e;
        std.mem.writeInt(u64, @ptrCast(target.ptr), size + 1, .big);
        break :blk @as(u1, 1);
    } catch {
        w.undo(w.end - start);
        try finalize(w, target);
        return error.Full;
    };

    _ = try res;
}

pub fn finalize(w: *std.Io.Writer, target: []u8) !void {
    var crc = std.hash.crc.Crc32Iscsi.init();
    crc.update(w.buffer[@intFromPtr(target.ptr) - @intFromPtr(w.buffer.ptr) - 4 .. w.end]);
    w.writeInt(u32, crc.final(), .big) catch unreachable;
    w.writeAll("EOF!") catch unreachable;
    w.writeInt(u64, w.end + 4, .big) catch unreachable;
    w.writeInt(u32, 0xAAAAAAAA, .big) catch unreachable;
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
                .type = @tagName(drv.key),
            }};

            const ET = drv.EventType;
            const ti = @typeInfo(ET);
            var ev: []const structures.EventType.Mapping = &.{};
            switch (ti) {
                .@"enum" => |e| {
                    if (!e.is_exhaustive) @compileError("EventType must be exhaustive!");
                    for (e.fields) |f| {
                        if (std.mem.eql(u8, f.name[0..f.name.len], "__end")) continue;
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
