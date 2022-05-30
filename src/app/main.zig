// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const vk = @import("vulkan");
const vulkan_config = @import("vulkan_config");
const glfw = @import("glfw");
const text = @import("text");
const gui = @import("gui");
const zvk = @import("vulkan_wrapper");
const geometry = @import("geometry");
const graphics = @import("graphics");
const RGBA = graphics.RGBA;
const GenericVertex = graphics.GenericVertex;
const QuadFace = graphics.QuadFace;
const constants = @import("constants");
const texture_layer_dimensions = constants.texture_layer_dimensions;
const texture_layer_size = constants.texture_layer_size;
const ScreenPixelBaseType = constants.ScreenPixelBaseType;
const ScreenNormalizedBaseType = constants.ScreenNormalizedBaseType;
const TexturePixelBaseType = constants.TexturePixelBaseType;
const event_system = @import("event_system");
const memory = @import("memory");
const FixedBuffer = memory.FixedBuffer;
const audio = @import("audio");
const user_config = @import("user_config");
const QuadFaceWriter = gui.QuadFaceWriter;
const QuadFaceWriterPool = gui.QuadFaceWriterPool;
const ui = @import("ui");
const theme = @import("Theme.zig").default;
const navigation = @import("navigation.zig").navigation;
const storage = @import("storage");
const SubPath = storage.SubPath;
const AbsolutePath = storage.AbsolutePath;
const String = storage.String;
const Playlist = @import("Playlist.zig");

pub const log_level: std.log.Level = .info;

// TODO
//
// - Reset progress bar after track finishes
// - Reclick on directory item doesn't reload anything
// - Don't reload track duration if available
// - Indicator of track playing
// - Show track details on side
// - How time markers beside progress bar
// - [done] Next and previous buttons
// - Update example library to have albums
// - Next track will automatically play
// - Get flac to work again
// - Calculate # directories to load based on available space
// - Build libmad into binary
// - Fix memory leak in audio.mp3.playFile

var is_render_requested: bool = true;
var is_draw_required: bool = true;

var quad_face_writer_pool: QuadFaceWriterPool(GenericVertex) = undefined;

var main_arena: memory.LinearArena = .{};
var trackview_arena: memory.LinearArena = undefined;

const ScreenScaleFactor = graphics.ScreenScaleFactor(
    .{
        .NDCRightType = ScreenNormalizedBaseType,
        .PixelType = ScreenPixelBaseType,
    },
);
var scale_factor: ScreenScaleFactor = undefined;

const RewindLevel = enum(u8) {
    directory_changed = 0,
    track_changed,
    none = std.math.maxInt(u8),
};

var rewind_level: RewindLevel = .none;
var arena_checkpoints: [2]u32 = undefined;

const RewindPoints = struct {
    const null_value = std.math.maxInt(u16);

    track_metadata: u16 = null_value,
    directory_list: u16 = null_value,
    audio_started: u16 = null_value,
};

const AudioDurationTime = packed struct {
    seconds: u16,
    minutes: u16,
};

var rewind_points: RewindPoints = .{};

var screen_dimensions = geometry.Dimensions2D(ScreenPixelBaseType){
    .width = 0,
    .height = 0,
};

var current_frame: u32 = 0;
var framebuffer_resized: bool = true;
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

const enable_validation_layers = false; // if (builtin.mode == .Debug) true else false;
const validation_layers = if (enable_validation_layers) [1][*:0]const u8{"VK_LAYER_KHRONOS_validation"} else [*:0]const u8{};
const device_extensions = [_][*:0]const u8{vk.extension_info.khr_swapchain.name};

const max_frames_in_flight: u32 = 2;

var texture_image_view: vk.ImageView = undefined;
var texture_image: vk.Image = undefined;
var texture_vertices_buffer: vk.Buffer = undefined;
var texture_indices_buffer: vk.Buffer = undefined;

// NOTE: For development
// const library_root_path = "../../../../mnt/data/media/music";

// TODO: You can define this with a env variable
const library_root_path = "assets/example_library";
var image_memory_map: [*]u8 = undefined;
var texture_size_bytes: usize = 0;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    navigation.subsystem_index = event_system.registerActionHandler(&navigation.doAction);
    audio.subsystem_index = event_system.registerActionHandler(&audio.doAction);
    gui.subsystem_index = event_system.registerActionHandler(&gui.doAction);
    ui.subsystem_index = event_system.registerActionHandler(&ui.doAction);
    Playlist.subsystem_index = event_system.registerActionHandler(&Playlist.doAction);

    var allocator = gpa.allocator();

    {
        const bytes_per_kib: u32 = 1024;
        var page_allocator = std.heap.page_allocator;
        var main_arena_memory = try page_allocator.alloc(u8, bytes_per_kib * 64);
        main_arena.init(main_arena_memory);
        storage.init(main_arena.access()[0..]);
    }

    event_system.mouse_event_writer.init(&main_arena, 1024);

    {
        const path_size_max: u32 = 256;
        const loaded_directories_max: u32 = 32;
        trackview_arena = main_arena.allocateChild(2, path_size_max * loaded_directories_max * 2);
    }

    {
        arena_checkpoints[@enumToInt(RewindLevel.directory_changed)] = main_arena.checkpoint();
        const current_directory = std.fs.cwd().openDir(library_root_path, .{ .iterate = true }) catch |err| {
            std.log.err("Failed to open directory {s}. Error -> {s}", .{ library_root_path, err });
            return;
        };
        try navigation.init(&main_arena, current_directory);
    }

    glfw.initialize() catch |err| {
        std.log.err("Failed to initialized glfw. Error: {s}", .{err});
        return;
    };
    defer glfw.terminate();

    if (!glfw.vulkanSupported()) {
        std.log.err("Vulkan is required", .{});
        return;
    }

    glfw.setHint(.client_api, .none);

    var graphics_context: GraphicsContext = undefined;
    graphics_context.window = try glfw.createWindow(constants.initial_window_dimensions, constants.application_title);

    const window_size = glfw.getFramebufferSize(graphics_context.window);
    graphics_context.screen_dimensions.width = window_size.width;
    graphics_context.screen_dimensions.height = window_size.height;

    std.debug.assert(window_size.width < 10_000 and window_size.height < 10_000);

    graphics_context.base_dispatch = try BaseDispatch.load(glfw.glfwGetInstanceProcAddress);

    var instance_extension_count: u32 = 0;
    const instance_extensions = glfw.getRequiredInstanceExtensions(&instance_extension_count);
    std.debug.assert(instance_extension_count > 0);

    graphics_context.instance = try graphics_context.base_dispatch.createInstance(&vk.InstanceCreateInfo{
        .s_type = .instance_create_info,
        .p_application_info = &vk.ApplicationInfo{
            .s_type = .application_info,
            .p_application_name = constants.application_title,
            .application_version = vk.makeApiVersion(0, 0, 1, 0),
            .p_engine_name = constants.application_title,
            .engine_version = vk.makeApiVersion(0, 0, 1, 0),
            .api_version = vk.API_VERSION_1_2,
            .p_next = null,
        },
        .enabled_extension_count = instance_extension_count,
        .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, instance_extensions),
        .enabled_layer_count = if (enable_validation_layers) validation_layers.len else 0,
        .pp_enabled_layer_names = if (enable_validation_layers) &validation_layers else undefined,
        .p_next = null,
        .flags = .{},
    }, null);

    graphics_context.instance_dispatch = try InstanceDispatch.load(graphics_context.instance, glfw.glfwGetInstanceProcAddress);
    errdefer graphics_context.instance_dispatch.destroyInstance(graphics_context.instance, null);

    _ = try glfw.createWindowSurface(graphics_context.instance, graphics_context.window, &graphics_context.surface);

    var present_mode: vk.PresentModeKHR = .fifo_khr;

    // Find a suitable physical device to use
    const best_physical_device = outer: {
        const physical_devices = blk: {
            var device_count: u32 = 0;
            _ = try graphics_context.instance_dispatch.enumeratePhysicalDevices(graphics_context.instance, &device_count, null);

            if (device_count == 0) {
                return error.NoDevicesFound;
            }

            const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
            _ = try graphics_context.instance_dispatch.enumeratePhysicalDevices(graphics_context.instance, &device_count, devices.ptr);

            break :blk devices;
        };
        defer allocator.free(physical_devices);

        // const physical_devices = try zvk.enumeratePhysicalDevices(allocator, graphics_context.instance, graphics_context.instance_dispatch);
        // defer allocator.free(physical_devices);

        for (physical_devices) |physical_device| {
            if ((try zvk.deviceSupportsExtensions(InstanceDispatch, graphics_context.instance_dispatch, allocator, physical_device, device_extensions[0..])) and
                (try zvk.getPhysicalDeviceSurfaceFormatsKHRCount(InstanceDispatch, graphics_context.instance_dispatch, physical_device, graphics_context.surface)) != 0 and
                (try zvk.getPhysicalDeviceSurfacePresentModesKHRCount(InstanceDispatch, graphics_context.instance_dispatch, physical_device, graphics_context.surface)) != 0)
            {
                var supported_present_modes = try zvk.getPhysicalDeviceSurfacePresentModesKHR(InstanceDispatch, graphics_context.instance_dispatch, allocator, physical_device, graphics_context.surface);
                defer allocator.free(supported_present_modes);

                // FIFO should be guaranteed by vulkan spec but validation layers are triggered
                // when vkGetPhysicalDeviceSurfacePresentModesKHR isn't used to get supported PresentModes
                for (supported_present_modes) |supported_present_mode| {
                    if (supported_present_mode == .fifo_khr) present_mode = .fifo_khr else continue;
                }

                const best_family_queue_index = inner: {
                    var queue_family_count: u32 = 0;
                    graphics_context.instance_dispatch.getPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);

                    if (queue_family_count == 0) {
                        break :inner null;
                    }

                    const max_family_queues: u32 = 16;
                    if (queue_family_count > max_family_queues) {
                        std.log.warn("Some family queues for selected device ignored", .{});
                    }

                    var queue_families: [max_family_queues]vk.QueueFamilyProperties = undefined;
                    graphics_context.instance_dispatch.getPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, &queue_families);

                    var i: u32 = 0;
                    while (i < queue_family_count) : (i += 1) {
                        if (queue_families[i].queue_count <= 0) {
                            continue;
                        }

                        if (queue_families[i].queue_flags.graphics_bit) {
                            const present_support = try graphics_context.instance_dispatch.getPhysicalDeviceSurfaceSupportKHR(physical_device, i, graphics_context.surface);
                            if (present_support != 0) {
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

    {
        const device_create_info = vk.DeviceCreateInfo{
            .s_type = vk.StructureType.device_create_info,
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast([*]vk.DeviceQueueCreateInfo, &vk.DeviceQueueCreateInfo{
                .s_type = vk.StructureType.device_queue_create_info,
                .queue_family_index = graphics_context.graphics_present_queue_index,
                .queue_count = 1,
                .p_queue_priorities = &[1]f32{1.0},
                .flags = .{},
                .p_next = null,
            }),
            .p_enabled_features = &vk.PhysicalDeviceFeatures{
                .robust_buffer_access = vk.FALSE,
                .full_draw_index_uint_32 = vk.FALSE,
                .image_cube_array = vk.FALSE,
                .independent_blend = vk.FALSE,
                .geometry_shader = vk.FALSE,
                .tessellation_shader = vk.FALSE,
                .sample_rate_shading = vk.FALSE,
                .dual_src_blend = vk.FALSE,
                .logic_op = vk.FALSE,
                .multi_draw_indirect = vk.FALSE,
                .draw_indirect_first_instance = vk.FALSE,
                .depth_clamp = vk.FALSE,
                .depth_bias_clamp = vk.FALSE,
                .fill_mode_non_solid = vk.FALSE,
                .depth_bounds = vk.FALSE,
                .wide_lines = vk.FALSE,
                .large_points = vk.FALSE,
                .alpha_to_one = vk.FALSE,
                .multi_viewport = vk.FALSE,
                .sampler_anisotropy = vk.TRUE,
                .texture_compression_etc2 = vk.FALSE,
                .texture_compression_astc_ldr = vk.FALSE,
                .texture_compression_bc = vk.FALSE,
                .occlusion_query_precise = vk.FALSE,
                .pipeline_statistics_query = vk.FALSE,
                .vertex_pipeline_stores_and_atomics = vk.FALSE,
                .fragment_stores_and_atomics = vk.FALSE,
                .shader_tessellation_and_geometry_point_size = vk.FALSE,
                .shader_image_gather_extended = vk.FALSE,
                .shader_storage_image_extended_formats = vk.FALSE,
                .shader_storage_image_multisample = vk.FALSE,
                .shader_storage_image_read_without_format = vk.FALSE,
                .shader_storage_image_write_without_format = vk.FALSE,
                .shader_uniform_buffer_array_dynamic_indexing = vk.FALSE,
                .shader_sampled_image_array_dynamic_indexing = vk.FALSE,
                .shader_storage_buffer_array_dynamic_indexing = vk.FALSE,
                .shader_storage_image_array_dynamic_indexing = vk.FALSE,
                .shader_clip_distance = vk.FALSE,
                .shader_cull_distance = vk.FALSE,
                .shader_float_64 = vk.FALSE,
                .shader_int_64 = vk.FALSE,
                .shader_int_16 = vk.FALSE,
                .shader_resource_residency = vk.FALSE,
                .shader_resource_min_lod = vk.FALSE,
                .sparse_binding = vk.FALSE,
                .sparse_residency_buffer = vk.FALSE,
                .sparse_residency_image_2d = vk.FALSE,
                .sparse_residency_image_3d = vk.FALSE,
                .sparse_residency_2_samples = vk.FALSE,
                .sparse_residency_4_samples = vk.FALSE,
                .sparse_residency_8_samples = vk.FALSE,
                .sparse_residency_16_samples = vk.FALSE,
                .sparse_residency_aliased = vk.FALSE,
                .variable_multisample_rate = vk.FALSE,
                .inherited_queries = vk.FALSE,
            },
            .enabled_extension_count = device_extensions.len,
            .pp_enabled_extension_names = &device_extensions,
            .enabled_layer_count = if (enable_validation_layers) validation_layers.len else 0,
            .pp_enabled_layer_names = if (enable_validation_layers) &validation_layers else undefined,
            .flags = .{},
            .p_next = null,
        };

        graphics_context.logical_device = try graphics_context.instance_dispatch.createDevice(
            graphics_context.physical_device,
            &device_create_info,
            null,
        );
    }

    graphics_context.device_dispatch = try DeviceDispatch.load(
        graphics_context.logical_device,
        graphics_context.instance_dispatch.dispatch.vkGetDeviceProcAddr,
    );
    graphics_context.graphics_present_queue = graphics_context.device_dispatch.getDeviceQueue(
        graphics_context.logical_device,
        graphics_context.graphics_present_queue_index,
        0,
    );

    var available_formats: []vk.SurfaceFormatKHR = try zvk.getPhysicalDeviceSurfaceFormatsKHR(
        InstanceDispatch,
        graphics_context.instance_dispatch,
        allocator,
        graphics_context.physical_device,
        graphics_context.surface,
    );
    defer allocator.free(available_formats);

    graphics_context.surface_format = zvk.chooseSwapSurfaceFormat(available_formats);
    graphics_context.swapchain_image_format = graphics_context.surface_format.format;

    try setupApplication(allocator, &graphics_context);
    try appLoop(allocator, &graphics_context);

    //
    // Deallocate resources
    //

    cleanupSwapchain(allocator, &graphics_context);
    clean(allocator, &graphics_context);

    std.log.info("Terminated cleanly", .{});
}

// TODO:
fn clean(allocator: Allocator, app: *GraphicsContext) void {
    allocator.free(app.images_available);
    allocator.free(app.renders_finished);
    allocator.free(app.inflight_fences);

    allocator.free(app.swapchain_image_views);
    allocator.free(app.swapchain_images);

    allocator.free(app.descriptor_set_layouts);
    allocator.free(app.descriptor_sets);
    allocator.free(app.framebuffers);

    glyph_set.deinit(allocator);
}

fn recreateSwapchain(allocator: Allocator, app: *GraphicsContext) !void {

    // TODO: Find a better synchronization method
    try app.device_dispatch.deviceWaitIdle(app.logical_device);

    std.log.info("Recreating swapchain", .{});

    //
    // Cleanup swapchain and associated images
    //

    std.debug.assert(app.command_buffers.len > 0);

    app.device_dispatch.freeCommandBuffers(
        app.logical_device,
        app.command_pool,
        @intCast(u32, app.command_buffers.len),
        app.command_buffers.ptr,
    );
    allocator.free(app.command_buffers);

    for (app.swapchain_image_views) |image_view| {
        app.device_dispatch.destroyImageView(app.logical_device, image_view, null);
    }

    app.device_dispatch.destroySwapchainKHR(app.logical_device, app.swapchain, null);

    //
    // Get new screen properties
    //

    const glfw_window_dimensions = glfw.getFramebufferSize(app.window);

    app.screen_dimensions.width = glfw_window_dimensions.width;
    app.screen_dimensions.height = glfw_window_dimensions.height;

    app.swapchain_extent.width = app.screen_dimensions.width;
    app.swapchain_extent.height = app.screen_dimensions.height;

    const surface_capabilities: vk.SurfaceCapabilitiesKHR = try app.instance_dispatch.getPhysicalDeviceSurfaceCapabilitiesKHR(
        app.physical_device,
        app.surface,
    );

    // TODO
    const available_formats: []vk.SurfaceFormatKHR = try zvk.getPhysicalDeviceSurfaceFormatsKHR(
        InstanceDispatch,
        app.instance_dispatch,
        allocator,
        app.physical_device,
        app.surface,
    );
    const surface_format = zvk.chooseSwapSurfaceFormat(available_formats);
    allocator.free(available_formats);

    //
    // Recreate the swapchain and associated imageviews
    //

    app.swapchain = try app.device_dispatch.createSwapchainKHR(app.logical_device, &vk.SwapchainCreateInfoKHR{
        .s_type = vk.StructureType.swapchain_create_info_khr,
        .surface = app.surface,
        .min_image_count = surface_capabilities.min_image_count + 1,
        .image_format = app.swapchain_image_format,
        .image_color_space = surface_format.color_space,
        .image_extent = app.swapchain_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .pre_transform = surface_capabilities.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = .fifo_khr,
        .clipped = vk.TRUE,
        .flags = .{},
        .old_swapchain = .null_handle,
        .p_next = null,
    }, null);

    var image_count: u32 = undefined;
    {
        if ((try app.device_dispatch.getSwapchainImagesKHR(app.logical_device, app.swapchain, &image_count, null)) != vk.Result.success) {
            return error.FailedToGetSwapchainImagesCount;
        }

        if (image_count != app.swapchain_images.len) {
            // TODO: Realloc
            unreachable;
        }
    }

    if ((try app.device_dispatch.getSwapchainImagesKHR(app.logical_device, app.swapchain, &image_count, app.swapchain_images.ptr)) != vk.Result.success) {
        return error.FailedToGetSwapchainImages;
    }

    for (app.swapchain_image_views) |*image_view, i| {
        const image_view_create_info = vk.ImageViewCreateInfo{
            .s_type = vk.StructureType.image_view_create_info,
            .image = app.swapchain_images[i],
            .view_type = .@"2d",
            .format = app.swapchain_image_format,
            .components = vk.ComponentMapping{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = vk.ImageSubresourceRange{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .p_next = null,
            .flags = .{},
        };

        image_view.* = try app.device_dispatch.createImageView(app.logical_device, &image_view_create_info, null);
    }

    app.device_dispatch.destroyPipeline(app.logical_device, app.graphics_pipeline, null);
    app.graphics_pipeline = try createGraphicsPipeline(app.*, app.pipeline_layout, app.render_pass);

    for (app.framebuffers) |framebuffer| {
        app.device_dispatch.destroyFramebuffer(app.logical_device, framebuffer, null);
    }
    // TODO
    allocator.free(app.framebuffers);
    app.framebuffers = try createFramebuffers(allocator, app.*);

    app.command_buffers = try allocateCommandBuffers(allocator, app.*, @intCast(u32, app.swapchain_images.len));
    try recordRenderPass(app.*, vertex_buffer_count * 6);

    std.log.info("Swapchain recreated", .{});
}

fn setupApplication(allocator: Allocator, app: *GraphicsContext) !void {
    // const large_image = try zigimg.Image.fromFilePath(allocator, "/home/keith/projects/zv_widgets_1/assets/pastal_castle.png");
    // defer large_image.deinit();

    // log.info("Load image format: {}", .{large_imageScreenPixelBaseType_format});
    // const formatted_image: []RGBA(f32) = blk: {
    // switch (large_imageScreenPixelBaseType_format) {
    // .Rgba32 => break :blk try image.convertImageRgba32(allocator, large_imageScreenPixelBaseTypes.?.Rgba32),
    // .Rgb24 => break :blk try image.convertImageRgb24(allocator, large_imageScreenPixelBaseTypes.?.Rgb24),
    // // TODO: Handle this error properly
    // else => unreachable,
    // }
    // unreachable;
    // };
    // defer allocator.free(formatted_image);

    // const horizontal_difference: f32 = @intToFloat(f32, texture_layer_dimensions.width) / @intToFloat(f32, large_image.width);
    // const vertical_difference: f32 = @intToFloat(f32, texture_layer_dimensions.height) / @intToFloat(f32, large_image.height);
    // const scale_factor: f32 = if (horizontal_difference < vertical_difference) horizontal_difference else vertical_difference;

    // const fitted_dimensions = geometry.Dimensions2D(TexturePixelBaseType){
    // .width = 256, //if (scale_factor < 1.0) @floatToInt(u32, @intToFloat(f32, large_image.width) * scale_factor) else @intCast(u32, large_image.width),
    // .height = 256, // if (scale_factor < 1.0) @floatToInt(u32, @intToFloat(f32, large_image.height) * scale_factor) else @intCast(u32, large_image.height),
    // };

    // const old_dimensions = geometry.Dimensions2D(TexturePixelBaseType){
    // .width = @intCast(u32, large_image.width),
    // .height = @intCast(u32, large_image.height),
    // };

    // TODO: I need to make a function to add and remove images as textures
    // It will be able to return the texture dimensions so that it can be drawn seperately
    // addTexture()

    // log.info("Shrinking image: {d}x{d} --> {d}x{d}", .{ old_dimensions.width, old_dimensions.height, fitted_dimensions.width, fitted_dimensions.height });

    // const fitted_image = try image.shrink(allocator, formatted_image, old_dimensions, fitted_dimensions);
    // defer allocator.free(fitted_image);

    // var texture_layer = try allocator.alloc(RGBA(f32), texture_layer_dimensions.width * texture_layer_dimensions.height);
    // defer allocator.free(texture_layer);
    // for (texture_layer) |ScreenPixelBaseType| {
    //ScreenPixelBaseType.r = 1.0;
    //ScreenPixelBaseType.g = 1.0;
    //ScreenPixelBaseType.b = 1.0;
    //ScreenPixelBaseType.a = 1.0;
    // }

    // assert(fitted_image.len == (fitted_dimensions.width * fitted_dimensions.height));

    // const image_crop_dimensions = geometry.Extent2D(TexturePixelBaseType){
    // .x = 0,
    // .y = 0,
    // .width = 100,
    // .height = 170,
    // };

    // const image_initial_dimensions = geometry.Dimensions2D(TexturePixelBaseType){
    // .width = @intCast(u32, large_image.width),
    // .height = @intCast(u32, large_image.height),
    // };

    // const processed_image = try shrinkImage(allocator, _converted_image, image_initial_dimensions, .{ .width = large_image.width, .height = large_image.height });
    // defer allocator.free(processed_image);

    const font_texture_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!\"£$%^&*()-_=+[]{};:'@#~,<.>/?\\|";
    glyph_set = try text.createGlyphSet(allocator, constants.default_font_path, font_texture_chars[0..], texture_layer_dimensions);

    //
    // TODO
    //

    // var debugging_font_bitmap_texture = try allocator.alloc(RGBA(f32), texture_layer_dimensions.width * texture_layer_dimensions.height);
    // defer allocator.free(debugging_font_bitmap_texture);

    // {
    // const source_image_extent = geometry.Extent2D(TexturePixelBaseType){
    // .x = 0,
    // .y = 0,
    // .width = @intCast(u32, fitted_dimensions.width),
    // .height = @intCast(u32, fitted_dimensions.height),
    // };

    // log.info("Image dimensions: {d}x{d}", .{ large_image.width, large_image.height });

    // const destination_placement = geometry.Coordinates2D(TexturePixelBaseType){
    // .x = 0,
    // .y = 0,
    // };

    // const destination_dimensions = geometry.Dimensions2D(TexturePixelBaseType){
    // .width = texture_layer_dimensions.width,
    // .height = texture_layer_dimensions.height,
    // };

    // image.copy(RGBA(f32), fitted_image, source_image_extent, &texture_layer, destination_placement, destination_dimensions);
    // }

    const memory_properties = app.instance_dispatch.getPhysicalDeviceMemoryProperties(app.physical_device);
    // var memory_properties = zvk.getDevicePhysicalMemoryProperties(app.physical_device);
    zvk.logDevicePhysicalMemoryProperties(memory_properties);

    const mesh_memory_index: u32 = blk: {

        // Find the best memory type for storing mesh + texture data
        // Requirements:
        //   - Sufficient space (20mib)
        //   - Host visible (Host refers to CPU. Allows for direct access without needing DMA)
        // Preferable
        //  - Device local (Memory on the GPU / APU)

        const kib: u32 = 1024;
        const mib: u32 = kib * 1024;
        const minimum_space_required: u32 = mib * 20;

        var memory_type_index: u32 = 0;
        var memory_type_count = memory_properties.memory_type_count;

        var suitable_memory_type_index_opt: ?u32 = null;

        while (memory_type_index < memory_type_count) : (memory_type_index += 1) {
            const memory_entry = memory_properties.memory_types[memory_type_index];
            const heap_index = memory_entry.heap_index;

            if (heap_index == memory_properties.memory_heap_count) {
                std.log.warn("Invalid heap index {d} for memory type at index {d}. Skipping", .{ heap_index, memory_type_index });
                continue;
            }

            const heap_size = memory_properties.memory_heaps[heap_index].size;

            if (heap_size < minimum_space_required) {
                continue;
            }

            const memory_flags = memory_entry.property_flags;
            if (memory_flags.host_visible_bit) {
                suitable_memory_type_index_opt = memory_type_index;
                if (memory_flags.device_local_bit) {
                    break :blk memory_type_index;
                }
            }
        }

        if (suitable_memory_type_index_opt) |suitable_memory_type_index| {
            break :blk suitable_memory_type_index;
        }

        return error.NoValidVulkanMemoryTypes;
    };

    std.log.info("Memory type selected: {d}", .{mesh_memory_index});

    var texture_width: u32 = glyph_set.width();
    var texture_height: u32 = glyph_set.height();

    std.log.info("Glyph dimensions: {}x{}", .{ texture_width, texture_height });

    // const font_bitmap_extent = geometry.Extent2D(TexturePixelBaseType){
    // .x = 0,
    // .y = 0,
    // .width = texture_width,
    // .height = texture_height,
    // };

    // const formatted_image_dimensions = geometry.Dimensions2D(TexturePixelBaseType){
    // .width = @intCast(u32, large_image.width),
    // .height = @intCast(u32, large_image.height),
    // };

    // const cropped_image = try cropImage(allocator, formatted_image, formatted_image_dimensions, font_bitmap_extent);
    // defer allocator.free(cropped_image);

    // texture_size_bytes = glyph_set.image.len * @sizeOf(RGBA(f32));
    // texture_size_bytes = texture_dimensions.height * texture_dimensions.width * @sizeOf(RGBA(f32));
    // assert(glyph_set.image.len == (texture_width * texture_height));

    // assert(texture_size_bytes == (texture_width * texture_height * @sizeOf(RGBA(f32))));

    {
        const image_create_info = vk.ImageCreateInfo{
            .s_type = vk.StructureType.image_create_info,
            .p_next = null,
            .flags = .{},
            .image_type = .@"2d",
            .format = .r32g32b32a32_sfloat,
            .tiling = .linear,
            .extent = vk.Extent3D{
                .width = texture_layer_dimensions.width,
                .height = texture_layer_dimensions.height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 2,
            .initial_layout = .@"undefined",
            .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
            .samples = .{ .@"1_bit" = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        };

        texture_image = try app.device_dispatch.createImage(app.logical_device, &image_create_info, null);
    }

    const texture_memory_requirements = app.device_dispatch.getImageMemoryRequirements(app.logical_device, texture_image);

    var image_memory = try app.device_dispatch.allocateMemory(app.logical_device, &vk.MemoryAllocateInfo{
        .s_type = vk.StructureType.memory_allocate_info,
        .p_next = null,
        .allocation_size = texture_memory_requirements.size,
        .memory_type_index = mesh_memory_index,
    }, null);

    try app.device_dispatch.bindImageMemory(app.logical_device, texture_image, image_memory, 0);

    const command_pool = try app.device_dispatch.createCommandPool(app.logical_device, &vk.CommandPoolCreateInfo{
        .s_type = vk.StructureType.command_pool_create_info,
        .p_next = null,
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = app.graphics_present_queue_index,
    }, null);

    var command_buffer = try zvk.allocateCommandBuffer(DeviceDispatch, app.device_dispatch, app.logical_device, vk.CommandBufferAllocateInfo{
        .s_type = vk.StructureType.command_buffer_allocate_info,
        .p_next = null,
        .level = .primary,
        .command_pool = command_pool,
        .command_buffer_count = 1,
    });

    try app.device_dispatch.beginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
        .s_type = vk.StructureType.command_buffer_begin_info,
        .p_next = null,
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    // Just putting this code here for reference
    // Currently I'm using host visible memory so a staging buffer is not required

    // TODO: Using the staging buffer will cause the image_memory_map map to point to the staging buffer
    //       Instead of the uploaded memory
    const is_staging_buffer_required: bool = false;
    if (is_staging_buffer_required) {
        std.debug.assert(false);

        var staging_buffer: vk.Buffer = try zvk.createBuffer(app.logical_device, .{
            .p_next = null,
            .flags = .{},
            .size = texture_size_bytes * 2,
            .usage = .{ .transferSrc = true },
            .sharingMode = .EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = undefined,
        });

        const staging_memory_alloc = vk.MemoryAllocateInfo{
            .s_type = vk.StructureType.MEMORY_ALLOCATE_INFO,
            .p_next = null,
            .allocationSize = texture_size_bytes * 2, // x2 because we have two array layers
            .memoryTypeIndex = 0,
        };

        var staging_memory = try zvk.allocateMemory(app.logical_device, staging_memory_alloc);

        try zvk.bindBufferMemory(app.logical_device, staging_buffer, staging_memory, 0);

        // TODO: texture_size_bytes * 2
        if (.success != vk.vkMapMemory(app.logical_device, staging_memory, 0, texture_layer_size * 2, 0, @ptrCast(?**anyopaque, &image_memory_map))) {
            return error.MapMemoryFailed;
        }

        // Copy our second image to same memory
        // TODO: Fix data layout access
        @memcpy(image_memory_map, @ptrCast([*]u8, glyph_set.image), texture_layer_size);
        // @memcpy(image_memory_map + texture_layer_size, @ptrCast([*]u8, texture_layer), texture_layer_size);

        // No need to unmap memory
        // vk.vkUnmapMemory(app.logical_device, staging_memory);

        {
            const barrier = [_]vk.ImageMemoryBarrier{
                .{
                    .s_type = vk.StructureType.IMAGE_MEMORY_BARRIER,
                    .p_next = null,
                    .src_access_mask = .{},
                    .dst_access_mask = .{ .transfer_write_bit = true },
                    .old_layout = .@"undefined",
                    .new_layout = .TRANSFER_DST_OPTIMAL,
                    .src_queue_family_index = vk.queue_family_ignored,
                    .dst_queue_family_index = vk.queue_family_ignored,
                    .image = texture_image,
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 2,
                    },
                },
            };

            const src_stage = @bitCast(u32, vk.PipelineStageFlags{ .top_of_pipe_bit = true });
            const dst_stage = @bitCast(u32, vk.PipelineStageFlags{ .transfer_bit = true });
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

        std.debug.assert(texture_layer_size * 2 <= texture_memory_requirements.size);
        image_memory_map = @ptrCast([*]u8, (try app.device_dispatch.mapMemory(app.logical_device, image_memory, 0, texture_layer_size * 2, .{})).?);

        // if (.success != vk.vkMapMemory(app.logical_device, image_memory, 0, texture_layer_size * 2, 0, @ptrCast(?**anyopaque, &image_memory_map))) {
        // return error.MapMemoryFailed;
        // }

        // Copy our second image to same memory
        // TODO: Fix data layout access
        @memcpy(image_memory_map, @ptrCast([*]u8, glyph_set.image), texture_layer_size);
        // @memcpy(image_memory_map + texture_layer_size, @ptrCast([*]u8, texture_layer), texture_layer_size);
    }

    allocator.free(glyph_set.image);

    // Regardless of whether a staging buffer was used, and the type of memory that backs the texture
    // It is neccessary to transition to image layout to SHADER_OPTIMAL

    const barrier = [_]vk.ImageMemoryBarrier{
        .{
            .s_type = vk.StructureType.image_memory_barrier,
            .p_next = null,
            .src_access_mask = .{},
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .@"undefined",
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = texture_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 2,
            },
        },
    };

    {
        const src_stage = vk.PipelineStageFlags{ .top_of_pipe_bit = true };
        const dst_stage = vk.PipelineStageFlags{ .fragment_shader_bit = true };
        const dependency_flags = vk.DependencyFlags{};
        app.device_dispatch.cmdPipelineBarrier(command_buffer, src_stage, dst_stage, dependency_flags, 0, undefined, 0, undefined, 1, &barrier);
    }
    // }

    try app.device_dispatch.endCommandBuffer(command_buffer);

    const submit_command_infos = [_]vk.SubmitInfo{.{
        .s_type = vk.StructureType.submit_info,
        .p_next = null,
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]vk.CommandBuffer, &command_buffer),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    }};

    try app.device_dispatch.queueSubmit(app.graphics_present_queue, 1, &submit_command_infos, .null_handle);

    texture_image_view = try app.device_dispatch.createImageView(app.logical_device, &vk.ImageViewCreateInfo{
        .flags = .{},
        .image = texture_image,
        .view_type = .@"2d_array",
        .format = .r32g32b32a32_sfloat,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 2,
        },
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
    }, null);

    const surface_capabilities: vk.SurfaceCapabilitiesKHR = try app.instance_dispatch.getPhysicalDeviceSurfaceCapabilitiesKHR(app.physical_device, app.surface);

    if (surface_capabilities.current_extent.width == 0xFFFFFFFF or surface_capabilities.current_extent.height == 0xFFFFFFFF) {
        std.log.info("Getting framebuffer size", .{});

        const window_size = glfw.getFramebufferSize(app.window);
        std.log.info("Screen size: {d}x{d}", .{ window_size.width, window_size.height });

        std.debug.assert(window_size.width < 10_000 and window_size.height < 10_000);

        if (window_size.width <= 0 or window_size.height <= 0) {
            return error.InvalidScreenDimensions;
        }

        app.swapchain_extent.width = window_size.width;
        app.swapchain_extent.height = window_size.height;

        screen_dimensions.width = @intCast(ScreenPixelBaseType, app.swapchain_extent.width);
        screen_dimensions.height = @intCast(ScreenPixelBaseType, app.swapchain_extent.height);
    }

    app.swapchain = try app.device_dispatch.createSwapchainKHR(app.logical_device, &vk.SwapchainCreateInfoKHR{
        .s_type = vk.StructureType.swapchain_create_info_khr,
        .surface = app.surface,
        .min_image_count = surface_capabilities.min_image_count + 1,
        .image_format = app.swapchain_image_format,
        .image_color_space = app.surface_format.color_space,
        .image_extent = app.swapchain_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .pre_transform = surface_capabilities.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = .fifo_khr,
        .clipped = vk.TRUE,
        .flags = .{},
        .old_swapchain = .null_handle,
        .p_next = null,
    }, null);

    app.swapchain_images = try zvk.getSwapchainImagesKHR(DeviceDispatch, app.device_dispatch, allocator, app.logical_device, app.swapchain);

    std.log.info("Swapchain images: {d}", .{app.swapchain_images.len});

    // TODO: Duplicated code
    app.swapchain_image_views = try allocator.alloc(vk.ImageView, app.swapchain_images.len);
    for (app.swapchain_image_views) |*image_view, i| {
        const image_view_create_info = vk.ImageViewCreateInfo{
            .s_type = vk.StructureType.image_view_create_info,
            .image = app.swapchain_images[i],
            .view_type = .@"2d",
            .format = app.swapchain_image_format,
            .components = vk.ComponentMapping{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = vk.ImageSubresourceRange{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .p_next = null,
            .flags = .{},
        };

        image_view.* = try app.device_dispatch.createImageView(app.logical_device, &image_view_create_info, null);
    }

    std.debug.assert(vertices_range_index_begin + vertices_range_size <= memory_size);

    // Memory used to store vertices and indices

    var mesh_memory = try app.device_dispatch.allocateMemory(app.logical_device, &vk.MemoryAllocateInfo{
        .s_type = vk.StructureType.memory_allocate_info,
        .allocation_size = memory_size,
        .memory_type_index = mesh_memory_index,
        .p_next = null,
    }, null);

    {
        //
        // Bind memory reserved for vertices to vertex buffer
        //

        const buffer_create_info = vk.BufferCreateInfo{
            .s_type = vk.StructureType.buffer_create_info,
            .size = vertices_range_size,
            .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
            .flags = .{},
            .p_next = null,
        };

        texture_vertices_buffer = try app.device_dispatch.createBuffer(app.logical_device, &buffer_create_info, null);
        try app.device_dispatch.bindBufferMemory(app.logical_device, texture_vertices_buffer, mesh_memory, vertices_range_index_begin);
    }

    {
        //
        // Bind memory reserved for indices to index buffer
        //

        const buffer_create_info = vk.BufferCreateInfo{
            .s_type = vk.StructureType.buffer_create_info,
            .size = indices_range_size,
            .usage = .{ .transfer_dst_bit = true, .index_buffer_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
            .flags = .{},
            .p_next = null,
        };

        texture_indices_buffer = try app.device_dispatch.createBuffer(app.logical_device, &buffer_create_info, null);
        try app.device_dispatch.bindBufferMemory(app.logical_device, texture_indices_buffer, mesh_memory, indices_range_index_begin);
    }

    // texture_vertices_buffer = try zvk.createBufferOnMemory(app.logical_device, vertices_range_size, vertices_range_index_begin, .{ .transferDst = true, .vertexBuffer = true }, mesh_memory);
    // texture_indices_buffer = try zvk.createBufferOnMemory(app.logical_device, indices_range_size, indices_range_index_begin, .{ .transferDst = true, .indexBuffer = true }, mesh_memory);

    mapped_device_memory = @ptrCast([*]u8, (try app.device_dispatch.mapMemory(app.logical_device, mesh_memory, 0, memory_size, .{})).?);

    {
        const vertices_addr = @ptrCast([*]align(@alignOf(GenericVertex)) u8, &mapped_device_memory[vertices_range_index_begin]);
        const vertices_quad_size: u32 = vertices_range_size / @sizeOf(GenericVertex);
        quad_face_writer_pool = QuadFaceWriterPool(GenericVertex).initialize(vertices_addr, vertices_quad_size);
    }

    {
        const vertices_base = @ptrCast([*]GenericVertex, &mapped_device_memory[vertices_range_index_begin]);
        const vertex_buffer_capacity = vertices_range_size / @sizeOf(GenericVertex);
        gui.init(vertices_base[0..vertex_buffer_capacity]);
    }

    // if (vk.vkMapMemory(app.logical_device, mesh_memory, 0, memory_size, 0, @ptrCast(**anyopaque, &mapped_device_memory)) != .success) {
    // return error.MapMemoryFailed;
    // }

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

    {
        const command_pool_create_info = vk.CommandPoolCreateInfo{
            .s_type = vk.StructureType.command_pool_create_info,
            .queue_family_index = app.graphics_present_queue_index,
            .flags = .{},
            .p_next = null,
        };

        app.command_pool = try app.device_dispatch.createCommandPool(app.logical_device, &command_pool_create_info, null);
    }

    app.images_available = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    app.renders_finished = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    app.inflight_fences = try allocator.alloc(vk.Fence, max_frames_in_flight);

    const semaphore_create_info = vk.SemaphoreCreateInfo{
        .s_type = vk.StructureType.semaphore_create_info,
        .flags = .{},
        .p_next = null,
    };

    const fence_create_info = vk.FenceCreateInfo{
        .s_type = vk.StructureType.fence_create_info,
        .flags = .{ .signaled_bit = true },
        .p_next = null,
    };

    var i: u32 = 0;
    while (i < max_frames_in_flight) {
        app.images_available[i] = try app.device_dispatch.createSemaphore(app.logical_device, &semaphore_create_info, null);
        app.renders_finished[i] = try app.device_dispatch.createSemaphore(app.logical_device, &semaphore_create_info, null);
        app.inflight_fences[i] = try app.device_dispatch.createFence(app.logical_device, &fence_create_info, null);
        i += 1;
    }

    app.vertex_shader_module = try createVertexShaderModule(app.*);
    app.fragment_shader_module = try createFragmentShaderModule(app.*);

    std.debug.assert(app.swapchain_images.len > 0);
    app.command_buffers = try allocateCommandBuffers(allocator, app.*, @intCast(u32, app.swapchain_images.len));

    app.render_pass = try createRenderPass(app.*);

    app.descriptor_set_layouts = try createDescriptorSetLayouts(allocator, app.*);
    app.pipeline_layout = try createPipelineLayout(app.*, app.descriptor_set_layouts);
    app.descriptor_pool = try createDescriptorPool(app.*);
    app.descriptor_sets = try createDescriptorSets(allocator, app.*, app.descriptor_set_layouts);
    app.graphics_pipeline = try createGraphicsPipeline(app.*, app.pipeline_layout, app.render_pass);
    app.framebuffers = try createFramebuffers(allocator, app.*);
}

fn swapTexture(app: *GraphicsContext) !void {
    std.log.info("SwapTexture begin", .{});

    const command_pool = try zvk.createCommandPool(app.logical_device, vk.CommandPoolCreateInfo{
        .s_type = vk.StructureType.COMMAND_POOL_CREATE_INFO,
        .p_next = null,
        .flags = .{ .resetCommandBuffer = true },
        .queueFamilyIndex = app.graphics_present_queue_index,
    });

    {
        var command_buffer = try zvk.allocateCommandBuffer(app.logical_device, vk.CommandBufferAllocateInfo{
            .s_type = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
            .p_next = null,
            .level = .PRIMARY,
            .commandPool = command_pool,
            .commandBufferCount = 1,
        });

        try zvk.beginCommandBuffer(command_buffer, .{
            .s_type = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
            .p_next = null,
            .flags = .{ .oneTimeSubmit = true },
            .pInheritanceInfo = null,
        });

        {
            const barrier = [_]vk.ImageMemoryBarrier{
                .{
                    .s_type = vk.StructureType.IMAGE_MEMORY_BARRIER,
                    .p_next = null,
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

        try app.device_dispatch.endCommandBuffer(command_buffer);

        // try zvk.endCommandBuffer(command_buffer);

        const submit_command_infos = [_]vk.SubmitInfo{.{
            .s_type = vk.StructureType.SUBMIT_INFO,
            .p_next = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = undefined,
            .pWaitDstStageMask = undefined,
            .commandBufferCount = 1,
            .pCommandBuffers = @ptrCast([*]vk.CommandBuffer, &command_buffer),
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = undefined,
        }};

        if (.success != vk.vkQueueSubmit(app.graphics_present_queue, 1, &submit_command_infos, null)) {
            return error.QueueSubmitFailed;
        }

        if (vk.vkDeviceWaitIdle(app.logical_device) != .success) {
            return error.DeviceWaitIdleFailed;
        }

        std.log.info("SwapTexture copy", .{});

        // TODO
        const second_image: []RGBA(f32) = undefined;
        @memcpy(image_memory_map + texture_size_bytes, @ptrCast([*]u8, second_image.?), texture_size_bytes);
    }

    std.log.info("SwapTexture end", .{});

    {
        var command_buffer = try zvk.allocateCommandBuffer(app.logical_device, vk.CommandBufferAllocateInfo{
            .s_type = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
            .p_next = null,
            .level = .PRIMARY,
            .commandPool = command_pool,
            .commandBufferCount = 1,
        });

        try zvk.beginCommandBuffer(command_buffer, .{
            .s_type = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
            .p_next = null,
            .flags = .{ .oneTimeSubmit = true },
            .pInheritanceInfo = null,
        });

        {
            const barrier = [_]vk.ImageMemoryBarrier{
                .{
                    .s_type = vk.StructureType.IMAGE_MEMORY_BARRIER,
                    .p_next = null,
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

        try app.device_dispatch.endCommandBuffer(command_buffer);

        // try zvk.endCommandBuffer(command_buffer);

        const submit_command_infos = [_]vk.SubmitInfo{.{
            .s_type = vk.StructureType.SUBMIT_INFO,
            .p_next = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = undefined,
            .pWaitDstStageMask = undefined,
            .commandBufferCount = 1,
            .pCommandBuffers = @ptrCast([*]vk.CommandBuffer, &command_buffer),
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = undefined,
        }};

        if (.success != vk.vkQueueSubmit(app.graphics_present_queue, 1, &submit_command_infos, null)) {
            return error.QueueSubmitFailed;
        }

        if (vk.vkDeviceWaitIdle(app.logical_device) != .success) {
            return error.DeviceWaitIdleFailed;
        }
    }
}

// TODO: Rename act
fn mouseButtonCallback(window: *glfw.Window, button: glfw.MouseButton, act: glfw.Action, mods: glfw.Mods) void {
    _ = mods;
    if (glfw.getCursorPos(window)) |cursor_position| {
        const half_width = @intToFloat(f32, screen_dimensions.width) / 2.0;
        const half_height = @intToFloat(f32, screen_dimensions.height) / 2.0;
        const position = geometry.Coordinates2D(ScreenNormalizedBaseType){
            .x = @floatCast(f32, (cursor_position.x - half_width) * 2.0) / @intToFloat(f32, screen_dimensions.width),
            .y = @floatCast(f32, (cursor_position.y - half_height) * 2.0) / @intToFloat(f32, screen_dimensions.height),
        };

        const is_pressed_left = (button == glfw.MouseButton.left and act == glfw.Action.press);
        const is_pressed_right = (button == glfw.MouseButton.right and act == glfw.Action.press);

        event_system.handleMouseEvents(position, is_pressed_left, is_pressed_right);
    } else |err| {
        std.log.warn("Failed to get cursor position : {s}", .{err});
    }
}

fn mousePositionCallback(window: *glfw.Window, x_position: f64, y_position: f64) void {
    _ = window;
    const half_width = @intToFloat(f32, screen_dimensions.width) / 2.0;
    const half_height = @intToFloat(f32, screen_dimensions.height) / 2.0;
    const position = geometry.Coordinates2D(ScreenNormalizedBaseType){
        .x = @floatCast(f32, (x_position - half_width) * 2.0) / @intToFloat(f32, screen_dimensions.width),
        .y = @floatCast(f32, (y_position - half_height) * 2.0) / @intToFloat(f32, screen_dimensions.height),
    };

    event_system.handleMouseEvents(position, false, false);
}

// TODO: Rename act
fn glfwKeyCallback(window: *glfw.Window, key: i32, scancode: i32, act: i32, mods: i32) callconv(.C) void {
    _ = window;
    _ = key;
    _ = scancode;
    _ = act;
    _ = mods;
}

fn parseFileNameFromPath(path: []const u8) ![]const u8 {
    var i = path.len - 1;
    while (i > 0) : (i -= 1) {
        if (path[i] == '/') {
            return path[i + 1 ..];
        }
    }

    std.log.err("Failed to parse file name from path '{s}'", .{path});
    return error.PathFormatError;
}

fn update(allocator: Allocator, app: *GraphicsContext) !void {
    event_system.mouse_event_writer.reset();

    _ = app;
    _ = allocator;

    std.log.info("Update called", .{});

    std.debug.assert(screen_dimensions.width > 0);
    std.debug.assert(screen_dimensions.height > 0);

    vertex_buffer_count = 0;

    ui.reset();
    audio.reset();
    event_system.resetBindings();

    var face_writer = quad_face_writer_pool.create(0, vertices_range_size / @sizeOf(GenericVertex));

    try ui.header.draw(&face_writer, glyph_set, scale_factor, theme);
    try ui.footer.draw(&face_writer, theme);
    try ui.directory_up_button.draw(&face_writer, glyph_set, scale_factor, theme);

    {
        // Progress bar will only ever required 2 quads
        // As a result it is better to allocate outside of the function
        var progress_bar_quads = try face_writer.allocate(2);
        ui.progress_bar.create(progress_bar_quads, scale_factor, theme);

        // const origin_event = event_system.SubsystemEventIndex{
        //     .subsystem = audio.subsystem_index,
        //     .index = @intCast(event_system.EventIndex, @enumToInt(audio.AudioEvent.started)),
        // };

        // // Add an action handler that will start the progress bar callback
        // // when audio starts playing
        // const target_event = event_system.SubsystemActionIndex{
        //     .subsystem = ui.subsystem_index,
        //     .index = ui.doStartProgressBar(),
        // };

        // _ = event_system.internalEventsBind(.{ .origin = origin_event, .target = target_event });
    }

    try ui.playlist_buttons.next.draw(&face_writer, scale_factor, theme);
    try ui.playlist_buttons.previous.draw(&face_writer, scale_factor, theme);
    try ui.playlist_buttons.toggle.draw(&face_writer, scale_factor, theme);

    if (navigation.directoryview_storage.count > 1 and screen_dimensions.width >= 300) {
        var slice_buffer: [64][]const u8 = undefined;
        const directory_count = navigation.directoryview_storage.directoryCount();
        var i: u8 = 0;
        while (i < directory_count) : (i += 1) {
            slice_buffer[i] = navigation.directoryview_storage.filename(i);
        }

        const width_percentage: f32 = if (navigation.trackview_path_opt != null) 0.6 else 0.9;
        const placement = scale_factor.convertPoint(.pixel, .ndc_right, .{
            .x = 20,
            .y = 200,
        });

        const directory_screen_space = geometry.Extent2D(ScreenNormalizedBaseType){
            .width = width_percentage * 2.0,
            .height = 1.6,
            .x = if (navigation.trackview_path_opt == null) placement.x else -1.0,
            .y = -0.7,
        };

        try ui.directory_view.draw(
            &face_writer,
            slice_buffer[0..directory_count],
            glyph_set,
            scale_factor,
            theme,
            directory_screen_space,
            .top_left,
        );
    }

    if (navigation.trackview_path_opt) |trackview_path| {
        const draw_region = geometry.Extent2D(ScreenPixelBaseType){
            .x = screen_dimensions.width - 400,
            .y = scale_factor.convertPoint(.ndc_right, .pixel, .{
                .y = -0.8,
                .x = 0.0,
            }).y,
            .width = 400,
            .height = scale_factor.convertLength(.ndc_right, .pixel, .vertical, 1.6),
        };

        if (navigation.trackview_storage_opt == null) {
            std.debug.assert(false);
            navigation.trackview_storage_opt = try Playlist.Storage.create(&trackview_arena, trackview_path, 0, 20);
        }

        var trackview_path_buffer: [256]u8 = undefined;
        const trackview_path_string = try trackview_path.realpath(".", trackview_path_buffer[0..]);

        const trackview_directory_name = parseFileNameFromPath(trackview_path_string) catch "Unknown";
        try ui.track_view.draw(
            &face_writer,
            navigation.trackview_storage_opt.?,
            glyph_set,
            scale_factor,
            theme,
            trackview_directory_name,
            draw_region,
        );
    }

    vertex_buffer_count = face_writer.used;

    is_draw_required = false;
    is_render_requested = true;

    std.log.info("Update completed", .{});

    event_system.mouse_event_writer.print();
}

fn appLoop(allocator: Allocator, app: *GraphicsContext) !void {
    const target_fps = 40;
    const target_ms_per_frame: u32 = 1000 / target_fps;

    std.log.info("Target MS / frame: {d}", .{target_ms_per_frame});

    glfw.setCursorPosCallback(app.window, mousePositionCallback);
    glfw.setMouseButtonCallback(app.window, mouseButtonCallback);

    scale_factor = ScreenScaleFactor.create(screen_dimensions);

    while (!glfw.shouldClose(app.window)) {
        glfw.pollEvents();

        // TODO: Don't get the screen every frame..
        const screen = glfw.getFramebufferSize(app.window);

        if (screen_dimensions.width <= 0 or screen_dimensions.height <= 0) {
            return error.InvalidScreenDimensions;
        }

        if (screen.width != screen_dimensions.width or
            screen.height != screen_dimensions.height)
        {
            framebuffer_resized = true;
            std.log.info("Framebuffer resized", .{});
            screen_dimensions.width = screen.width;
            screen_dimensions.height = screen.height;

            scale_factor = ScreenScaleFactor.create(screen_dimensions);
        }

        for (audio.output_event_buffer.collect()) |event| {
            if (event == .finished) {
                std.log.info("Track finished. Starting next..", .{});
                // event_system.resetActiveTimeIntervalEvents();
                Playlist.trackNext() catch |err| {
                    std.log.warn("Error playing next track in playlist -> {s}", .{err});
                };
            }

            if (event == .started or event == .paused or event == .stopped or event == .resumed) {
                is_draw_required = true;
            }
        }

        for (gui.message_queue.collect()) |message| {
            if (message == .vertices_modified) {
                is_render_requested = true;
                break;
            }
        }

        // TODO: Remove
        for (Playlist.output_events.collect()) |event| {
            if (event == .new_track_started) {
                is_draw_required = true;
            }

            if (event == .playlist_initialized) {
                const origin_event = event_system.SubsystemEventIndex{
                    .subsystem = audio.subsystem_index,
                    .index = @intCast(event_system.EventIndex, @enumToInt(audio.AudioEvent.finished)),
                };

                const target_event = event_system.SubsystemActionIndex{
                    .subsystem = Playlist.subsystem_index,
                    .index = Playlist.doNextTrackPlay(),
                };

                _ = event_system.internalEventsBind(.{ .origin = origin_event, .target = target_event });

                // TODO: Should not require a redraw
                // For the current track indicator
                is_draw_required = true;
            }
        }

        for (navigation.message_queue.collect()) |message| {
            switch (message) {
                .trackview_opened => {
                    // TODO: Very ugly code
                    if (navigation.trackview_path_opt) |trackview_path| {
                        if (Playlist.storage_opt) |playlist_storage| {
                            // Reuse *Storage from Playlist if it matches
                            const playlist_path = AbsolutePath.interface.value(playlist_storage.parent_path);
                            const playlist_path_trimmed = playlist_path[0 .. playlist_path.len - 1];
                            var output_buffer: [256]u8 = undefined;
                            const trackview_path_string = try trackview_path.realpath(".", output_buffer[0..]);
                            if (std.mem.eql(u8, playlist_path_trimmed, trackview_path_string)) {
                                navigation.trackview_storage_opt = playlist_storage;
                                continue;
                            }
                        }
                        navigation.trackview_storage_opt = try Playlist.Storage.create(&trackview_arena, trackview_path, 0, 20);
                        _ = try std.Thread.spawn(.{}, navigation.calculateDurationsWrapper, .{navigation.trackview_storage_opt.?});
                        is_draw_required = true;
                    }
                },
                .directory_changed => {
                    // const checkpoint_index = @enumToInt(RewindLevel.directory_changed);
                    // main_arena.rewindTo(@intCast(u16, arena_checkpoints[checkpoint_index]));
                    try navigation.init(&main_arena, navigation.directoryview_path);
                    is_draw_required = true;
                },
                .duration_calculated => {
                    is_draw_required = true;
                },
            }
        }

        // TODO: Don't do this every frame
        if (audio.output.getState() == .playing) {
            ui.progress_bar.update();
            is_render_requested = true;
        }

        if (framebuffer_resized) {
            is_draw_required = true;
            framebuffer_resized = false;
            try recreateSwapchain(allocator, app);
        }

        const frame_start_ms: i64 = std.time.milliTimestamp();

        if (is_draw_required) {
            try update(allocator, app);
            is_render_requested = true;
        }

        // TODO:
        if (is_render_requested) {
            try app.device_dispatch.deviceWaitIdle(app.logical_device);
            try app.device_dispatch.resetCommandPool(app.logical_device, app.command_pool, .{});
            try recordRenderPass(app.*, vertex_buffer_count * 6);
            try renderFrame(allocator, app);
            is_render_requested = false;
        }

        const frame_end_ms: i64 = std.time.milliTimestamp();
        const frame_duration_ms = frame_end_ms - frame_start_ms;

        event_system.handleTimeEvents(frame_end_ms);

        // TODO: I think the loop is running less than 1ms so you should update
        //       to nanosecond precision
        std.debug.assert(frame_duration_ms >= 0);

        if (frame_duration_ms >= target_ms_per_frame) {
            continue;
        }

        std.debug.assert(target_ms_per_frame > frame_duration_ms);
        const remaining_ms: u32 = target_ms_per_frame - @intCast(u32, frame_duration_ms);
        std.time.sleep(remaining_ms * 1000 * 1000);
    }

    try app.device_dispatch.deviceWaitIdle(app.logical_device);
}

fn recordRenderPass(
    app: GraphicsContext,
    indices_count: u32,
) !void {
    std.debug.assert(app.command_buffers.len > 0);
    std.debug.assert(app.swapchain_images.len == app.command_buffers.len);
    std.debug.assert(app.screen_dimensions.width == app.swapchain_extent.width);
    std.debug.assert(app.screen_dimensions.height == app.swapchain_extent.height);

    const clear_color = theme.navigation_background;
    const clear_colors = [1]vk.ClearValue{
        vk.ClearValue{
            .color = vk.ClearColorValue{
                .float_32 = @bitCast([4]f32, clear_color),
            },
        },
    };

    for (app.command_buffers) |command_buffer, i| {
        try app.device_dispatch.beginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
            .s_type = vk.StructureType.command_buffer_begin_info,
            .p_next = null,
            .flags = .{},
            .p_inheritance_info = null,
        });

        app.device_dispatch.cmdBeginRenderPass(command_buffer, &vk.RenderPassBeginInfo{
            .s_type = vk.StructureType.render_pass_begin_info,
            .render_pass = app.render_pass,
            .framebuffer = app.framebuffers[i],
            .render_area = vk.Rect2D{
                .offset = vk.Offset2D{
                    .x = 0,
                    .y = 0,
                },
                .extent = app.swapchain_extent,
            },
            .clear_value_count = 1,
            .p_clear_values = &clear_colors,
            .p_next = null,
        }, .@"inline");

        app.device_dispatch.cmdBindPipeline(command_buffer, .graphics, app.graphics_pipeline);
        app.device_dispatch.cmdBindVertexBuffers(command_buffer, 0, 1, &[1]vk.Buffer{texture_vertices_buffer}, &[1]vk.DeviceSize{0});
        app.device_dispatch.cmdBindIndexBuffer(command_buffer, texture_indices_buffer, 0, .uint16);
        app.device_dispatch.cmdBindDescriptorSets(command_buffer, .graphics, app.pipeline_layout, 0, 1, &[1]vk.DescriptorSet{app.descriptor_sets[i]}, 0, undefined);

        app.device_dispatch.cmdDrawIndexed(command_buffer, indices_count, 1, 0, 0, 0);

        app.device_dispatch.cmdEndRenderPass(command_buffer);
        try app.device_dispatch.endCommandBuffer(command_buffer);
    }
}

fn renderFrame(allocator: Allocator, app: *GraphicsContext) !void {
    _ = try app.device_dispatch.waitForFences(app.logical_device, 1, @ptrCast([*]const vk.Fence, &app.inflight_fences[current_frame]), vk.TRUE, std.math.maxInt(u64));

    var swapchain_image_index: u32 = undefined;
    const acquire_image_result = try app.device_dispatch.acquireNextImageKHR(app.logical_device, app.swapchain, std.math.maxInt(u64), app.images_available[current_frame], .null_handle);
    swapchain_image_index = acquire_image_result.image_index;
    var result = acquire_image_result.result;

    if (result == .error_out_of_date_khr) {
        std.log.info("Swapchain out of date; Recreating..", .{});
        try recreateSwapchain(allocator, app);
        return;
    } else if (result != .success and result != .suboptimal_khr) {
        return error.AcquireNextImageFailed;
    }

    const wait_semaphores = [1]vk.Semaphore{app.images_available[current_frame]};
    const wait_stages = [1]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
    const signal_semaphores = [1]vk.Semaphore{app.renders_finished[current_frame]};

    const command_submit_info = vk.SubmitInfo{
        .s_type = vk.StructureType.submit_info,
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &wait_semaphores,
        .p_wait_dst_stage_mask = @ptrCast([*]align(4) const vk.PipelineStageFlags, &wait_stages),
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]vk.CommandBuffer, &app.command_buffers[swapchain_image_index]),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = &signal_semaphores,
        .p_next = null,
    };

    try app.device_dispatch.resetFences(app.logical_device, 1, @ptrCast([*]const vk.Fence, &app.inflight_fences[current_frame]));
    try app.device_dispatch.queueSubmit(app.graphics_present_queue, 1, @ptrCast([*]const vk.SubmitInfo, &command_submit_info), app.inflight_fences[current_frame]);

    const swapchains = [1]vk.SwapchainKHR{app.swapchain};
    const present_info = vk.PresentInfoKHR{
        .s_type = vk.StructureType.present_info_khr,
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &signal_semaphores,
        .swapchain_count = 1,
        .p_swapchains = &swapchains,
        .p_image_indices = @ptrCast([*]u32, &swapchain_image_index),
        .p_results = null,
        .p_next = null,
    };

    result = try app.device_dispatch.queuePresentKHR(app.graphics_present_queue, &present_info);

    if (result == .error_out_of_date_khr or result == .suboptimal_khr or framebuffer_resized) {
        framebuffer_resized = false;
        try recreateSwapchain(allocator, app);
        return;
    } else if (result != .success) {
        return error.QueuePresentFailed;
    }

    current_frame = (current_frame + 1) % max_frames_in_flight;
}

const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
});

const InstanceDispatch = vk.InstanceWrapper(.{
    .destroyInstance = true,
    .createDevice = true,
    .destroySurfaceKHR = true,
    .enumeratePhysicalDevices = true,
    .getPhysicalDeviceProperties = true,
    .enumerateDeviceExtensionProperties = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .getPhysicalDeviceMemoryProperties = true,
    .getDeviceProcAddr = true,
});

const DeviceDispatch = vk.DeviceWrapper(.{
    .destroyDevice = true,
    .getDeviceQueue = true,
    .createSemaphore = true,
    .createFence = true,
    .createImageView = true,
    .destroyImageView = true,
    .destroySemaphore = true,
    .destroyFence = true,
    .getSwapchainImagesKHR = true,
    .createSwapchainKHR = true,
    .destroySwapchainKHR = true,
    .acquireNextImageKHR = true,
    .deviceWaitIdle = true,
    .waitForFences = true,
    .resetFences = true,
    .queueSubmit = true,
    .queuePresentKHR = true,
    .createCommandPool = true,
    .destroyCommandPool = true,
    .allocateCommandBuffers = true,
    .freeCommandBuffers = true,
    .queueWaitIdle = true,
    .createShaderModule = true,
    .destroyShaderModule = true,
    .createPipelineLayout = true,
    .destroyPipelineLayout = true,
    .createRenderPass = true,
    .destroyRenderPass = true,
    .createGraphicsPipelines = true,
    .destroyPipeline = true,
    .createFramebuffer = true,
    .destroyFramebuffer = true,
    .beginCommandBuffer = true,
    .endCommandBuffer = true,
    .allocateMemory = true,
    .freeMemory = true,
    .createBuffer = true,
    .destroyBuffer = true,
    .getBufferMemoryRequirements = true,
    .mapMemory = true,
    .unmapMemory = true,
    .bindBufferMemory = true,
    .cmdBeginRenderPass = true,
    .cmdEndRenderPass = true,
    .cmdBindPipeline = true,
    .cmdDraw = true,
    .cmdSetViewport = true,
    .cmdSetScissor = true,
    .cmdBindVertexBuffers = true,
    .cmdCopyBuffer = true,
    .cmdDrawIndexed = true,
    .createImage = true,
    .getImageMemoryRequirements = true,
    .bindImageMemory = true,
    .cmdPipelineBarrier = true,
    .createDescriptorSetLayout = true,
    .createDescriptorPool = true,
    .allocateDescriptorSets = true,
    .createSampler = true,
    .updateDescriptorSets = true,
    .resetCommandPool = true,
    .cmdBindIndexBuffer = true,
    .cmdBindDescriptorSets = true,
});

const GraphicsContext = struct {
    base_dispatch: BaseDispatch,
    instance_dispatch: InstanceDispatch,
    device_dispatch: DeviceDispatch,

    window: *glfw.Window,
    vertex_shader_module: vk.ShaderModule,
    fragment_shader_module: vk.ShaderModule,
    screen_dimensions: geometry.Extent2D(ScreenPixelBaseType),

    render_pass: vk.RenderPass,
    framebuffers: []vk.Framebuffer,
    graphics_pipeline: vk.Pipeline,
    descriptor_pool: vk.DescriptorPool,
    descriptor_sets: []vk.DescriptorSet,
    descriptor_set_layouts: []vk.DescriptorSetLayout,
    pipeline_layout: vk.PipelineLayout,

    instance: vk.Instance,
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

fn createFragmentShaderModule(app: GraphicsContext) !vk.ShaderModule {
    const fragment_shader_path = "../../shaders/generic.frag.spv";
    const shader_fragment_spv align(4) = @embedFile(fragment_shader_path);

    const create_info = vk.ShaderModuleCreateInfo{
        .s_type = vk.StructureType.shader_module_create_info,
        .code_size = shader_fragment_spv.len,
        .p_code = @ptrCast([*]const u32, shader_fragment_spv),
        .p_next = null,
        .flags = .{},
    };

    return try app.device_dispatch.createShaderModule(app.logical_device, &create_info, null);
}

fn createVertexShaderModule(app: GraphicsContext) !vk.ShaderModule {
    const vertex_shader_path = "../../shaders/generic.vert.spv";
    const shader_vertex_spv align(4) = @embedFile(vertex_shader_path);

    const create_info = vk.ShaderModuleCreateInfo{
        .s_type = vk.StructureType.shader_module_create_info,
        .code_size = shader_vertex_spv.len,
        .p_code = @ptrCast([*]const u32, shader_vertex_spv),
        .p_next = null,
        .flags = .{},
    };

    return try app.device_dispatch.createShaderModule(app.logical_device, &create_info, null);
}

fn createRenderPass(app: GraphicsContext) !vk.RenderPass {
    return try app.device_dispatch.createRenderPass(app.logical_device, &vk.RenderPassCreateInfo{
        .s_type = vk.StructureType.render_pass_create_info,
        .attachment_count = 1,
        .p_attachments = &[1]vk.AttachmentDescription{
            .{
                .format = app.swapchain_image_format,
                .samples = .{ .@"1_bit" = true },
                .load_op = .clear,
                .store_op = .store,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = .@"undefined",
                .final_layout = .present_src_khr,
                .flags = .{},
            },
        },
        .subpass_count = 1,
        .p_subpasses = &[1]vk.SubpassDescription{
            .{
                .pipeline_bind_point = .graphics,
                .color_attachment_count = 1,
                .p_color_attachments = &[1]vk.AttachmentReference{
                    vk.AttachmentReference{
                        .attachment = 0,
                        .layout = .color_attachment_optimal,
                    },
                },
                .input_attachment_count = 0,
                .p_input_attachments = undefined,
                .p_resolve_attachments = null,
                .p_depth_stencil_attachment = null,
                .preserve_attachment_count = 0,
                .p_preserve_attachments = undefined,
                .flags = .{},
            },
        },
        .dependency_count = 1,
        .p_dependencies = &[1]vk.SubpassDependency{
            .{
                .src_subpass = vk.SUBPASS_EXTERNAL,
                .dst_subpass = 0,
                .src_stage_mask = .{ .color_attachment_output_bit = true },
                .dst_stage_mask = .{ .color_attachment_output_bit = true },
                .src_access_mask = .{},
                .dst_access_mask = .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
                .dependency_flags = .{},
            },
        },
        .flags = .{},
        .p_next = null,
    }, null);
}

fn createDescriptorPool(app: GraphicsContext) !vk.DescriptorPool {
    const image_count: u32 = @intCast(u32, app.swapchain_image_views.len);
    const descriptor_pool_sizes = [_]vk.DescriptorPoolSize{
        .{
            .@"type" = .sampler,
            .descriptor_count = image_count,
        },
        .{
            .@"type" = .sampled_image,
            // TODO * 2 ?
            .descriptor_count = image_count * 2,
        },
    };

    const create_pool_info = vk.DescriptorPoolCreateInfo{
        .s_type = vk.StructureType.descriptor_pool_create_info,
        .pool_size_count = descriptor_pool_sizes.len,
        .p_pool_sizes = &descriptor_pool_sizes,
        .max_sets = image_count,
        .p_next = null,
        .flags = .{},
    };

    return try app.device_dispatch.createDescriptorPool(app.logical_device, &create_pool_info, null);
}

fn createDescriptorSetLayouts(allocator: Allocator, app: GraphicsContext) ![]vk.DescriptorSetLayout {
    var descriptor_set_layouts = try allocator.alloc(vk.DescriptorSetLayout, app.swapchain_image_views.len);
    {
        const descriptor_set_layout_bindings = [_]vk.DescriptorSetLayoutBinding{vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_immutable_samplers = null,
            .stage_flags = .{ .fragment_bit = true },
        }};

        const descriptor_set_layout_create_info = vk.DescriptorSetLayoutCreateInfo{
            .s_type = vk.StructureType.descriptor_set_layout_create_info,
            .binding_count = 1,
            .p_bindings = @ptrCast([*]const vk.DescriptorSetLayoutBinding, &descriptor_set_layout_bindings[0]),
            .p_next = null,
            .flags = .{},
        };

        descriptor_set_layouts[0] = try app.device_dispatch.createDescriptorSetLayout(app.logical_device, &descriptor_set_layout_create_info, null);

        //
        // We can copy the same descriptor set layout for each swapchain image
        //

        var x: u32 = 1;
        while (x < app.swapchain_image_views.len) : (x += 1) {
            descriptor_set_layouts[x] = descriptor_set_layouts[0];
        }
    }

    return descriptor_set_layouts;
}

fn createDescriptorSets(allocator: Allocator, app: GraphicsContext, descriptor_set_layouts: []vk.DescriptorSetLayout) ![]vk.DescriptorSet {
    const swapchain_image_count: u32 = @intCast(u32, app.swapchain_image_views.len);

    //
    // 1. Allocate DescriptorSets from DescriptorPool
    //

    var descriptor_sets = try allocator.alloc(vk.DescriptorSet, swapchain_image_count);
    {
        const descriptor_set_allocator_info = vk.DescriptorSetAllocateInfo{
            .s_type = vk.StructureType.descriptor_set_allocate_info,
            .p_next = null,
            .descriptor_pool = app.descriptor_pool,
            .descriptor_set_count = swapchain_image_count,
            .p_set_layouts = descriptor_set_layouts.ptr,
        };

        try app.device_dispatch.allocateDescriptorSets(app.logical_device, &descriptor_set_allocator_info, @ptrCast([*]vk.DescriptorSet, descriptor_sets.ptr));
    }

    //
    // 2. Create Sampler that will be written to DescriptorSet
    //

    const sampler_create_info = vk.SamplerCreateInfo{
        .s_type = vk.StructureType.sampler_create_info,
        .p_next = null,
        .flags = .{},
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .mip_lod_bias = 0.0,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 16.0,
        .border_color = .int_opaque_black,
        .min_lod = 0.0,
        .max_lod = 0.0,
        .unnormalized_coordinates = vk.FALSE,
        .compare_enable = vk.FALSE,
        .compare_op = .always,
        .mipmap_mode = .linear,
    };

    const sampler = try app.device_dispatch.createSampler(app.logical_device, &sampler_create_info, null);

    //
    // 3. Write to DescriptorSets
    //

    var i: u32 = 0;
    while (i < swapchain_image_count) : (i += 1) {
        const descriptor_image_info = [_]vk.DescriptorImageInfo{
            .{
                .image_layout = .shader_read_only_optimal,
                .image_view = texture_image_view,
                .sampler = sampler,
            },
        };

        const write_descriptor_set = [_]vk.WriteDescriptorSet{.{
            .s_type = vk.StructureType.write_descriptor_set,
            .p_next = null,
            .dst_set = descriptor_sets[i],
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .p_image_info = &descriptor_image_info,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }};

        app.device_dispatch.updateDescriptorSets(app.logical_device, 1, &write_descriptor_set, 0, undefined);
    }

    return descriptor_sets;
}

fn createPipelineLayout(app: GraphicsContext, descriptor_set_layouts: []vk.DescriptorSetLayout) !vk.PipelineLayout {
    const pipeline_layout_create_info = vk.PipelineLayoutCreateInfo{
        .s_type = vk.StructureType.pipeline_layout_create_info,
        .set_layout_count = 1,
        .p_set_layouts = descriptor_set_layouts.ptr,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
        .flags = .{},
        .p_next = null,
    };

    return try app.device_dispatch.createPipelineLayout(app.logical_device, &pipeline_layout_create_info, null);
}

fn createGraphicsPipeline(app: GraphicsContext, pipeline_layout: vk.PipelineLayout, render_pass: vk.RenderPass) !vk.Pipeline {
    const vertex_input_attribute_descriptions = [_]vk.VertexInputAttributeDescription{
        // inPosition
        vk.VertexInputAttributeDescription{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = 0,
        },
        // inTexCoord
        vk.VertexInputAttributeDescription{
            .binding = 0,
            .location = 1,
            .format = .r32g32_sfloat,
            .offset = 8,
        },
        // inColor
        vk.VertexInputAttributeDescription{
            .binding = 0,
            .location = 2,
            .format = .r32g32b32a32_sfloat,
            .offset = 16,
        },
    };

    const vertex_shader_stage_info = vk.PipelineShaderStageCreateInfo{
        .s_type = vk.StructureType.pipeline_shader_stage_create_info,
        .stage = .{ .vertex_bit = true },
        .module = app.vertex_shader_module,
        .p_name = "main",
        .p_specialization_info = null,
        .flags = .{},
        .p_next = null,
    };

    const fragment_shader_stage_info = vk.PipelineShaderStageCreateInfo{
        .s_type = vk.StructureType.pipeline_shader_stage_create_info,
        .stage = .{ .fragment_bit = true },
        .module = app.fragment_shader_module,
        .p_name = "main",
        .p_specialization_info = null,
        .flags = .{},
        .p_next = null,
    };

    const shader_stages = [2]vk.PipelineShaderStageCreateInfo{
        vertex_shader_stage_info,
        fragment_shader_stage_info,
    };

    const vertex_input_binding_descriptions = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = 32,
        .input_rate = .vertex,
    };

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .s_type = vk.StructureType.pipeline_vertex_input_state_create_info,
        .vertex_binding_description_count = @intCast(u32, 1),
        .vertex_attribute_description_count = @intCast(u32, 3),
        .p_vertex_binding_descriptions = @ptrCast([*]const vk.VertexInputBindingDescription, &vertex_input_binding_descriptions),
        .p_vertex_attribute_descriptions = @ptrCast([*]const vk.VertexInputAttributeDescription, &vertex_input_attribute_descriptions),
        .flags = .{},
        .p_next = null,
    };

    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .s_type = vk.StructureType.pipeline_input_assembly_state_create_info,
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
        .flags = .{},
        .p_next = null,
    };

    const viewports = [1]vk.Viewport{
        vk.Viewport{
            .x = 0.0,
            .y = 0.0,
            .width = @intToFloat(f32, app.screen_dimensions.width),
            .height = @intToFloat(f32, app.screen_dimensions.height),
            .min_depth = 0.0,
            .max_depth = 1.0,
        },
    };

    const scissors = [1]vk.Rect2D{
        vk.Rect2D{
            .offset = vk.Offset2D{
                .x = 0,
                .y = 0,
            },
            .extent = vk.Extent2D{
                .width = app.screen_dimensions.width,
                .height = app.screen_dimensions.height,
            },
        },
    };

    const viewport_state = vk.PipelineViewportStateCreateInfo{
        .s_type = vk.StructureType.pipeline_viewport_state_create_info,
        .viewport_count = 1,
        .p_viewports = &viewports,
        .scissor_count = 1,
        .p_scissors = &scissors,
        .flags = .{},
        .p_next = null,
    };

    const rasterizer = vk.PipelineRasterizationStateCreateInfo{
        .s_type = vk.StructureType.pipeline_rasterization_state_create_info,
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .line_width = 1.0,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_clamp = 0.0,
        .depth_bias_slope_factor = 0.0,
        .flags = .{},
        .p_next = null,
    };

    const multisampling = vk.PipelineMultisampleStateCreateInfo{
        .s_type = vk.StructureType.pipeline_multisample_state_create_info,
        .sample_shading_enable = vk.FALSE,
        .rasterization_samples = .{ .@"1_bit" = true },
        .min_sample_shading = 0.0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
        .flags = .{},
        .p_next = null,
    };

    const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        .blend_enable = vk.TRUE,
        .alpha_blend_op = .add,
        .color_blend_op = .add,
        .dst_alpha_blend_factor = .zero,
        .src_alpha_blend_factor = .one,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .src_color_blend_factor = .src_alpha,
    };

    const blend_constants = [1]f32{0.0} ** 4;

    const color_blending = vk.PipelineColorBlendStateCreateInfo{
        .s_type = vk.StructureType.pipeline_color_blend_state_create_info,
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast([*]const vk.PipelineColorBlendAttachmentState, &color_blend_attachment),
        .blend_constants = blend_constants,
        .flags = .{},
        .p_next = null,
    };

    const pipeline_create_infos = [1]vk.GraphicsPipelineCreateInfo{
        vk.GraphicsPipelineCreateInfo{
            .s_type = vk.StructureType.graphics_pipeline_create_info,
            .stage_count = 2,
            .p_stages = &shader_stages,
            .p_vertex_input_state = &vertex_input_info,
            .p_input_assembly_state = &input_assembly,
            .p_tessellation_state = null,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterizer,
            .p_multisample_state = &multisampling,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &color_blending,
            .p_dynamic_state = null,
            .layout = pipeline_layout,
            .render_pass = render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = 0,
            .flags = .{},
            .p_next = null,
        },
    };

    var graphics_pipeline: vk.Pipeline = undefined;
    _ = try app.device_dispatch.createGraphicsPipelines(app.logical_device, .null_handle, 1, &pipeline_create_infos, null, @ptrCast([*]vk.Pipeline, &graphics_pipeline));
    return graphics_pipeline;
}

fn createFramebuffers(allocator: Allocator, app: GraphicsContext) ![]vk.Framebuffer {
    std.debug.assert(app.swapchain_image_views.len > 0);
    var framebuffer_create_info = vk.FramebufferCreateInfo{
        .s_type = vk.StructureType.framebuffer_create_info,
        .render_pass = app.render_pass,
        .attachment_count = 1,
        .p_attachments = undefined,
        .width = app.screen_dimensions.width,
        .height = app.screen_dimensions.height,
        .layers = 1,
        .p_next = null,
        .flags = .{},
    };

    var framebuffers = try allocator.alloc(vk.Framebuffer, app.swapchain_image_views.len);

    var i: u32 = 0;
    while (i < app.swapchain_image_views.len) : (i += 1) {
        // We reuse framebuffer_create_info for each framebuffer we create, only we need to update the swapchain_image_view that is attached
        framebuffer_create_info.p_attachments = @ptrCast([*]vk.ImageView, &app.swapchain_image_views[i]);
        framebuffers[i] = try app.device_dispatch.createFramebuffer(app.logical_device, &framebuffer_create_info, null);
    }

    return framebuffers;
}

fn allocateCommandBuffers(allocator: Allocator, app: GraphicsContext, count: u32) ![]vk.CommandBuffer {
    std.debug.assert(count > 0);
    const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
        .s_type = vk.StructureType.command_buffer_allocate_info,
        .command_pool = app.command_pool,
        .level = .primary,
        .command_buffer_count = count,
        .p_next = null,
    };

    const command_buffers = try allocator.alloc(vk.CommandBuffer, count);
    try app.device_dispatch.allocateCommandBuffers(app.logical_device, &command_buffer_allocate_info, command_buffers.ptr);
    return command_buffers;
}

fn cleanupSwapchain(allocator: Allocator, app: *GraphicsContext) void {
    std.log.info("Cleaning swapchain", .{});

    app.device_dispatch.freeCommandBuffers(
        app.logical_device,
        app.command_pool,
        @intCast(u32, app.command_buffers.len),
        app.command_buffers.ptr,
    );
    allocator.free(app.command_buffers);

    for (app.swapchain_image_views) |image_view| {
        app.device_dispatch.destroyImageView(app.logical_device, image_view, null);
    }

    app.device_dispatch.destroySwapchainKHR(app.logical_device, app.swapchain, null);
}
