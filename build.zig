const std = @import("std");

const GpuRuntime = enum {
    hip,
    cuda,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const runtime = b.option(GpuRuntime, "gpu-runtime", "GPU runtime to use (hip or cuda)") orelse .hip;

    const opencl = b.dependency("opencl", .{
        .target = target,
        .optimize = optimize,
    }).module("opencl");

    const opts = b.addOptions();
    opts.addOption(GpuRuntime, "gpu_runtime", runtime);

    const exe = b.addExecutable(.{
        .name = "exaregex",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("opencl", opencl);
    exe.linkLibC();
    exe.linkSystemLibrary("OpenCL");
    exe.root_module.addOptions("build_options", opts);
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

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    switch (runtime) {
        .hip => {
            const amdgcn_mcpu = b.option([]const u8, "gpu", "Target GPU features to add or subtract") orelse "gfx1101";
            const amdgcn_target = b.resolveTargetQuery(std.Build.parseTargetQuery(.{
                .arch_os_abi = "amdgcn-amdhsa-none",
                .cpu_features = amdgcn_mcpu,
            }) catch unreachable);

            const hip = b.dependency("hip", .{});

            const amdgcn_code = b.addSharedLibrary(.{
                .name = "match-kernel",
                .root_source_file = b.path("src/engine/match.zig"),
                .target = amdgcn_target,
                .optimize = .ReleaseFast,
            });
            amdgcn_code.linker_allow_shlib_undefined = false;
            amdgcn_code.bundle_compiler_rt = false;

            const amdgcn_module = amdgcn_code.getEmittedBin();

            const dis = b.addSystemCommand(&.{"llvm-objdump", "-dj", ".text"});
            dis.addFileArg(amdgcn_module);

            const dis_step = b.step("dis", "disassemble HIP kernel");
            dis_step.dependOn(&dis.step);

            exe.addIncludePath(hip.path("include"));
            exe.addLibraryPath(.{ .cwd_relative = "/opt/rocm/lib" });
            exe.linkSystemLibrary("amdhip64");
            exe.root_module.addAnonymousImport("match-module", .{
                .root_source_file = amdgcn_module,
            });

            tests.addIncludePath(hip.path("include"));
            tests.addLibraryPath(.{ .cwd_relative = "/opt/rocm/lib" });
            tests.linkSystemLibrary("amdhip64");
            tests.root_module.addAnonymousImport("match-module", .{
                .root_source_file = amdgcn_module,
            });
        },
        .cuda => {
            const nvptx_mcpu = b.option([]const u8, "gpu", "Target GPU features to add or subtract") orelse "sm_80";
            const nvptx_target = b.resolveTargetQuery(std.Build.parseTargetQuery(.{
                .arch_os_abi = "nvptx64-cuda-none",
                .cpu_features = nvptx_mcpu,
            }) catch unreachable);

            const nvptx_code = b.addSharedLibrary(.{
                .name = "match-kernel",
                .root_source_file = b.path("src/engine/match.zig"),
                .target = nvptx_target,
                .optimize = .ReleaseFast,
            });
            nvptx_code.linker_allow_shlib_undefined = false;
            nvptx_code.bundle_compiler_rt = false;

            const nvptx_module = nvptx_code.getEmittedAsm();

            exe.addIncludePath(.{ .cwd_relative = "/usr/local/cuda/include" });
            exe.addLibraryPath(.{ .cwd_relative = "/usr/local/cuda/lib64" });
            exe.linkSystemLibrary("cuda");
            exe.root_module.addAnonymousImport("match-module", .{
                .root_source_file = nvptx_module,
            });

            exe.addIncludePath(.{ .cwd_relative = "/usr/local/cuda/include" });
            tests.addLibraryPath(.{ .cwd_relative = "/usr/local/cuda/lib64" });
            tests.linkSystemLibrary("cuda");
            tests.root_module.addAnonymousImport("match-module", .{
                .root_source_file = nvptx_module,
            });
        },
    }
}
