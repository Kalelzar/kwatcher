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
    const kw_http = b.dependency("kw_http", .{ .target = target, .optimize = optimize }).module("kw-http");
    const kw_core = b.dependency("kw_core", .{ .target = target, .optimize = optimize }).module("kw-core");

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
