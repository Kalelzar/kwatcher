const std = @import("std");

pub fn build(b: *std.Build) !void {
    // Options
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_example = b.option(bool, "example", "Build the example application") orelse build_all;
    const build_static_library = b.option(bool, "lib", "Build a static library object") orelse build_all;
    const build_dump_tool = b.option(bool, "dump", "Build the dump tool") orelse build_all;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kwatcher_library = b.addModule("kwatcher", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const kwatcher_example = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const kwatcher_dump = b.createModule(.{
        .root_source_file = b.path("src/tools/dmp.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = kwatcher_library,
    });

    // Artifacts:
    const example = b.addExecutable(.{
        .name = "kwatcher-example",
        .root_module = kwatcher_example,
    });
    if (build_example) {
        b.installArtifact(example);
    }

    const dump = b.addExecutable(.{
        .name = "kwatcher-dmp",
        .root_module = kwatcher_dump,
    });
    if (build_dump_tool) {
        b.installArtifact(dump);
    }

    const lib = b.addLibrary(.{
        .name = "kwatcher",
        .root_module = kwatcher_library,
        .linkage = .static,
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
    check.dependOn(&example.step);
    check.dependOn(&dump.step);

    const test_step = b.step("test", "Run the unit tests.");
    test_step.dependOn(&run_tests.step);
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
    const zamqp = b.dependency("zamqp", .{ .target = target, .optimize = optimize }).module("zamqp");
    const uuid = b.dependency("uuid", .{ .target = target, .optimize = optimize }).module("uuid");
    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    // Imports:
    // Internal:
    kwatcher_example.addImport("kwatcher", kwatcher_library);
    kwatcher_dump.addImport("kwatcher", kwatcher_library);
    // 1st Party:
    kwatcher_library.addImport("klib", klib);
    // 3rd Party:
    kwatcher_library.addImport("zamqp", zamqp);
    kwatcher_library.addImport("uuid", uuid);
    kwatcher_library.addImport("metrics", metrics);
}
