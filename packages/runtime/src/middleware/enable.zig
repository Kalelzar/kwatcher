pub fn EnableIf(comptime cond: bool, comptime routes: []const type) []const type {
    if (comptime routes.len == 0 or cond) return routes;

    return &.{};
}
