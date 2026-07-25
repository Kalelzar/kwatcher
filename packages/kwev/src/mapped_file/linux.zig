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

fn errnoToError(errno: std.os.linux.E) !void {
    return switch (errno) {
        .SUCCESS => {},
        .BADF => error.BadFileDescriptor,
        .FBIG => error.MaxFileSizeOverflow,
        .INTR => error.Signal,
        .INVAL => error.Invalid,
        .IO => error.IO,
        .NODEV => error.NotAFile,
        .NOSPC => error.OutOfSpace,
        .NOSYS => error.NotImplemented,
        .OPNOTSUPP => error.FsNotSupported,
        .PERM => error.PermissionError,
        .SPIPE => error.UnexpectedPipe,
        .TXTBSY => error.Busy,
        else => unreachable,
    };
}

fn fallocate(fd: i32, mode: i32, offset: i64, length: i64) !void {
    const errno = std.os.linux.E.init(std.os.linux.fallocate(fd, mode, offset, length));
    return errnoToError(errno);
}

fn preallocate(file: std.fs.File, offset: i64, length: i64) !void {
    return fallocate(file.handle, 0, offset, length);
}

fn mapFile(file: std.fs.File, length: usize, prot: u32, flags: std.posix.MAP, offset: u64) ![]align(std.heap.page_size_min) u8 {
    return std.posix.mmap(null, length, prot, flags, file.handle, offset);
}

pub const MappedFile = struct {
    file: std.fs.File,
    mapping: []align(std.heap.page_size_min) u8,

    pub fn init(rel: []const u8, flen: isize) !MappedFile {
        const file = try std.fs.cwd().createFile(rel, .{
            .exclusive = false,
            .lock = .exclusive,
            .read = true,
        });
        errdefer file.close();

        try preallocate(file, 0, flen);
        const buf = try mapFile(
            file,
            @intCast(flen),
            std.posix.PROT.WRITE | std.posix.PROT.READ,
            std.posix.MAP{
                .TYPE = .SHARED,
                .POPULATE = true,
            },
            0,
        );
        errdefer std.posix.munmap(buf);
        try std.posix.madvise(buf.ptr, @intCast(flen), std.posix.MADV.SEQUENTIAL);

        return .{
            .file = file,
            .mapping = buf,
        };
    }

    pub fn deinit(self: *MappedFile, should_sync: bool) void {
        if (should_sync) std.posix.msync(self.mapping, std.posix.MSF.SYNC) catch {};
        std.posix.munmap(self.mapping);
        self.file.close();
    }

    pub fn truncate(self: *MappedFile, final_size: usize) !void {
        try std.posix.ftruncate(self.file.handle, final_size);
    }

    pub fn writer(self: *MappedFile) std.Io.Writer {
        return .{
            .buffer = self.mapping,
            .vtable = &.{
                .drain = std.Io.Writer.fixedDrain,
                .rebase = std.Io.Writer.failingRebase,
                .flush = msyncFlush,
            },
        };
    }

    pub fn reader(self: *MappedFile) std.Io.Reader {
        return std.Io.Reader.fixed(self.mapping);
    }

    pub fn limitReader(self: *MappedFile, offset: usize, length: usize) std.Io.Reader {
        std.debug.assert(offset + length <= self.mapping.len);
        return std.Io.Reader.fixed(self.mapping[offset .. offset + length]);
    }
};

fn msyncFlush(w: *std.Io.Writer) std.Io.Writer.Error!void {
    std.posix.msync(@alignCast(w.buffer), std.posix.MSF.ASYNC) catch return error.WriteFailed;
}
