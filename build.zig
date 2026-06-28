const std = @import("std");
const docgen = @import("kw_docgen").build_docgen;

pub fn build(b: *std.Build) !void {
    // Options
    const build_all = b.option(bool, "all", "Build all components. You can still disable individual components") orelse false;
    const build_example = b.option(bool, "example", "Build the example application") orelse build_all;
    const build_kwev = b.option(bool, "kwev", "Build the kwev tooling ") orelse build_all;
    const openapi_version = b.option([]const u8, "openapi_version", "Target OpenAPI version for HTTP docgen") orelse "3.2.0";
    const asyncapi_version = b.option([]const u8, "asyncapi_version", "Target AsyncAPI version for AMQP docgen") orelse "3.0.0";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    check.dependOn(&example.step);
    check.dependOn(&kwev.step);

    // - fmt
    const fmt_step = b.step("fmt", "Check formatting");
    fmt_step.dependOn(&fmt.step);
    check.dependOn(fmt_step);
    b.getInstallStep().dependOn(fmt_step);

    // Dependencies:
    // 1st Party:
    const kw_core = b.dependency("kw_core", .{ .target = target, .optimize = optimize }).module("kw-core");
    const kwatcher = b.dependency("kwatcher", .{ .target = target, .optimize = optimize }).module("kwatcher");
    const kw_amqp = b.dependency("kw_amqp", .{ .target = target, .optimize = optimize }).module("kw-amqp");
    const kw_http = b.dependency("kw_http", .{ .target = target, .optimize = optimize }).module("kw-http");
    const kw_cron = b.dependency("kw_cron", .{ .target = target, .optimize = optimize }).module("kw-cron");
    const kw_action = b.dependency("kw_action", .{ .target = target, .optimize = optimize }).module("kw-action");
    const kw_signal = b.dependency("kw_signal", .{ .target = target, .optimize = optimize }).module("kw-signal");
    const kw_kwev = b.dependency("kw_kwev", .{ .target = target, .optimize = optimize }).module("kw-kwev");

    const kw_docgen_none = b.dependency("kw_docgen_none", .{
        .target = target,
        .optimize = optimize,
    }).module("kw-docgen--none");

    const kw_docgen_http = b.dependency("kw_docgen_http", .{
        .target = target,
        .optimize = optimize,
        .openapi_version = openapi_version,
    }).module("kw-docgen--http");

    const kw_docgen_amqp = b.dependency("kw_docgen_amqp", .{
        .target = target,
        .optimize = optimize,
        .asyncapi_version = asyncapi_version,
    }).module("kw-docgen--amqp");

    // 3rd Party:
    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize }).module("httpz");
    const zmpl_d = b.dependency("zmpl", .{ .target = target, .optimize = optimize });
    const zmpl = zmpl_d.module("zmpl");

    // Imports:
    // Example application:
    kwatcher_example.addImport("kw-core", kw_core);
    kwatcher_example.addImport("kwatcher", kwatcher);
    kwatcher_example.addImport("kw-amqp", kw_amqp);
    kwatcher_example.addImport("kw-http", kw_http);
    kwatcher_example.addImport("kw-cron", kw_cron);
    kwatcher_example.addImport("kw-action", kw_action);
    kwatcher_example.addImport("kw-signal", kw_signal);
    kwatcher_example.addImport("httpz", httpz);
    kwatcher_example.addImport("zmpl", zmpl);

    // Docgen: wired after the example's imports are in place so the helper can mirror
    // them onto the host-target entrypoint it derives internally. This also adds the
    // generated `kw-gen--docs` module to `kwatcher_example`.
    const docs = docgen.wire(b, .{
        .target = target,
        .optimize = optimize,
        .consumer = kwatcher_example,
        .backends = &.{
            .{ .kind = "http", .module = kw_docgen_http },
            .{ .kind = "cron", .module = kw_docgen_none },
            .{ .kind = "amqp", .module = kw_docgen_amqp },
            .{ .kind = "action", .module = kw_docgen_none },
            .{ .kind = "signal", .module = kw_docgen_none },
            .{ .kind = "internal", .module = kw_docgen_none },
        },
    });

    example.step.dependOn(&docs.docgen_step.step);

    // kwev tooling:
    kwatcher_kwev.addImport("kw-kwev", kw_kwev);
}
