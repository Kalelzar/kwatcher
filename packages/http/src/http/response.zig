const std = @import("std");
const http = @import("../http.zig");
const core = @import("kw-core");

/// An RFC 7807 problem-details payload describing an error response.
pub const ProblemDetails = struct {
    type: anyerror,
    /// A short, human-readable summary of the problem.
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
    comptime expected_statuses: anytype,
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
    comptime expected_statuses: anytype,
) type {
    const StatusEnum = Enumize(expected_statuses);
    return struct {
        const statuses = StatusEnum;
        pub const ContentType = "application/json";
        value: ApiResult(Result, ProblemDetails, expected_statuses),

        pub fn write(self: *const @This(), writer: *std.Io.Writer, res: *http.Response) !void {
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

        pub fn Extend(new_statuses: anytype) type {
            const Eql = struct {
                pub fn eql(a: anytype, b: anytype) bool {
                    return toStatus(a) == toStatus(b);
                }
            };
            const stats = core.shared.SetUnionEql(
                @TypeOf(expected_statuses[0]),
                expected_statuses,
                new_statuses,
                Eql,
            );
            return Json(Result, stats);
        }
    };
}

pub fn toStatus(status: anytype) std.http.Status {
    const S = @TypeOf(status);
    const res: std.http.Status = sw: switch (S) {
        []const u8, []u8 => std.meta.stringToEnum(std.http.Status, status) orelse blk: {
            const int = std.fmt.parseInt(u10, status, 10) catch {
                @compileError("Expected status to be either the canonical name or a status code.");
            };
            const numerically: std.http.Status = @enumFromInt(int);
            break :blk numerically;
        },
        usize, u64, u32, u16, isize, i64, i32, i16, u10, comptime_int => @enumFromInt(status),
        @Type(.enum_literal) => @field(std.http.Status, @tagName(status)),
        else => {
            const ti = @typeInfo(S);
            typedef: switch (ti) {
                .array => |a| {
                    if (a.child == u8) {
                        continue :sw []const u8;
                    }
                },
                .pointer => |p| {
                    const ti2 = @typeInfo(p.child);

                    switch (ti2) {
                        .array => |_| {
                            continue :typedef ti2;
                        },
                        else => @compileError("Unsupported pointer status type: " ++ @typeName(S)),
                    }
                },
                else => @compileError("Unsupported status type: " ++ @typeName(S)),
            }
        },
    };
    return res;
}

pub fn Enumize(comptime statuses: anytype) type {
    @setEvalBranchQuota(20000);
    comptime {
        var fields: [statuses.len]std.builtin.Type.EnumField = undefined;
        for (statuses, 0..) |status, i| {
            const stringly = toStatus(status);
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
}

pub fn Unionize(
    comptime statuses: anytype,
    comptime Tag: type,
    comptime Result: type,
    comptime Error: type,
) type {
    @setEvalBranchQuota(5000);
    var fields: [statuses.len]std.builtin.Type.UnionField = undefined;
    for (statuses, 0..) |status, i| {
        const stringly = toStatus(status);

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
    return FullRequest(Body, null);
}

/// A result type that can return a file from disk.
/// @see InternalFile for files embedded in the executable.
pub fn File(
    comptime _ContentType: []const u8,
) type {
    return struct {
        pub const ContentType = _ContentType;
        value: std.fs.File,

        pub fn write(self: *const @This(), writer: *std.Io.Writer, res: *http.Response) !void {
            _ = writer;
            defer self.value.close();
            res.header("Content-Type", ContentType);

            var buffer: [1024]u8 = undefined;

            const file_size = (try self.value.stat()).size;
            var temp: [64]u8 = undefined;
            res.header("Content-Length", try std.fmt.bufPrint(&temp, "{d}", .{file_size}));

            var reader = self.value.readerStreaming(&.{});
            try res.writeHeader();

            res.written = true;

            var streamWriter = res.conn.stream.writer(&buffer);
            const wi = &streamWriter.interface;

            var switched_to_blocking = false;
            defer if (switched_to_blocking) res.conn.nonblockingMode() catch {};

            while (true) {
                const n = wi.sendFile(&reader, .unlimited) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                if (n != 0) continue;

                // No progress: either a stashed error or a benign mode-switch retry.
                const se = streamWriter.file_writer.sendfile_err orelse continue;
                streamWriter.file_writer.sendfile_err = null;
                if (se != error.WouldBlock) return se;
                if (!switched_to_blocking) {
                    try res.conn.blockingMode();
                    switched_to_blocking = true;
                }
            }

            try wi.flush();
        }
    };
}

// Ref all decls
comptime {
    _ = ProblemDetails;

    _ = ApiResult(struct { x: u8 }, ProblemDetails, .{ .ok, .bad_request });

    const J = Json(struct { x: u8 }, .{ .ok, .bad_request });
    _ = &J.write;
    _ = J.Extend(.{.created});

    _ = Enumize(.{ .ok, 404 });
    _ = Enumize(.{"accepted"});
    _ = Unionize(.{.ok}, Enumize(.{.ok}), struct {}, ProblemDetails);

    _ = Request(null);
    _ = Request(struct { name: []const u8 });
    _ = FullRequest(struct {}, struct { q: []const u8 });
}

pub fn FullRequest(comptime Body: ?type, comptime Query: ?type) type {
    const S = std.builtin.Type.StructField;
    comptime var fields: []const S = &.{};
    fields = fields ++ .{S{
        .name = "request",
        .type = *http.Request,
        .is_comptime = false,
        .alignment = @alignOf(*http.Request),
        .default_value_ptr = null,
    }};
    fields = fields ++ .{S{
        .name = "response",
        .type = *http.Response,
        .is_comptime = false,
        .alignment = @alignOf(*http.Response),
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
    if (Query) |Q| {
        fields = fields ++ .{S{
            .name = "query",
            .type = Q,
            .is_comptime = false,
            .alignment = @alignOf(Q),
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
