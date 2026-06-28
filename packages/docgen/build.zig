const std = @import("std");

/// Build-time helper for wiring the docgen pipeline into a consumer's build graph.
/// Consumers reach it as `@import("kw_docgen").build_docgen`.
pub const build_docgen = @import("build_docgen.zig");

pub fn build(b: *std.Build) !void {
    // Options
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_executable = b.option(bool, "exe", "Build an executable") orelse build_all;
    const include_metrics = b.option(bool, "metrics", "Include metrics generation in code.") orelse true;
    const module_only = b.option(bool, "module_only", "Generate only modules.") orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const o = b.addOptions();
    o.addOption(bool, "enable_metrics", include_metrics);
    o.addOption(bool, "module_only", module_only);

    const kw_docgen = b.addModule("kw-docgen", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const kw_docgen_dummy = b.addModule("dummy", .{
        .root_source_file = b.path("src/dummy.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = kw_docgen_dummy;

    kw_docgen.addOptions("build_config", o);

    // The protocol-agnostic JSON-Schema kernel (model nodes + reflection), exposed
    // as its own module so docgen backends (http, amqp, …) can share one copy
    // without dragging in the orchestrator's build-time `entrypoint`/`kw-gen--modules`
    // imports. Its only dependency is the doc-comment index.
    const kw_docschema = b.addModule("kw-docschema", .{
        .root_source_file = b.path("src/schema/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Backend-agnostic example-value generation: synthesize a neutral sample from a
    // `Schema`, then serialize it per content type. Sits one layer above the schema
    // kernel; shared by every backend that emits examples into its runtime projection.
    const kw_docexample = b.addModule("kw-docexample", .{
        .root_source_file = b.path("src/example/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    kw_docexample.addImport("kw-docschema", kw_docschema);

    const tests = b.addTest(.{
        .root_module = kw_docgen,
        .use_llvm = true,
    });

    const docschema_tests = b.addTest(.{
        .root_module = kw_docschema,
        .use_llvm = true,
    });

    const docexample_tests = b.addTest(.{
        .root_module = kw_docexample,
        .use_llvm = true,
    });

    // Artifacts:
    const exe = b.addExecutable(.{
        .name = if (module_only) "kw-modgen" else "kw-docgen",
        .root_module = kw_docgen,
        .linkage = .dynamic,
        .use_llvm = true,
    });

    if (build_executable) {
        b.installArtifact(exe);
    }

    const run_tests = b.addRunArtifact(tests);
    const run_docschema_tests = b.addRunArtifact(docschema_tests);
    const run_docexample_tests = b.addRunArtifact(docexample_tests);

    const install_docs = b.addInstallDirectory(
        .{
            .source_dir = exe.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        },
    );

    const fmt = b.addFmt(.{
        .paths = &.{
            "src/",
            "build.zig",
            "build_docgen.zig",
            "build.zig.zon",
        },
        .check = true,
    });

    // Steps:
    const check = b.step("check", "Build without generating artifacts.");
    check.dependOn(&exe.step);

    const test_step = b.step("test", "Run the unit tests.");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_docschema_tests.step);
    test_step.dependOn(&run_docexample_tests.step);
    exe.step.dependOn(&run_tests.step);

    // The orchestrator module imports the build-time-injected `entrypoint` /
    // `kw-gen--modules`, so it only compiles once `build_docgen.wire` runs. The
    // schema kernel has no such dependency — this step runs its tests standalone.
    const schema_test_step = b.step("test-schema", "Run the kw-docschema unit tests.");
    schema_test_step.dependOn(&run_docschema_tests.step);

    // Likewise standalone — kw-docexample depends only on the schema kernel.
    const example_test_step = b.step("test-example", "Run the kw-docexample unit tests.");
    example_test_step.dependOn(&run_docexample_tests.step);

    // - fmt
    const fmt_step = b.step("fmt", "Check formatting");
    fmt_step.dependOn(&fmt.step);
    check.dependOn(fmt_step);
    b.getInstallStep().dependOn(fmt_step);

    // - docs
    const docs_step = b.step("docs", "Generate docs");
    docs_step.dependOn(&install_docs.step);
    docs_step.dependOn(&exe.step);

    // Dependencies:
    // 1st Party:
    const kw_core = b.dependency("kw_core", .{ .target = target, .optimize = optimize }).module("kw-core");
    const kwatcher = b.dependency("kwatcher", .{ .target = target, .optimize = optimize }).module("kwatcher");
    const kw_docindex = b.dependency("kw_docindex", .{ .target = target, .optimize = optimize }).module("kw-docindex");

    // Imports:
    // 1st Party:
    kw_docgen.addImport("kw-core", kw_core);
    kw_docgen.addImport("kwatcher", kwatcher);
    kw_docgen.addImport("kw-docindex", kw_docindex);

    kw_docschema.addImport("kw-docindex", kw_docindex);
}
