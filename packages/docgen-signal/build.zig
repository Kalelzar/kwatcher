const std = @import("std");

pub fn build(b: *std.Build) !void {
    // Options
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_static_library = b.option(bool, "lib", "Build a static library object") orelse build_all;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kw_docgen_signal = b.addModule("kw-docgen--signal", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const kw_docindex = b.dependency("kw_docindex", .{ .target = target, .optimize = optimize }).module("kw-docindex");
    kw_docgen_signal.addImport("kw-docindex", kw_docindex);

    // The runtime-facing signal introspection backend (kw-introspect--signal): a separate
    // module from the build-time `kw-docgen--signal` codegen above, so the host tool stays
    // free of kw-http/zmpl. Consumers import it and inject the wired `kw-http-template` +
    // generated `kw-gen--docs` at build time (neither is wired here — it compiles only in a
    // consumer).
    const kw_core = b.dependency("kw_core", .{ .target = target, .optimize = optimize }).module("kw-core");
    const kw_http = b.dependency("kw_http", .{ .target = target, .optimize = optimize }).module("kw-http");
    const kw_http_template = b.dependency("kw_http_template", .{ .target = target, .optimize = optimize }).module("kw-http-template");
    const kw_introspect_signal = b.addModule("kw-introspect--signal", .{
        .root_source_file = b.path("src/introspect/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    kw_introspect_signal.addImport("kw-core", kw_core);
    kw_introspect_signal.addImport("kw-http", kw_http);
    kw_introspect_signal.addImport("kw-http-template", kw_http_template);

    const tests = b.addTest(.{
        .root_module = kw_docgen_signal,
        .use_llvm = true,
    });

    // Artifacts:
    const lib = b.addLibrary(.{
        .name = "kw-docgen--signal",
        .root_module = kw_docgen_signal,
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
