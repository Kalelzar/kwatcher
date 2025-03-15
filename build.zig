const std = @import("std");

const Builder = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
    check_step: *std.Build.Step,
    klib: *std.Build.Module,
    zamqp: *std.Build.Module,
    uuid: *std.Build.Module,
    metrics: *std.Build.Module,
    kwatcher: *std.Build.Module,
    kwatcher_example: *std.Build.Module,

    fn init(b: *std.Build) Builder {
        const target = b.standardTargetOptions(.{});
        const opt = b.standardOptimizeOption(.{});

        const check_step = b.step("check", "");

        const klib = b.dependency("klib", .{ .target = target, .optimize = opt }).module("klib");
        const zamqp = b.dependency("zamqp", .{ .target = target, .optimize = opt }).module("zamqp");
        const uuid = b.dependency("uuid", .{ .target = target, .optimize = opt }).module("uuid");
        const metrics = b.dependency("metrics", .{ .target = target, .optimize = opt }).module("metrics");
        const kwatcher = b.addModule("kwatcher", .{
            .root_source_file = b.path("src/watcher.zig"),
        });
        kwatcher.addImport("zamqp", zamqp);
        kwatcher.addImport("uuid", uuid);
        kwatcher.addImport("metrics", metrics);
        kwatcher.addImport("klib", klib);
        kwatcher.link_libc = true;

        const kwatcher_example = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
        });
        kwatcher_example.link_libc = true;

        return .{
            .b = b,
            .check_step = check_step,
            .target = target,
            .opt = opt,
            .zamqp = zamqp,
            .uuid = uuid,
            .kwatcher = kwatcher,
            .kwatcher_example = kwatcher_example,
            .metrics = metrics,
            .klib = klib,
        };
    }

    fn addDependencies(
        self: *Builder,
        step: *std.Build.Step.Compile,
    ) void {
        step.linkLibC();
        step.addLibraryPath(.{ .cwd_relative = "." });
        step.addLibraryPath(.{ .cwd_relative = "." });
        step.linkSystemLibrary("rabbitmq");
        step.root_module.addImport("zamqp", self.zamqp);
        step.root_module.addImport("uuid", self.uuid);
        step.root_module.addImport("metrics", self.metrics);
        step.root_module.addImport("klib", self.klib);
    }

    fn addExecutable(self: *Builder, name: []const u8, root_source_file: []const u8) *std.Build.Step.Compile {
        return self.b.addExecutable(.{
            .name = name,
            .root_source_file = self.b.path(root_source_file),
            .target = self.target,
            .optimize = self.opt,
        });
    }

    fn addStaticLibrary(self: *Builder, name: []const u8, root_source_file: []const u8) *std.Build.Step.Compile {
        return self.b.addStaticLibrary(.{
            .name = name,
            .root_source_file = self.b.path(root_source_file),
            .target = self.target,
            .optimize = self.opt,
        });
    }

    fn addTest(self: *Builder, name: []const u8, root_source_file: []const u8) *std.Build.Step.Compile {
        return self.b.addTest(.{
            .name = name,
            .root_source_file = self.b.path(root_source_file),
            .target = self.target,
            .optimize = self.opt,
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

    const lib = builder.addStaticLibrary("kwatcher", "src/watcher.zig");
    builder.addDependencies(lib);
    try builder.installAndCheck(lib);

    const exe = builder.addExecutable("kwatcher-examples", "src/main.zig");
    builder.addDependencies(exe);
    exe.root_module.addImport("kwatcher", builder.kwatcher);
    try builder.installAndCheck(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
