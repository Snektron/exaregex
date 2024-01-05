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
const block_size: usize = 256;
const items_per_thread: usize = 20;
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
    initial: c.cl_mem,
    merge_table: c.cl_mem,
};

platform: c.cl_platform_id,
device: c.cl_device_id,
context: c.cl_context,
queue: c.cl_command_queue,
kernel: c.cl_kernel,

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

    var status: c.cl_int = undefined;
    const properties = [_]c.cl_context_properties{ c.CL_CONTEXT_PLATFORM, @as(c.cl_context_properties, @bitCast(@intFromPtr(platform.id))), 0 };
    const context = c.clCreateContext(&properties, 1, &device.id, null, null, &status);
    switch (status) {
        c.CL_SUCCESS => {},
        c.CL_INVALID_PLATFORM,
        c.CL_INVALID_PROPERTY,
        c.CL_INVALID_VALUE,
        c.CL_INVALID_DEVICE,
        => unreachable,
        c.CL_DEVICE_NOT_AVAILABLE => return error.NoDevice,
        c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
        c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
        else => unreachable,
    }
    errdefer _ = c.clReleaseContext(context);

    const queue = c.clCreateCommandQueue(context, device.id, c.CL_QUEUE_PROFILING_ENABLE, &status);
    switch (status) {
        c.CL_SUCCESS => {},
        c.CL_INVALID_CONTEXT,
        c.CL_INVALID_DEVICE,
        c.CL_INVALID_VALUE,
        c.CL_INVALID_QUEUE_PROPERTIES,
        => unreachable,
        c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
        c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
        else => unreachable,
    }
    errdefer _ = c.clReleaseCommandQueue(queue);

    var kernel_source_mut: [*c]const u8 = kernel_source;
    const program = c.clCreateProgramWithSource(context, 1, &kernel_source_mut, &kernel_source.len, &status);
    switch (status) {
        c.CL_SUCCESS => {},
        c.CL_INVALID_CONTEXT,
        c.CL_INVALID_VALUE,
        => unreachable,
        c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
        c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
        else => unreachable,
    }
    defer _ = c.clReleaseProgram(program);

    status = c.clBuildProgram(
        program,
        1,
        &device.id,
        std.fmt.comptimePrint("-D BLOCK_SIZE={} -D ITEMS_PER_THREAD={}", .{ block_size, items_per_thread }),
        null,
        null,
    );
    switch (status) {
        c.CL_SUCCESS => {},
        c.CL_INVALID_PROGRAM,
        c.CL_INVALID_VALUE,
        c.CL_INVALID_DEVICE,
        c.CL_INVALID_BINARY,
        c.CL_INVALID_BUILD_OPTIONS,
        c.CL_INVALID_OPERATION,
        => unreachable,
        c.CL_COMPILER_NOT_AVAILABLE => return error.CompilerNotAvailable,
        c.CL_BUILD_PROGRAM_FAILURE => unreachable, // TODO: Get error log?
        c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
        c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
        else => unreachable,
    }

    const kernel = c.clCreateKernel(program, "match", &status);
    switch (status) {
        c.CL_SUCCESS => {},
        c.CL_INVALID_PROGRAM,
        c.CL_INVALID_PROGRAM_EXECUTABLE,
        c.CL_INVALID_KERNEL_NAME,
        c.CL_INVALID_KERNEL_DEFINITION,
        c.CL_INVALID_VALUE,
        => unreachable,
        c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
        c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
        else => unreachable,
    }
    errdefer _ = c.clReleaseKernel(kernel);
    return OpenCLEngine{
        .platform = platform.id,
        .device = device.id,
        .context = context,
        .queue = queue,
        .kernel = kernel,
    };
}

pub fn deinit(self: *OpenCLEngine) void {
    _ = c.clReleaseKernel(self.kernel);
    _ = c.clReleaseCommandQueue(self.queue);
    _ = c.clReleaseContext(self.context);
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

fn createBuffer(self: OpenCLEngine, flags: c.cl_mem_flags, size: usize, maybe_host_ptr: ?[*]const u8) !c.cl_mem {
    var status: c.cl_int = undefined;
    const buffer = c.clCreateBuffer(
        self.context,
        flags | if (maybe_host_ptr == null) @as(c.cl_mem_flags, 0) else c.CL_MEM_COPY_HOST_PTR,
        size,
        @as(?*anyopaque, @ptrFromInt(@intFromPtr(maybe_host_ptr))),
        &status,
    );
    switch (status) {
        c.CL_SUCCESS => {},
        c.CL_INVALID_CONTEXT, c.CL_INVALID_PROPERTY, c.CL_INVALID_VALUE, c.CL_INVALID_BUFFER_SIZE, c.CL_INVALID_HOST_PTR, c.CL_MEM_OBJECT_ALLOCATION_FAILURE => return error.OutOfDeviceMemory,
        c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
        c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
        else => unreachable,
    }

    return buffer;
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
    const cl_initial = try self.createBuffer(c.CL_MEM_READ_ONLY, initial.len, &initial);
    errdefer _ = c.clReleaseMemObject(cl_initial);

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
    const cl_merge_table = try self.createBuffer(c.CL_MEM_READ_ONLY, merge_table.len, merge_table.ptr);
    errdefer _ = c.clReleaseMemObject(cl_merge_table);

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
    _ = c.clReleaseMemObject(pattern.initial);
    _ = c.clReleaseMemObject(pattern.merge_table);
}

fn setKernelArg(self: *OpenCLEngine, index: c.cl_uint, arg: []const u8) !void {
    const status = c.clSetKernelArg(
        self.kernel,
        index,
        arg.len,
        arg.ptr,
    );
    switch (status) {
        c.CL_SUCCESS => {},
        c.CL_INVALID_ARG_INDEX,
        c.CL_INVALID_ARG_VALUE,
        c.CL_INVALID_MEM_OBJECT,
        c.CL_INVALID_SAMPLER,
        c.CL_INVALID_DEVICE_QUEUE,
        c.CL_INVALID_ARG_SIZE,
        c.CL_MAX_SIZE_RESTRICTION_EXCEEDED,
        => unreachable,
        c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
        c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
        else => unreachable,
    }
}

fn alignForward(size: usize, alignment: usize) usize {
    return alignment * (std.math.divCeil(usize, size, alignment) catch unreachable);
}

pub fn matches(self: *OpenCLEngine, pattern: CompiledPattern, input: []const u8) !bool {
    const global_work_size = alignForward(input.len, items_per_block) / items_per_thread;
    const reduce_exchange_size = std.math.divCeil(usize, input.len, items_per_block) catch unreachable;

    std.log.debug("global work size: {} items", .{global_work_size});

    const cl_input = try self.createBuffer(c.CL_MEM_READ_ONLY, input.len, input.ptr);
    defer _ = c.clReleaseMemObject(cl_input);

    const cl_reduce_exchange = try self.createBuffer(c.CL_MEM_READ_WRITE, reduce_exchange_size, null);
    defer _ = c.clReleaseMemObject(cl_reduce_exchange);

    try self.setKernelArg(0, std.mem.asBytes(&pattern.initial));
    try self.setKernelArg(1, std.mem.asBytes(&pattern.merge_table));
    try self.setKernelArg(2, std.mem.asBytes(&@as(c.cl_int, @intCast(pattern.pdfa.stateCount()))));
    try self.setKernelArg(3, std.mem.asBytes(&cl_input));
    try self.setKernelArg(4, std.mem.asBytes(&@as(c.cl_int, @intCast(input.len))));
    try self.setKernelArg(5, std.mem.asBytes(&cl_reduce_exchange));

    var kernel_completed_event: c.cl_event = undefined;
    var status = c.clEnqueueNDRangeKernel(self.queue, self.kernel, 1, null, &global_work_size, &block_size, 0, null, &kernel_completed_event);
    switch (status) {
        c.CL_SUCCESS => {},
        c.CL_INVALID_PROGRAM_EXECUTABLE,
        c.CL_INVALID_COMMAND_QUEUE,
        c.CL_INVALID_KERNEL,
        c.CL_INVALID_CONTEXT,
        c.CL_INVALID_KERNEL_ARGS,
        c.CL_INVALID_WORK_DIMENSION,
        c.CL_INVALID_GLOBAL_WORK_SIZE,
        c.CL_INVALID_GLOBAL_OFFSET,
        c.CL_INVALID_WORK_GROUP_SIZE,
        c.CL_INVALID_WORK_ITEM_SIZE,
        c.CL_MISALIGNED_SUB_BUFFER_OFFSET,
        c.CL_INVALID_IMAGE_SIZE,
        c.CL_IMAGE_FORMAT_NOT_SUPPORTED,
        c.CL_INVALID_EVENT_WAIT_LIST,
        c.CL_INVALID_OPERATION,
        => unreachable,
        c.CL_MEM_OBJECT_ALLOCATION_FAILURE => return error.OutOfDeviceMemory,
        c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
        c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
        else => unreachable,
    }

    var read_completed_event: c.cl_event = undefined;
    var result: u8 = undefined;
    status = c.clEnqueueReadBuffer(
        self.queue,
        cl_reduce_exchange,
        c.CL_FALSE,
        0,
        1,
        &result,
        1,
        &kernel_completed_event,
        &read_completed_event,
    );
    switch (status) {
        c.CL_SUCCESS => {},
        c.CL_INVALID_COMMAND_QUEUE,
        c.CL_INVALID_MEM_OBJECT,
        c.CL_INVALID_VALUE,
        c.CL_INVALID_EVENT_WAIT_LIST,
        c.CL_MISALIGNED_SUB_BUFFER_OFFSET,
        c.CL_EXEC_STATUS_ERROR_FOR_EVENTS_IN_WAIT_LIST,
        c.CL_INVALID_OPERATION,
        => unreachable,
        c.CL_MEM_OBJECT_ALLOCATION_FAILURE => return error.OutOfDeviceMemory,
        c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
        c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
        else => unreachable,
    }

    status = c.clWaitForEvents(1, &read_completed_event);
    switch (status) {
        c.CL_SUCCESS => {},
        c.CL_INVALID_VALUE,
        c.CL_INVALID_CONTEXT,
        c.CL_INVALID_EVENT,
        c.CL_EXEC_STATUS_ERROR_FOR_EVENTS_IN_WAIT_LIST,
        => unreachable,
        c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
        c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
        else => unreachable,
    }

    var start: c.cl_ulong = undefined;
    var stop: c.cl_ulong = undefined;
    _ = c.clGetEventProfilingInfo(kernel_completed_event, c.CL_PROFILING_COMMAND_START, @sizeOf(c.cl_ulong), &start, null);
    _ = c.clGetEventProfilingInfo(kernel_completed_event, c.CL_PROFILING_COMMAND_END, @sizeOf(c.cl_ulong), &stop, null);
    std.debug.print("kernel runtime: {}us\n", .{(stop - start) / std.time.ns_per_us});
    std.debug.print("kernel throughput: {d:.2} GB/s\n", .{
        @as(f32, @floatFromInt(input.len)) / (@as(f32, @floatFromInt(stop - start)) / std.time.ns_per_s) / 1000_000_000
    });

    // std.debug.print("{}\n", .{result});
    // std.debug.print("{}\n", .{pattern.pdfa.initial_states[input[3]]});
    const result_state = switch (result) {
        255 => .reject,
        else => @as(ParallelDfa.StateRef, @enumFromInt(result)),
    };
    // {
    //     const pdfa = pattern.pdfa;
    //     var i: usize = 0;
    //     const ws = 4;
    //     while (i < input.len) : (i += ws) {
    //         var x = pdfa.initial(input[i]);
    //         var j: usize = 1;
    //         while (j < ws) : (j += 1) {
    //             x = pdfa.merge(x, pdfa.initial(input[i + j]));
    //         }
    //         std.debug.print("[{:0>2}] = {}\n", .{i / ws, x});
    //     }
    //     // var state = pdfa.initial(input[0]);
    //     // for (input[1..]) |sym| {
    //         // state = pdfa.merge(state, pdfa.initial(sym));
    //     // }
    // }
    return pattern.pdfa.isAccepting(result_state);
}

test "OpenCLEngine" {
    _ = OpenCLEngine;
}
