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

pub fn build(b: *std.Build) !void {
    // Options
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_static_library = b.option(bool, "lib", "Build a static library object") orelse build_all;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kw_docgen_cron = b.addModule("kw-docgen--cron", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const kw_docindex = b.dependency("kw_docindex", .{ .target = target, .optimize = optimize }).module("kw-docindex");
    kw_docgen_cron.addImport("kw-docindex", kw_docindex);

    // The runtime-facing cron introspection backend (kw-introspect--cron): a separate module
    // from the build-time `kw-docgen--cron` codegen above, so the host tool stays free of
    // kw-http/zmpl. Consumers import it and inject the wired `kw-http-template` + generated
    // `kw-gen--docs` at build time (neither is wired here — it compiles only in a consumer).
    const kw_core = b.dependency("kw_core", .{ .target = target, .optimize = optimize }).module("kw-core");
    const kw_http = b.dependency("kw_http", .{ .target = target, .optimize = optimize }).module("kw-http");
    const kw_http_template = b.dependency("kw_http_template", .{ .target = target, .optimize = optimize }).module("kw-http-template");
    const kw_cron = b.dependency("kw_cron", .{ .target = target, .optimize = optimize }).module("kw-cron");
    const kw_introspect_cron = b.addModule("kw-introspect--cron", .{
        .root_source_file = b.path("src/introspect/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    kw_introspect_cron.addImport("kw-core", kw_core);
    kw_introspect_cron.addImport("kw-http", kw_http);
    kw_introspect_cron.addImport("kw-http-template", kw_http_template);
    kw_introspect_cron.addImport("kw-cron", kw_cron);

    const tests = b.addTest(.{
        .root_module = kw_docgen_cron,
        .use_llvm = true,
    });

    // Artifacts:
    const lib = b.addLibrary(.{
        .name = "kw-docgen--cron",
        .root_module = kw_docgen_cron,
        .linkage = .static,
        .use_llvm = true,
    });
    if (build_static_library) {
        b.installArtifact(lib);
    }

    const run_tests = b.addRunArtifact(tests);

    const install_docs = b.addInstallDirectory(
        .{
            .source_dir = lib.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        },
    );

    const fmt = b.addFmt(.{
        .paths = &.{
            "src/",
            "build.zig",
            "build.zig.zon",
        },
        .check = true,
    });

    // Steps:
    const check = b.step("check", "Build without generating artifacts.");
    check.dependOn(&lib.step);

    const test_step = b.step("test", "Run the unit tests.");
    test_step.dependOn(&run_tests.step);
    lib.step.dependOn(&run_tests.step);

    // - fmt
    const fmt_step = b.step("fmt", "Check formatting");
    fmt_step.dependOn(&fmt.step);
    check.dependOn(fmt_step);
    b.getInstallStep().dependOn(fmt_step);

    // - docs
    const docs_step = b.step("docs", "Generate docs");
    docs_step.dependOn(&install_docs.step);
    docs_step.dependOn(&lib.step);
}
