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
