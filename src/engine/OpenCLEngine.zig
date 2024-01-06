const OpenCLEngine = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Pattern = @import("../Pattern.zig");
const automaton = @import("../automaton.zig");
const ParallelDfa = automaton.parallel.ParallelDfa;

const c = @cImport({
    @cInclude("CL/opencl.h");
});

const cl = @import("../opencl.zig");

const kernel_source = @embedFile("match.cl");
const block_size: usize = 768; // Why doesn't 1024 work?
const items_per_thread: usize = 16; // for global_load_dwordx4
const items_per_block = block_size * items_per_thread;

/// Configuration options for the OpenCL engine
pub const Options = struct {
    /// Substring that the platform name must match.
    /// By default, selects the first platform.
    platform: ?[]const u8 = null,
    /// Substring that the device name must match.
    /// By default, selects the first device.
    device: ?[]const u8 = null,
};

pub const CompiledPattern = struct {
    pdfa: ParallelDfa,
    initial: cl.Buffer(u8),
    merge_table: cl.Buffer(u8),
};

platform: cl.Platform,
device: cl.Device,
context: cl.Context,
queue: cl.CommandQueue,
initial_kernel: cl.Kernel,
reduce_kernel: cl.Kernel,

pub fn init(a: Allocator, options: Options) !OpenCLEngine {
    const platform, const device = try pickPlatformAndDevice(a, options);

    {
        const name = try platform.getName(a);
        defer a.free(name);
        std.log.debug("platform: {s}", .{name});
    }

    {
        const name = try device.getName(a);
        defer a.free(name);
        std.log.debug("device: {s}", .{name});
    }

    const context = try cl.Context.create(&.{device}, .{.platform = platform});
    errdefer context.release();

    const queue = try cl.CommandQueue.create(context, device, .{.profiling = true});
    errdefer queue.release();

    const program = try cl.Program.createWithSource(context, kernel_source);
    defer program.release();

    try program.build(
        &.{device},
        std.fmt.comptimePrint("-D BLOCK_SIZE={} -D ITEMS_PER_THREAD={}", .{ block_size, items_per_thread }),
    );

    const initial_kernel = try cl.Kernel.create(program, "initial");
    errdefer initial_kernel.release();

    const reduce_kernel = try cl.Kernel.create(program, "reduce");
    errdefer reduce_kernel.release();

    return OpenCLEngine{
        .platform = platform,
        .device = device,
        .context = context,
        .queue = queue,
        .initial_kernel = initial_kernel,
        .reduce_kernel = reduce_kernel,
    };
}

pub fn deinit(self: *OpenCLEngine) void {
    self.initial_kernel.release();
    self.reduce_kernel.release();
    self.queue.release();
    self.context.release();
    self.* = undefined;
}

fn pickPlatformAndDevice(
    a: Allocator,
    options: Options,
) !struct{cl.Platform, cl.Device} {
    const platforms = try cl.getPlatforms(a);
    defer a.free(platforms);

    if (platforms.len == 0) {
        return error.NoPlatform;
    }

    var chosen_platform: cl.Platform = undefined;
    var chosen_device: cl.Device = undefined;

    if (options.platform) |platform_query| {
        for (platforms) |platform| {
            const name = try platform.getName(a);
            defer a.free(name);

            if (std.mem.indexOf(u8, name, platform_query) != null) {
                chosen_platform = platform;
                break;
            }
        } else {
            return error.NoPlatform;
        }

        chosen_device = try pickDevice(a, chosen_platform, options.device);
    } else if (options.device) |device_query| {
        // Loop through all platforms to find one which matches the device
        for (platforms) |platform| {
            chosen_device = pickDevice(a, platform, device_query) catch |err| switch (err) {
                error.NoDevice => continue,
                else => return err,
            };

            chosen_platform = platform;
            break;
        } else {
            return error.NoDevice;
        }
    } else {
        for (platforms) |platform| {
            chosen_device = pickDevice(a, platform, null) catch |err| switch (err) {
                error.NoDevice => continue,
                else => return err,
            };
            chosen_platform = platform;
            break;
        } else {
            return error.NoDevice;
        }
    }

    return .{ chosen_platform, chosen_device };
}

fn pickDevice(a: Allocator, platform: cl.Platform, query: ?[]const u8) !cl.Device {
    const devices = try platform.getDevices(a, .{.gpu = true});
    defer a.free(devices);

    if (devices.len == 0) {
        return error.NoDevice;
    }

    if (query) |device_query| {
        for (devices) |device| {
            const device_name = try device.getName(a);
            defer a.free(device_name);

            if (std.mem.indexOf(u8, device_name, device_query) != null) {
                return device;
            }
        }

        return error.NoDevice;
    } else {
        return devices[0];
    }
}

pub fn compilePattern(self: *OpenCLEngine, a: Allocator, pattern: Pattern) !CompiledPattern {
    var nfa = try automaton.thompson(a, pattern, .{});
    defer nfa.deinit(a);

    var dfa = try automaton.subset(a, nfa, .{});
    defer dfa.deinit(a);

    const pdfa = try automaton.parallelize(a, dfa, .{});

    var initial: [256]u8 = undefined;
    for (&initial, 0..) |*x, i| {
        x.* = switch (pdfa.initial_states[i]) {
            .reject => 255,
            else => |state| if (@intFromEnum(state) >= 255) {
                return error.TodoLargeAutomatons;
            } else @as(u8, @intCast(@intFromEnum(state))),
        };
    }

    const cl_initial = try cl.Buffer(u8).createWithData(self.context, .{.read_only = true}, &initial);
    errdefer cl_initial.release();

    const size = pdfa.stateCount();
    if (size * size + initial.len > 32768) {
        return error.TodoLargeAutomatons;
    }

    const merge_table = try a.alloc(u8, size * size);
    defer a.free(merge_table);
    for (merge_table, 0..) |*x, i| {
        x.* = switch (pdfa.merges[i]) {
            .reject => 255,
            else => |state| if (@intFromEnum(state) >= 255) {
                return error.TodoLargeAutomatons;
            } else @as(u8, @intCast(@intFromEnum(state))),
        };
    }
    std.log.debug("parallel states: {}", .{ size });
    std.log.debug("merge table size: {}", .{ merge_table.len });
    const cl_merge_table = try cl.Buffer(u8).createWithData(self.context, .{.read_only = true}, merge_table);
    errdefer cl_merge_table.release();

    return CompiledPattern{
        .pdfa = pdfa,
        .initial = cl_initial,
        .merge_table = cl_merge_table,
    };
}

pub fn destroyCompiledPattern(self: *OpenCLEngine, a: Allocator, pattern: CompiledPattern) void {
    _ = self;
    var pdfa = pattern.pdfa;
    pdfa.deinit(a);
    pattern.initial.release();
    pattern.merge_table.release();
}

pub fn matches(self: *OpenCLEngine, pattern: CompiledPattern, input: []const u8) !bool {
    const compute_units = try self.device.getInfo(.max_compute_units);
    const blocks: u32 = @intCast(std.math.divCeil(usize, input.len, items_per_block) catch unreachable);

    const output_size = blocks;

    std.log.debug("compute units: {}", .{compute_units});
    std.log.debug("work size: {}", .{blocks});

    var cl_input = try cl.Buffer(u8).createWithData(self.context, .{.read_write = true}, input);
    defer cl_input.release();

    var cl_output = try cl.Buffer(u8).create(self.context, .{.read_write = true}, output_size);
    defer cl_output.release();

    var cl_counter = try cl.Buffer(u32).createWithData(self.context, .{.read_write = true}, &.{blocks});
    defer cl_counter.release();

    // Launch the initial kernel
    try self.initial_kernel.setArg(cl.Buffer(u8), 0, &pattern.initial);
    try self.initial_kernel.setArg(cl.Buffer(u8), 1, &pattern.merge_table);
    try self.initial_kernel.setArg(cl.uint, 2, &@intCast(pattern.pdfa.stateCount()));
    try self.initial_kernel.setArg(cl.Buffer(u8), 3, &cl_input);
    try self.initial_kernel.setArg(cl.uint, 4, &@intCast(input.len));
    try self.initial_kernel.setArg(cl.Buffer(u8), 5, &cl_output);
    try self.initial_kernel.setArg(cl.Buffer(u32), 6, &cl_counter);

    var kernel_completed = try self.queue.enqueueNDRangeKernel(
        self.initial_kernel,
        null,
        &.{compute_units * block_size},
        &.{block_size},
        &.{},
    );

    const first_kernel_completed = kernel_completed;

    var size: usize = output_size;
    while (size > 1) {
        const out_size = std.math.divCeil(usize, size, items_per_block) catch unreachable;
        const out_blocks = std.math.divCeil(usize, size, items_per_block) catch unreachable;
        const new_global_work_size = out_blocks * block_size;
        std.log.debug("reducing: {} -> {}", .{size, out_size});

        const tmp = cl_input;
        cl_input = cl_output;
        cl_output = tmp;

        try self.reduce_kernel.setArg(cl.Buffer(u8), 0, &pattern.merge_table);
        try self.reduce_kernel.setArg(cl.uint, 1, &@intCast(pattern.pdfa.stateCount()));
        try self.reduce_kernel.setArg(cl.Buffer(u8), 2, &cl_input);
        try self.reduce_kernel.setArg(cl.uint, 3, &@intCast(size));
        try self.reduce_kernel.setArg(cl.Buffer(u8), 4, &cl_output);

        kernel_completed = try self.queue.enqueueNDRangeKernel(
            self.reduce_kernel,
            null,
             &.{new_global_work_size},
             &.{block_size},
             &.{kernel_completed},
        );

        size = out_size;
    }

    var result: u8 = undefined;
    const read_completed = try self.queue.enqueueReadBuffer(
        u8,
        cl_output,
        false,
        0,
        std.mem.asBytes(&result),
        &.{kernel_completed},
    );

    try cl.waitForEvents(&.{read_completed});

    const start = try first_kernel_completed.commandStartTime();
    const stop = try kernel_completed.commandEndTime();

    std.log.debug("result: {}", .{result});
    std.log.debug("kernel runtime: {}us", .{(stop - start) / std.time.ns_per_us});
    std.log.debug("kernel throughput: {d:.2} GB/s", .{
        @as(f32, @floatFromInt(input.len)) / (@as(f32, @floatFromInt(stop - start)) / std.time.ns_per_s) / 1000_000_000
    });

    const result_state = switch (result) {
        255 => .reject,
        else => @as(ParallelDfa.StateRef, @enumFromInt(result)),
    };
    return pattern.pdfa.isAccepting(result_state);
}

test "OpenCLEngine" {
    var engine = try OpenCLEngine.init(std.testing.allocator, .{
        .platform = std.os.getenv("EXAREGEX_PLATFORM"),
        .device = std.os.getenv("EXAREGEX_DEVICE"),
    });
    defer engine.deinit();

    try @import("test.zig").testEngine(OpenCLEngine, &engine);
}
