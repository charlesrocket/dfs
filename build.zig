pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_options = b.addOptions();

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "dfs",
        .root_module = exe_mod,
    });

    exe_mod.addImport("libdfs", lib_mod);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "dfs_lib",
        .root_module = lib_mod,
    });

    const cova_dep = b.dependency("cova", .{
        .target = target,
        .optimize = optimize,
    });

    const cova_mod = cova_dep.module("cova");

    if (target.query.cpu_arch == null) {
        const cova_gen = @import("cova").addCovaDocGenStep(b, cova_dep, exe, .{
            .kinds = &.{.all},
            .version = version(b),
            .help_docs_config = .{
                .section = '1',
            },
            .tab_complete_config = .{
                .include_opts = true,
                .add_cova_lib_msg = false,
                .add_install_instructions = false,
            },
        });

        const meta_doc_gen = b.step("gen-doc", "Generate Meta Docs");
        meta_doc_gen.dependOn(&cova_gen.step);
    }

    exe.root_module.addImport("cova", cova_mod);
    exe.root_module.addOptions("build_options", build_options);
    build_options.addOption([]const u8, "version", version(b));

    b.installArtifact(lib);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_options = b.addOptions();
    test_options.addOptionPath("exe_path", exe.getEmittedBin());

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const integration_tests = b.addTest(.{
        .root_source_file = b.path("test/cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    integration_tests.root_module.addOptions("build_options", test_options);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    const merge_step = b.addSystemCommand(&.{ "kcov", "--merge" });
    merge_step.addDirectoryArg(b.path("coverage"));
    merge_step.addDirectoryArg(b.path("kcov-unit"));
    merge_step.addDirectoryArg(b.path("kcov-int"));

    const kcov_unit = b.addSystemCommand(&.{ "kcov", "--include-path=src,test" });
    kcov_unit.addDirectoryArg(b.path("kcov-unit"));
    kcov_unit.addArtifactArg(lib_unit_tests);
    merge_step.step.dependOn(&kcov_unit.step);

    const kcov_exe_unit = b.addSystemCommand(&.{ "kcov", "--include-path=src,test" });
    kcov_exe_unit.addDirectoryArg(b.path("kcov-exe-unit"));
    kcov_exe_unit.addArtifactArg(exe_unit_tests);
    merge_step.step.dependOn(&kcov_exe_unit.step);

    const kcov_int = b.addSystemCommand(&.{ "kcov", "--include-path=src,test" });
    kcov_int.addDirectoryArg(b.path("kcov-int"));
    kcov_int.addArtifactArg(integration_tests);

    merge_step.step.dependOn(&kcov_int.step);

    const coverage_step = b.step("coverage", "Generate test coverage (kcov)");
    coverage_step.dependOn(&merge_step.step);

    const build_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "../docs",
    });

    const build_docs_step = b.step("docs", "Build library documentation");
    build_docs_step.dependOn(&build_docs.step);

    const clean_step = b.step("clean", "Clean up project directory");
    clean_step.dependOn(&b.addRemoveDirTree(b.path("meta")).step);
    clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-out")).step);
    clean_step.dependOn(&b.addRemoveDirTree(b.path(".zig-cache")).step);
}

fn version(b: *std.Build) []const u8 {
    const semver = manifest.version;
    const os = @tagName(builtin.target.os.tag);
    var gxt = Ghext.init(std.heap.page_allocator) catch return semver;
    const hash = gxt.hash(Ghext.HashLen.Short, Ghext.Worktree.Checked);
    return b.fmt("{s} ({s}) {s}", .{ semver, os, hash });
}

const manifest: struct {
    const Dependency = struct {
        url: []const u8,
        hash: []const u8,
        lazy: bool = false,
    };

    name: enum { dfs },
    version: []const u8,
    fingerprint: u64,
    paths: []const []const u8,
    minimum_zig_version: []const u8,
    dependencies: struct {
        cova: Dependency,
        ghext: Dependency,
    },
} = @import("build.zig.zon");

const std = @import("std");
const builtin = @import("builtin");
const Ghext = @import("ghext").Ghext;
