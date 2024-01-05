//! This module has some Zig-style wrappers for OpenCL functions.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const c = @cImport({
    @cInclude("CL/opencl.h");
});

pub const uint = c.cl_uint;

pub const Context = c.cl_context;
pub const CommandQueue = c.cl_command_queue;
pub const Mem = c.cl_mem;
pub const Program = c.cl_program;
pub const Kernel = c.cl_kernel;
pub const Event = c.cl_event;

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
};
