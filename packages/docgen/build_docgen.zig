//! Build-time helper that wires the two-stage docgen pipeline (kw-modgen + kw-docgen)
//! into a consumer's build graph. Pure build-graph logic — references only `std.Build`
//! types, never the runtime docgen code. Re-exported from this package's `build.zig` as
//! `build_docgen`, so a consumer uses `@import("kw_docgen").build_docgen.wire(b, .{…})`.
const std = @import("std");

/// One driver-kind → docgen-backend-module mapping. The consumer owns this decision
/// (which kinds its app uses, and which backend documents each); the helper stays
/// generic and never enumerates kinds itself.
pub const Backend = struct {
    /// Driver kind tag as it appears in `@tagName(Driver.kind)`, e.g. "http", "cron".
    kind: []const u8,
    /// The kw-docgen--<kind> backend module (e.g. kw-docgen--http / --none).
    module: *std.Build.Module,
};

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Module that consumes the emitted docs; receives the `kw-gen--docs` anon import.
    /// Its imports must already be wired when `wire` is called (the derived entrypoint
    /// mirrors them — see `entrypoint`).
    consumer: *std.Build.Module,
    /// Host-target build of the app the generators introspect, imported as "entrypoint"
    /// by modgen and docgen. Must NOT import `kw-gen--docs`, or the docgen run would
    /// depend on its own output. Leave null (the default) and the helper derives it by
    /// mirroring `consumer`'s root source + imports onto the host target — so callers
    /// needn't hand-maintain a second copy. Set explicitly only when the introspected
    /// app must differ from the doc consumer.
    entrypoint: ?*std.Build.Module = null,
    /// App source root walked for doc comments, relative to the consumer build root.
    app_source_root: []const u8 = "src",
    /// Driver-kind → backend module mapping.
    backends: []const Backend,
    /// Consumer's zon key for the docgen package (where kw-modgen/kw-docgen come from).
    docgen_dep_name: []const u8 = "kw_docgen",
};

pub const Result = struct {
    /// The `kw-docgen` run step; consumers add `compile.step.dependOn(&docgen_step.step)`.
    docgen_step: *std.Build.Step.Run,
    /// InstallDir step copying emitted *.json into <prefix>/docs.
    install_docs: *std.Build.Step.InstallDir,
};

/// Wire the docgen pipeline. Builds the docgen package twice (module_only on/off) to get
/// the kw-modgen and kw-docgen artifacts, runs them in sequence, mines doc comments from
/// the app sources plus every package in the build graph, installs the emitted JSON, and
/// stitches the generated-module graph back into both the consumer and the docgen module.
pub fn wire(b: *std.Build, opts: Options) Result {
    const kw_modgen_dep = b.dependency(opts.docgen_dep_name, .{
        .target = b.graph.host,
        .optimize = opts.optimize,
        .module_only = true,
        .all = true,
    });

    const kw_docgen_dep = b.dependency(opts.docgen_dep_name, .{
        .target = b.graph.host,
        .optimize = opts.optimize,
        .module_only = false,
        .all = true,
    });

    const kw_modgen = kw_modgen_dep.artifact("kw-modgen");
    const kw_docgen = kw_docgen_dep.artifact("kw-docgen");

    const kw_modgen_mod = kw_modgen_dep.module("kw-docgen");
    const kw_docgen_mod = kw_docgen_dep.module("kw-docgen");

    const entrypoint = opts.entrypoint orelse deriveEntrypoint(b, opts.consumer);
    kw_modgen_mod.addImport("entrypoint", entrypoint);
    kw_docgen_mod.addImport("entrypoint", entrypoint);

    const docgen = b.addRunArtifact(kw_docgen);
    const modgen = b.addRunArtifact(kw_modgen);
    kw_docgen.step.dependOn(&kw_modgen.step);

    const modgen_path = modgen.addOutputDirectoryArg("kw-modgen");
    const docgen_path = docgen.addOutputDirectoryArg("kw-docgen");
    // Source roots for doc-comment mining (kw-docindex), walked at generation time.
    // The app's own sources, plus every package in the build graph (transitive,
    // path- and fetched-deps alike) so routes/types defined in dependencies are
    // documented too.
    docgen.addArg(b.pathFromRoot(opts.app_source_root));
    inline for (@typeInfo(@import("root").dependencies.packages).@"struct".decls) |decl| {
        const pkg = @field(@import("root").dependencies.packages, decl.name);
        if (@hasDecl(pkg, "build_root")) docgen.addArg(pkg.build_root);
    }

    // Copy the generated OpenAPI documents into zig-out/docs on install.
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docgen_path,
        .install_dir = .prefix,
        .install_subdir = "docs",
        .include_extensions = &.{"json"},
    });
    b.getInstallStep().dependOn(&install_docs.step);

    opts.consumer.addAnonymousImport("kw-gen--docs", .{
        .root_source_file = docgen_path.path(b, "generated.zig"),
    });

    const docgen_modules = b.createModule(.{
        .root_source_file = modgen_path.path(b, "modules.zig"),
    });

    for (opts.backends) |back| {
        docgen_modules.addImport(b.fmt("kw-docgen--{s}", .{back.kind}), back.module);
    }

    kw_docgen_mod.addImport("kw-gen--modules", docgen_modules);

    return .{
        .docgen_step = docgen,
        .install_docs = install_docs,
    };
}

/// Build a host-target copy of `consumer` for the generators to introspect. The
/// generators are build-time host tools, so the app they import must be host-built; we
/// mirror the consumer's root source, imports, and module flags but force the host
/// target / ReleaseFast. Crucially this copies the consumer's imports *as they stand
/// now* — call it before `kw-gen--docs` is added to the consumer, so the copy stays free
/// of the generated output and the docgen cycle is broken.
fn deriveEntrypoint(b: *std.Build, consumer: *std.Build.Module) *std.Build.Module {
    const dummy = b.createModule(.{
        .root_source_file = consumer.root_source_file,
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .dwarf_format = consumer.dwarf_format,
        .link_libc = consumer.link_libc,
        .omit_frame_pointer = consumer.omit_frame_pointer,
    });
    for (consumer.import_table.keys(), consumer.import_table.values()) |name, mod| {
        dummy.addImport(name, mod);
    }
    return dummy;
}
