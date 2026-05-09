const std = @import("std");
const kw = @import("../../root.zig");

pub const ProblemDetails = struct {
    type: anyerror,
    title: []const u8,
    details: ?[]const u8 = null,
    instance: []const u8,
    additional_details: []const struct {
        type: anyerror,
        title: []const u8,
        details: ?[]const u8 = null,
    } = &.{},
};

pub fn ApiResult(
    comptime Result: type,
    comptime Error: type,
    comptime expected_statuses: []const []const u8,
) type {
    const StatusEnum = Enumize(expected_statuses);
    const StatusUnion = Unionize(
        expected_statuses,
        StatusEnum,
        Result,
        Error,
    );

    return StatusUnion;
}

pub fn Json(
    comptime Result: type,
    comptime expected_statuses: []const []const u8,
) type {
    const StatusEnum = Enumize(expected_statuses);
    return struct {
        const statuses = StatusEnum;
        value: ApiResult(Result, ProblemDetails, expected_statuses),

        pub fn write(self: *const @This(), writer: *std.Io.Writer, res: *kw.http.Response) !void {
            res.content_type = .JSON;
            res.status = @intFromEnum(std.meta.activeTag(self.value));
            // NOTE: We might want to set content_type to application/problem+json for 400+ codes
            switch (self.value) {
                inline else => |payload| {
                    const Payload = @TypeOf(payload);
                    if (Payload != void) {
                        const fmt = std.json.fmt(payload, .{});
                        try fmt.format(writer);
                    }
                },
            }
        }

        pub fn Extend(new_statuses: []const []const u8) type {
            const Eql = struct {
                pub fn eql(a: []const u8, b: []const u8) bool {
                    return std.mem.eql(u8, a, b);
                }
            };
            const stats = kw.shared.SetUnionEql([]const u8, expected_statuses, new_statuses, Eql);
            return Json(Result, stats);
        }
    };
}

pub fn Enumize(comptime statuses: []const []const u8) type {
    @setEvalBranchQuota(20000);
    var fields: [statuses.len]std.builtin.Type.EnumField = undefined;
    for (statuses, 0..) |status, i| {
        const stringly = std.meta.stringToEnum(std.http.Status, status) orelse blk: {
            const int = std.fmt.parseInt(u10, status, 10) catch {
                @compileError("Expected status to be either the canonical name or a status code.");
            };
            const numerically: std.http.Status = @enumFromInt(int);
            break :blk numerically;
        };

        fields[i] = .{
            .name = @tagName(stringly),
            .value = @intFromEnum(stringly),
        };
    }

    return @Type(.{
        .@"enum" = .{
            .decls = &.{},
            .fields = &fields,
            .tag_type = u10,
            .is_exhaustive = true,
        },
    });
}

pub fn Unionize(
    comptime statuses: []const []const u8,
    comptime Tag: type,
    comptime Result: type,
    comptime Error: type,
) type {
    @setEvalBranchQuota(5000);
    var fields: [statuses.len]std.builtin.Type.UnionField = undefined;
    for (statuses, 0..) |status, i| {
        const stringly = std.meta.stringToEnum(std.http.Status, status) orelse blk: {
            const int = std.fmt.parseInt(u10, status, 10) catch {
                @compileError("Expected status to be either the canonical name or a status code.");
            };
            const numerically: std.http.Status = @enumFromInt(int);
            break :blk numerically;
        };

        // God only knows if this is correct
        const T = switch (@intFromEnum(stringly)) {
            100...203, 205...299 => Result,
            204 => void,
            300...399 => void,
            400...599 => Error,
            else => void,
        };

        fields[i] = .{
            .name = @tagName(stringly),
            .type = T,
            .alignment = @alignOf(T),
        };
    }

    return @Type(.{
        .@"union" = .{
            .decls = &.{},
            .fields = &fields,
            .tag_type = Tag,
            .layout = .auto,
        },
    });
}

pub fn Request(comptime Body: ?type) type {
    const S = std.builtin.Type.StructField;
    comptime var fields: []const S = &.{};
    fields = fields ++ .{S{
        .name = "request",
        .type = *kw.http.Request,
        .is_comptime = false,
        .alignment = @alignOf(*kw.http.Request),
        .default_value_ptr = null,
    }};
    fields = fields ++ .{S{
        .name = "response",
        .type = *kw.http.Response,
        .is_comptime = false,
        .alignment = @alignOf(*kw.http.Response),
        .default_value_ptr = null,
    }};
    if (Body) |B| {
        fields = fields ++ .{S{
            .name = "body",
            .type = B,
            .is_comptime = false,
            .alignment = @alignOf(B),
            .default_value_ptr = null,
        }};
    }

    return @Type(
        .{
            .@"struct" = .{
                .decls = &.{},
                .fields = fields,
                .is_tuple = false,
                .layout = .auto,
            },
        },
    );
}
