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
