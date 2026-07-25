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

/// Build-time helper for wiring template sources into a consumer's build graph.
/// Consumers reach it as `@import("kw_http_template").build_templates`.
pub const build_templates = @import("build_templates.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Forwarded verbatim to the zmpl dependency: which template sources to compile, in zmpl's
    // `prefix=...,path=...` format. Left unset, zmpl falls back to its default `src/templates`
    // scan so the package still builds standalone; real consumers pass their own sources via
    // `build_templates.wire`.
    const templates_paths = b.option(
        []const []const u8,
        "zmpl_templates_paths",
        "Directories to search for .zmpl templates. Format: `prefix=...,path=...`",
    );

    const kw_http_template = b.addModule("kw-http-template", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Dependencies:
    const kw_http = kwDependency(b, "kw_http", "kw_http_vendored", "http", .{ .target = target, .optimize = optimize }).module("kw-http");
    const kw_core = kwDependency(b, "kw_core", "kw_core_vendored", "core", .{ .target = target, .optimize = optimize }).module("kw-core");

    const zmpl = if (templates_paths) |paths|
        b.dependency("zmpl", .{ .target = target, .optimize = optimize, .zmpl_templates_paths = paths }).module("zmpl")
    else
        b.dependency("zmpl", .{ .target = target, .optimize = optimize }).module("zmpl");

    kw_http_template.addImport("kw-http", kw_http);
    kw_http_template.addImport("kw-core", kw_core);
    kw_http_template.addImport("zmpl", zmpl);

    // Artifacts / steps:
    const tests = b.addTest(.{ .root_module = kw_http_template, .use_llvm = true });
    const run_tests = b.addRunArtifact(tests);

    const fmt = b.addFmt(.{
        .paths = &.{ "src/", "build.zig", "build_templates.zig", "build.zig.zon" },
        .check = true,
    });

    const test_step = b.step("test", "Run the unit tests.");
    test_step.dependOn(&run_tests.step);

    const fmt_step = b.step("fmt", "Check formatting");
    fmt_step.dependOn(&fmt.step);
    b.getInstallStep().dependOn(fmt_step);

    const check = b.step("check", "Build without generating artifacts.");
    check.dependOn(&tests.step);
    check.dependOn(fmt_step);
}

fn kwWorkspace(b: *std.Build) bool {
    b.build_root.handle.access("../../.kw-workspace", .{}) catch return false;
    return true;
}

fn kwAccessible(b: *std.Build, comptime path: []const u8) bool {
    b.build_root.handle.access(path, .{}) catch return false;
    return true;
}

/// Resolve a kw dependency: prefer the sibling checkout (umbrella packages/
/// or another repo's flat vendor/ layout, gated on the ../../.kw-workspace
/// marker) so every consumer shares one module instance; fall back to this
/// package's own vendored submodule for standalone checkouts.
fn kwDependency(
    b: *std.Build,
    comptime sibling_dep: []const u8,
    comptime vendored_dep: []const u8,
    comptime dir_name: []const u8,
    args: anytype,
) *std.Build.Dependency {
    if (kwWorkspace(b) and kwAccessible(b, "../" ++ dir_name ++ "/build.zig.zon"))
        return b.dependency(sibling_dep, args);
    if (kwAccessible(b, "vendor/" ++ dir_name ++ "/build.zig.zon"))
        return b.dependency(vendored_dep, args);
    std.process.fatal(
        "kw dependency '{s}': neither ../{s} nor vendor/{s} is a valid checkout;" ++
            " run `git submodule update --init --recursive`",
        .{ sibling_dep, dir_name, dir_name },
    );
}
