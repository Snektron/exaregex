const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const hip_mcpu = b.option([]const u8, "gpu", "Target GPU features to add or subtract") orelse "gfx1101";
    const hip_target = b.resolveTargetQuery(std.Build.parseTargetQuery(.{
        .arch_os_abi = "amdgcn-amdhsa-none",
        .cpu_features = hip_mcpu,
    }) catch unreachable);

    const hip_code = b.addSharedLibrary(.{
        .name = "match-kernel",
        .root_source_file = b.path("src/engine/match.zig"),
        .target = hip_target,
        .optimize = .ReleaseFast,
    });
    hip_code.linker_allow_shlib_undefined = false;
    hip_code.bundle_compiler_rt = false;

    const offload_bundle_cmd = b.addSystemCommand(&.{
        "clang-offload-bundler",
        "-type=o",
        "-bundle-align=4096",
        // TODO: add sramecc+ xnack+?
        b.fmt("-targets=host-x86_64-unknown-linux,hipv4-amdgcn-amd-amdhsa--{s}", .{hip_target.result.cpu.model.name}),
        "-input=/dev/null",
    });
    offload_bundle_cmd.addPrefixedFileArg("-input=", hip_code.getEmittedBin());
    const offload_bundle = offload_bundle_cmd.addPrefixedOutputFileArg("-output=", "module.co");

    const opencl = b.dependency("opencl", .{
        .target = target,
        .optimize = optimize,
    }).module("opencl");

    const exe = b.addExecutable(.{
        .name = "exaregex",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("opencl", opencl);
    exe.linkLibC();
    exe.linkSystemLibrary("OpenCL");
    exe.addIncludePath(.{ .cwd_relative = "/opt/rocm/include" });
    exe.addLibraryPath(.{ .cwd_relative = "/opt/rocm/lib" });
    exe.linkSystemLibrary("amdhip64");
    exe.root_module.addAnonymousImport("match-offload-bundle", .{
        .root_source_file = offload_bundle,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_exe.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    tests.linkLibC();
    tests.linkSystemLibrary("OpenCL");

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
