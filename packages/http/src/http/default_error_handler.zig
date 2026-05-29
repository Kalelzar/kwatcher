const Response = @import("../http.zig").Response;
const Request = @import("../http.zig").Request;
const Result = @import("./response.zig");

pub const DefaultErrorHandler = struct {
    pub fn preQueue(e: anyerror, req: *Request, res: *Response) void {
        _ = req;
        switch (e) {
            error.NotFound => {
                const R = Result.Json(void, .{404});
                const r = R{
                    .value = .{
                        .not_found = .{
                            .type = e,
                            .title = "Not Found",
                            .details = "TODO",
                            .instance = "TODO",
                        },
                    },
                };
                res.status = 404;
                r.write(res.writer(), res) catch {
                    res.written = true;
                };
            },
            error.MethodNotAllowed => {
                const R = Result.Json(void, .{405});
                const r = R{
                    .value = .{
                        .method_not_allowed = .{
                            .type = e,
                            .title = "Method Not Allowed",
                            .details = "TODO",
                            .instance = "TODO",
                        },
                    },
                };
                res.status = 405;
                r.write(res.writer(), res) catch {
                    res.written = true;
                };
            },
            error.QueueFull => {
                const R = Result.Json(void, .{503});
                const r = R{
                    .value = .{
                        .service_unavailable = .{
                            .type = e,
                            .title = "Service is busy",
                            .details = "TODO",
                            .instance = "TODO",
                        },
                    },
                };
                res.status = 405;
                r.write(res.writer(), res) catch {
                    res.written = true;
                };
            },
            else => {
                const R = Result.Json(void, .{500});
                const r = R{
                    .value = .{
                        .internal_server_error = .{
                            .type = e,
                            .title = "Unexpected Error",
                            .instance = "TODO",
                        },
                    },
                };
                res.status = 500;
                r.write(res.writer(), res) catch {
                    res.written = true;
                };
            },
        }
    }

    pub fn postQueue(e: anyerror, req: *Request, res: *Response) void {
        _ = req;
        switch (e) {
            else => {
                const R = Result.Json(void, .{500});
                const r = R{
                    .value = .{
                        .internal_server_error = .{
                            .type = e,
                            .title = "Unexpected Error",
                            .instance = "TODO",
                        },
                    },
                };
                res.status = 500;
                r.write(res.writer(), res) catch {
                    res.written = true;
                };
            },
        }
    }
};
