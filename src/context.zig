pub fn Context(comptime Custom: type) type {
    return struct {
        custom: Custom = .{},
        id: []const u8 = "default",
    };
}
