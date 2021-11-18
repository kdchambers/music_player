// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const vk = @import("vulkan");
const std = @import("std");
const assert = std.debug.assert;
const log = std.log;
const Allocator = std.mem.Allocator;

// TODO: Add format function for std print instead
pub fn logDevicePhysicalMemoryProperties(memory_properties: vk.PhysicalDeviceMemoryProperties) void {
    var heap_count: u32 = memory_properties.memoryHeapCount;

    var i: u32 = 0;
    while (i < heap_count) {
        log.info("Heap #{}", .{i});
        log.info("  Capacity: {} bytes", .{memory_properties.memoryHeaps[i].size});
        log.info("  Device Local:   {}", .{memory_properties.memoryHeaps[i].flags.deviceLocal});
        log.info("  Multi Instance: {}", .{memory_properties.memoryHeaps[i].flags.multiInstance});

        i += 1;
    }

    var memory_type_counter: u32 = 0;
    var memory_type_count = memory_properties.memoryTypeCount;

    while (memory_type_counter < memory_type_count) : (memory_type_counter += 1) {
        log.info("Memory Type #{}", .{memory_type_counter});
        log.info("  Memory Heap Index: {}", .{memory_properties.memoryTypes[memory_type_counter].heapIndex});

        const memory_flags = memory_properties.memoryTypes[memory_type_counter].propertyFlags;
        log.info("  Device Local:     {}", .{memory_flags.deviceLocal});
        log.info("  Host Visible:     {}", .{memory_flags.hostVisible});
        log.info("  Host Coherent:    {}", .{memory_flags.hostCoherent});
        log.info("  Host Cached:      {}", .{memory_flags.hostCached});
        log.info("  Lazily Allocated: {}", .{memory_flags.lazilyAllocated});
        log.info("  Protected:        {}", .{memory_flags.protected});
    }
}

pub fn getImageMemoryRequirements(device: vk.Device, image: vk.Image) vk.MemoryRequirements {
    var memory_requirements: vk.MemoryRequirements = undefined;
    vk.vkGetImageMemoryRequirements(device, image, &memory_requirements);
    return memory_requirements;
}

pub fn getDevicePhysicalMemoryProperties(physical_device: vk.PhysicalDevice) vk.PhysicalDeviceMemoryProperties {
    var memory_properties: vk.PhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(physical_device, &memory_properties);
    return memory_properties;
}

pub fn allocateMemory(device: vk.Device, allocate_info: vk.MemoryAllocateInfo) !vk.DeviceMemory {
    var memory: vk.DeviceMemory = undefined;
    if (.SUCCESS != vk.vkAllocateMemory(device, &allocate_info, null, &memory)) {
        return error.AllocateMemoryFailed;
    }
    return memory;
}

pub fn createImageView(device: vk.Device, create_info: vk.ImageViewCreateInfo) !vk.ImageView {
    var image_view: vk.ImageView = undefined;
    if (vk.vkCreateImageView(device, &create_info, null, &image_view) != .SUCCESS) {
        return error.CreateImageViewFailed;
    }
    return image_view;
}

pub fn endCommandBuffer(command_buffer: vk.CommandBuffer) !void {
    if (vk.vkEndCommandBuffer(command_buffer) != .SUCCESS) {
        return error.EndCommandBufferFailed;
    }
}

pub fn beginCommandBuffer(command_buffer: vk.CommandBuffer, begin_command_info: vk.CommandBufferBeginInfo) !void {
    if (vk.vkBeginCommandBuffer(command_buffer, &begin_command_info) != .SUCCESS) {
        return error.BeginCommandBufferFailed;
    }
}

pub fn allocateCommandBuffers(allocator: *std.mem.Allocator, device: vk.Device, allocation_info: vk.CommandBufferAllocateInfo) ![]vk.CommandBuffer {
    var command_buffers: []vk.CommandBuffer = try allocator.alloc(vk.CommandBuffer, allocation_info.commandBufferCount);
    if (vk.vkAllocateCommandBuffers(device, &allocation_info, command_buffers.ptr) != .SUCCESS) {
        return error.AllocateCommandBuffersFailed;
    }
    return command_buffers;
}

pub fn allocateCommandBuffer(device: vk.Device, allocation_info: vk.CommandBufferAllocateInfo) !vk.CommandBuffer {
    assert(allocation_info.commandBufferCount == 1);
    var command_buffer: vk.CommandBuffer = undefined;
    if (vk.vkAllocateCommandBuffers(device, &allocation_info, @ptrCast([*]vk.CommandBuffer, &command_buffer)) != .SUCCESS) {
        return error.AllocateCommandBuffersFailed;
    }
    return command_buffer;
}

pub fn createBuffer(device: vk.Device, create_buffer_info: vk.BufferCreateInfo) !vk.Buffer {
    var buffer: vk.Buffer = undefined;
    if (.SUCCESS != vk.vkCreateBuffer(device, &create_buffer_info, null, &buffer)) {
        return error.CreateBufferFailed;
    }
    return buffer;
}

pub fn createImage(logical_device: vk.Device, create_image_info: vk.ImageCreateInfo) !vk.Image {
    var image: vk.Image = undefined;
    if (.SUCCESS != vk.vkCreateImage(logical_device, &create_image_info, null, &image)) {
        return error.CreateImageFailed;
    }
    return image;
}

pub fn createCommandPool(logical_device: vk.Device, command_pool_create_info: vk.CommandPoolCreateInfo) !vk.CommandPool {
    var command_pool: vk.CommandPool = undefined;
    if (.SUCCESS != vk.vkCreateCommandPool(logical_device, &command_pool_create_info, null, &command_pool)) {
        return error.CreateCommandPoolFailed;
    }
    return command_pool;
}

pub fn getPhysicalDeviceSurfaceFormatsKHRCount(physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !u32 {
    var format_count: u32 = undefined;

    if (vk.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, null) != .SUCCESS) {
        return error.FailedToGetNumberSurfaceFormats;
    }

    return format_count;
}

pub fn getPhysicalDeviceSurfacePresentModesKHRCount(physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !u32 {
    var present_mode_count: u32 = undefined;
    if (vk.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_mode_count, null) != .SUCCESS) {
        return error.FailedToGetNumberPresentModes;
    }
    return present_mode_count;
}

pub fn getPhysicalDeviceSurfacePresentModesKHR(allocator: *Allocator, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) ![]vk.PresentModeKHR {
    var present_mode_count: u32 = undefined;
    if (vk.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_mode_count, null) != .SUCCESS) {
        return error.FailedToGetPresentModesCount;
    }
    var present_modes = try allocator.alloc(vk.PresentModeKHR, present_mode_count);
    if (vk.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_mode_count, present_modes.ptr) != .SUCCESS) {
        return error.FailedToGetPresentModes;
    }

    return present_modes;
}

pub fn enumeratePhysicalDevices(allocator: *std.mem.Allocator, instance: vk.Instance) ![]vk.PhysicalDevice {
    var device_count: u32 = 0;
    if (vk.vkEnumeratePhysicalDevices(instance, &device_count, null) != .SUCCESS) {
        return error.FailedToGetPhysicalDevicesCount;
    }

    if (device_count == 0) {
        return error.NoDevicesFound;
    }

    const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
    if (vk.vkEnumeratePhysicalDevices(instance, &device_count, devices.ptr) != .SUCCESS) {
        return error.FailedToGetPhysicalDevices;
    }

    return devices;
}

pub fn createSwapchain(logical_device: vk.Device, create_info: vk.SwapchainCreateInfoKHR) !vk.SwapchainKHR {
    var swapchain: vk.SwapchainKHR = undefined;
    if (vk.vkCreateSwapchainKHR(logical_device, &create_info, null, &swapchain) != .SUCCESS) {
        return error.FailedToCreateSwapchain;
    }

    return swapchain;
}

pub fn getSwapchainImagesKHR(allocator: *std.mem.Allocator, logical_device: vk.Device, swapchain: vk.SwapchainKHR) ![]vk.Image {
    var image_count: u32 = undefined;
    if (vk.vkGetSwapchainImagesKHR(logical_device, swapchain, &image_count, null) != .SUCCESS) {
        return error.FailedToGetSwapchainImagesCount;
    }

    var swapchain_images = try allocator.alloc(vk.Image, image_count);
    if (vk.vkGetSwapchainImagesKHR(logical_device, swapchain, &image_count, swapchain_images.ptr) != .SUCCESS) {
        return error.FailedToGetSwapchainImages;
    }

    return swapchain_images;
}

// TODO: Take ShaderModuleCreateInfo as param
pub fn createShaderModule(logical_device: vk.Device, code: []align(@alignOf(u32)) const u8) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .sType = vk.StructureType.SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = @ptrCast([*]const u32, &code[0]),
        .pNext = null,
        .flags = .{},
    };

    var shader_module: vk.ShaderModule = undefined;
    if (vk.vkCreateShaderModule(logical_device, &create_info, null, &shader_module) != .SUCCESS) {
        return error.CreateShaderModuleFailed;
    }

    return shader_module;
}

pub fn getPhysicalDeviceSurfaceFormatsKHR(allocator: *std.mem.Allocator, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) ![]vk.SurfaceFormatKHR {
    var format_count: u32 = undefined;
    if (vk.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, null) != .SUCCESS) {
        return error.FailedToGetSurfaceFormatCount;
    }

    // Vulkan 1.1 spec specifies that format_count will not be 0
    assert(format_count != 0);

    var available_formats: []vk.SurfaceFormatKHR = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
    if (vk.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, available_formats.ptr) != .SUCCESS) {
        return error.FailedToGetSurfaceFormats;
    }

    return available_formats;
}

pub fn getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !vk.SurfaceCapabilitiesKHR {
    var surface_capabilities: vk.SurfaceCapabilitiesKHR = undefined;
    if (vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &surface_capabilities) != .SUCCESS) {
        return error.UnableToGetSurfaceCapabilities;
    }
    return surface_capabilities;
}

pub fn bindBufferMemory(logical_device: vk.Device, buffer: vk.Buffer, memory: vk.DeviceMemory, offset: u32) !void {
    if (.SUCCESS != vk.vkBindBufferMemory(logical_device, buffer, memory, offset)) {
        return error.BindBufferMemoryFailed;
    }
}

// TODO: Audit
pub fn createBufferOnMemory(logical_device: vk.Device, size: vk.DeviceSize, memory_offset: u32, usage: vk.BufferUsageFlags, memory: vk.DeviceMemory) !vk.Buffer {
    var buffer_create_info = vk.BufferCreateInfo{
        .sType = vk.StructureType.BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = .EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = undefined,
        .flags = .{},
        .pNext = null,
    };

    var buffer: vk.Buffer = undefined;

    if (vk.vkCreateBuffer(logical_device, &buffer_create_info, null, &buffer) != .SUCCESS) {
        return error.CreateBufferFailed;
    }

    if (vk.vkBindBufferMemory(logical_device, buffer, memory, memory_offset) != .SUCCESS) {
        return error.BindBufferMemoryFailed;
    }

    return buffer;
}

// TODO: Audit
pub fn chooseSwapSurfaceFormat(available_formats: []vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    if (available_formats.len == 1 and available_formats[0].format == .UNDEFINED) {
        return vk.SurfaceFormatKHR{
            .format = .B8G8R8A8_UNORM,
            .colorSpace = .SRGB_NONLINEAR,
        };
    }

    for (available_formats) |available_format| {
        if (available_format.format == .B8G8R8A8_UNORM and available_format.colorSpace == .SRGB_NONLINEAR) {
            return available_format;
        }
    }

    log.warn("Failed to find optimal surface format", .{});

    return available_formats[0];
}

pub fn createFrameBuffer(logical_device: vk.Device, create_info: vk.FramebufferCreateInfo) !vk.Framebuffer {
    var framebuffer: vk.Framebuffer = undefined;
    if (vk.vkCreateFramebuffer(logical_device, &create_info, null, &framebuffer) != .SUCCESS) {
        return error.CreateFrameBufferFailed;
    }
    return framebuffer;
}

pub fn createFrameBuffersAlloc(allocator: *Allocator, logical_device: vk.Device, create_infos: []vk.FramebufferCreateInfo) ![]vk.Framebuffer {
    var framebuffers = try allocator.alloc(vk.Framebuffer, create_infos.len);
    errdefer allocator.free(framebuffers);

    for (create_infos) |create_info, i| {
        framebuffers[i] = try createFrameBuffer(logical_device, create_info);
    }

    return framebuffers;
}

pub fn createInstance(create_info: vk.InstanceCreateInfo) !vk.Instance {
    var instance: vk.Instance = undefined;
    if (vk.vkCreateInstance(&create_info, null, &instance) != .SUCCESS) {
        return error.InstanceCreationFailed;
    }
    return instance;
}

pub fn createDevice(physical_device: vk.PhysicalDevice, create_info: vk.DeviceCreateInfo) !vk.Device {
    var logical_device: vk.Device = undefined;
    if (vk.vkCreateDevice(physical_device, &create_info, null, &logical_device) != .SUCCESS) {
        return error.FailedToCreateDevice;
    }

    return logical_device;
}

pub fn deviceSupportsExtensions(allocator: *Allocator, physical_device: vk.PhysicalDevice, requested_extensions: []const [*:0]const u8) !bool {
    var extension_count: u32 = undefined;
    if (vk.vkEnumerateDeviceExtensionProperties(physical_device, null, &extension_count, null) != .SUCCESS) {
        return error.FailedToGetDevicePropertiesCount;
    }

    const available_extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
    defer allocator.free(available_extensions);

    if (vk.vkEnumerateDeviceExtensionProperties(physical_device, null, &extension_count, available_extensions.ptr) != .SUCCESS) {
        return error.FailedToGetDeviceProperties;
    }

    dev_extensions: for (requested_extensions) |requested_extension| {
        for (available_extensions) |available_extension| {
            if (std.cstr.cmp(requested_extension, &available_extension.extensionName) == 0) {
                continue :dev_extensions;
            }
        }

        return false;
    }

    return true;
}

pub fn createSurfaceGlfw(instance: vk.Instance, window: *vk.GLFWwindow) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    if (.SUCCESS != vk.glfwCreateWindowSurface(instance, window, null, &surface)) {
        var err_description: [*:0]u8 = undefined;
        _ = vk.glfwGetError(&err_description);
        log.warn("Failed to create surface: {s}", .{err_description});
        return error.FailedToCreateSurface;
    }

    return surface;
}

pub fn glfwGetRequiredInstanceExtensions() ![]const [*:0]const u8 {
    var glfwExtensionCount: u32 = 0;
    var glfwExtensions = vk.glfwGetRequiredInstanceExtensions(&glfwExtensionCount);

    if (glfwExtensionCount == 0 or glfwExtensions == null) {
        return error.GetRequiredGLFWExtensionsFailed;
    }

    return glfwExtensions.?[0..glfwExtensionCount];
}

pub fn logMemoryRequirements(memory_requirements: vk.MemoryRequirements) void {
    log.info("Memory requirements for image", .{});
    log.info("  Size:        {}", .{memory_requirements.size});
    log.info("  Alignment:   {}", .{memory_requirements.alignment});
    log.info("  Memory Type: {}", .{memory_requirements.memoryTypeBits});
}

pub fn createRenderPass(logical_device: vk.Device, create_info: vk.RenderPassCreateInfo) !vk.RenderPass {
    var render_pass: vk.RenderPass = undefined;
    if (vk.vkCreateRenderPass(logical_device, &create_info, null, &render_pass) != .SUCCESS) {
        return error.CreateRenderPassFailed;
    }

    return render_pass;
}

pub fn beginRenderPass(command_buffer: vk.CommandBuffer, pRenderPassBegin: *const RenderPassBeginInfo, contents: SubpassContents) void {
    vk.vkCmdBeginRenderPass(command_buffer, &begin_render_pass_info, .INLINE);
}
