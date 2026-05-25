const std = @import("std");

pub fn benchmarks(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
) !*std.Build.Step {
    const name: []const []const u8 = &.{
        "memCacheN",
        "memCacheNFull",
        "memCacheNFullLinear",
        "memCacheNFullRandom",
        "memCacheNWithLRU",
        "memCacheNWithTTL",
        "memCacheNWithLRUThenTTL",
        "memGetNLinear",
        "memGetNLinearWithLRU",
        "memGetNRandom",
        "memGetNRandomWithLRU",
        "fileCacheN",
        "fileCacheNWithLRU",
        "tierCacheN",
    };
    const step = b.step("benchmark", "Builds various benchmarks.");

    inline for (name) |n| {
        const file = "src/benchmark/cache/" ++ n ++ ".zig";
        const bench_mod = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
        });

        bench_mod.addImport("kwatcher", lib_mod);

        const bench_exe = b.addExecutable(.{
            .name = n,
            .root_module = bench_mod,
        });

        const install = b.addInstallArtifact(bench_exe, .{});

        step.dependOn(&install.step);
    }

    return step;
}

pub fn build(b: *std.Build) !void {
    // Options
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_example = b.option(bool, "example", "Build the example application") orelse build_all;
    const build_kwev = b.option(bool, "kwev", "Build the kwev tooling ") orelse build_all;
    const build_static_library = b.option(bool, "lib", "Build a static library object") orelse build_all;
    const include_metrics = b.option(bool, "metrics", "Include metrics generation in code.") orelse true;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const o = b.addOptions();
    o.addOption(bool, "enable_metrics", include_metrics);

    const kwatcher_library = b.addModule("kwatcher", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    kwatcher_library.addOptions("build_config", o);

    const kwatcher_example = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .dwarf_format = .@"64",
        .link_libc = false,
        .omit_frame_pointer = false,
    });

    const kwatcher_kwev = b.createModule(.{
        .root_source_file = b.path("src/kwev.zig"),
        .target = target,
        .optimize = optimize,
        .dwarf_format = .@"64",
        .link_libc = false,
        .omit_frame_pointer = false,
    });

    const tests = b.addTest(.{
        .root_module = kwatcher_library,
        .use_llvm = true,
    });

    // Artifacts:
    const example = b.addExecutable(.{
        .name = "kwatcher-example",
        .root_module = kwatcher_example,
        .use_llvm = true, // Due to https://github.com/ziglang/zig/issues/24181
    });
    if (build_example) {
        b.installArtifact(example);
    }

    const kwev = b.addExecutable(.{
        .name = "kwev",
        .root_module = kwatcher_kwev,
        .use_llvm = true, // Due to https://github.com/ziglang/zig/issues/24181
    });
    if (build_kwev) {
        b.installArtifact(kwev);
    }

    const lib = b.addLibrary(.{
        .name = "kwatcher",
        .root_module = kwatcher_library,
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
    check.dependOn(&example.step);
    check.dependOn(&kwev.step);

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

    const bench_step = try benchmarks(b, target, optimize, kwatcher_library);
    bench_step.dependOn(&lib.step);

    // Dependencies:
    // 1st Party:
    const klib = b.dependency("klib", .{ .target = target, .optimize = optimize }).module("klib");

    // 3rd Party:
    const zamqp = b.dependency("zamqp", .{ .target = target, .optimize = optimize }).module("zamqp");
    const uuid = b.dependency("uuid", .{ .target = target, .optimize = optimize }).module("uuid");
    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize }).module("httpz");

    // Imports:
    // Internal:
    kwatcher_example.addImport("kwatcher", kwatcher_library);
    kwatcher_kwev.addImport("kwatcher", kwatcher_library);

    // 1st Party:
    kwatcher_library.addImport("klib", klib);
    kwatcher_example.addImport("klib", klib);

    // 3rd Party:
    kwatcher_library.addImport("zamqp", zamqp);
    kwatcher_library.addImport("uuid", uuid);
    kwatcher_library.addImport("metrics", metrics);
    kwatcher_library.addImport("httpz", httpz);
    kwatcher_example.addImport("httpz", httpz);
}
