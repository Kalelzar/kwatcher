const std = @import("std");
pub const meta = @import("meta.zig");

test {
    std.testing.refAllDeclsRecursive(@This());
}
