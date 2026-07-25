const std = @import("std");

/// Build-time helper for wiring the docgen pipeline into a consumer's build graph.
/// Consumers reach it as `@import("kw_docgen").build_docgen`.
pub const build_docgen = @import("build_docgen.zig");

pub fn build(b: *std.Build) !void {
    // Options
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_executable = b.option(bool, "exe", "Build an executable") orelse build_all;
    const include_metrics = b.option(bool, "metrics", "Include metrics generation in code.") orelse true;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const o = b.addOptions();
    o.addOption(bool, "enable_metrics", include_metrics);
    // Keeps this options module content-distinct from the kwatcher packages'
    // `build_config` (which is also just enable_metrics): zig caches options
    // by content, and two module names rooted at the same generated file in
    // one compilation is a hard "file exists in modules" error. `module_only`
    // used to provide the distinction before kw-modgen was removed.
    o.addOption([]const u8, "package", "kw-docgen");

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

    // Self-hosted backend for Debug-at-musl, LLVM otherwise: musl is what
    // keeps the self-hosted linker away from the system glibc CRT (.sframe
    // sections it can't process), and the backend is Debug-quality — release
    // builds want LLVM's optimizer. The old LLVM pin (u128 queue atomics,
    // ziglang/zig#24181) is dead since kw-core's queue header went u64.
    const no_llvm = target.result.abi == .musl and optimize == .Debug;

    const tests = b.addTest(.{
        .root_module = kw_docgen,
        .use_llvm = !no_llvm,
    });

    const docschema_tests = b.addTest(.{
        .root_module = kw_docschema,
        .use_llvm = !no_llvm,
    });

    const docexample_tests = b.addTest(.{
        .root_module = kw_docexample,
        .use_llvm = !no_llvm,
    });

    // Artifacts:
    const exe = b.addExecutable(.{
        .name = "kw-docgen",
        .root_module = kw_docgen,
        // Static under musl: dynamic musl would need /lib/ld-musl on the
        // host, and the whole point of musl here is keeping the self-hosted
        // linker away from the system glibc objects.
        .linkage = if (target.result.abi == .musl) .static else .dynamic,
        .use_llvm = !no_llvm,
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

    // The exe deliberately does NOT depend on the test runs: the orchestrator
    // tests compile the consumer's whole app graph (they import `entrypoint`),
    // and gating the generator on them serializes ~20s of test compile ahead
    // of the codegen chain. Consumers reach this `test` step through
    // `build_docgen.wire`'s Result and run it in parallel instead.
    const test_step = b.step("test", "Run the unit tests.");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_docschema_tests.step);
    test_step.dependOn(&run_docexample_tests.step);

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

    // The runtime-facing introspection UI core (kw-introspect). Deliberately a separate
    // module from the build-time codegen tool above, with its own root source and import
    // edges, so the host-target `kw-docgen` exe never drags in kw-http/zmpl. Consumers import
    // it and, at build time, override `kw-http-template` with their wired instance (whose zmpl
    // manifest covers the introspect template prefixes) and inject the generated `kw-gen--docs`
    // — neither is wired here, so the module compiles only inside a consumer's graph.
    const kw_http = b.dependency("kw_http", .{ .target = target, .optimize = optimize }).module("kw-http");
    const kw_http_template = b.dependency("kw_http_template", .{ .target = target, .optimize = optimize }).module("kw-http-template");
    const kw_introspect = b.addModule("kw-introspect", .{
        .root_source_file = b.path("src/introspect/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    kw_introspect.addImport("kw-core", kw_core);
    kw_introspect.addImport("kw-http", kw_http);
    kw_introspect.addImport("kw-auth-oidc", b.dependency("kw_auth_oidc", .{ .target = target, .optimize = optimize }).module("kw-auth-oidc"));
    kw_introspect.addImport("kw-http-template", kw_http_template);
    // The hardcoded private mount (private_mount.zig) wires its config deps via kwatcher.default.
    // The `kwatcher` module dep is already declared (build.zig.zon) and bound above; this is
    // acyclic — kwatcher imports no introspect package.
    kw_introspect.addImport("kwatcher", kwatcher);
}
