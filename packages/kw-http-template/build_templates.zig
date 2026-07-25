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

/// One template source: a `prefix` namespace and the directory `path` (as path segments) that
/// contains its `.zmpl` files. The prefix keeps each contributing source separate — templates are
/// looked up with `zmpl.findPrefixed(prefix, key)`, so two sources can ship same-named templates
/// without colliding.
pub const TemplateSource = struct {
    prefix: []const u8,
    path: []const []const u8,
};

pub const WireOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sources: []const TemplateSource,
};

/// Wire a consumer up to the `kw-http-template` module with a zmpl instance whose manifest covers
/// `opts.sources`. Resolves each source to zmpl's `prefix=...,path=ABSPATH` format (paths relative
/// to the build cwd) and forwards them to the package's `zmpl_templates_paths` option.
pub fn wire(b: *std.Build, opts: WireOptions) *std.Build.Module {
    return b.dependency("kw_http_template", .{
        .target = opts.target,
        .optimize = opts.optimize,
        .zmpl_templates_paths = resolvePaths(b, opts.sources),
    }).module("kw-http-template");
}

/// Build a `TemplateSource` for a directory that ships *inside a dependency package* (e.g. a
/// backend's bundled `templates/`), resolved to an absolute path under the dep's build root.
/// zmpl realpaths template dirs at configure time, and path deps exist on disk then, so this
/// hands `wire` an already-absolute path that `resolvePaths` passes straight through.
pub fn packageSource(
    dep: *std.Build.Dependency,
    prefix: []const u8,
    subpath: []const []const u8,
) TemplateSource {
    const a = dep.builder.allocator;
    const root = dep.builder.build_root.path orelse @panic("kw-http-template: dependency has no build root path");

    var parts = a.alloc([]const u8, subpath.len + 1) catch @panic("OOM");
    parts[0] = root;
    for (subpath, 0..) |s, i| parts[i + 1] = s;
    const joined = std.fs.path.join(a, parts) catch @panic("OOM");

    const seg = a.alloc([]const u8, 1) catch @panic("OOM");
    seg[0] = joined;
    return .{ .prefix = prefix, .path = seg };
}

/// Mirror of zmpl's own `templatesPaths` (which is private to its build.zig): join each source's
/// path segments, make it absolute relative to the build cwd, and emit zmpl's option syntax. A
/// missing directory becomes `_`, which zmpl skips with a warning.
fn resolvePaths(b: *std.Build, sources: []const TemplateSource) []const []const u8 {
    const a = b.allocator;
    const out = a.alloc([]const u8, sources.len) catch @panic("OOM");
    for (sources, 0..) |src, i| {
        const joined = std.fs.path.join(a, src.path) catch @panic("OOM");
        const absolute = if (std.fs.path.isAbsolute(joined))
            joined
        else
            std.fs.cwd().realpathAlloc(a, joined) catch |err| switch (err) {
                error.FileNotFound => "_",
                else => @panic("kw-http-template: failed to resolve template path"),
            };
        out[i] = std.mem.concat(a, u8, &.{ "prefix=", src.prefix, ",path=", absolute }) catch @panic("OOM");
    }
    return out;
}
