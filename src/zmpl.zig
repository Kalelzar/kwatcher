const std = @import("std");
const zmpl = @import("zmpl");
const core = @import("kw-core");
const http = @import("kw-http");

pub fn ContentTypes(comptime Formatters: []const type) type {
    const result: []const std.builtin.Type.EnumField = comptime blk: {
        var result: [Formatters.len]std.builtin.Type.EnumField = undefined;
        for (Formatters, 0..) |F, i| {
            // TODO: Formally verify no duplicate content type?
            // This will error out anyway but might as well give a sane error maybe?
            result[i] = .{
                .name = F.ContentType,
                .value = i,
            };
        }

        break :blk &result;
    };

    return @Type(.{
        .@"enum" = .{
            .decls = &.{},
            .fields = result,
            .is_exhaustive = true,
            .tag_type = core.meta.UIntShrink(Formatters.len),
        },
    });
}

pub fn Many(comptime T: type, comptime Formatters: []const type) type {
    const CTs = ContentTypes(Formatters);

    return struct {
        value: T,
        to: CTs,

        pub const AllowedTypes = CTs;

        pub fn write(self: *const @This(), writer: *std.Io.Writer, res: *http.Response) !void {
            switch (self.to) {
                inline else => |t| {
                    const i = comptime @intFromEnum(t);
                    const F = Formatters[i];
                    const f: F = .{
                        .value = self.value,
                    };
                    try f.write(writer, res);
                },
            }

            res.content_type = null;
            res.header("content-type", @tagName(self.to));
        }
    };
}

const Value = zmpl.Data.Value;

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn makeString(alloc: std.mem.Allocator, s: []const u8) !*Value {
    const v = try alloc.create(Value);
    v.* = .{ .string = .{ .value = s, .allocator = alloc } };
    return v;
}

/// Recursively serialize an arbitrary value into a zmpl `Value` tree for template
/// rendering. zmpl's own `zmplValue` already walks structs/slices/optionals/scalars,
/// but it rejects three things our http response types use: tagged unions (the
/// `ApiResult` status union), error sets (`ProblemDetails.type: anyerror`), and `void`
/// (no-content arms). We intercept exactly those and delegate everything else to zmpl.
fn toValue(value: anytype, alloc: std.mem.Allocator) !*Value {
    const T = @TypeOf(value);
    if (comptime isString(T)) return makeString(alloc, value);

    switch (@typeInfo(T)) {
        // Serialize the active arm and surface the tag so templates can branch on it.
        // zmpl has no enum value type, so the tag is the status name as a string
        // (e.g. "ok", "bad_request"). Merged into the payload object when possible so
        // `{.field}` access is unaffected; non-object payloads are wrapped as `{tag, value}`.
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                const inner = try toValue(payload, alloc);
                const tag_val = try makeString(alloc, @tagName(tag));
                switch (inner.*) {
                    .object => {
                        try inner.put("tag", tag_val);
                        return inner;
                    },
                    else => {
                        const obj = try zmpl.Data.createObject(alloc);
                        try obj.put("tag", tag_val);
                        try obj.put("value", inner);
                        return obj;
                    },
                }
            },
        },
        .@"struct" => |s| {
            const obj = try zmpl.Data.createObject(alloc);
            inline for (s.fields) |f| {
                if (comptime f.type == type) continue;
                try obj.put(f.name, try toValue(@field(value, f.name), alloc));
            }
            return obj;
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                const arr = try zmpl.Data.createArray(alloc);
                for (value) |item| try arr.append(try toValue(item, alloc));
                return arr;
            },
            .one => return toValue(value.*, alloc),
            else => @compileError("toValue: unsupported pointer " ++ @typeName(T)),
        },
        .array => |a| {
            if (comptime a.child == u8) return makeString(alloc, try alloc.dupe(u8, &value));
            const arr = try zmpl.Data.createArray(alloc);
            for (value) |item| try arr.append(try toValue(item, alloc));
            return arr;
        },
        .optional => {
            if (value) |v| return toValue(v, alloc);
            return zmpl.Data._null(alloc);
        },
        .error_union => if (value) |v| return toValue(v, alloc) else |e| return e,
        .error_set => return makeString(alloc, @errorName(value)),
        .void => return zmpl.Data.createObject(alloc),
        // ints, floats, bools, enums, datetime — zmpl handles these directly.
        else => return zmpl.Data.zmplValue(value, alloc),
    }
}

pub fn Template(comptime T: type, comptime template_name: []const u8) type {
    const template = zmpl.find(template_name) orelse @compileError("Template '" ++ template_name ++ "' not found.");
    return struct {
        value: T,
        pub const ContentType = "text/html";

        pub fn write(self: *const @This(), writer: *std.Io.Writer, res: *http.Response) !void {
            res.content_type = .HTML;

            var data = zmpl.Data.init(res.arena);
            defer data.deinit();

            data.value = try toValue(self.value, data.allocator);

            const tmpl = try template.render(&data, null, null, &.{}, .{});
            try writer.writeAll(tmpl);
        }
    };
}

/// Pick a response content type from an Accept header. Deliberately not RFC-compliant:
/// reads the listed media types left to right, ignores q-weights and wildcards, and
/// returns the first one we actually offer. Falls back to `def` when nothing matches
/// — e.g. a bare `*/*`, which we don't honor.
fn negotiate(comptime Enum: type, accept: ?[]const u8, def: Enum) Enum {
    if (accept) |header| {
        var it = std.mem.splitScalar(u8, header, ',');
        while (it.next()) |raw| {
            const semi = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
            const range = std.mem.trim(u8, raw[0..semi], " \t");
            if (std.meta.stringToEnum(Enum, range)) |e| return e;
        }
    }
    return def;
}

pub fn TemplateHandler(comptime M: type, comptime OG: type) type {
    return struct {
        pub fn create(comptime HandlerFac: anytype) type {
            return struct {
                pub fn make(comptime Base: anytype) type {
                    const Handler = HandlerFac(Base);
                    return struct {
                        pub const CallContext = Handler.CallContext;

                        pub const Dependencies = Handler.Dependencies;

                        pub fn call(
                            inj: *core.deps.DepCtx,
                            ctx: CallContext,
                            evprop: core.event.ExtendedProperties,
                        ) !*anyopaque {
                            const req = ctx.request;
                            // OG is always one of M's formatters, so its content type is a valid tag.
                            // HACK: Default to HTML until HTMX's setup requests html as by default it does */*;
                            const default_ct = comptime std.meta.stringToEnum(M.AllowedTypes, "text/html").?;
                            const accept = negotiate(M.AllowedTypes, req.header("accept"), default_ct);
                            const arena = try inj.require(core.mem.ScopedAllocator);
                            const allocator = arena.value;

                            const result: *anyopaque = try Handler.call(inj, ctx, evprop);
                            const actual: *OG = @ptrCast(@alignCast(result));

                            const many: M = .{
                                .value = actual.value,
                                .to = accept,
                            };

                            allocator.destroy(actual);
                            const slot = try allocator.create(M);
                            slot.* = many;

                            return @ptrCast(@alignCast(slot));
                        }
                    };
                }
            };
        }
    };
}

/// Like `TemplateHandler` but for HTML-only routes: there is nothing to negotiate, so the
/// inner handler's `OG.value` is rewrapped straight into the (now name-resolved) `Tmpl`
/// rather than a single-formatter `Many`. `Tmpl` renders it as the route's final response.
pub fn TemplateOnlyHandler(comptime Tmpl: type, comptime OG: type) type {
    return struct {
        pub fn create(comptime HandlerFac: anytype) type {
            return struct {
                pub fn make(comptime Base: anytype) type {
                    const Handler = HandlerFac(Base);
                    return struct {
                        pub const CallContext = Handler.CallContext;

                        pub const Dependencies = Handler.Dependencies;

                        pub fn call(
                            inj: *core.deps.DepCtx,
                            ctx: CallContext,
                            evprop: core.event.ExtendedProperties,
                        ) !*anyopaque {
                            const arena = try inj.require(core.mem.ScopedAllocator);
                            const allocator = arena.value;

                            const result: *anyopaque = try Handler.call(inj, ctx, evprop);
                            const actual: *OG = @ptrCast(@alignCast(result));

                            const tmpl: Tmpl = .{ .value = actual.value };

                            allocator.destroy(actual);
                            const slot = try allocator.create(Tmpl);
                            slot.* = tmpl;

                            return @ptrCast(@alignCast(slot));
                        }
                    };
                }
            };
        }
    };
}

/// An HTML-only template response. Unlike `http.data.Json`, a route returning `Html(T, statuses)`
/// is *only* ever rendered through its zmpl template — it carries no JSON representation and so
/// never content-negotiates. Use it for FE-only routes (page shells, htmx fragments, the JSON
/// pretty-printer) that expose nothing a separate frontend would consume.
///
/// Deliberately name-less: the template name is resolved by `WithTemplates` from the prefix key
/// and the route id (`<key>/<id>`), the same convention the JSON routes already use — so the route
/// never repeats it and the prefix is honored in one place. The `text/html` content type is the
/// signal `WithTemplates` keys on to take the HTML-only path. The value shape mirrors `Json` (a
/// status union over `ApiResult`) so templates can branch on `$.tag` (`ok` vs `not_found`)
/// identically; `WithTemplates` rewraps `.value` into the name-resolved `Template`, which renders it.
pub fn Html(comptime Result: type, comptime statuses: anytype) type {
    return struct {
        pub const ContentType = "text/html";
        value: http.data.ApiResult(Result, http.data.ProblemDetails, statuses),
    };
}

pub fn WithTemplates(comptime key: @Type(.enum_literal), comptime routes: []const type) []const type {
    var nroutes: [routes.len]type = undefined;

    for (routes, 0..) |R, i| {
        R.requires(.response);
        const OG = R.query(.response);
        const is_html = comptime std.mem.eql(u8, OG.ContentType, "text/html");
        const is_json = comptime std.mem.eql(u8, OG.ContentType, "application/json");
        // Anything else (e.g. a raw File) is served as-is.
        if (comptime !is_html and !is_json) {
            nroutes[i] = R;
            continue;
        }

        const tname = @tagName(key) ++ "/" ++ R.id;
        const result = comptime zmpl.find(tname);
        if (comptime result == null) {
            @compileError(std.fmt.comptimePrint(
                "[{s}] Could not find template for route '{s}'",
                .{ @tagName(key), R.id },
            ));
        }

        const Inner = @FieldType(OG, "value");
        const tmpl = Template(Inner, tname);

        if (comptime is_html) {
            // HTML-only: render straight through the template, no JSON, no negotiation.
            const TH = TemplateOnlyHandler(tmpl, OG);
            nroutes[i] = R.wrap(TH.create)
                .mod(.{ .response = tmpl });
        } else {
            // Dual: offer both formatters and content-negotiate between them.
            const M = Many(Inner, &.{ OG, tmpl });
            const TH = TemplateHandler(M, OG);
            nroutes[i] = R.wrap(TH.create)
                .mod(.{ .response = M });
        }
    }

    return &nroutes;
}
