//! This module has some Zig-style wrappers for OpenCL functions.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const c = @cImport({
    @cInclude("CL/opencl.h");
});

pub const int = c.cl_int;
pub const uint = c.cl_uint;
pub const long = c.cl_long;
pub const ulong = c.cl_ulong;

const DeviceType = packed struct(c.cl_device_type) {
    default: bool = false,
    cpu: bool = false,
    gpu: bool = false,
    accelerator: bool = false,
    custom: bool = false,
    _unused: u59 = 0,
};

pub fn getPlatforms(a: Allocator) ![]const Platform {
    comptime std.debug.assert(@sizeOf(Platform) == @sizeOf(c.cl_platform_id));

    var num_platforms: uint = undefined;
    switch (c.clGetPlatformIDs(0, null, &num_platforms)) {
        c.CL_SUCCESS => {},
        c.CL_INVALID_VALUE => unreachable,
        c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
        else => unreachable, // Undocumented error
    }

    if (num_platforms == 0) {
        return &.{};
    }

    const platforms = try a.alloc(Platform, num_platforms);
    errdefer a.free(platforms);

    switch (c.clGetPlatformIDs(num_platforms, @ptrCast(platforms.ptr), null)) {
        c.CL_SUCCESS => {},
        c.CL_INVALID_VALUE => unreachable,
        c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
        else => unreachable, // Undocumented error
    }

    return platforms;
}

pub const Platform = extern struct {
    id: c.cl_platform_id,

    pub fn getName(platform: Platform, a: Allocator) ![]const u8 {
        var name_size: usize = undefined;
        switch (c.clGetPlatformInfo(platform.id, c.CL_PLATFORM_NAME, 0, null, &name_size)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_PLATFORM => unreachable,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
            else => unreachable, // Undocumented error
        }

        const name = try a.alloc(u8, name_size);
        errdefer a.free(name);

        switch (c.clGetPlatformInfo(platform.id, c.CL_PLATFORM_NAME, name_size, name.ptr, null)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_VALUE => unreachable,
            c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
            else => unreachable, // Undocumented error
        }

        return name;
    }

    pub fn getDevices(platform: Platform, a: Allocator, device_type: DeviceType) ![]const Device {
        comptime std.debug.assert(@sizeOf(Device) == @sizeOf(c.cl_device_id));

        var num_devices: uint = undefined;
        switch (c.clGetDeviceIDs(platform.id, @bitCast(device_type), 0, null, &num_devices)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_PLATFORM => unreachable,
            c.CL_INVALID_DEVICE_TYPE => unreachable,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_DEVICE_NOT_FOUND => return &.{},
            c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
            else => unreachable, // Undocumented error
        }

        if (num_devices == 0) {
            return &.{};
        }

        const devices = try a.alloc(Device, num_devices);
        errdefer a.free(devices);

        switch (c.clGetDeviceIDs(platform.id, @bitCast(device_type), num_devices, @ptrCast(devices.ptr), null)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_PLATFORM => unreachable,
            c.CL_INVALID_DEVICE_TYPE => unreachable,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_DEVICE_NOT_FOUND => unreachable,
            c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
            else => unreachable, // Undocumented error
        }

        return devices;
    }
};

pub const Device = extern struct {
    pub const Info = enum(uint) {
        @"type" = c.CL_DEVICE_TYPE,
        max_compute_units = c.CL_DEVICE_MAX_COMPUTE_UNITS,

        pub fn Type(comptime info: Info) type {
            return switch (info) {
                .@"type" => DeviceType,
                .max_compute_units => uint,
            };
        }
    };

    id: c.cl_device_id,

    pub fn getName(device: Device, a: Allocator) ![]const u8 {
        var name_size: usize = undefined;
        switch (c.clGetDeviceInfo(device.id, c.CL_DEVICE_NAME, 0, null, &name_size)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_DEVICE => unreachable,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
            else => unreachable, // Undocumented error
        }

        const name = try a.alloc(u8, name_size);
        errdefer a.free(name);

        switch (c.clGetDeviceInfo(device.id, c.CL_DEVICE_NAME, name_size, name.ptr, null)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_DEVICE => unreachable,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
            else => unreachable, // Undocumented error
        }
        return name;
    }

    pub fn getInfo(device: Device, comptime info: Info) !info.Type() {
        var data: info.Type() = undefined;
        return switch (c.clGetDeviceInfo(device.id, @intFromEnum(info), @sizeOf(info.Type()), &data, null)) {
            c.CL_SUCCESS => data,
            c.CL_INVALID_DEVICE => unreachable,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_OUT_OF_RESOURCES => error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => error.OutOfMemory,
            else => unreachable, // Undocumented error
        };
    }
};

pub const Context = extern struct {
    pub const Properties = struct {
        platform: ?Platform = null,
    };

    handle: c.cl_context,

    pub fn create(devices: []const Device, properties: Properties) !Context {
        var cl_props = std.BoundedArray(c.cl_context_properties, 3).init(0) catch unreachable;

        if (properties.platform) |platform| {
            cl_props.appendAssumeCapacity(c.CL_CONTEXT_PLATFORM);
            cl_props.appendAssumeCapacity(@bitCast(@intFromPtr(platform.id)));
        }
        cl_props.appendAssumeCapacity(0);

        var status: int = undefined;
        const context = c.clCreateContext(
            &cl_props.buffer,
            @intCast(devices.len),
            @ptrCast(devices.ptr),
            null,
            null,
            &status,
        );
        return switch (status) {
            c.CL_SUCCESS => .{.handle = context},
            c.CL_INVALID_PLATFORM => unreachable,
            c.CL_INVALID_PROPERTY => unreachable,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_INVALID_DEVICE => unreachable,
            c.CL_DEVICE_NOT_AVAILABLE => error.DeviceNotAvailable,
            c.CL_OUT_OF_RESOURCES => error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => error.OutOfMemory,
            else => unreachable, // Undocumented error
        };
    }

    pub fn release(context: Context) void {
        switch (c.clReleaseContext(context.handle)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_CONTEXT => unreachable,
            // Ignore any errors
            c.CL_OUT_OF_RESOURCES => {},
            c.CL_OUT_OF_HOST_MEMORY => {},
            else => unreachable, // Undocumented error
        }
    }

    pub fn retain(context: Context) !void {
        switch (c.clRetainContext(context.handle)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_CONTEXT => unreachable,
            c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
            else => unreachable, // Undocumented error
        }
    }
};

pub const CommandQueue = extern struct {
    pub const Properties = packed struct(c.cl_command_queue_properties) {
        out_of_order_exec_mode: bool = false,
        profiling: bool = false,
        on_device: bool = false,
        on_device_default: bool = false,
        _unused: u60 = 0,
    };

    handle: c.cl_command_queue,

    pub fn create(context: Context, device: Device, properties: Properties) !CommandQueue {
        var status: int = undefined;
        const queue = c.clCreateCommandQueue(context.handle, device.id, @bitCast(properties), &status);
        return switch (status) {
            c.CL_SUCCESS => .{.handle = queue},
            c.CL_INVALID_CONTEXT => unreachable,
            c.CL_INVALID_DEVICE => unreachable,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_INVALID_QUEUE_PROPERTIES => unreachable,
            c.CL_OUT_OF_RESOURCES => error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => error.OutOfMemory,
            else => unreachable, // Undocumented error
        };
    }

    pub fn release(queue: CommandQueue) void {
        switch (c.clReleaseCommandQueue(queue.handle)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_COMMAND_QUEUE => unreachable,
            // Ignore any errors
            c.CL_OUT_OF_RESOURCES => {},
            c.CL_OUT_OF_HOST_MEMORY => {},
            else => unreachable, // Undocumented error
        }
    }

    pub fn retain(queue: CommandQueue) !void {
        switch (c.clRetainCommandQueue(queue.handle)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_COMMAND_QUEUE => unreachable,
            c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
            else => unreachable, // Undocumented error
        }
    }

    pub fn enqueueNDRangeKernel(
        queue: CommandQueue,
        kernel: Kernel,
        maybe_global_work_offset: ?[]const usize,
        global_work_size: []const usize,
        local_work_size: []const usize,
        wait_list: []const Event,
    ) !Event {
        const work_dim = global_work_size.len;
        std.debug.assert(work_dim == local_work_size.len);
        if (maybe_global_work_offset) |global_work_offset| {
            std.debug.assert(work_dim == global_work_offset.len);
        }

        var event: Event = undefined;
        return switch (c.clEnqueueNDRangeKernel(
            queue.handle,
            kernel.handle,
            @intCast(work_dim),
            if (maybe_global_work_offset) |global_work_offset| global_work_offset.ptr else null,
            global_work_size.ptr,
            local_work_size.ptr,
            @intCast(wait_list.len),
            if (wait_list.len == 0) null else @ptrCast(wait_list.ptr),
            &event.handle,
        )) {
            c.CL_SUCCESS => event,
            c.CL_INVALID_PROGRAM_EXECUTABLE => unreachable,
            c.CL_INVALID_COMMAND_QUEUE => unreachable,
            c.CL_INVALID_KERNEL => unreachable,
            c.CL_INVALID_CONTEXT => unreachable,
            c.CL_INVALID_KERNEL_ARGS => unreachable,
            c.CL_INVALID_WORK_DIMENSION => unreachable,
            c.CL_INVALID_GLOBAL_WORK_SIZE => unreachable,
            c.CL_INVALID_GLOBAL_OFFSET => unreachable,
            c.CL_INVALID_WORK_GROUP_SIZE => unreachable,
            c.CL_INVALID_WORK_ITEM_SIZE => unreachable,
            c.CL_MISALIGNED_SUB_BUFFER_OFFSET => unreachable,
            c.CL_INVALID_IMAGE_SIZE => unreachable,
            c.CL_IMAGE_FORMAT_NOT_SUPPORTED => unreachable,
            c.CL_INVALID_EVENT_WAIT_LIST => unreachable,
            c.CL_INVALID_OPERATION => unreachable,
            c.CL_MEM_OBJECT_ALLOCATION_FAILURE => error.OutOfDeviceMemory,
            c.CL_OUT_OF_RESOURCES => error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => error.OutOfMemory,
            else => unreachable,
        };
    }

    pub fn enqueueReadBuffer(
        queue: CommandQueue,
        comptime T: type,
        buffer: Buffer(T),
        blocking_read: bool,
        offset: usize,
        dst: []T,
        wait_list: []const Event,
    ) !Event {
        var event: Event = undefined;
        return switch (c.clEnqueueReadBuffer(
            queue.handle,
            buffer.handle,
            if (blocking_read) c.CL_TRUE else c.CL_FALSE,
            offset * @sizeOf(T),
            dst.len * @sizeOf(T),
            dst.ptr,
            @intCast(wait_list.len),
            if (wait_list.len == 0) null else @ptrCast(wait_list.ptr),
            &event.handle,
        )) {
            c.CL_SUCCESS => event,
            c.CL_INVALID_COMMAND_QUEUE => unreachable,
            c.CL_INVALID_MEM_OBJECT => unreachable,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_INVALID_EVENT_WAIT_LIST => unreachable,
            c.CL_MISALIGNED_SUB_BUFFER_OFFSET => unreachable,
            c.CL_EXEC_STATUS_ERROR_FOR_EVENTS_IN_WAIT_LIST => unreachable,
            c.CL_INVALID_OPERATION => unreachable,
            c.CL_MEM_OBJECT_ALLOCATION_FAILURE => error.OutOfDeviceMemory,
            c.CL_OUT_OF_RESOURCES => error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => error.OutOfMemory,
            else => unreachable,
        };
    }
};

pub const Program = extern struct {
    pub const BuildStatus = enum(c.cl_build_status) {
        Success = c.CL_BUILD_SUCCESS,
        None = c.CL_BUILD_NONE,
        Error = c.CL_BUILD_ERROR,
        InProgress = c.CL_BUILD_IN_PROGRESS,
    };

    handle: c.cl_program,

    pub fn createWithSource(context: Context, source: [:0] const u8) !Program {
        return createWithSources(context, &.{source.ptr}, &.{source.len});
    }

    pub fn createWithSources(context: Context, strings: []const [*:0] const u8, lengths: []const usize) !Program {
        std.debug.assert(strings.len == lengths.len);
        var status: int = undefined;
        const program = c.clCreateProgramWithSource(
            context.handle,
            @intCast(strings.len),
            @constCast(@ptrCast(strings.ptr)),
            lengths.ptr,
            &status,
        );
        return switch (status) {
            c.CL_SUCCESS => .{.handle = program},
            c.CL_INVALID_CONTEXT => unreachable,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_OUT_OF_RESOURCES => error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => error.OutOfMemory,
            else => unreachable,
        };
    }

    pub fn release(program: Program) void {
        switch (c.clReleaseProgram(program.handle)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_PROGRAM => unreachable,
            // Ignore any errors
            c.CL_OUT_OF_RESOURCES => {},
            c.CL_OUT_OF_HOST_MEMORY => {},
            else => unreachable, // Undocumented error
        }
    }

    pub fn retain(program: Program) !void {
        switch (c.clRetainProgram(program.handle)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_PROGRAM => unreachable,
            c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
            else => unreachable, // Undocumented error
        }
    }

    pub fn build(program: Program, devices: []const Device, options: [*:0]const u8) !void {
        return switch (c.clBuildProgram(
            program.handle,
            @intCast(devices.len),
            @ptrCast(devices.ptr),
            options,
            null,
            null,
        )) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_PROGRAM => unreachable,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_INVALID_DEVICE => unreachable,
            c.CL_INVALID_BINARY => unreachable,
            c.CL_INVALID_BUILD_OPTIONS => unreachable,
            c.CL_INVALID_OPERATION => unreachable,
            c.CL_COMPILER_NOT_AVAILABLE => error.CompilerNotAvailable,
            c.CL_BUILD_PROGRAM_FAILURE => error.BuildProgramFailure,
            c.CL_OUT_OF_RESOURCES => error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => error.OutOfMemory,
            else => unreachable, // Undocumented error
        };
    }

    pub fn getBuildLog(program: Program, a: Allocator, device: Device) ![]const u8 {
        var log_size: usize = undefined;
        switch (c.clGetProgramBuildInfo(
            program.handle,
            device.id,
            c.CL_PROGRAM_BUILD_LOG,
            0,
            null,
            &log_size,
        )) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_DEVICE => unreachable,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_INVALID_PROGRAM => unreachable,
            c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
            else => unreachable, // Undocumented error
        }

        const log = try a.alloc(u8, log_size);
        errdefer a.free(log);

        return switch (c.clGetProgramBuildInfo(
            program.handle,
            device.id,
            c.CL_PROGRAM_BUILD_LOG,
            log_size,
            log.ptr,
            null,
        )) {
            c.CL_SUCCESS => log,
            c.CL_INVALID_DEVICE => unreachable,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_INVALID_PROGRAM => unreachable,
            c.CL_OUT_OF_RESOURCES => error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => error.OutOfMemory,
            else => unreachable, // Undocumented error
        };
    }
};

pub const Kernel = extern struct {
    handle: c.cl_kernel,

    pub fn create(program: Program, entrypoint: [*:0]const u8) !Kernel {
        var status: int = undefined;
        const kernel = c.clCreateKernel(program.handle, entrypoint, &status);
        return switch (status) {
            c.CL_SUCCESS => .{.handle = kernel},
            c.CL_INVALID_PROGRAM => unreachable,
            c.CL_INVALID_PROGRAM_EXECUTABLE => unreachable,
            c.CL_INVALID_KERNEL_NAME => error.InvalidKernelName,
            c.CL_INVALID_KERNEL_DEFINITION => error.InvalidKernelDefinition,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
            else => unreachable,
        };
    }

    pub fn release(kernel: Kernel) void {
        switch (c.clReleaseKernel(kernel.handle)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_KERNEL => unreachable,
            // Ignore any errors
            c.CL_OUT_OF_RESOURCES => {},
            c.CL_OUT_OF_HOST_MEMORY => {},
            else => unreachable, // Undocumented error
        }
    }

    pub fn retain(kernel: Kernel) !void {
        switch (c.clRetainKernel(kernel.handle)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_KERNEL => unreachable,
            c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
            else => unreachable, // Undocumented error
        }
    }

    pub fn setArg(kernel: Kernel, comptime T: type, index: uint, value: *const T) !void {
        return switch (c.clSetKernelArg(
            kernel.handle,
            index,
            @sizeOf(T),
            @ptrCast(value),
        )) {
            c.CL_SUCCESS => {},
            // TODO: Should these be errors?
            c.CL_INVALID_ARG_INDEX => unreachable,
            c.CL_INVALID_ARG_VALUE => unreachable,
            c.CL_INVALID_MEM_OBJECT => unreachable,
            c.CL_INVALID_SAMPLER => unreachable,
            c.CL_INVALID_DEVICE_QUEUE => unreachable,
            c.CL_INVALID_ARG_SIZE => unreachable,
            c.CL_MAX_SIZE_RESTRICTION_EXCEEDED => unreachable,
            c.CL_OUT_OF_RESOURCES => error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => error.OutOfMemory,
            else => unreachable, // Undocumented error
        };
    }
};

pub const Event = extern struct {
    handle: c.cl_event,

    pub fn release(event: Event) void {
        switch (c.clReleaseEvent(event.handle)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_EVENT => unreachable,
            // Ignore any errors
            c.CL_OUT_OF_RESOURCES => {},
            c.CL_OUT_OF_HOST_MEMORY => {},
            else => unreachable, // Undocumented error
        }
    }

    pub fn retain(event: Event) !void {
        switch (c.clRetainEvent(event.handle)) {
            c.CL_SUCCESS => {},
            c.CL_INVALID_EVENT => unreachable,
            c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
            else => unreachable, // Undocumented error
        }
    }

    pub fn commandQueuedTime(event: Event) !u64 {
        return event.getProfilingInfo(c.CL_PROFILING_COMMAND_QUEUED);
    }

    pub fn commandSubmitTime(event: Event) !u64 {
        return event.getProfilingInfo(c.CL_PROFILING_COMMAND_SUBMIT);
    }

    pub fn commandStartTime(event: Event) !u64 {
        return event.getProfilingInfo(c.CL_PROFILING_COMMAND_START);
    }

    pub fn commandEndTime(event: Event) !u64 {
        return event.getProfilingInfo(c.CL_PROFILING_COMMAND_END);
    }

    pub fn commandCompleteTime(event: Event) !u64 {
        return event.getProfilingInfo(c.CL_PROFILING_COMMAND_COMPLETE);
    }

    fn getProfilingInfo(event: Event, info: c.cl_profiling_info) !u64 {
        var value: ulong = undefined;
        return switch (c.clGetEventProfilingInfo(event.handle, info, @sizeOf(ulong), &value, null)) {
            c.CL_SUCCESS => value,
            c.CL_PROFILING_INFO_NOT_AVAILABLE => unreachable,
            c.CL_INVALID_VALUE => unreachable,
            c.CL_INVALID_EVENT => unreachable,
            c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
            c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
            else => unreachable, // Undocumented error
        };
    }
};

pub fn waitForEvents(events: []const Event) !void {
    return switch (c.clWaitForEvents(@intCast(events.len), @ptrCast(events.ptr))) {
        c.CL_SUCCESS => {},
        c.CL_INVALID_VALUE => unreachable,
        c.CL_INVALID_CONTEXT => unreachable,
        c.CL_INVALID_EVENT => unreachable,
        c.CL_EXEC_STATUS_ERROR_FOR_EVENTS_IN_WAIT_LIST => unreachable,
        c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
        c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
        else => unreachable, // Undocumented error
    };
}

pub fn Buffer(comptime T: type) type {
    return extern struct {
        const Self = @This();

        pub const Flags = packed struct(c.cl_mem_flags) {
            read_write: bool = false,
            write_only: bool = false,
            read_only: bool = false,
            use_host_ptr: bool = false,
            alloc_host_ptr: bool = false,
            copy_host_ptr: bool = false,
            _reserved0: u1 = 0,
            host_write_only: bool = false,
            host_read_only: bool = false,
            host_no_access: bool = false,
            svm_fine_grain_buffer: bool = false,
            svm_atomics: bool = false,
            kernel_read_and_write: bool = false,
            _unused: u51 = 0,
        };

        handle: c.cl_mem,

        pub fn create(context: Context, flags: Flags, size: usize) !Self {
            return createBuffer(context, flags, size, null);
        }

        pub fn createWithData(context: Context, flags: Flags, data: []const T) !Self {
            var new_flags = flags;
            new_flags.copy_host_ptr = true;
            return createBuffer(context, new_flags, data.len, @ptrCast(data.ptr));
        }

        fn createBuffer(context: Context, flags: Flags, size: usize, host_ptr: ?*const T) !Self {
            var status: int = undefined;
            const buffer = c.clCreateBuffer(
                context.handle,
                @bitCast(flags),
                size * @sizeOf(T),
                @constCast(host_ptr),
                &status,
            );
            return switch (status) {
                c.CL_SUCCESS => .{.handle = buffer},
                c.CL_INVALID_CONTEXT => unreachable,
                c.CL_INVALID_PROPERTY => unreachable,
                c.CL_INVALID_VALUE => unreachable,
                c.CL_INVALID_BUFFER_SIZE => unreachable,
                c.CL_INVALID_HOST_PTR => unreachable,
                c.CL_MEM_OBJECT_ALLOCATION_FAILURE => return error.OutOfDeviceMemory,
                c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
                c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
                else => unreachable, // Undocumented error
            };
        }

        pub fn release(buffer: Self) void {
            switch (c.clReleaseMemObject(buffer.handle)) {
                c.CL_SUCCESS => {},
                c.CL_INVALID_MEM_OBJECT => unreachable,
                // Ignore any errors
                c.CL_OUT_OF_RESOURCES => {},
                c.CL_OUT_OF_HOST_MEMORY => {},
                else => unreachable, // Undocumented error
            }
        }

        pub fn retain(buffer: Self) !void {
            switch (c.clRetainMemObject(buffer.handle)) {
                c.CL_SUCCESS => {},
                c.CL_INVALID_MEM_OBJECT => unreachable,
                c.CL_OUT_OF_RESOURCES => return error.OutOfDeviceResources,
                c.CL_OUT_OF_HOST_MEMORY => return error.OutOfMemory,
                else => unreachable, // Undocumented error
            }
        }
    };
}
