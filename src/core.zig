// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

// Force client code to draw in order, expect reserve a space at the start of the index buffer
// for out of order draw calls (Let the user/client configure)

const std = @import("std");
const c = std.c;
const os = std.os;
const fs = std.fs;
const fmt = std.fmt;
const builtin = @import("builtin");
const log = std.log;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zigimg = @import("zigimg");

const ft = text.ft;
const vk = @import("vulkan");
const glfw = vk.glfw;

const text = @import("text.zig");
const gui = @import("gui");
const zvk = @import("vulkan_wrapper.zig");
const GenericPipeline = @import("pipelines/generic.zig").GenericPipeline;
const geometry = @import("geometry");
const graphics = @import("graphics.zig");
const RGBA = graphics.RGBA;
const Mesh = graphics.Mesh;
const GenericVertex = text.GenericVertex;
const TextCursor = @import("text_cursor.zig").TextCursor;
const QuadFace = graphics.QuadFace;

const event_system = @import("event_system.zig");

const memory = @import("memory.zig");
const FixedBuffer = memory.FixedBuffer;

const utility = @import("utility.zig");

const audio = @import("audio.zig");

var is_render_requested: bool = true;

// TODO: Move?
const null_face: QuadFace(GenericVertex) = .{ .{}, .{}, .{}, .{} };

// Build User Configuration
const BuildConfig = struct {
// zig fmt: off
    comptime app_name: [:0]const u8 = "zedikor",
    comptime font_size: u16 = 16,
    comptime font_path: [:0]const u8 = "/usr/share/fonts/TTF/Hack-Regular.ttf",
    comptime window_dimensions: geometry.Dimensions2D(.pixel) = .{
        .width = 800,
        .height = 600,
    }
    // zig fmt: on
};

const config: BuildConfig = .{};

// Types
const GraphicsContext = struct {
    window: *vk.GLFWwindow,
    vk_instance: vk.Instance,
    surface: vk.SurfaceKHR,
    surface_format: vk.SurfaceFormatKHR,
    physical_device: vk.PhysicalDevice,
    logical_device: vk.Device,
    graphics_present_queue: vk.Queue, // Same queue used for graphics + presenting
    graphics_present_queue_index: u32,
    swapchain: vk.SwapchainKHR,
    swapchain_extent: vk.Extent2D,
    swapchain_image_format: vk.Format,
    swapchain_images: []vk.Image,
    swapchain_image_views: []vk.ImageView,
    command_pool: vk.CommandPool,
    command_buffers: []vk.CommandBuffer,
    images_available: []vk.Semaphore,
    renders_finished: []vk.Semaphore,
    inflight_fences: []vk.Fence,
};

// Globals

var screen_dimensions_previous = geometry.Dimensions2D(.pixel){
    .width = 0,
    .height = 0,
};

var screen_dimensions = geometry.Dimensions2D(.pixel){
    .width = 0,
    .height = 0,
};

var current_frame: u32 = 0;
var framebuffer_resized: bool = true;

var text_buffer_dirty: bool = true;

var mapped_device_memory: [*]u8 = undefined;

const max_texture_quads_per_render: u32 = 1024 * 2;

// Beginning index for indices / vertices in mapped device memory
const indices_range_index_begin = 0;
const indices_range_size = max_texture_quads_per_render * @sizeOf(u16) * 6; // 12 kb
const indices_range_count = indices_range_size / @sizeOf(u16);

const vertices_range_index_begin = indices_range_size;
const vertices_range_size = max_texture_quads_per_render * @sizeOf(GenericVertex) * 4; // 80 kb
const vertices_range_count = vertices_range_size / @sizeOf(GenericVertex);

const memory_size = indices_range_size + vertices_range_size;

var glyph_set: text.GlyphSet = undefined;

var vertex_buffer: []QuadFace(GenericVertex) = undefined;

// TODO: This is actually a count of the quads.
//       All it does it let us determine the number of indices to render
var vertex_buffer_count: u32 = 0;

const enable_validation_layers = if (builtin.mode == .Debug) true else false;
const validation_layers = if (enable_validation_layers) [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"} else [*:0]const u8{};
const device_extensions = [_][*:0]const u8{vk.KHR_SWAPCHAIN_EXTENSION_NAME};

const max_frames_in_flight: u32 = 2;
var texture_pipeline: GenericPipeline = undefined;

var texture_image_view: vk.ImageView = undefined;
var texture_image: vk.Image = undefined;
var texture_vertices_buffer: vk.Buffer = undefined;
var texture_indices_buffer: vk.Buffer = undefined;

var button_faces: []QuadFace(GenericVertex) = undefined;

const help_message =
    \\music_player [<options>] [<filename>]
    \\options:
    \\    --help: display this help message
    \\
;

var music_dir: std.fs.Dir = undefined;
const music_dir_path = "/mnt/data/media/music/Kaytranada/";

const media_library_directory: std.fs.Dir = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    // Let's read all the files in a directory
    music_dir = try std.fs.openDirAbsolute(music_dir_path, .{ .iterate = true });
    var iterator = music_dir.iterate();
    var entry = try iterator.next();

    const max_audio_files: u32 = 10;
    var audio_file_index: u32 = 0;
    while (entry != null and audio_files.count < 10) {
        if (audio_file_index >= max_audio_files) break;
        const file_name = entry.?.name;
        if (std.mem.eql(u8, file_name[file_name.len - 4 ..], "flac")) {
            const new_name = try allocator.dupeZ(u8, entry.?.name);

            const paths: [2][]const u8 = .{ music_dir_path, file_name };
            const full_path = std.fs.path.joinZ(allocator, paths[0..]) catch null;
            defer allocator.free(full_path.?);

            // TODO:
            const track_metadata = try audio.flac.extractTrackMetadata(full_path.?);

            log.info("Dir: {s}", .{new_name});
            _ = track_metadatas.append(track_metadata);
            _ = audio_files.append(new_name);
            audio_file_index += 1;
        }

        entry = try iterator.next();
    }

    var graphics_context: GraphicsContext = undefined;
    graphics_context.window = try initWindow(config.window_dimensions, config.app_name);

    const instance_extension = try zvk.glfwGetRequiredInstanceExtensions();

    for (instance_extension) |extension| {
        log.info("Extension: {s}", .{extension});
    }

    graphics_context.vk_instance = try zvk.createInstance(vk.InstanceCreateInfo{
        .sType = vk.StructureType.INSTANCE_CREATE_INFO,
        .pApplicationInfo = &vk.ApplicationInfo{
            .sType = vk.StructureType.APPLICATION_INFO,
            .pApplicationName = config.app_name,
            .applicationVersion = vk.MAKE_VERSION(0, 0, 1),
            .pEngineName = config.app_name,
            .engineVersion = vk.MAKE_VERSION(0, 0, 1),
            .apiVersion = vk.MAKE_VERSION(1, 2, 0),
            .pNext = null,
        },
        .enabledExtensionCount = @intCast(u32, instance_extension.len),
        .ppEnabledExtensionNames = instance_extension.ptr,
        .enabledLayerCount = if (enable_validation_layers) validation_layers.len else 0,
        .ppEnabledLayerNames = if (enable_validation_layers) &validation_layers else undefined,
        .pNext = null,
        .flags = .{},
    });

    graphics_context.surface = try zvk.createSurfaceGlfw(graphics_context.vk_instance, graphics_context.window);

    var present_mode: vk.PresentModeKHR = .FIFO;

    // Find a suitable physical device to use
    const best_physical_device = outer: {
        const physical_devices = try zvk.enumeratePhysicalDevices(allocator, graphics_context.vk_instance);
        defer allocator.free(physical_devices);

        for (physical_devices) |physical_device| {
            if ((try zvk.deviceSupportsExtensions(allocator, physical_device, device_extensions[0..])) and
                (try zvk.getPhysicalDeviceSurfaceFormatsKHRCount(physical_device, graphics_context.surface)) != 0 and
                (try zvk.getPhysicalDeviceSurfacePresentModesKHRCount(physical_device, graphics_context.surface)) != 0)
            {
                var supported_present_modes = try zvk.getPhysicalDeviceSurfacePresentModesKHR(allocator, physical_device, graphics_context.surface);
                defer allocator.free(supported_present_modes);

                // FIFO should be guaranteed by vulkan spec but validation layers are triggered
                // when vkGetPhysicalDeviceSurfacePresentModesKHR isn't used to get supported PresentModes
                for (supported_present_modes) |supported_present_mode| {
                    if (supported_present_mode == .FIFO) present_mode = .FIFO else continue;
                }

                const best_family_queue_index = inner: {
                    var queue_family_count: u32 = 0;
                    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);

                    if (queue_family_count == 0) {
                        break :inner null;
                    }

                    comptime const max_family_queues: u32 = 16;
                    if (queue_family_count > max_family_queues) {
                        log.warn("Some family queues for selected device ignored", .{});
                    }

                    var queue_families: [max_family_queues]vk.QueueFamilyProperties = undefined;
                    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, &queue_families);

                    var i: u32 = 0;
                    while (i < queue_family_count) : (i += 1) {
                        if (queue_families[i].queueCount <= 0) {
                            continue;
                        }

                        if (queue_families[i].queueFlags.graphics) {
                            var present_support: vk.Bool32 = 0;
                            if (vk.vkGetPhysicalDeviceSurfaceSupportKHR(physical_device, i, graphics_context.surface, &present_support) != .SUCCESS) {
                                return error.FailedToGetPhysicalDeviceSupport;
                            }

                            if (present_support != vk.FALSE) {
                                break :inner i;
                            }
                        }
                    }

                    break :inner null;
                };

                if (best_family_queue_index) |queue_index| {
                    graphics_context.graphics_present_queue_index = queue_index;
                    break :outer physical_device;
                }
            }
        }

        break :outer null;
    };

    if (best_physical_device) |physical_device| {
        graphics_context.physical_device = physical_device;
    } else return error.NoSuitablePhysicalDevice;

    graphics_context.logical_device = try zvk.createDevice(graphics_context.physical_device, vk.DeviceCreateInfo{
        .sType = vk.StructureType.DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = @ptrCast([*]vk.DeviceQueueCreateInfo, &vk.DeviceQueueCreateInfo{
            .sType = vk.StructureType.DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = graphics_context.graphics_present_queue_index,
            .queueCount = 1,
            .pQueuePriorities = &[1]f32{1.0},
            .flags = .{},
            .pNext = null,
        }),
        .pEnabledFeatures = &vk.PhysicalDeviceFeatures{
            .robustBufferAccess = vk.FALSE,
            .fullDrawIndexUint32 = vk.FALSE,
            .imageCubeArray = vk.FALSE,
            .independentBlend = vk.FALSE,
            .geometryShader = vk.FALSE,
            .tessellationShader = vk.FALSE,
            .sampleRateShading = vk.FALSE,
            .dualSrcBlend = vk.FALSE,
            .logicOp = vk.FALSE,
            .multiDrawIndirect = vk.FALSE,
            .drawIndirectFirstInstance = vk.FALSE,
            .depthClamp = vk.FALSE,
            .depthBiasClamp = vk.FALSE,
            .fillModeNonSolid = vk.FALSE,
            .depthBounds = vk.FALSE,
            .wideLines = vk.FALSE,
            .largePoints = vk.FALSE,
            .alphaToOne = vk.FALSE,
            .multiViewport = vk.FALSE,
            .samplerAnisotropy = vk.TRUE,
            .textureCompressionETC2 = vk.FALSE,
            .textureCompressionASTC_LDR = vk.FALSE,
            .textureCompressionBC = vk.FALSE,
            .occlusionQueryPrecise = vk.FALSE,
            .pipelineStatisticsQuery = vk.FALSE,
            .vertexPipelineStoresAndAtomics = vk.FALSE,
            .fragmentStoresAndAtomics = vk.FALSE,
            .shaderTessellationAndGeometryPointSize = vk.FALSE,
            .shaderImageGatherExtended = vk.FALSE,
            .shaderStorageImageExtendedFormats = vk.FALSE,
            .shaderStorageImageMultisample = vk.FALSE,
            .shaderStorageImageReadWithoutFormat = vk.FALSE,
            .shaderStorageImageWriteWithoutFormat = vk.FALSE,
            .shaderUniformBufferArrayDynamicIndexing = vk.FALSE,
            .shaderSampledImageArrayDynamicIndexing = vk.FALSE,
            .shaderStorageBufferArrayDynamicIndexing = vk.FALSE,
            .shaderStorageImageArrayDynamicIndexing = vk.FALSE,
            .shaderClipDistance = vk.FALSE,
            .shaderCullDistance = vk.FALSE,
            .shaderFloat64 = vk.FALSE,
            .shaderInt64 = vk.FALSE,
            .shaderInt16 = vk.FALSE,
            .shaderResourceResidency = vk.FALSE,
            .shaderResourceMinLod = vk.FALSE,
            .sparseBinding = vk.FALSE,
            .sparseResidencyBuffer = vk.FALSE,
            .sparseResidencyImage2D = vk.FALSE,
            .sparseResidencyImage3D = vk.FALSE,
            .sparseResidency2Samples = vk.FALSE,
            .sparseResidency4Samples = vk.FALSE,
            .sparseResidency8Samples = vk.FALSE,
            .sparseResidency16Samples = vk.FALSE,
            .sparseResidencyAliased = vk.FALSE,
            .variableMultisampleRate = vk.FALSE,
            .inheritedQueries = vk.FALSE,
        },
        .enabledExtensionCount = device_extensions.len,
        .ppEnabledExtensionNames = &device_extensions,
        .enabledLayerCount = if (enable_validation_layers) validation_layers.len else 0,
        .ppEnabledLayerNames = if (enable_validation_layers) &validation_layers else undefined,
        .flags = .{},
        .pNext = null,
    });

    vk.vkGetDeviceQueue(graphics_context.logical_device, graphics_context.graphics_present_queue_index, 0, &graphics_context.graphics_present_queue);

    var available_formats: []vk.SurfaceFormatKHR = try zvk.getPhysicalDeviceSurfaceFormatsKHR(allocator, graphics_context.physical_device, graphics_context.surface);
    defer allocator.free(available_formats);

    graphics_context.surface_format = zvk.chooseSwapSurfaceFormat(available_formats);
    graphics_context.swapchain_image_format = graphics_context.surface_format.format;

    try setupApplication(allocator, &graphics_context);

    try appLoop(allocator, &graphics_context);

    //
    // Deallocate resources
    //

    for (audio_files.items[0..audio_files.count]) |audio_file| {
        allocator.free(audio_file);
    }

    cleanupSwapchain(allocator, &graphics_context);
    clean(allocator, &graphics_context);

    log.info("Terminated cleanly", .{});
}

// TODO:
fn clean(allocator: *Allocator, app: *GraphicsContext) void {
    allocator.free(app.images_available);
    allocator.free(app.renders_finished);
    allocator.free(app.inflight_fences);

    allocator.free(app.swapchain_image_views);
    allocator.free(app.swapchain_images);

    allocator.free(glyph_set.image);

    texture_pipeline.deinit(allocator);
    glyph_set.deinit(allocator);
}

fn cleanupSwapchain(allocator: *Allocator, app: *GraphicsContext) void {
    vk.vkFreeCommandBuffers(app.logical_device, app.command_pool, @intCast(u32, app.command_buffers.len), app.command_buffers.ptr);
    allocator.free(app.command_buffers);

    for (app.swapchain_image_views) |image_view| {
        vk.vkDestroyImageView(app.logical_device, image_view, null);
    }

    vk.vkDestroySwapchainKHR(app.logical_device, app.swapchain, null);
}

fn recreateSwapchain(allocator: *Allocator, app: *GraphicsContext) !void {
    _ = vk.vkDeviceWaitIdle(app.logical_device);
    cleanupSwapchain(allocator, app);

    const available_formats: []vk.SurfaceFormatKHR = try zvk.getPhysicalDeviceSurfaceFormatsKHR(allocator, app.physical_device, app.surface);
    const surface_format = zvk.chooseSwapSurfaceFormat(available_formats);
    allocator.free(available_formats);

    var surface_capabilities: vk.SurfaceCapabilitiesKHR = undefined;
    if (vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(app.physical_device, app.surface, &surface_capabilities) != .SUCCESS) {
        return error.FailedToGetSurfaceCapabilities;
    }

    if (surface_capabilities.currentExtent.width == 0xFFFFFFFF or surface_capabilities.currentExtent.height == 0xFFFFFFFF) {
        var screen_width: i32 = undefined;
        var screen_height: i32 = undefined;
        vk.glfwGetFramebufferSize(app.window, &screen_width, &screen_height);

        if (screen_width <= 0 or screen_height <= 0) {
            return error.InvalidScreenDimensions;
        }

        app.swapchain_extent.width = @intCast(u32, screen_width);
        app.swapchain_extent.height = @intCast(u32, screen_height);

        screen_dimensions_previous = screen_dimensions;

        screen_dimensions.width = app.swapchain_extent.width;
        screen_dimensions.height = app.swapchain_extent.height;
    }

    app.swapchain = try zvk.createSwapchain(app.logical_device, vk.SwapchainCreateInfoKHR{
        .sType = vk.StructureType.SWAPCHAIN_CREATE_INFO_KHR,
        .surface = app.surface,
        .minImageCount = surface_capabilities.minImageCount + 1,
        .imageFormat = app.swapchain_image_format,
        .imageColorSpace = surface_format.colorSpace,
        .imageExtent = app.swapchain_extent,
        .imageArrayLayers = 1,
        .imageUsage = .{ .colorAttachment = true },
        .imageSharingMode = .EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = undefined,
        .preTransform = surface_capabilities.currentTransform,
        .compositeAlpha = .{ .opaqueFlag = true },
        .presentMode = .FIFO,
        .clipped = vk.TRUE,
        .flags = .{},
        .oldSwapchain = null,
        .pNext = null,
    });

    // TODO:
    allocator.free(app.swapchain_images);

    // TODO: We already have the memory allocated, we should just be able to reuse it
    //       Another point for making alloc and non-alloc functions
    app.swapchain_images = try zvk.getSwapchainImagesKHR(allocator, app.logical_device, app.swapchain);

    app.swapchain_image_views = try allocator.realloc(app.swapchain_image_views, app.swapchain_images.len);
    for (app.swapchain_image_views) |*image_view, i| {
        const image_view_create_info = vk.ImageViewCreateInfo{
            .sType = vk.StructureType.IMAGE_VIEW_CREATE_INFO,
            .image = app.swapchain_images[i],
            .viewType = .T_2D,
            .format = app.swapchain_image_format,
            .components = vk.ComponentMapping{
                .r = .IDENTITY,
                .g = .IDENTITY,
                .b = .IDENTITY,
                .a = .IDENTITY,
            },
            .subresourceRange = vk.ImageSubresourceRange{
                .aspectMask = .{ .color = true },
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .pNext = null,
            .flags = .{},
        };

        image_view.* = try zvk.createImageView(app.logical_device, image_view_create_info);
    }

    try texture_pipeline.create(allocator, app.logical_device, app.surface_format.format, app.swapchain_extent, app.swapchain_image_views, texture_image_view);

    app.command_buffers = try zvk.allocateCommandBuffers(allocator, app.logical_device, vk.CommandBufferAllocateInfo{
        .sType = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = app.command_pool,
        .level = .PRIMARY,
        .commandBufferCount = @intCast(u32, app.swapchain_images.len),
        .pNext = null,
    });

    try updateCommandBuffers(app);
}

const freetype = struct {
    pub fn init() !ft.FT_Library {
        var libary: ft.FT_Library = undefined;
        if (ft.FT_Init_FreeType(&libary) != ft.FT_Err_Ok) {
            return error.InitFreeTypeLibraryFailed;
        }
        return libary;
    }

    pub fn newFace(libary: ft.FT_Library, font_path: [:0]const u8, face_index: i64) !ft.FT_Face {
        var face: ft.FT_Face = undefined;
        if (ft.FT_New_Face(libary, font_path, 0, &face) != ft.FT_Err_Ok) {
            return error.CreateNewFaceFailed;
        }
        return face;
    }
};

// TODO: Nuke
fn cropImage(allocator: *Allocator, source_image: []RGBA(f32), source_dimensions: geometry.Dimensions2D(.carthesian), extent: geometry.Extent2D(.carthesian)) ![]RGBA(f32) {
    log.info("Source {}x{} Target {}x{}", .{ source_dimensions.width, source_dimensions.height, extent.width, extent.height });

    if (source_dimensions.width == extent.width and source_dimensions.height == extent.height) {
        return error.DimensionsMatch;
    }

    var dest_image = try allocator.alloc(RGBA(f32), extent.width * extent.height);

    var y: u32 = extent.y;
    var dest_i: u32 = 0;

    while (y < (extent.y + extent.height)) : (y += 1) {
        var x: u32 = extent.x;
        while (x < (extent.x + extent.width)) : (x += 1) {
            dest_image[dest_i] = source_image[x + (y * source_dimensions.width)];
            dest_i += 1;
        }
    }

    assert(dest_image.len == (extent.width * extent.height));
    log.info("Image cropped to {}x{} {} pixels", .{ extent.width, extent.height, dest_image.len });

    return dest_image;
}

// TODO: Write, and then later nuke
fn shrinkImage(allocator: *Allocator, source_image: []RGBA(f32), old_dimensions: geometry.Dimensions2D(.carthesian), new_dimensions: geometry.Dimensions2D(.carthesian)) ![]RGBA(f32) {
    var new_image = try allocator.alloc(RGBA(f32), new_dimensions.width * new_dimensions.height);
    const compression_ratio_x: u32 = old_dimensions.width / new_dimensions.width;
    const compression_ratio_y: u32 = old_dimensions.height / new_dimensions.height;

    assert(source_image.len == (old_dimensions.height * old_dimensions.width));

    log.info("Merge ratio: {}x{}", .{ compression_ratio_x, compression_ratio_y });

    log.info("Source image size: {}", .{source_image.len});
    log.info("Destination image size: {}", .{new_image.len});

    // TODO: MERGE
    assert(compression_ratio_y > 0);
    assert(compression_ratio_x > 0);

    var dst_y: u32 = 0;

    const pixels_to_merge_count: u32 = compression_ratio_x * compression_ratio_y;
    log.info("Pixels to merge count: {}", .{pixels_to_merge_count});

    while (dst_y < new_dimensions.height) : (dst_y += 1) {
        var dst_x: u32 = 0;
        while (dst_x < new_dimensions.width) : (dst_x += 1) {
            assert(dst_x * dst_y < new_dimensions.width * new_dimensions.height);

            var average_r: f32 = 0.0;
            var average_g: f32 = 0.0;
            var average_b: f32 = 0.0;
            var compression_x_count: u32 = 0;
            var compression_y_count: u32 = 0;

            // Indicing algorithm
            //  x + (y * height)
            //  (x * merge_x) + (y * merge_y * height)
            while (compression_y_count < compression_ratio_y) : (compression_y_count += 1) {
                const source_y = (dst_y * compression_ratio_y) + compression_y_count;
                while (compression_x_count < compression_ratio_x) : (compression_x_count += 1) {
                    const source_x = (dst_x * compression_ratio_x) + compression_x_count;

                    if (compression_ratio_y == 1) assert(source_y == dst_y);
                    if (compression_ratio_x == 1) assert(source_x == dst_x);

                    average_r += source_image[source_x + (source_y * old_dimensions.width)].r;
                    average_g += source_image[source_x + (source_y * old_dimensions.width)].g;
                    average_b += source_image[source_x + (source_y * old_dimensions.width)].b;
                }
            }

            new_image[dst_x + (dst_y * new_dimensions.width)].r = average_r / @intToFloat(f32, pixels_to_merge_count);
            new_image[dst_x + (dst_y * new_dimensions.width)].g = average_g / @intToFloat(f32, pixels_to_merge_count);
            new_image[dst_x + (dst_y * new_dimensions.width)].b = average_b / @intToFloat(f32, pixels_to_merge_count);
            new_image[dst_x + (dst_y * new_dimensions.width)].a = 1.0;

            if (pixels_to_merge_count == 1) {
                assert(source_image[dst_x + (dst_y * new_dimensions.width)].r == average_r);
                assert(source_image[dst_x + (dst_y * new_dimensions.width)].g == average_g);
                assert(source_image[dst_x + (dst_y * new_dimensions.width)].b == average_b);
            }
        }
    }

    if (pixels_to_merge_count == 1) {
        assert(new_image.len == source_image.len);
        for (new_image) |pixel, i| {
            assert(pixel.r == source_image[i].r);
            assert(pixel.g == source_image[i].g);
            assert(pixel.b == source_image[i].b);
        }
    }

    return new_image;
}

// TODO: Update name based on output type (RGBA(f32))
fn convertImageRgba32(allocator: *Allocator, source_image: []zigimg.color.Rgba32) ![]RGBA(f32) {
    var new_image = try allocator.alloc(RGBA(f32), source_image.len);
    for (source_image) |source_pixel, i| {
        new_image[i].r = @intToFloat(f32, source_pixel.R) / 255.0;
        new_image[i].g = @intToFloat(f32, source_pixel.G) / 255.0;
        new_image[i].b = @intToFloat(f32, source_pixel.B) / 255.0;
        new_image[i].a = 1.0;
    }
    return new_image;
}

fn convertImageRgb24(allocator: *Allocator, source_image: []zigimg.color.Rgb24) ![]RGBA(f32) {
    var new_image = try allocator.alloc(RGBA(f32), source_image.len);
    for (source_image) |source_pixel, i| {
        new_image[i].r = @intToFloat(f32, source_pixel.R) / 255.0;
        new_image[i].g = @intToFloat(f32, source_pixel.G) / 255.0;
        new_image[i].b = @intToFloat(f32, source_pixel.B) / 255.0;
        new_image[i].a = 1.0;
    }
    return new_image;
}

var image_memory_map: [*]u8 = undefined;
var texture_size_bytes: usize = 0;

fn setupApplication(allocator: *Allocator, app: *GraphicsContext) !void {
    var font_library: ft.FT_Library = try freetype.init();
    var font_face: ft.FT_Face = try freetype.newFace(font_library, config.font_path, 0);

    // TODO: Wrap FT api in zig code
    _ = ft.FT_Select_Charmap(font_face, @intToEnum(ft.enum_FT_Encoding_, ft.FT_ENCODING_UNICODE));
    _ = ft.FT_Set_Pixel_Sizes(font_face, 0, config.font_size);

    // TODO: Hard coded asset path
    const initial_second_image = try zigimg.Image.fromFilePath(allocator, "/home/keith/projects/zv_widgets_1/assets/warm_spirals_cropped.png");
    defer initial_second_image.deinit();

    // const large_image = try zigimg.Image.fromFilePath(allocator, "/home/keith/projects/zv_widgets_1/assets/warm_spirals_cropped.png");
    const large_image = try zigimg.Image.fromFilePath(allocator, "/home/keith/projects/zv_widgets_1/assets/pastal_castle_cropped.png");
    defer large_image.deinit();

    log.info("Load image format: {}", .{large_image.pixel_format});

    const _converted_image: []RGBA(f32) = blk: {
        switch (large_image.pixel_format) {
            .Rgba32 => break :blk try convertImageRgba32(allocator, large_image.pixels.?.Rgba32),
            .Rgb24 => break :blk try convertImageRgb24(allocator, large_image.pixels.?.Rgb24),
            // TODO: Handle this error properly
            else => unreachable,
        }
        unreachable;
    };
    defer allocator.free(_converted_image);

    const image_crop_dimensions = geometry.Extent2D(.carthesian){
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 170,
    };

    const image_initial_dimensions = geometry.Dimensions2D(.carthesian){
        .width = @intCast(u32, large_image.width),
        .height = @intCast(u32, large_image.height),
    };

    const processed_image = try shrinkImage(allocator, _converted_image, image_initial_dimensions, .{ .width = 100, .height = 170 });
    defer allocator.free(processed_image);

    const font_texture_chars =
        \\abcdefghijklmnopqrstuvwxyz
        \\ABCDEFGHIJKLMNOPQRSTUVWXYZ
        \\0123456789
        \\!\"£$%^&*()-_=+[]{};:'@#~,<.>/?\\|
    ;

    glyph_set = try text.createGlyphSet(allocator, font_face, font_texture_chars[0..]);

    var memory_properties = zvk.getDevicePhysicalMemoryProperties(app.physical_device);
    // zvk.logDevicePhysicalMemoryProperties(memory_properties);

    var texture_width: u32 = glyph_set.width();
    var texture_height: u32 = glyph_set.height();

    log.info("Glyph dimensions: {}x{}", .{ texture_width, texture_height });

    texture_size_bytes = glyph_set.image.len * @sizeOf(RGBA(f32));

    assert(texture_size_bytes == (texture_width * texture_height * @sizeOf(RGBA(f32))));

    texture_image = try zvk.createImage(app.logical_device, vk.ImageCreateInfo{
        .sType = vk.StructureType.IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = .{},
        .imageType = .T_2D,
        .format = .R32G32B32A32_SFLOAT,
        .tiling = .LINEAR, // .OPTIMAL,
        .extent = vk.Extent3D{ .width = texture_width, .height = texture_height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 2,
        .initialLayout = .UNDEFINED,
        .usage = .{ .transferDst = true, .sampled = true },
        .samples = .{ .t1 = true },
        .sharingMode = .EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = undefined,
    });

    const texture_memory_requirements = zvk.getImageMemoryRequirements(app.logical_device, texture_image);

    const alloc_memory_info = vk.MemoryAllocateInfo{
        .sType = vk.StructureType.MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = texture_memory_requirements.size,
        .memoryTypeIndex = 0,
    };

    var image_memory = try zvk.allocateMemory(app.logical_device, alloc_memory_info);

    if (.SUCCESS != vk.vkBindImageMemory(app.logical_device, texture_image, image_memory, 0)) {
        return error.BindImageMemoryFailed;
    }

    const command_pool = try zvk.createCommandPool(app.logical_device, vk.CommandPoolCreateInfo{
        .sType = vk.StructureType.COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = .{ .resetCommandBuffer = true },
        .queueFamilyIndex = app.graphics_present_queue_index,
    });

    var command_buffer = try zvk.allocateCommandBuffer(app.logical_device, vk.CommandBufferAllocateInfo{
        .sType = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .level = .PRIMARY,
        .commandPool = command_pool,
        .commandBufferCount = 1,
    });

    try zvk.beginCommandBuffer(command_buffer, .{
        .sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = .{ .oneTimeSubmit = true },
        .pInheritanceInfo = null,
    });

    // Just putting this code here for reference
    // Currently I'm using host visible memory so a staging buffer is not required

    // TODO: Using the staging buffer will cause the image_memory_map map to point to the staging buffer
    //       Instead of the uploaded memory
    const is_staging_buffer_required: bool = false;
    if (is_staging_buffer_required) {
        var staging_buffer: vk.Buffer = try zvk.createBuffer(app.logical_device, .{
            .pNext = null,
            .flags = .{},
            .size = texture_size_bytes * 2,
            .usage = .{ .transferSrc = true },
            .sharingMode = .EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = undefined,
        });

        const staging_memory_alloc = vk.MemoryAllocateInfo{
            .sType = vk.StructureType.MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = texture_size_bytes * 2, // x2 because we have two array layers
            .memoryTypeIndex = 0,
        };

        var staging_memory = try zvk.allocateMemory(app.logical_device, staging_memory_alloc);

        try zvk.bindBufferMemory(app.logical_device, staging_buffer, staging_memory, 0);

        // TODO: texture_size_bytes * 2
        if (.SUCCESS != vk.vkMapMemory(app.logical_device, staging_memory, 0, texture_size_bytes * 2, 0, @ptrCast(?**c_void, &image_memory_map))) {
            return error.MapMemoryFailed;
        }

        // Copy our second image to same memory
        // TODO: Fix data layout access
        @memcpy(image_memory_map, @ptrCast([*]u8, glyph_set.image), texture_size_bytes);
        @memcpy(image_memory_map + texture_size_bytes, @ptrCast([*]u8, processed_image), texture_size_bytes);

        // No need to unmap memory
        // vk.vkUnmapMemory(app.logical_device, staging_memory);

        allocator.free(glyph_set.image);

        {
            const barrier = [_]vk.ImageMemoryBarrier{
                .{
                    .sType = vk.StructureType.IMAGE_MEMORY_BARRIER,
                    .pNext = null,
                    .srcAccessMask = .{},
                    .dstAccessMask = .{ .transferWrite = true },
                    .oldLayout = .UNDEFINED,
                    .newLayout = .TRANSFER_DST_OPTIMAL,
                    .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                    .image = texture_image,
                    .subresourceRange = .{
                        .aspectMask = .{ .color = true },
                        .baseMipLevel = 0,
                        .levelCount = 1,
                        .baseArrayLayer = 0,
                        .layerCount = 2,
                    },
                },
            };

            const src_stage = @bitCast(u32, vk.PipelineStageFlags{ .topOfPipe = true });
            const dst_stage = @bitCast(u32, vk.PipelineStageFlags{ .transfer = true });
            vk.vkCmdPipelineBarrier(command_buffer, src_stage, dst_stage, 0, 0, undefined, 0, undefined, 1, &barrier);
        }

        const regions = [_]vk.BufferImageCopy{
            .{ .bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0, .imageSubresource = .{
                .aspectMask = .{ .color = true },
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            }, .imageOffset = .{ .x = 0, .y = 0, .z = 0 }, .imageExtent = .{
                .width = texture_width,
                .height = texture_height,
                .depth = 1,
            } },
            .{ .bufferOffset = texture_size_bytes, .bufferRowLength = 0, .bufferImageHeight = 0, .imageSubresource = .{
                .aspectMask = .{ .color = true },
                .mipLevel = 0,
                .baseArrayLayer = 1,
                .layerCount = 1,
            }, .imageOffset = .{ .x = 0, .y = 0, .z = 0 }, .imageExtent = .{
                .width = texture_width,
                .height = texture_height,
                .depth = 1,
            } },
        };

        _ = vk.vkCmdCopyBufferToImage(command_buffer, staging_buffer, texture_image, .TRANSFER_DST_OPTIMAL, 2, &regions);
    } else {
        // TODO: texture_size_bytes * 2
        if (.SUCCESS != vk.vkMapMemory(app.logical_device, image_memory, 0, texture_size_bytes * 2, 0, @ptrCast(?**c_void, &image_memory_map))) {
            return error.MapMemoryFailed;
        }

        // Copy our second image to same memory
        // TODO: Fix data layout access
        @memcpy(image_memory_map, @ptrCast([*]u8, glyph_set.image), texture_size_bytes);
        @memcpy(image_memory_map + texture_size_bytes, @ptrCast([*]u8, processed_image), texture_size_bytes);
    }

    // Regardless of whether a staging buffer was used, and the type of memory that backs the texture
    // It is neccessary to transition to image layout to SHADER_OPTIMAL

    const barrier = [_]vk.ImageMemoryBarrier{
        .{
            .sType = vk.StructureType.IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = .{},
            .dstAccessMask = .{ .shaderRead = true },
            .oldLayout = .UNDEFINED,
            .newLayout = .SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            .image = texture_image,
            .subresourceRange = .{
                .aspectMask = .{ .color = true },
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 2,
            },
        },
    };

    const src_stage = @bitCast(u32, vk.PipelineStageFlags{ .topOfPipe = true });
    const dst_stage = @bitCast(u32, vk.PipelineStageFlags{ .fragmentShader = true });
    vk.vkCmdPipelineBarrier(command_buffer, src_stage, dst_stage, 0, 0, undefined, 0, undefined, 1, &barrier);
    // }

    try zvk.endCommandBuffer(command_buffer);

    const submit_command_infos = [_]vk.SubmitInfo{.{
        .sType = vk.StructureType.SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = undefined,
        .pWaitDstStageMask = undefined,
        .commandBufferCount = 1,
        .pCommandBuffers = @ptrCast([*]vk.CommandBuffer, &command_buffer),
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = undefined,
    }};

    if (.SUCCESS != vk.vkQueueSubmit(app.graphics_present_queue, 1, &submit_command_infos, null)) {
        return error.QueueSubmitFailed;
    }

    texture_image_view = try zvk.createImageView(app.logical_device, .{
        .flags = .{},
        .image = texture_image,
        .viewType = .T_2D_ARRAY,
        .format = .R32G32B32A32_SFLOAT,
        .subresourceRange = .{
            .aspectMask = .{ .color = true },
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 2,
        },
        .components = .{ .r = .IDENTITY, .g = .IDENTITY, .b = .IDENTITY, .a = .IDENTITY },
    });

    var surface_capabilities: vk.SurfaceCapabilitiesKHR = undefined;
    if (vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(app.physical_device, app.surface, &surface_capabilities) != .SUCCESS) {
        return error.FailedToGetSurfaceCapabilities;
    }

    if (surface_capabilities.currentExtent.width == 0xFFFFFFFF or surface_capabilities.currentExtent.height == 0xFFFFFFFF) {
        var screen_width: i32 = undefined;
        var screen_height: i32 = undefined;
        vk.glfwGetFramebufferSize(app.window, &screen_width, &screen_height);

        if (screen_width <= 0 or screen_height <= 0) {
            return error.InvalidScreenDimensions;
        }

        app.swapchain_extent.width = @intCast(u32, screen_width);
        app.swapchain_extent.height = @intCast(u32, screen_height);

        screen_dimensions_previous = screen_dimensions;

        screen_dimensions.width = app.swapchain_extent.width;
        screen_dimensions.height = app.swapchain_extent.height;
    }

    app.swapchain = try zvk.createSwapchain(app.logical_device, vk.SwapchainCreateInfoKHR{
        .sType = vk.StructureType.SWAPCHAIN_CREATE_INFO_KHR,
        .surface = app.surface,
        .minImageCount = surface_capabilities.minImageCount + 1,
        .imageFormat = app.swapchain_image_format,
        .imageColorSpace = app.surface_format.colorSpace,
        .imageExtent = app.swapchain_extent,
        .imageArrayLayers = 1,
        .imageUsage = .{ .colorAttachment = true },
        .imageSharingMode = .EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = undefined,
        .preTransform = surface_capabilities.currentTransform,
        .compositeAlpha = .{ .opaqueFlag = true },
        .presentMode = .FIFO,
        .clipped = vk.TRUE,
        .flags = .{},
        .oldSwapchain = null,
        .pNext = null,
    });

    app.swapchain_images = try zvk.getSwapchainImagesKHR(allocator, app.logical_device, app.swapchain);

    log.info("Swapchain images: {d}", .{app.swapchain_images.len});

    // TODO: Duplicated code
    app.swapchain_image_views = try allocator.alloc(vk.ImageView, app.swapchain_images.len);
    for (app.swapchain_image_views) |image, i| {
        const image_view_create_info = vk.ImageViewCreateInfo{
            .sType = vk.StructureType.IMAGE_VIEW_CREATE_INFO,
            .image = app.swapchain_images[i],
            .viewType = .T_2D,
            .format = app.swapchain_image_format,
            .components = vk.ComponentMapping{
                .r = .IDENTITY,
                .g = .IDENTITY,
                .b = .IDENTITY,
                .a = .IDENTITY,
            },
            .subresourceRange = vk.ImageSubresourceRange{
                .aspectMask = .{ .color = true },
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .pNext = null,
            .flags = .{},
        };

        app.swapchain_image_views[i] = try zvk.createImageView(app.logical_device, image_view_create_info);
    }

    try texture_pipeline.init(app.logical_device);
    try texture_pipeline.create(allocator, app.logical_device, app.surface_format.format, app.swapchain_extent, app.swapchain_image_views, texture_image_view);

    assert(vertices_range_index_begin + vertices_range_size <= memory_size);

    // Memory used to store vertices and indices
    var mesh_memory: vk.DeviceMemory = try zvk.allocateMemory(app.logical_device, vk.MemoryAllocateInfo{
        .sType = vk.StructureType.MEMORY_ALLOCATE_INFO,
        .allocationSize = memory_size,
        .memoryTypeIndex = 0, // TODO: Audit
        .pNext = null,
    });

    texture_vertices_buffer = try zvk.createBufferOnMemory(app.logical_device, vertices_range_size, vertices_range_index_begin, .{ .transferDst = true, .vertexBuffer = true }, mesh_memory);
    texture_indices_buffer = try zvk.createBufferOnMemory(app.logical_device, indices_range_size, indices_range_index_begin, .{ .transferDst = true, .indexBuffer = true }, mesh_memory);

    if (vk.vkMapMemory(app.logical_device, mesh_memory, 0, memory_size, 0, @ptrCast(**c_void, &mapped_device_memory)) != .SUCCESS) {
        return error.MapMemoryFailed;
    }

    {
        // We won't be reusing vertices except in making quads so we can pre-generate the entire indices buffer
        var indices = @ptrCast([*]u16, @alignCast(16, &mapped_device_memory[indices_range_index_begin]));

        var j: u32 = 0;
        while (j < (indices_range_count / 6)) : (j += 1) {
            indices[j * 6 + 0] = @intCast(u16, j * 4) + 0; // TL
            indices[j * 6 + 1] = @intCast(u16, j * 4) + 1; // TR
            indices[j * 6 + 2] = @intCast(u16, j * 4) + 2; // BR
            indices[j * 6 + 3] = @intCast(u16, j * 4) + 0; // TL
            indices[j * 6 + 4] = @intCast(u16, j * 4) + 2; // BR
            indices[j * 6 + 5] = @intCast(u16, j * 4) + 3; // BL
        }
    }

    var command_pool_create_info = vk.CommandPoolCreateInfo{
        .sType = vk.StructureType.COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = app.graphics_present_queue_index,
        .flags = .{},
        .pNext = null,
    };

    if (vk.vkCreateCommandPool(app.logical_device, &command_pool_create_info, null, &app.command_pool) != .SUCCESS) {
        return error.CreateCommandPoolFailed;
    }

    assert(app.swapchain_images.len > 0);

    app.command_buffers = try zvk.allocateCommandBuffers(allocator, app.logical_device, vk.CommandBufferAllocateInfo{
        .sType = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = app.command_pool,
        .level = .PRIMARY,
        .commandBufferCount = @intCast(u32, app.swapchain_images.len),
        .pNext = null,
    });

    app.images_available = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    app.renders_finished = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    app.inflight_fences = try allocator.alloc(vk.Fence, max_frames_in_flight);

    var semaphore_create_info = vk.SemaphoreCreateInfo{
        .sType = vk.StructureType.SEMAPHORE_CREATE_INFO,
        .flags = .{},
        .pNext = null,
    };

    var fence_create_info = vk.FenceCreateInfo{
        .sType = vk.StructureType.FENCE_CREATE_INFO,
        .flags = .{ .signaled = true },
        .pNext = null,
    };

    var i: u32 = 0;
    while (i < max_frames_in_flight) {
        if (vk.vkCreateSemaphore(app.logical_device, &semaphore_create_info, null, &app.images_available[i]) != .SUCCESS or
            vk.vkCreateSemaphore(app.logical_device, &semaphore_create_info, null, &app.renders_finished[i]) != .SUCCESS or
            vk.vkCreateFence(app.logical_device, &fence_create_info, null, &app.inflight_fences[i]) != .SUCCESS)
        {
            return error.CreateSemaphoreFailed;
        }

        i += 1;
    }
}

fn swapTexture(app: *GraphicsContext) !void {
    log.info("SwapTexture begin", .{});

    const command_pool = try zvk.createCommandPool(app.logical_device, vk.CommandPoolCreateInfo{
        .sType = vk.StructureType.COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = .{ .resetCommandBuffer = true },
        .queueFamilyIndex = app.graphics_present_queue_index,
    });

    {
        var command_buffer = try zvk.allocateCommandBuffer(app.logical_device, vk.CommandBufferAllocateInfo{
            .sType = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .level = .PRIMARY,
            .commandPool = command_pool,
            .commandBufferCount = 1,
        });

        try zvk.beginCommandBuffer(command_buffer, .{
            .sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = .{ .oneTimeSubmit = true },
            .pInheritanceInfo = null,
        });

        {
            const barrier = [_]vk.ImageMemoryBarrier{
                .{
                    .sType = vk.StructureType.IMAGE_MEMORY_BARRIER,
                    .pNext = null,
                    .srcAccessMask = .{},
                    .dstAccessMask = .{ .shaderRead = true },
                    .oldLayout = .SHADER_READ_ONLY_OPTIMAL,
                    .newLayout = .GENERAL,
                    .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                    .image = texture_image,
                    .subresourceRange = .{
                        .aspectMask = .{ .color = true },
                        .baseMipLevel = 0,
                        .levelCount = 1,
                        .baseArrayLayer = 0,
                        .layerCount = 2,
                    },
                },
            };

            const src_stage = @bitCast(u32, vk.PipelineStageFlags{ .topOfPipe = true });
            const dst_stage = @bitCast(u32, vk.PipelineStageFlags{ .fragmentShader = true });
            vk.vkCmdPipelineBarrier(command_buffer, src_stage, dst_stage, 0, 0, undefined, 0, undefined, 1, &barrier);
        }

        try zvk.endCommandBuffer(command_buffer);

        const submit_command_infos = [_]vk.SubmitInfo{.{
            .sType = vk.StructureType.SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = undefined,
            .pWaitDstStageMask = undefined,
            .commandBufferCount = 1,
            .pCommandBuffers = @ptrCast([*]vk.CommandBuffer, &command_buffer),
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = undefined,
        }};

        if (.SUCCESS != vk.vkQueueSubmit(app.graphics_present_queue, 1, &submit_command_infos, null)) {
            return error.QueueSubmitFailed;
        }

        if (vk.vkDeviceWaitIdle(app.logical_device) != .SUCCESS) {
            return error.DeviceWaitIdleFailed;
        }

        log.info("SwapTexture copy", .{});

        @memcpy(image_memory_map + texture_size_bytes, @ptrCast([*]u8, second_image.?), texture_size_bytes);
    }

    log.info("SwapTexture end", .{});

    {
        var command_buffer = try zvk.allocateCommandBuffer(app.logical_device, vk.CommandBufferAllocateInfo{
            .sType = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .level = .PRIMARY,
            .commandPool = command_pool,
            .commandBufferCount = 1,
        });

        try zvk.beginCommandBuffer(command_buffer, .{
            .sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = .{ .oneTimeSubmit = true },
            .pInheritanceInfo = null,
        });

        {
            const barrier = [_]vk.ImageMemoryBarrier{
                .{
                    .sType = vk.StructureType.IMAGE_MEMORY_BARRIER,
                    .pNext = null,
                    .srcAccessMask = .{},
                    .dstAccessMask = .{ .shaderRead = true },
                    .oldLayout = .GENERAL,
                    .newLayout = .SHADER_READ_ONLY_OPTIMAL,
                    .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                    .image = texture_image,
                    .subresourceRange = .{
                        .aspectMask = .{ .color = true },
                        .baseMipLevel = 0,
                        .levelCount = 1,
                        .baseArrayLayer = 0,
                        .layerCount = 2,
                    },
                },
            };

            const src_stage = @bitCast(u32, vk.PipelineStageFlags{ .topOfPipe = true });
            const dst_stage = @bitCast(u32, vk.PipelineStageFlags{ .fragmentShader = true });
            vk.vkCmdPipelineBarrier(command_buffer, src_stage, dst_stage, 0, 0, undefined, 0, undefined, 1, &barrier);
        }

        try zvk.endCommandBuffer(command_buffer);

        const submit_command_infos = [_]vk.SubmitInfo{.{
            .sType = vk.StructureType.SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = undefined,
            .pWaitDstStageMask = undefined,
            .commandBufferCount = 1,
            .pCommandBuffers = @ptrCast([*]vk.CommandBuffer, &command_buffer),
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = undefined,
        }};

        if (.SUCCESS != vk.vkQueueSubmit(app.graphics_present_queue, 1, &submit_command_infos, null)) {
            return error.QueueSubmitFailed;
        }

        if (vk.vkDeviceWaitIdle(app.logical_device) != .SUCCESS) {
            return error.DeviceWaitIdleFailed;
        }
    }
}

fn glfwTextCallback(window: *vk.GLFWwindow, codepoint: u32) callconv(.C) void {}

var color_list: FixedBuffer(RGBA(f32), 30) = undefined;

fn customActions(action_id: u16) void {
    if (action_id == 1) {
        // update_image = true;
    }
}

var track_metadatas: FixedBuffer(audio.TrackMetadata, 20) = undefined;
var audio_files: FixedBuffer([:0]const u8, 20) = undefined;
var update_media_icon_action_id_opt: ?u32 = null;

fn handleAudioPlay(allocator: *Allocator, action_payload: ActionPayloadAudioPlay) !void {

    // TODO: If track is already set, update
    const audio_track_name = audio_files.items[action_payload.id];
    log.info("Playing track {s}", .{audio_track_name});

    const paths: [2][]const u8 = .{ music_dir_path, audio_track_name };
    const full_path = std.fs.path.joinZ(allocator, paths[0..]) catch null;
    defer allocator.free(full_path.?);

    audio.flac.playFile(allocator, full_path.?) catch |err| {
        log.err("Failed to play music", .{});
    };

    // TODO:
    std.time.sleep(50000000 * 2);
    assert(audio.output.getState() == .playing);
}

fn handleUpdateVertices(allocator: *Allocator, action_payload: *ActionPayloadVerticesUpdate) !void {
    const vertices = @ptrCast([*]GenericVertex, @alignCast(16, &mapped_device_memory[vertices_range_index_begin]));

    // TODO: All added for consistency but some variables not used
    // TODO: Updated members of update_vertices to reflect values are for quads, not vertices
    const loaded_vertex_begin = @intCast(u32, action_payload.loaded_vertex_begin) * 4;
    const alternate_vertex_begin = action_payload.alternate_vertex_begin * 4;

    const loaded_quad_begin = @intCast(u32, action_payload.loaded_vertex_begin);
    const alternate_quad_begin = action_payload.alternate_vertex_begin;

    const loaded_vertex_count = action_payload.loaded_vertex_count * 4;
    const alternate_vertex_count = action_payload.alternate_vertex_count * 4;

    const loaded_vertex_quad_count = action_payload.loaded_vertex_count;
    const alternate_vertex_quad_count = action_payload.alternate_vertex_count;

    var alternate_base_vertex: [*]GenericVertex = &inactive_vertices_attachments.items[alternate_quad_begin];

    const largest_range_vertex_count = if (alternate_vertex_count > loaded_vertex_count) alternate_vertex_count else loaded_vertex_count;

    var temp_swap_buffer = allocator.alloc(GenericVertex, largest_range_vertex_count) catch |err| {
        log.err("Failed to allocate temporary swapping buffer for alternatve vertices", .{});
        return;
    };
    defer allocator.free(temp_swap_buffer);

    {
        var i: u32 = 0;
        while (i < (largest_range_vertex_count)) : (i += 1) {
            temp_swap_buffer[i] = vertices[loaded_vertex_begin + i];
            vertices[loaded_vertex_begin + i] = if (i < alternate_vertex_count)
                alternate_base_vertex[i]
            else
                null_face[0];
        }
    }

    // Now we need to copy back our swapped out loaded vertices into the alternate vertices buffer
    for (temp_swap_buffer) |vertex, i| {
        alternate_base_vertex[i] = vertex;
    }

    const temporary_vertex_count = action_payload.loaded_vertex_count;
    action_payload.loaded_vertex_count = action_payload.alternate_vertex_count;
    action_payload.alternate_vertex_count = temporary_vertex_count;

    log.info("Updating vertices", .{});
}

fn handleMouseEvents(x: f64, y: f64, is_pressed_left: bool, is_pressed_right: bool) void {
    const half_width = @intToFloat(f32, screen_dimensions.width) / 2.0;
    const half_height = @intToFloat(f32, screen_dimensions.height) / 2.0;

    comptime const triggered_events_buffer_size = 10;
    const triggered_events = event_system.eventsFromMouseUpdate(triggered_events_buffer_size, .{
        .x = @floatCast(f32, (x - half_width) * 2.0) / @intToFloat(f32, screen_dimensions.width),
        .y = @floatCast(f32, (y - half_height) * 2.0) / @intToFloat(f32, screen_dimensions.height),
    }, .{ .is_left_pressed = is_pressed_left, .is_right_pressed = is_pressed_right });

    if (triggered_events.count == 0) return;

    // NOTE: Could make self ordering, when an action is matched,
    //       move it to the beginning of the buffer

    const vertices = @ptrCast([*]GenericVertex, @alignCast(16, &mapped_device_memory[vertices_range_index_begin]));

    for (triggered_events.toSlice()) |event_id| {
        // TODO: Determine the action type based on offsets

        var action = system_actions.items[event_id];

        switch (action.action_type) {
            .color_set => {
                const index = action.payload.color_set.color_index;
                const color = color_list.items[index];

                const vertices_begin = vertex_range_attachments.items[action.payload.color_set.vertex_range_begin].vertex_begin * 4;

                // NOTE: For now, assume we are only using a single face (4 vertices)
                assert(action.payload.color_set.vertex_range_span == 1);

                const vertices_end = vertices_begin + (vertex_range_attachments.items[action.payload.color_set.vertex_range_begin].vertex_count * 4);

                assert(vertices_end > vertices_begin);

                for (vertices[vertices_begin..vertices_end]) |*vertex| {
                    vertex.color = color;
                }
            },
            .audio_play => {
                const is_media_icon_resume = (audio.output.getState() != .playing);
                var allocator = std.heap.c_allocator;
                handleAudioPlay(allocator, action.payload.audio_play) catch |err| {
                    log.err("Failed to play audio track", .{});
                };

                //
                // If the media icon is set to `resume` (I.e Triangle) we need to update it to `pause`
                //

                if (is_media_icon_resume) {
                    if (update_media_icon_action_id_opt) |update_media_icon_action_id| {
                        handleUpdateVertices(allocator, &system_actions.items[update_media_icon_action_id].payload.update_vertices) catch |err| {
                            log.err("Failed to update vertices for animation", .{});
                        };
                    }
                }

                // Set the media icon button to update when clicked
                if (update_media_icon_action_id_opt) |update_media_icon_action_id| {
                    system_actions.items[update_media_icon_action_id].action_type = .update_vertices;
                }

                log.info("Audio play", .{});
                system_actions.items[media_button_toggle_audio_action_id].action_type = .audio_pause;
            },
            .audio_pause => {
                log.info("Audio paused", .{});
                if (audio.output.getState() == .playing) {
                    audio.output.pause();
                }
                std.time.sleep(10000000);
                assert(audio.output.getState() == .paused);

                log.info("Audio paused -- ", .{});
                system_actions.items[media_button_toggle_audio_action_id].action_type = .audio_resume;
            },
            .audio_resume => {
                log.info("Audio resumed", .{});
                if (audio.output.getState() == .paused) {
                    audio.output.@"resume"() catch |err| {
                        log.info("Failed to resume audio track", .{});
                    };
                    std.time.sleep(10000000);
                    assert(audio.output.getState() == .playing);
                    system_actions.items[media_button_toggle_audio_action_id].action_type = .audio_pause;
                    // text_buffer_dirty = true;
                }
            },
            .update_vertices => {
                // TODO:
                var gpa = std.heap.GeneralPurposeAllocator(.{}){};
                defer _ = gpa.deinit();
                const allocator = &gpa.allocator;

                handleUpdateVertices(allocator, &system_actions.items[event_id].payload.update_vertices) catch |err| {
                    log.err("Failed to update vertices for animation", .{});
                };
            },
            .custom => {
                customActions(action.payload.custom.id);
            },
            else => {
                log.warn("Unmatched event: id {} type {}", .{ event_id, action.action_type });
            },
        }
    }

    is_render_requested = true;
}

// NOTE: You can have a "Complex" Action type that supports non-primative actions + flags
//       That will atleast give us the property of not paying for what we don't use.

const ActionType = enum(u8) {
    none,
    color_set,
    update_vertices,
    custom,
    audio_play,
    audio_pause,
    audio_resume,
    // multi
};

// If it was likely that you would have to do this multiple times before rendering,
// it would be worth filling up a buffer full of changes to be made and then doing them all
// at once after all changes have been triggered

// Limit of 64 is based on alternate_vertex_count being u6
var inactive_vertices_attachments: FixedBuffer(QuadFace(GenericVertex), 64) = .{};

const VertexRange = packed struct {
    vertex_begin: u24,
    vertex_count: u8,
};

// 2 * 20 = 40 bytes
var vertex_range_attachments: FixedBuffer(VertexRange, 20) = .{};
const ActionPayloadColorSet = packed struct {
    vertex_range_begin: u8,
    vertex_range_span: u8,
    color_index: u8,
};

const ActionPayloadSetAction = packed struct {
    action_type: ActionType,
    index: u16,
};

const ActionPayloadVerticesUpdate = packed struct {
    loaded_vertex_begin: u10,
    alternate_vertex_begin: u6,
    loaded_vertex_count: u4,
    alternate_vertex_count: u4,
};

const ActionPayloadRedirect = packed struct {
    action_1: u12,
    action_2: u12,
};

const ActionPayloadAudioResume = packed struct {
    dummy: u24,
};

const ActionPayloadAudioPause = packed struct {
    dummy: u24,
};

const ActionPayloadCustom = packed struct {
    id: u16,
    dummy: u8,
};

const ActionPayloadAudioPlay = packed struct {
    id: u16,
    dummy: u8,
};

const ActionPayload = packed union {
    color_set: ActionPayloadColorSet,
    audio_play: ActionPayloadAudioPlay,
    audio_pause: ActionPayloadAudioPause,
    audio_resume: ActionPayloadAudioResume,
    update_vertices: ActionPayloadVerticesUpdate,
    redirect: ActionPayloadRedirect,
    custom: ActionPayloadCustom,
};

// NOTE: Making this struct packed appears to trigger a compile bug that prevents
//       arrays from being indexed properly. Probably the alignment is incorrect
const Action = struct {
    action_type: ActionType,
    payload: ActionPayload,
};

var system_actions: FixedBuffer(Action, 50) = .{};

fn mouseButtonCallback(window: *vk.GLFWwindow, button: i32, action: i32, mods: i32) callconv(.C) void {
    var x_position: f64 = undefined;
    var y_position: f64 = undefined;
    vk.glfwGetCursorPos(window, &x_position, &y_position);
    handleMouseEvents(x_position, y_position, button == vk.GLFW_MOUSE_BUTTON_LEFT and action == vk.GLFW_PRESS, button == vk.GLFW_MOUSE_BUTTON_LEFT and action == vk.GLFW_PRESS);
}

fn mousePositionCallback(window: *vk.GLFWwindow, x_position: f64, y_position: f64) callconv(.C) void {
    handleMouseEvents(x_position, y_position, false, false);
}

fn glfwKeyCallback(window: *vk.GLFWwindow, key: i32, scancode: i32, action: i32, mods: i32) callconv(.C) void {}

// TODO: move
// Allocator wrapper around fixed-size array with linear access pattern
const FixedBufferAllocator = struct {
    allocator: Allocator = Allocator{
        .allocFn = alloc,
        .resizeFn = resize,
    },

    buffer: [*]u8,
    capacity: u32,
    used: u32,

    const Self = @This();

    pub fn init(self: *Self, fixed_buffer: [*]u8, length: u32) void {
        self.buffer = fixed_buffer;
        self.capacity = length;
        self.used = 0;
    }

    fn alloc(allocator: *Allocator, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) Allocator.Error![]u8 {
        const self = @fieldParentPtr(Self, "allocator", allocator);
        const aligned_size = std.math.max(len, ptr_align);

        if (aligned_size > (self.capacity - self.used)) return error.OutOfMemory;

        defer self.used += @intCast(u32, aligned_size);
        return self.buffer[self.used .. self.used + aligned_size];
    }

    fn resize(
        allocator: *Allocator,
        old_mem: []u8,
        old_align: u29,
        new_size: usize,
        len_align: u29,
        ret_addr: usize,
    ) Allocator.Error!usize {
        const diff: i32 = (@intCast(i32, old_mem.len) - @intCast(i32, new_size));
        if (diff < 0) return error.OutOfMemory;

        const self = @fieldParentPtr(Self, "allocator", allocator);
        self.used -= @intCast(u32, diff);

        return new_size;
    }
};

fn calculateQuadIndex(base: [*]align(16) GenericVertex, widget_faces: []QuadFace(GenericVertex)) u16 {
    return @intCast(u16, (@ptrToInt(&widget_faces[0]) - @ptrToInt(base)) / @sizeOf(QuadFace(GenericVertex)));
}

// TODO: move
var media_button_toggle_audio_action_id: u32 = undefined;

fn update(allocator: *Allocator, app: *GraphicsContext) !void {
    const vertices = @ptrCast([*]GenericVertex, @alignCast(16, &mapped_device_memory[vertices_range_index_begin]));

    log.info("Update called", .{});

    assert(screen_dimensions.width > 0);
    assert(screen_dimensions.height > 0);

    vertex_buffer_count = 0;

    // Wrap our fixed-size buffer in allocator interface to be generic
    var fixed_buffer_allocator = FixedBufferAllocator{
        .allocator = .{
            .allocFn = FixedBufferAllocator.alloc,
            .resizeFn = FixedBufferAllocator.resize,
        },
        .buffer = @ptrCast([*]u8, &vertices[0]),
        .capacity = @intCast(u32, vertices_range_count * @sizeOf(GenericVertex)),
        .used = 0,
    };

    var face_allocator = &fixed_buffer_allocator.allocator;

    const scale_factor = geometry.ScaleFactor2D{
        .horizontal = (2.0 / @intToFloat(f32, screen_dimensions.width)),
        .vertical = (2.0 / @intToFloat(f32, screen_dimensions.height)),
    };

    // Reset event system
    color_list.clear();
    system_actions.clear();
    event_system.clearEvents();
    vertex_range_attachments.clear();
    inactive_vertices_attachments.clear();

    const proceed_button = blk: {
        const button_placement = geometry.Coordinates2D(.ndc_right){ .x = -0.95, .y = -0.92 };
        const button_dimensions = geometry.Dimensions2D(.pixel){ .width = 50, .height = 25 };

        const button_extent = geometry.Extent2D(.ndc_right){
            .x = button_placement.x,
            .y = button_placement.y,
            .width = geometry.pixelToNativeDeviceCoordinateRight(button_dimensions.width, scale_factor.horizontal),
            .height = geometry.pixelToNativeDeviceCoordinateRight(button_dimensions.height, scale_factor.vertical),
        };

        const button_color = RGBA(f32){ .r = 0.9, .g = 0.5, .b = 0.5, .a = 1.0 };
        const label_color = RGBA(f32){ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

        const faces = try gui.button.generate(GenericVertex, face_allocator, glyph_set, "<-", button_extent, scale_factor, button_color, label_color, .center);

        // Register a mouse_hover event that will change the color of the button
        const on_hover_color = RGBA(f32){ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 };

        const button_color_index = color_list.append(button_color);
        const on_hover_color_index = color_list.append(on_hover_color);

        // NOTE: system_actions needs to correspond to given on_hover_event_ids here
        const on_hover_event_ids = event_system.registerMouseHoverReflexiveEnterAction(button_extent);

        // Index of the quad face (I.e Mulples of 4 faces) within the face allocator
        const widget_index = calculateQuadIndex(vertices, faces);

        const vertex_attachment_index = @intCast(u8, vertex_range_attachments.append(.{ .vertex_begin = widget_index, .vertex_count = gui.button.face_count }));

        const on_hover_enter_action_payload = ActionPayloadColorSet{
            .vertex_range_begin = vertex_attachment_index,
            .vertex_range_span = 1,
            .color_index = @intCast(u8, on_hover_color_index),
        };

        const on_hover_exit_action_payload = ActionPayloadColorSet{
            .vertex_range_begin = vertex_attachment_index,
            .vertex_range_span = 1,
            .color_index = @intCast(u8, button_color_index),
        };

        const on_hover_exit_action = Action{ .action_type = .color_set, .payload = .{ .color_set = on_hover_exit_action_payload } };
        const on_hover_enter_action = Action{ .action_type = .color_set, .payload = .{ .color_set = on_hover_enter_action_payload } };

        log.info("Event ids for button: {d} {d}", .{ on_hover_event_ids[0], on_hover_event_ids[1] });

        assert(on_hover_event_ids[0] == system_actions.append(on_hover_enter_action));
        assert(on_hover_event_ids[1] == system_actions.append(on_hover_exit_action));

        break :blk faces;
    };

    //
    // Dimensions for media pause / play button
    //
    // We need to add it here because we'll be adding an action to all of the
    // track list items that will update the media button from paused to resume
    //

    const media_button_color = RGBA(f32){ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 };

    const media_button_placement = geometry.Coordinates2D(.ndc_right){ .x = 0.0, .y = 0.9 };
    const media_button_paused_dimensions = geometry.Dimensions2D(.pixel){ .width = 20, .height = 20 };
    const media_button_resumed_dimensions = geometry.Dimensions2D(.pixel){ .width = 4, .height = 15 };

    const media_button_paused_extent = geometry.Extent2D(.ndc_right){
        .x = media_button_placement.x,
        .y = media_button_placement.y,
        .width = geometry.pixelToNativeDeviceCoordinateRight(media_button_paused_dimensions.width, scale_factor.horizontal),
        .height = geometry.pixelToNativeDeviceCoordinateRight(media_button_paused_dimensions.height, scale_factor.vertical),
    };

    const media_button_resumed_left_extent = geometry.Extent2D(.ndc_right){
        .x = media_button_placement.x,
        .y = media_button_placement.y,
        .width = geometry.pixelToNativeDeviceCoordinateRight(media_button_resumed_dimensions.width, scale_factor.horizontal),
        .height = geometry.pixelToNativeDeviceCoordinateRight(media_button_resumed_dimensions.height, scale_factor.vertical),
    };

    const media_button_resumed_right_extent = geometry.Extent2D(.ndc_right){
        .x = media_button_placement.x + 0.02,
        .y = media_button_placement.y,
        .width = geometry.pixelToNativeDeviceCoordinateRight(media_button_resumed_dimensions.width, scale_factor.horizontal),
        .height = geometry.pixelToNativeDeviceCoordinateRight(media_button_resumed_dimensions.height, scale_factor.vertical),
    };

    var playing_icon_faces: [2]QuadFace(GenericVertex) = undefined;
    playing_icon_faces[0] = graphics.generateQuadColored(GenericVertex, media_button_resumed_left_extent, media_button_color);
    playing_icon_faces[1] = graphics.generateQuadColored(GenericVertex, media_button_resumed_right_extent, media_button_color);

    _ = inactive_vertices_attachments.append(playing_icon_faces[0]);
    _ = inactive_vertices_attachments.append(playing_icon_faces[1]);

    //
    // Generate our Media (pause / resume) button
    //

    assert(audio.output.getState() != .playing);

    // NOTE: Even though we only need one face to generate a triangle,
    //       we need to reserve a second for the resumed icon
    var media_button_paused_faces = try face_allocator.alloc(QuadFace(GenericVertex), 2);

    {
        // const media_button_on_left_click_event_id = event_system.registerMouseLeftPressAction(media_button_paused_extent);
        // const media_button_resume_audio_action_payload = ActionPayloadAudioResume{
        // .dummy = 0,
        // };

        // const media_button_resume_audio_action = Action{ .action_type = .audio_resume, .payload = .{ .audio_resume = media_button_resume_audio_action_payload } };
        // assert(media_button_on_left_click_event_id == system_actions.append(media_button_resume_audio_action));
    }

    media_button_paused_faces[0] = graphics.generateTriangleColored(GenericVertex, media_button_paused_extent, media_button_color);
    media_button_paused_faces[1] = null_face;

    // Let's add a second left_click event emitter to change the icon
    const media_button_on_left_click_event_id = event_system.registerMouseLeftPressAction(media_button_paused_extent);
    const media_button_paused_quad_index = @intCast(u16, (@ptrToInt(&media_button_paused_faces[0]) - @ptrToInt(vertices)) / @sizeOf(QuadFace(GenericVertex)));

    // Needs to fit into a u10
    assert(media_button_paused_quad_index <= std.math.pow(u32, 2, 10));

    const media_button_update_icon_action_payload = ActionPayloadVerticesUpdate{
        .loaded_vertex_begin = @intCast(u10, media_button_paused_quad_index),
        .loaded_vertex_count = 1,
        .alternate_vertex_begin = 0,
        .alternate_vertex_count = 2, // Number of faces
    };

    // Action type set to .none so that action is disabled initially
    const media_button_update_icon_action = Action{ .action_type = .none, .payload = .{ .update_vertices = media_button_update_icon_action_payload } };
    update_media_icon_action_id_opt = system_actions.append(media_button_update_icon_action);

    assert(update_media_icon_action_id_opt.? == media_button_on_left_click_event_id);

    // Setup a Pause Action

    // TODO: Change extent
    const media_button_on_left_click_event_id_2 = event_system.registerMouseLeftPressAction(media_button_paused_extent);

    const media_button_audio_pause_action_payload = ActionPayloadAudioPause{
        .dummy = 0,
    };

    const media_button_audio_pause_action = Action{ .action_type = .none, .payload = .{ .audio_pause = media_button_audio_pause_action_payload } };
    assert(media_button_on_left_click_event_id_2 == system_actions.append(media_button_audio_pause_action));

    media_button_toggle_audio_action_id = media_button_on_left_click_event_id_2;

    // TODO:
    var addicional_vertices: usize = 0;
    for (track_metadatas.items[0..track_metadatas.count]) |track_metadata, track_index| {
        const track_name = track_metadata.title[0..track_metadata.title_length];

        const track_item_placement = geometry.Coordinates2D(.ndc_right){ .x = -0.8, .y = -0.8 + (@intToFloat(f32, track_index) * 0.075) };
        const track_item_dimensions = geometry.Dimensions2D(.pixel){ .width = 600, .height = 30 };

        const track_item_extent = geometry.Extent2D(.ndc_right){
            .x = track_item_placement.x,
            .y = track_item_placement.y,
            .width = geometry.pixelToNativeDeviceCoordinateRight(track_item_dimensions.width, scale_factor.horizontal),
            .height = geometry.pixelToNativeDeviceCoordinateRight(track_item_dimensions.height, scale_factor.vertical),
        };

        const track_item_background_color = RGBA(f32){ .r = 0.9, .g = 0.5, .b = 0.5, .a = 1.0 };
        const track_item_label_color = RGBA(f32){ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

        const track_item_faces = try gui.button.generate(GenericVertex, face_allocator, glyph_set, track_name, track_item_extent, scale_factor, track_item_background_color, track_item_label_color, .left);

        const track_item_on_left_click_event_id = event_system.registerMouseLeftPressAction(track_item_extent);

        const track_item_audio_play_action_payload = ActionPayloadAudioPlay{
            .id = @intCast(u16, track_index),
            .dummy = 0,
        };

        const track_item_audio_play_action = Action{ .action_type = .audio_play, .payload = .{ .audio_play = track_item_audio_play_action_payload } };
        assert(track_item_on_left_click_event_id == system_actions.append(track_item_audio_play_action));

        // Register a mouse_hover event that will change the color of the button
        const track_item_on_hover_color = RGBA(f32){ .r = 0.1, .g = 0.2, .b = 0.3, .a = 1.0 };

        const track_item_background_color_index = color_list.append(track_item_background_color);
        const track_item_on_hover_color_index = color_list.append(track_item_on_hover_color);

        // NOTE: system_actions needs to correspond to given on_hover_event_ids here
        const track_item_on_hover_event_ids = event_system.registerMouseHoverReflexiveEnterAction(track_item_extent);

        // Index of the quad face (I.e Mulples of 4 faces) within the face allocator
        const track_item_quad_index = calculateQuadIndex(vertices, track_item_faces);

        const track_item_update_color_vertex_attachment_index = @intCast(u8, vertex_range_attachments.append(.{ .vertex_begin = track_item_quad_index, .vertex_count = gui.button.face_count }));

        const track_item_update_color_enter_action_payload = ActionPayloadColorSet{
            .vertex_range_begin = track_item_update_color_vertex_attachment_index,
            .vertex_range_span = 1,
            .color_index = @intCast(u8, track_item_on_hover_color_index),
        };

        const track_item_update_color_exit_action_payload = ActionPayloadColorSet{
            .vertex_range_begin = track_item_update_color_vertex_attachment_index,
            .vertex_range_span = 1,
            .color_index = @intCast(u8, track_item_background_color_index),
        };

        const track_item_update_color_enter_action = Action{ .action_type = .color_set, .payload = .{ .color_set = track_item_update_color_enter_action_payload } };
        const track_item_update_color_exit_action = Action{ .action_type = .color_set, .payload = .{ .color_set = track_item_update_color_exit_action_payload } };

        assert(track_item_on_hover_event_ids[0] == system_actions.append(track_item_update_color_enter_action));
        assert(track_item_on_hover_event_ids[1] == system_actions.append(track_item_update_color_exit_action));

        addicional_vertices += track_item_faces.len;
    }

    //
    // Duration of audio played
    //

    const audio_progress_label_maximum_charactors = 11;
    const audio_progress_label_text = "00:00 / 00:00";

    const audio_progress_label_placement = geometry.Coordinates2D(.ndc_right){ .x = -0.9, .y = 0.9 };
    const audio_progress_text_color = RGBA(f32){ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 };

    const audio_progess_label_faces = try gui.generateText(GenericVertex, face_allocator, audio_progress_label_text, audio_progress_label_placement, scale_factor, glyph_set, audio_progress_text_color, null);

    audio_progress_label_faces_quad_index = calculateQuadIndex(vertices, audio_progess_label_faces);

    vertex_buffer_count += @intCast(u32, audio_progess_label_faces.len + media_button_paused_faces.len + proceed_button.len + addicional_vertices);

    text_buffer_dirty = false;
    is_render_requested = true;
}

var audio_progress_label_faces_quad_index: u32 = undefined;

fn updateAudioDurationLabel(current_point_seconds: u32, track_duration_seconds: u32, vertices: []GenericVertex) !void {
    // Wrap our fixed-size buffer in allocator interface to be generic
    var fixed_buffer_allocator = FixedBufferAllocator{
        .allocator = .{
            .allocFn = FixedBufferAllocator.alloc,
            .resizeFn = FixedBufferAllocator.resize,
        },
        .buffer = @ptrCast([*]u8, &vertices[0]),
        .capacity = @intCast(u32, vertices.len * @sizeOf(GenericVertex)),
        .used = 0,
    };

    assert(vertices.len == 11 * 4);

    var face_allocator = &fixed_buffer_allocator.allocator;

    var current_seconds: u32 = current_point_seconds;
    const current_minutes = blk: {
        var minutes: u32 = 0;
        while (current_seconds >= 60) {
            minutes += 1;
            current_seconds -= 60;
        }
        break :blk minutes;
    };

    var track_seconds: u32 = track_duration_seconds;
    const track_minutes = blk: {
        var minutes: u32 = 0;
        while (track_seconds >= 60) {
            minutes += 1;
            track_seconds -= 60;
        }
        break :blk minutes;
    };

    const scale_factor = geometry.ScaleFactor2D{
        .horizontal = (2.0 / @intToFloat(f32, screen_dimensions.width)),
        .vertical = (2.0 / @intToFloat(f32, screen_dimensions.height)),
    };

    var buffer: [13]u8 = undefined;
    const audio_progress_label_text = try std.fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2} / {d:0>2}:{d:0>2}", .{ current_minutes, current_seconds, track_minutes, track_seconds });
    const audio_progress_label_placement = geometry.Coordinates2D(.ndc_right){ .x = -0.9, .y = 0.9 };
    const audio_progress_text_color = RGBA(f32){ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 };

    _ = try gui.generateText(GenericVertex, face_allocator, audio_progress_label_text, audio_progress_label_placement, scale_factor, glyph_set, audio_progress_text_color, null);

    is_render_requested = true;
}

fn appLoop(allocator: *Allocator, app: *GraphicsContext) !void {
    const target_fps = 50;
    const target_ms_per_frame: u32 = 1000 / target_fps;

    log.info("Target MS / frame: {d}", .{target_ms_per_frame});

    var actual_fps: u64 = 0;
    var frames_current_second: u64 = 0;

    // Timestamp in milliseconds since last update of audio duration label
    var audio_duration_last_update_ts: i64 = std.time.milliTimestamp();
    const audio_duraction_update_interval_ms: u64 = 1000;

    _ = vk.glfwSetCursorPosCallback(app.window, mousePositionCallback);
    _ = vk.glfwSetMouseButtonCallback(app.window, mouseButtonCallback);

    _ = vk.glfwSetCharCallback(app.window, glfwTextCallback);
    _ = vk.glfwSetKeyCallback(app.window, glfwKeyCallback);

    while (vk.glfwWindowShouldClose(app.window) == 0) {
        vk.glfwPollEvents();

        var screen_width: i32 = undefined;
        var screen_height: i32 = undefined;

        vk.glfwGetFramebufferSize(app.window, &screen_width, &screen_height);

        if (screen_width <= 0 or screen_height <= 0) {
            return error.InvalidScreenDimensions;
        }

        if (screen_width != screen_dimensions.width or
            screen_height != screen_dimensions.height)
        {
            framebuffer_resized = true;
            screen_dimensions_previous = screen_dimensions;

            screen_dimensions.width = @intCast(u32, screen_width);
            screen_dimensions.height = @intCast(u32, screen_height);
        }

        if (framebuffer_resized) {
            text_buffer_dirty = true;
            framebuffer_resized = false;
            try recreateSwapchain(allocator, app);
        }

        if (text_buffer_dirty) {
            try update(allocator, app);
            is_render_requested = true;
        }

        // TODO:
        if (is_render_requested) {
            if (vk.vkDeviceWaitIdle(app.logical_device) != .SUCCESS) {
                return error.DeviceWaitIdleFailed;
            }
            if (vk.vkResetCommandPool(app.logical_device, app.command_pool, 0) != .SUCCESS) {
                return error.resetCommandBufferFailed;
            }
            try updateCommandBuffers(app);

            try renderFrame(allocator, app);

            is_render_requested = false;
        }

        const frame_start_ms: i64 = std.time.milliTimestamp();

        const frame_end_ms: i64 = std.time.milliTimestamp();
        const frame_duration_ms = frame_end_ms - frame_start_ms;

        // TODO: I think the loop is running less than 1ms so you should update
        //       to nanosecond precision
        assert(frame_duration_ms >= 0);

        if (frame_duration_ms >= target_ms_per_frame) {
            continue;
        }

        // Each second update the audio duration
        if (frame_start_ms >= (audio_duration_last_update_ts + audio_duraction_update_interval_ms)) {
            const track_length_seconds: u32 = audio.output.trackLengthSeconds() catch 0;
            const track_played_seconds: u32 = audio.output.secondsPlayed() catch 0;

            const vertices = @ptrCast([*]GenericVertex, @alignCast(16, &mapped_device_memory[vertices_range_index_begin]));
            const vertices_begin_index: usize = audio_progress_label_faces_quad_index * 4;
            try updateAudioDurationLabel(track_played_seconds, track_length_seconds, vertices[vertices_begin_index .. vertices_begin_index + (11 * 4)]);
            audio_duration_last_update_ts = frame_start_ms;
        }

        assert(target_ms_per_frame > frame_duration_ms);
        const remaining_ms: u32 = target_ms_per_frame - @intCast(u32, frame_duration_ms);
        std.time.sleep(remaining_ms * 1000 * 1000);
    }

    if (vk.vkDeviceWaitIdle(app.logical_device) != .SUCCESS) {
        return error.DeviceWaitIdleFailed;
    }
}

fn updateCommandBuffers(app: *GraphicsContext) !void {
    try texture_pipeline.recordRenderPass(app.command_buffers, texture_vertices_buffer, texture_indices_buffer, app.swapchain_extent, vertex_buffer_count * 6);
}

fn renderFrame(allocator: *Allocator, app: *GraphicsContext) !void {
    if (vk.vkWaitForFences(app.logical_device, 1, @ptrCast([*]const vk.Fence, &app.inflight_fences[current_frame]), vk.TRUE, std.math.maxInt(u64)) != .SUCCESS) {
        return error.WaitForFencesFailed;
    }

    var swapchain_image_index: u32 = undefined;
    var result = vk.vkAcquireNextImageKHR(app.logical_device, app.swapchain, std.math.maxInt(u64), app.images_available[current_frame], null, &swapchain_image_index);

    if (result == .ERROR_OUT_OF_DATE_KHR) {
        log.info("Swapchain out of date; Recreating..", .{});
        try recreateSwapchain(allocator, app);
        return;
    } else if (result != .SUCCESS and result != .SUBOPTIMAL_KHR) {
        return error.AcquireNextImageFailed;
    }

    const wait_semaphores = [1]vk.Semaphore{app.images_available[current_frame]};
    const wait_stages = [1]vk.PipelineStageFlags{.{ .colorAttachmentOutput = true }};
    const signal_semaphores = [1]vk.Semaphore{app.renders_finished[current_frame]};

    const command_submit_info = vk.SubmitInfo{
        .sType = vk.StructureType.SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &wait_semaphores,
        .pWaitDstStageMask = @ptrCast([*]align(4) const vk.PipelineStageFlags, &wait_stages),
        .commandBufferCount = 1,
        .pCommandBuffers = @ptrCast([*]vk.CommandBuffer, &app.command_buffers[swapchain_image_index]),
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &signal_semaphores,
        .pNext = null,
    };

    if (vk.vkResetFences(app.logical_device, 1, @ptrCast([*]const vk.Fence, &app.inflight_fences[current_frame])) != .SUCCESS) {
        return error.ResetFencesFailed;
    }

    if (vk.vkQueueSubmit(app.graphics_present_queue, 1, @ptrCast([*]const vk.SubmitInfo, &command_submit_info), app.inflight_fences[current_frame]) != .SUCCESS) {
        return error.QueueSubmitFailed;
    }

    const swapchains = [1]vk.SwapchainKHR{app.swapchain};
    const present_info = vk.PresentInfoKHR{
        .sType = vk.StructureType.PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &signal_semaphores,
        .swapchainCount = 1,
        .pSwapchains = &swapchains,
        .pImageIndices = @ptrCast([*]u32, &swapchain_image_index),
        .pResults = null,
        .pNext = null,
    };

    result = vk.vkQueuePresentKHR(app.graphics_present_queue, &present_info);

    if (result == .ERROR_OUT_OF_DATE_KHR or result == .SUBOPTIMAL_KHR or framebuffer_resized) {
        framebuffer_resized = false;
        try recreateSwapchain(allocator, app);
        return;
    } else if (result != .SUCCESS) {
        return error.QueuePresentFailed;
    }

    current_frame = (current_frame + 1) % max_frames_in_flight;
}

fn initWindow(window_dimensions: geometry.Dimensions2D(.pixel), title: [:0]const u8) !*vk.GLFWwindow {
    if (vk.glfwInit() != 1) {
        return error.GLFWInitFailed;
    }
    vk.glfwWindowHint(vk.GLFW_CLIENT_API, vk.GLFW_NO_API);

    return vk.glfwCreateWindow(@intCast(c_int, window_dimensions.width), @intCast(c_int, window_dimensions.height), title.ptr, null, null) orelse
        return error.GlfwCreateWindowFailed;
}
