const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const amdgcn_mcpu = b.option([]const u8, "gpu", "Target GPU features to add or subtract") orelse "gfx1101";
    const amdgcn_target = b.resolveTargetQuery(std.Build.parseTargetQuery(.{
        .arch_os_abi = "amdgcn-amdhsa-none",
        .cpu_features = amdgcn_mcpu,
    }) catch unreachable);

    const amdgcn_code = b.addSharedLibrary(.{
        .name = "match-kernel",
        .root_source_file = b.path("src/engine/match.zig"),
        .target = amdgcn_target,
        .optimize = .ReleaseFast,
        // .optimize = .Debug,
    });
    amdgcn_code.linker_allow_shlib_undefined = false;
    amdgcn_code.bundle_compiler_rt = false;

    const dis = b.addSystemCommand(&.{"llvm-objdump", "-dj", ".text"});
    dis.addFileArg(amdgcn_code.getEmittedBin());

    const dis_step = b.step("dis", "disassemble HIP kernel");
    dis_step.dependOn(&dis.step);

    const offload_bundle_cmd = b.addSystemCommand(&.{
        "clang-offload-bundler",
        "-type=o",
        "-bundle-align=4096",
        // TODO: add sramecc+ xnack+?
        b.fmt("-targets=host-x86_64-unknown-linux,hipv4-amdgcn-amd-amdhsa--{s}", .{amdgcn_target.result.cpu.model.name}),
        "-input=/dev/null",
    });

    offload_bundle_cmd.addPrefixedFileArg("-input=", amdgcn_code.getEmittedBin());
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

    tests.root_module.addImport("opencl", opencl);
    tests.linkLibC();
    tests.linkSystemLibrary("OpenCL");
    tests.addIncludePath(.{ .cwd_relative = "/opt/rocm/include" });
    tests.addLibraryPath(.{ .cwd_relative = "/opt/rocm/lib" });
    tests.linkSystemLibrary("amdhip64");
    tests.root_module.addAnonymousImport("match-offload-bundle", .{
        .root_source_file = offload_bundle,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
