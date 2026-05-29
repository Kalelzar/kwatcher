const std = @import("std");
const http = @import("../Http.zig");

const Route = http.RouteGen.Route;

const RouteState = enum {
    static,
    capture,
};

const RouteGroup = struct {
    prefix: []const u8,
    routes: []const type,
};

const Grouped = struct {
    static: []const RouteGroup,
    capture: []const type,
    wildcard: []const type,
    parameter: []const type,
};

fn groupBySegments(
    comptime routes: []const type,
    comptime offs: usize,
) Grouped {
    comptime var buckets: usize = 0;
    comptime var grouped_routes: [routes.len]RouteGroup = undefined;
    comptime var grouped_captures: []const type = &.{};
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
            .capture => |c| {
                if (comptime c.wildcard) {} else {
                    grouped_captures = grouped_captures ++ .{r};
                }
            },
            else => {}, // TODO
        }
    }

    return .{
        .static = grouped_routes[0..buckets],
        .capture = grouped_captures,
        .wildcard = &.{},
        .parameter = &.{},
    };
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
    capture_buffer: [][]const u8,
    capture_index: usize,
    incoming: []const u8,
    runtime_offs: usize,
) ?struct { key: []const u8, captures: []const []const u8 } {
    const terminal, const nonterminal = terminalSegments(routes, offs);
    if (comptime terminal.len > 1) {
        comptime var affected: []const u8 = "";
        inline for (terminal) |T| {
            affected = affected ++ "\n\t" ++ T.id;
        }
        @compileError("Conflicting routes:" ++ affected);
    }

    if (comptime terminal.len == 1) {
        if (runtime_offs >= incoming.len) {
            // std.log.debug("Matched: {s}", .{terminal[0].inner.identifier});
            // for (0..capture_index) |i| {
            //     // std.log.debug("\t Capture {d}: {s}", .{ i, capture_buffer[i] });
            // }
            return .{
                .key = terminal[0].inner.identifier,
                .captures = capture_buffer[0..capture_index],
            };
        }
    }

    if (runtime_offs >= incoming.len) {
        // std.log.debug("Reached end of url without match", .{});
        return null;
    }

    const groups = comptime groupBySegments(nonterminal, offs);
    const boundary_offs = std.mem.indexOf(u8, incoming[runtime_offs..], "/") orelse incoming.len - runtime_offs;
    const raw = incoming[runtime_offs .. runtime_offs + boundary_offs];

    const state: RouteState = .static;
    branch: switch (state) {
        .static => {
            // inline for (groups.static) |g| {
            //     // std.log.debug("[{d}] Group: {s}", .{ g.routes.len, g.prefix });
            // }

            if (comptime groups.static.len == 0) {
                // std.log.debug("No more static groups. Bailing...", .{});
                continue :branch .capture;
            }

            const map = comptime Map(groups.static);

            const match = map.get(raw);
            if (match == null) {
                // std.log.debug(
                //     "[{d}..{d}]Could not match {s} | Tried segment {s}",
                //     .{ runtime_offs, boundary_offs, incoming, raw },
                // );
                continue :branch .capture;
            }

            switch (match.?) {
                inline else => |m| {
                    // std.log.debug("Segment {d} matched against {t}", .{ offs, m });
                    const g = @intFromEnum(m) -| 1;
                    return route(
                        groups.static[g].routes,
                        offs + 1,
                        capture_buffer,
                        capture_index,
                        incoming,
                        runtime_offs + groups.static[g].prefix.len + 1,
                    ) orelse continue :branch .capture;
                },
            }
        },
        .capture => {
            // std.log.debug(
            //     "[{d}] Capture Group: {s}",
            //     .{ groups.capture.len, raw },
            // );

            if (comptime groups.capture.len == 0) {
                // std.log.debug("No more captures. Bailing...", .{});
                return null;
            }

            capture_buffer[capture_index] = raw;

            //TODO: This needs to return multiple routes to account for ambiguous captures that only differ by type
            return route(
                groups.capture,
                offs + 1,
                capture_buffer,
                capture_index + 1,
                incoming,
                runtime_offs + raw.len + 1,
            );
        },
    }
}
