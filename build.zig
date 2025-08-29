pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_options = b.addOptions();

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
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
                .section = '6',
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

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
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
