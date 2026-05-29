const std = @import("std");

pub const MappedFile = struct {
    discarding_writer: std.Io.Writer.Discarding = .init(""),

    pub fn init(_: []const u8, _: isize) !MappedFile {
        return .{};
    }

    pub fn deinit(_: *MappedFile, _: bool) void {}

    pub fn truncate(_: *MappedFile, _: usize) !void {}

    pub fn writer(self: *MappedFile) std.Io.Writer {
        return self.discarding_writer.writer;
    }

    pub fn reader(_: *MappedFile) std.Io.Reader {
        return std.Io.Reader.fixed("");
    }

    pub fn limitReader(_: *MappedFile, _: usize, _: usize) std.Io.Reader {
        return std.Io.Reader.fixed("");
    }
};
