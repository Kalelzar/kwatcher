const std = @import("std");

/// Build-time migration wiring for consumer apps (snapshot + embedded
/// committed migrations); use as `@import("kw_sqlite").build_migrations`.
pub const build_migrations = @import("build_migrations.zig");

pub fn build(b: *std.Build) !void {
    // Options
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_static_library = b.option(bool, "lib", "Build a static library object") orelse build_all;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kw_sqlite = b.addModule("kw-sqlite", .{
        .root_source_file = b.path("src/driver.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = kw_sqlite,
        .use_llvm = true,
    });

    // Artifacts:
    const lib = b.addLibrary(.{
        .name = "kw-sqlite",
        .root_module = kw_sqlite,
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
    const kw_core = b.dependency("kw_core", .{ .target = target, .optimize = optimize }).module("kw-core");
    const klib = b.dependency("klib", .{ .target = target, .optimize = optimize }).module("klib");
    // The ORM brings its own zqlite bindings and the vendored sqlite3 static
    // lib attached at module level, so no linkLibrary is needed here.
    const kw_orm_sqlite = b.dependency("kw_orm_sqlite", .{ .target = target, .optimize = optimize }).module("kw-orm-sqlite");

    // Imports:
    // 1st Party:
    kw_sqlite.addImport("kw-core", kw_core);
    kw_sqlite.addImport("klib", klib);
    kw_sqlite.addImport("kw-orm-sqlite", kw_orm_sqlite);
}
