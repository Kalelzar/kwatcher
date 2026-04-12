const std = @import("std");
const http = @import("../../template/Http.zig");

const Route = http.RouteGen.Route;

const RouteGroup = struct {
    prefix: []const u8,
    routes: []const type,
};

fn groupBySegments(
    comptime routes: []const type,
    comptime offs: usize,
) []const RouteGroup {
    comptime var buckets: usize = 0;
    comptime var grouped_routes: [routes.len]RouteGroup = undefined;
    outer: inline for (routes) |r| {
        if (comptime r.inner.path.len <= offs) @compileError("BAD! A route was too short for the grouping.");
        switch (r.inner.path[offs]) {
            .static => |s| {
                inline for (0..buckets) |i| {
                    const bucket = grouped_routes[i];
                    const prefix = bucket.prefix;
                    if (comptime std.mem.eql(u8, prefix, s)) {
                        grouped_routes[i].routes = bucket.routes ++ .{r};
                        continue :outer;
                    }
                }
                grouped_routes[buckets] = .{
                    .prefix = s,
                    .routes = &.{r},
                };
                buckets += 1;
            },
            else => {}, // Captures and others are handled separately
        }
    }

    return grouped_routes[0..buckets];
}

fn terminalSegments(
    comptime routes: []const type,
    comptime offs: usize,
) struct { []const type, []const type } {
    comptime var end_routes: []const type = &.{};
    comptime var other: []const type = &.{};
    inline for (routes) |r| {
        if (comptime r.inner.path.len <= offs) {
            end_routes = end_routes ++ .{r};
        } else {
            other = other ++ .{r};
        }
    }

    return .{ end_routes, other };
}

fn Enumize(comptime strs: []const RouteGroup) type {
    var enum_fields: [strs.len + 1]std.builtin.Type.EnumField = undefined;
    enum_fields[0] = .{
        .name = "$__none_%_reserved__",
        .value = 0,
    };
    for (strs, 1..) |str, i| {
        const name: [:0]const u8 = @ptrCast(str.prefix ++ .{0});
        enum_fields[i] = .{
            .name = name,
            .value = i,
        };
    }

    return @Type(
        .{
            .@"enum" = .{
                .decls = &.{},
                .fields = &enum_fields,
                .is_exhaustive = true,
                .tag_type = u8,
            },
        },
    );
}

fn Map(comptime strs: []const RouteGroup) std.StaticStringMap(Enumize(strs)) {
    var res: [strs.len]struct { []const u8, Enumize(strs) } = undefined;
    for (strs, 0..) |str, i| {
        res[i] = .{ str.prefix, @enumFromInt(i + 1) };
    }

    return .initComptime(res);
}

pub fn route(
    comptime routes: []const type,
    comptime offs: usize,
    incoming: []const u8,
    runtime_offs: usize,
) ?[]const u8 {
    const terminal, const nonterminal = terminalSegments(routes, offs);
    if (comptime terminal.len > 1) {
        @compileLog(terminal);
        @compileError("Conflicting routes");
    }

    if (comptime terminal.len == 1) {
        if (runtime_offs >= incoming.len) {
            std.log.debug("Matched: {s}", .{terminal[0].inner.identifier});
            return terminal[0].inner.identifier;
        }
    }

    if (runtime_offs >= incoming.len) {
        std.log.debug("Reached end of url without match", .{});
        return null;
    }

    const groups = groupBySegments(nonterminal, offs);
    inline for (groups) |g| {
        std.log.debug("[{d}] Group: {s}", .{ g.routes.len, g.prefix });
    }

    if (groups.len == 0) {
        std.log.debug("No more static groups. Bailing...", .{});
        return null;
    }

    const map = comptime Map(groups);
    const boundary_offs = std.mem.indexOf(u8, incoming[runtime_offs..], "/") orelse incoming.len - runtime_offs;

    const match = map.get(incoming[runtime_offs .. runtime_offs + boundary_offs]);
    if (match == null) {
        std.log.debug("[{d}..{d}]Could not match {s} | Tried segment {s}", .{ runtime_offs, boundary_offs, incoming, incoming[runtime_offs .. runtime_offs + boundary_offs] });
        return null;
    }

    switch (match.?) {
        inline else => |m| {
            std.log.debug("Segment {d} matched against {t}", .{ offs, m });
            const g = @intFromEnum(m) -| 1;
            return route(
                groups[g].routes,
                offs + 1,
                incoming,
                runtime_offs + groups[g].prefix.len + 1,
            );
        },
    }
}
