const Response = @import("../http.zig").Response;
const Request = @import("../http.zig").Request;
const Result = @import("./response.zig");

fn makeResult(
    e: anyerror,
    comptime title: []const u8,
    comptime status: u10,
    res: *Response,
) void {
    const stat = comptime Result.toStatus(status);
    const R = Result.Json(void, .{status});
    const I = @FieldType(R, "value");
    const i = @unionInit(I, @tagName(stat), .{
        .type = e,
        .title = title,
        .details = "TODO",
        .instance = "TODO",
    });
    const r = R{ .value = i };
    res.status = 404;
    r.write(res.writer(), res) catch {
        res.written = true;
    };
}

pub const DefaultErrorHandler = struct {
    pub fn preQueue(e: anyerror, req: *Request, res: *Response) void {
        _ = req;
        if (res.written) return;
        switch (e) {
            error.NotFound, error.FileNotFound => |fe| makeResult(
                fe,
                "Not Found",
                404,
                res,
            ),
            error.MethodNotAllowed => |fe| makeResult(
                fe,
                "Method not allowed",
                405,
                res,
            ),
            error.QueueFull => |fe| makeResult(
                fe,
                "Service is unavailable",
                503,
                res,
            ),
            else => makeResult(e, "Unexpected Error", 500, res),
        }
    }

    pub fn postQueue(e: anyerror, req: *Request, res: *Response) ?anyerror {
        _ = req;
        if (res.written) return e;
        switch (e) {
            error.NotFound, error.FileNotFound => |fe| makeResult(
                fe,
                "Not Found",
                404,
                res,
            ),
            error.Unauthorized => |fe| makeResult(
                fe,
                "Unauthorized",
                401,
                res,
            ),
            error.Forbidden => |fe| makeResult(
                fe,
                "Forbidden",
                403,
                res,
            ),
            else => |fe| {
                makeResult(
                    fe,
                    "Unexpected Error",
                    500,
                    res,
                );
                return fe;
            },
        }
        return null;
    }
};

// Ref all decls
comptime {
    _ = &DefaultErrorHandler.preQueue;
    _ = &DefaultErrorHandler.postQueue;
}
