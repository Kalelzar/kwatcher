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

    const kw_docgen_sqlite = b.addModule("kw-docgen--sqlite", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const kw_docindex = b.dependency("kw_docindex", .{ .target = target, .optimize = optimize }).module("kw-docindex");
    kw_docgen_sqlite.addImport("kw-docindex", kw_docindex);

    // The runtime-facing sqlite introspection backend (kw-introspect--sqlite): a separate
    // module from the build-time `kw-docgen--sqlite` codegen above, so the host tool stays
    // free of kw-http/zmpl (and of kw-sqlite — the codegen module must never pull a second
    // kw-orm-sqlite instance into the generator graph). Consumers import it and inject the
    // wired `kw-http-template` + generated `kw-gen--docs` at build time (neither is wired
    // here — it compiles only in a consumer).
    const kw_core = b.dependency("kw_core", .{ .target = target, .optimize = optimize }).module("kw-core");
    const kw_http = b.dependency("kw_http", .{ .target = target, .optimize = optimize }).module("kw-http");
    const kw_http_template = b.dependency("kw_http_template", .{ .target = target, .optimize = optimize }).module("kw-http-template");
    const kw_sqlite = b.dependency("kw_sqlite", .{ .target = target, .optimize = optimize }).module("kw-sqlite");
    const kw_introspect_sqlite = b.addModule("kw-introspect--sqlite", .{
        .root_source_file = b.path("src/introspect/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    kw_introspect_sqlite.addImport("kw-core", kw_core);
    kw_introspect_sqlite.addImport("kw-http", kw_http);
    kw_introspect_sqlite.addImport("kw-http-template", kw_http_template);
    kw_introspect_sqlite.addImport("kw-sqlite", kw_sqlite);

    const tests = b.addTest(.{
        .root_module = kw_docgen_sqlite,
        .use_llvm = true,
    });

    // Artifacts:
    const lib = b.addLibrary(.{
        .name = "kw-docgen--sqlite",
        .root_module = kw_docgen_sqlite,
        .linkage = .static,
        .use_llvm = true,
    });
    if (build_static_library) {
        b.installArtifact(lib);
    }

    // The commit tool: promotes a generated candidate migration into the
    // consumer's migrations directory (run via `zig build commit-migration`).
    const commit_tool = b.addExecutable(.{
        .name = "kw-sqlite-commit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/commit.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    b.installArtifact(commit_tool);

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
