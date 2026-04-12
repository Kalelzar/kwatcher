const std = @import("std");
const builtin = @import("builtin");
const platform = switch (builtin.target.os.tag) {
    .windows => @import("mapped_file/windows.zig"),
    .linux => @import("mapped_file/linux.zig"),
    else => @compileError("Not supported"),
};

pub const MappedFile = platform.MappedFile;
