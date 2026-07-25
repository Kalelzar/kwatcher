// This file is part of the kwatcher project.
//
// Copyright (C) 2025-2026 Borislav Atanasov
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, version 3 of the License only.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const zmpl = @import("zmpl");
const core = @import("kw-core");
const http = @import("kw-http");

const Template = @import("template.zig").Template;

/// Pick a response content type from an Accept header. Deliberately not RFC-compliant: reads the
/// listed media types left to right, ignores q-weights and wildcards, and returns the first one we
/// actually offer. Falls back to `def` when nothing matches — e.g. a bare `*/*`, which we don't
/// honor.
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

/// Handler wrapper for a dual (negotiated) route: calls the inner handler, content-negotiates from
/// the Accept header, and rewraps the result's `value` into the `Many` (JSON + template).
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

/// Like `TemplateHandler` but for HTML-only routes: there is nothing to negotiate, so the inner
/// handler's `OG.value` is rewrapped straight into the (name-resolved) `Tmpl` rather than a
/// single-formatter `Many`. `Tmpl` renders it as the route's final response.
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

/// Rewrite a set of routes to render through zmpl templates, looked up within `prefix` (a template
/// source registered at build time — see `build_templates.wire`). For each route, by its response
/// `ContentType`:
///   - in `exclude` → left untouched (e.g. a raw `File`);
///   - `text/html` (an `http.data.Html` marker) → HTML-only via `TemplateOnlyHandler`;
///   - anything else → dual: `http.data.Many{ original-formatter, template }` content-negotiated.
/// The template for a route is `findPrefixed(prefix, R.id)`, so the route id is the template key.
pub fn WithTemplates(
    comptime prefix: []const u8,
    comptime routes: []const type,
    comptime exclude: []const []const u8,
) []const type {
    var nroutes: [routes.len]type = undefined;

    for (routes, 0..) |R, i| {
        R.requires(.response);
        const OG = R.query(.response);

        const excluded = comptime blk: {
            for (exclude) |ct| {
                if (std.mem.eql(u8, ct, OG.ContentType)) break :blk true;
            }
            break :blk false;
        };
        if (comptime excluded) {
            nroutes[i] = R;
            continue;
        }

        const is_html = comptime std.mem.eql(u8, OG.ContentType, "text/html");

        const result = comptime zmpl.findPrefixed(prefix, R.id);
        if (comptime result == null) {
            @compileError(std.fmt.comptimePrint(
                "[{s}] Could not find template for route '{s}'",
                .{ prefix, R.id },
            ));
        }

        const Inner = @FieldType(OG, "value");
        const Tmpl = Template(prefix, Inner, R.id);

        if (comptime is_html) {
            // HTML pages/fragments are the bulk of the UI's byte weight, so render them through
            // `Gzip`. `Gzip(Tmpl)` keeps `Tmpl`'s single `value` field and `text/html` content
            // type, so the name-resolving handler builds it exactly like a bare `Tmpl`.
            //const Gz = http.data.Gzip(Tmpl);
            const TH = TemplateOnlyHandler(Tmpl, OG);
            nroutes[i] = R.wrap(TH.create)
                .mod(.{ .response = Tmpl });
        } else {
            const M = http.data.Many(Inner, &.{ OG, Tmpl });
            const TH = TemplateHandler(M, OG);
            nroutes[i] = R.wrap(TH.create)
                .mod(.{ .response = M });
        }
    }

    return &nroutes;
}

comptime {
    _ = &WithTemplates;
    _ = &TemplateHandler;
    _ = &TemplateOnlyHandler;
    _ = &negotiate;
}
