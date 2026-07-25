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
const zettel = @import("zettel");

pub fn build(b: *std.Build) !void {
    // Options
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_static_library = b.option(bool, "lib", "Build a static library object") orelse build_all;
    const include_metrics = b.option(bool, "metrics", "Include metrics generation in code.") orelse true;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const o = b.addOptions();
    o.addOption(bool, "enable_metrics", include_metrics);

    const kw_core = b.addModule("kw-core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    kw_core.addOptions("build_config", o);

    const tests = b.addTest(.{
        .root_module = kw_core,
        .use_llvm = true,
    });

    // Artifacts:
    const lib = b.addLibrary(.{
        .name = "kw-core",
        .root_module = kw_core,
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

    // Dependencies:
    // 1st Party:
    const klib = b.dependency("klib", .{ .target = target, .optimize = optimize }).module("klib");

    // 3rd Party:
    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");

    // Imports:
    // 3rd Party:
    kw_core.addImport("klib", klib);
    kw_core.addImport("metrics", metrics);

    // zettel schema codegen: schema/*.ztl -> the kw-core-schema module.
    // Nothing generated is checked in; dependents re-run zettel over the
    // same sources through the exported "schema-dir" named path.
    // Debug, deliberately: the schema compiler runs in ~50ms on these inputs,
    // while a ReleaseSafe build of it costs ~50s of LLVM at the head of the
    // build graph. Debug also skips LLVM entirely (self-hosted backend).
    const zettel_dep = b.dependency("zettel", .{ .optimize = .Debug });
    const kw_core_schema = zettel.schemaModule(b, zettel_dep, .{
        .source_dir = b.path("schema"),
        .root_module = "kwatcher:core",
        .check_step = check,
        .expose_as = "kw-core-schema",
        .target = target,
        .optimize = optimize,
    });
    kw_core.addImport("kw-core-schema", kw_core_schema);
    b.addNamedLazyPath("schema-dir", b.path("schema"));
}
