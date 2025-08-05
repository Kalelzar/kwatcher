const std = @import("std");

const Builder = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
    check_step: *std.Build.Step,
    kwatcher: *std.Build.Module,
    kwatcher_example: *std.Build.Module,
    kwatcher_dump: *std.Build.Module,
    kwatcher_test: *std.Build.Module,

    fn init(b: *std.Build) Builder {
        const target = b.standardTargetOptions(.{});
        const opt = b.standardOptimizeOption(.{});

        const check_step = b.step("check", "");

        const klib = b.dependency("klib", .{ .target = target, .optimize = opt }).module("klib");
        const rmq = b.dependency("rabbitmq_c", .{ .target = target, .optimize = opt }).artifact("rabbitmq-c-static");
        const zamqp = b.dependency("zamqp", .{ .target = target, .optimize = opt }).module("zamqp");
        const uuid = b.dependency("uuid", .{ .target = target, .optimize = opt }).module("uuid");
        const metrics = b.dependency("metrics", .{ .target = target, .optimize = opt }).module("metrics");
        const kwatcher = b.addModule("kwatcher", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = opt,
        });
        kwatcher.addImport("zamqp", zamqp);
        kwatcher.addImport("uuid", uuid);
        kwatcher.addImport("metrics", metrics);
        kwatcher.addImport("klib", klib);
        kwatcher.linkLibrary(rmq);
        kwatcher.link_libc = true;

        const kwatcher_test = b.addModule("test", .{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = opt,
        });
        kwatcher_test.addImport("zamqp", zamqp);
        kwatcher_test.addImport("uuid", uuid);
        kwatcher_test.addImport("metrics", metrics);
        kwatcher_test.addImport("klib", klib);
        kwatcher_test.link_libc = true;

        const kwatcher_example = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = opt,
        });
        kwatcher_example.link_libc = true;
        kwatcher_example.addImport("kwatcher", kwatcher);

        const kwatcher_dump = b.createModule(.{
            .root_source_file = b.path("src/tools/dmp.zig"),
            .target = target,
            .optimize = opt,
        });
        kwatcher_dump.link_libc = true;
        kwatcher_dump.addImport("kwatcher", kwatcher);

        return .{
            .b = b,
            .check_step = check_step,
            .target = target,
            .opt = opt,
            .kwatcher = kwatcher,
            .kwatcher_example = kwatcher_example,
            .kwatcher_test = kwatcher_test,
            .kwatcher_dump = kwatcher_dump,
        };
    }

    fn addDependencies(
        self: *Builder,
        step: *std.Build.Step.Compile,
    ) void {
        _ = self;
        step.linkLibC();
    }

    fn addExecutable(self: *Builder, name: []const u8, root_module: *std.Build.Module) *std.Build.Step.Compile {
        return self.b.addExecutable(.{
            .name = name,
            .root_module = root_module,
        });
    }

    fn addStaticLibrary(self: *Builder, name: []const u8, root_module: *std.Build.Module) *std.Build.Step.Compile {
        return self.b.addStaticLibrary(.{
            .name = name,
            .root_module = root_module,
        });
    }

    fn addTest(self: *Builder, name: []const u8, root_module: *std.Build.Module) *std.Build.Step.Compile {
        return self.b.addTest(.{
            .name = name,
            .root_module = root_module,
        });
    }

    fn installAndCheck(self: *Builder, exe: *std.Build.Step.Compile) !void {
        const check_exe = try self.b.allocator.create(std.Build.Step.Compile);
        check_exe.* = exe.*;
        self.check_step.dependOn(&check_exe.step);
        self.b.installArtifact(exe);
    }
};

pub fn build(b: *std.Build) !void {
    var builder = Builder.init(b);

    const lib = builder.addStaticLibrary("kwatcher", builder.kwatcher);
    builder.addDependencies(lib);
    try builder.installAndCheck(lib);

    const exe = builder.addExecutable("kwatcher-examples", builder.kwatcher_example);
    builder.addDependencies(exe);
    try builder.installAndCheck(exe);

    const dmp = builder.addExecutable("kwatcher-dmp", builder.kwatcher_dump);
    builder.addDependencies(dmp);
    try builder.installAndCheck(dmp);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const lib_unit_tests = b.addTest(.{
        .root_module = builder.kwatcher_test,
        .name = "test",
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const install_docs = b.addInstallDirectory(
        .{ .source_dir = lib.getEmittedDocs(), .install_dir = .prefix, .install_subdir = "docs" },
    );
    const docs_step = b.step("docs", "Generate docs");
    docs_step.dependOn(&install_docs.step);
    docs_step.dependOn(&lib.step);
}
