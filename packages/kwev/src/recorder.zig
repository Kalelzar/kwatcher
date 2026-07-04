const std = @import("std");
const kwev = @import("kwev.zig");

pub const Recorder = struct {
    kwfile: kwev.KWEV,
    writer: std.Io.Writer,
    salt: [32]u8 = undefined,
    /// The link target for the definitions file, owned by the recorder
    /// (the caller's slice may be stack-local).
    header_buf: [64]u8 = undefined,
    header_len: usize = 0,
    /// The directory all files are written to, owned by the recorder.
    dir_buf: [128]u8 = undefined,
    dir_len: usize = 0,
    /// The current file's path including the ".part" suffix it carries
    /// while being written.
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    stamp: i64 = 0,
    index: u64 = 0,
    id: u64 = 0,
    max_len: isize = 0,

    const part_suffix = ".part";

    pub fn initPinned(
        self: *Recorder,
        id: u64,
        max_len: isize,
        stamp: i64,
        dir: []const u8,
        link_target: []const u8,
    ) !void {
        self.index = 0;
        self.id = id;
        self.max_len = max_len;
        self.stamp = stamp;
        @memcpy(self.dir_buf[0..dir.len], dir);
        self.dir_len = dir.len;
        @memcpy(self.header_buf[0..link_target.len], link_target);
        self.header_len = link_target.len;
        try self.open();
    }

    fn header(self: *const Recorder) []const u8 {
        return self.header_buf[0..self.header_len];
    }

    fn partName(self: *const Recorder) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn finalName(self: *const Recorder) []const u8 {
        return self.name_buf[0 .. self.name_len - part_suffix.len];
    }

    fn open(self: *Recorder) !void {
        const file = try std.fmt.bufPrint(
            &self.name_buf,
            "{s}/{d}-thread-{d}.{d}.kwev" ++ part_suffix,
            .{ self.dir_buf[0..self.dir_len], self.stamp, self.id, self.index },
        );
        self.name_len = file.len;
        self.kwfile = try kwev.KWEV.init(file, self.max_len);
        self.writer = self.kwfile.file.writer();
        // The salt must be fresh per SEVT chunk (and never all-zero, which
        // crypto random cannot produce in practice).
        std.crypto.random.bytes(&self.salt);
        try kwev.next(&self.writer, self.header(), self.salt);
    }

    pub fn deinit(self: *Recorder) void {
        // The file already ends in a valid end marker after every append;
        // sealing needs no extra write, only trimming the mapping to size
        // and dropping the ".part" staging suffix.
        self.writer.flush() catch {};
        self.kwfile.finalize(self.writer.end) catch {};
        self.kwfile.deinit();
        std.fs.cwd().rename(self.partName(), self.finalName()) catch |e| {
            std.log.warn("could not rename {s}: {t}", .{ self.partName(), e });
        };
    }

    pub fn rotate(self: *Recorder) !void {
        self.deinit();
        self.index += 1;
        try self.open();
    }

    pub fn append(self: *Recorder, event: anytype) !void {
        kwev.append(&self.writer, self.salt, event) catch {
            try self.rotate();
            try kwev.append(&self.writer, self.salt, event);
        };
    }
};
