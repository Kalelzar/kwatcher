const std = @import("std");

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

    kw_docgen.addOptions("build_config", o);

    const tests = b.addTest(.{
        .root_module = kw_docgen,
        .use_llvm = true,
    });

    // Artifacts:
    const exe = b.addExecutable(.{
        .name = if (module_only) "kw-modgen" else "kw-docgen",
        .root_module = kw_docgen,
        .linkage = .static,
        .use_llvm = true,
    });

    if (build_executable) {
        b.installArtifact(exe);
    }

    const run_tests = b.addRunArtifact(tests);

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
            "build.zig.zon",
        },
        .check = true,
    });

    // Steps:
    const check = b.step("check", "Build without generating artifacts.");
    check.dependOn(&exe.step);

    const test_step = b.step("test", "Run the unit tests.");
    test_step.dependOn(&run_tests.step);
    exe.step.dependOn(&run_tests.step);

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

    // Imports:
    // 1st Party:
    kw_docgen.addImport("kw-core", kw_core);
    kw_docgen.addImport("kwatcher", kwatcher);
}
