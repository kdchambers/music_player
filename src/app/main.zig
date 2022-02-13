// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const c = std.c;
const os = std.os;
const fs = std.fs;
const fmt = std.fmt;
const builtin = @import("builtin");
const log = std.log;
const assert = std.debug.assert;
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
const Mesh = graphics.Mesh;
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

const theme = @import("Theme.zig").default;

var is_render_requested: bool = true;
var quad_face_writer_pool: QuadFaceWriterPool(GenericVertex) = undefined;

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
    assert(app.swapchain_image_views.len > 0);
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

// Globals

var screen_dimensions = geometry.Dimensions2D(ScreenPixelBaseType){
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
const device_extensions = [_][*:0]const u8{vk.extension_info.khr_swapchain.name};

const max_frames_in_flight: u32 = 2;

var texture_image_view: vk.ImageView = undefined;
var texture_image: vk.Image = undefined;
var texture_vertices_buffer: vk.Buffer = undefined;
var texture_indices_buffer: vk.Buffer = undefined;

const help_message =
    \\music_player [<options>] [<filename>]
    \\options:
    \\    --help: display this help message
    \\
;

var music_dir: std.fs.Dir = undefined;

const MediaItemKind = enum {
    mp3,
    flac,
    directory,
    unknown,
};

fn StringBuffer(comptime size: u32) type {
    return struct {
        const This = @This();

        fn toSlice(self: *This) []u8 {
            return self.bytes[0..self.count];
        }

        fn fromSlice(self: *This, slice: []const u8) !void {
            if (slice.len > (size - 1)) {
                return error.InsuffienceSpace;
            }

            std.mem.copy(u8, self.bytes[0..], slice[0..]);
            self.bytes[slice.len] = 0; // Null terminate

            self.count = @intCast(u32, slice.len);
        }

        count: u32,
        bytes: [size]u8,
    };
}

const MediaItem = struct {
    kind: MediaItemKind,
    name: StringBuffer(60),
};

// TODO: You can define this with a env variable
// const library_root_path = "/mnt/data/media/music";
const library_root_path = "assets/example_library";
var loaded_media_items: FixedBuffer(MediaItem, 32) = .{ .count = 0 };
var current_directory: std.fs.Dir = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocator = gpa.allocator();

    //
    // Load all media items in the library root directory
    //

    {
        current_directory = try std.fs.cwd().openDir(library_root_path, .{ .iterate = true });

        const max_media_items: u32 = 10;

        var iterator = current_directory.iterate();
        var entry = try iterator.next();

        var i: u32 = 0;
        while (entry != null and loaded_media_items.count < max_media_items) {
            if (i == max_media_items) break;

            i += 1;

            const item_name = entry.?.name;

            var media_item: MediaItem = undefined;
            media_item.kind = blk: {
                if (item_name.len > 4) {
                    var extension_label: []u8 = try allocator.dupe(u8, item_name[item_name.len - 4 ..]);
                    defer allocator.free(extension_label);
                    toUpper(&extension_label);

                    if (std.mem.eql(u8, extension_label, "FLAC")) {
                        break :blk .flac;
                    } else if (std.mem.eql(u8, extension_label, ".MP3")) {
                        break :blk .mp3;
                    } else {
                        break :blk .directory;
                    }
                } else {
                    break :blk .directory;
                }
            };

            try media_item.name.fromSlice(item_name);
            _ = loaded_media_items.append(media_item);

            log.info("Media item: '{s}' {s}", .{ media_item.name.toSlice(), media_item.kind });
            entry = try iterator.next();
        }
    }

    var graphics_context: GraphicsContext = undefined;

    glfw.initialize() catch |err| {
        log.err("Failed to initialized glfw. Error: {s}", .{err});
        return;
    };
    defer glfw.terminate();

    // if (!glfw.vulkanSupported()) {
    // log.err("Vulkan is required", .{});
    // return;
    // }

    log.info("Initialized", .{});
    glfw.setHint(.client_api, .none);
    graphics_context.window = try glfw.createWindow(constants.initial_window_dimensions, constants.application_title);

    const window_size = glfw.getFramebufferSize(graphics_context.window);

    graphics_context.screen_dimensions.width = window_size.width;
    graphics_context.screen_dimensions.height = window_size.height;

    assert(window_size.width < 10_000 and window_size.height < 10_000);

    const vk_proc = @ptrCast(fn (instance: vk.Instance, procname: [*:0]const u8) callconv(.C) vk.PfnVoidFunction, glfw.getInstanceProcAddress);
    graphics_context.base_dispatch = try BaseDispatch.load(vk_proc);

    const instance_extension = try zvk.glfwGetRequiredInstanceExtensions();

    for (instance_extension) |extension| {
        log.info("Extension: {s}", .{extension});
    }

    graphics_context.instance = try graphics_context.base_dispatch.createInstance(&vk.InstanceCreateInfo{
        .s_type = .instance_create_info,
        .p_application_info = &vk.ApplicationInfo{
            .s_type = .application_info,
            .p_application_name = constants.application_title,
            .application_version = vk.makeApiVersion(0, 0, 1, 0),
            .p_engine_name = constants.application_title,
            .engine_version = vk.makeApiVersion(0, 0, 1, 0),
            .api_version = vk.makeApiVersion(1, 2, 0, 0),
            .p_next = null,
        },
        .enabled_extension_count = @intCast(u32, instance_extension.len),
        .pp_enabled_extension_names = instance_extension.ptr,
        .enabled_layer_count = if (enable_validation_layers) validation_layers.len else 0,
        .pp_enabled_layer_names = if (enable_validation_layers) &validation_layers else undefined,
        .p_next = null,
        .flags = .{},
    }, null);

    graphics_context.instance_dispatch = try InstanceDispatch.load(graphics_context.instance, vk_proc);
    _ = try glfw.createWindowSurface(graphics_context.instance, graphics_context.window, null, &graphics_context.surface);

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
                        log.warn("Some family queues for selected device ignored", .{});
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

        graphics_context.logical_device = try graphics_context.instance_dispatch.createDevice(graphics_context.physical_device, &device_create_info, null);
    }

    graphics_context.device_dispatch = try DeviceDispatch.load(graphics_context.logical_device, graphics_context.instance_dispatch.dispatch.vkGetDeviceProcAddr);
    graphics_context.graphics_present_queue = graphics_context.device_dispatch.getDeviceQueue(graphics_context.logical_device, graphics_context.graphics_present_queue_index, 0);

    var available_formats: []vk.SurfaceFormatKHR = try zvk.getPhysicalDeviceSurfaceFormatsKHR(InstanceDispatch, graphics_context.instance_dispatch, allocator, graphics_context.physical_device, graphics_context.surface);
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

    log.info("Terminated cleanly", .{});
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

fn cleanupSwapchain(allocator: Allocator, app: *GraphicsContext) void {
    log.info("Cleaning swapchain", .{});

    app.device_dispatch.freeCommandBuffers(app.logical_device, app.command_pool, @intCast(u32, app.command_buffers.len), app.command_buffers.ptr);
    allocator.free(app.command_buffers);

    for (app.swapchain_image_views) |image_view| {
        app.device_dispatch.destroyImageView(app.logical_device, image_view, null);
    }

    app.device_dispatch.destroySwapchainKHR(app.logical_device, app.swapchain, null);
}

fn recreateSwapchain(allocator: Allocator, app: *GraphicsContext) !void {

    // TODO: Find a better synchronization method
    try app.device_dispatch.deviceWaitIdle(app.logical_device);

    log.info("Recreating swapchain", .{});

    //
    // Cleanup swapchain and associated images
    //

    assert(app.command_buffers.len > 0);

    app.device_dispatch.freeCommandBuffers(app.logical_device, app.command_pool, @intCast(u32, app.command_buffers.len), app.command_buffers.ptr);
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

    const surface_capabilities: vk.SurfaceCapabilitiesKHR = try app.instance_dispatch.getPhysicalDeviceSurfaceCapabilitiesKHR(app.physical_device, app.surface);

    // TODO
    const available_formats: []vk.SurfaceFormatKHR = try zvk.getPhysicalDeviceSurfaceFormatsKHR(InstanceDispatch, app.instance_dispatch, allocator, app.physical_device, app.surface);
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

    // app.render_pass = try createRenderPass(app.*);
    // app.descriptor_set_layouts = try createDescriptorSetLayouts(allocator, app.*);
    // app.pipeline_layout = try createPipelineLayout(app.*, app.descriptor_set_layouts);
    // app.descriptor_pool = try createDescriptorPool(app.*);
    // app.descriptor_sets = try createDescriptorSets(allocator, app.*);

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

    log.info("Swapchain recreated", .{});

    //
}

fn allocateCommandBuffers(allocator: Allocator, app: GraphicsContext, count: u32) ![]vk.CommandBuffer {
    assert(count > 0);
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

var image_memory_map: [*]u8 = undefined;
var texture_size_bytes: usize = 0;

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
    glyph_set = try text.createGlyphSet(allocator, font_texture_chars[0..], texture_layer_dimensions);

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

    // var memory_properties = zvk.getDevicePhysicalMemoryProperties(app.physical_device);
    // zvk.logDevicePhysicalMemoryProperties(memory_properties);

    var texture_width: u32 = glyph_set.width();
    var texture_height: u32 = glyph_set.height();

    log.info("Glyph dimensions: {}x{}", .{ texture_width, texture_height });

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
            .extent = vk.Extent3D{ .width = texture_layer_dimensions.width, .height = texture_layer_dimensions.height, .depth = 1 },
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
        .memory_type_index = 0,
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
        assert(false);

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
        log.info("Getting framebuffer size", .{});

        const window_size = glfw.getFramebufferSize(app.window);
        log.info("Screen size: {d}x{d}", .{ window_size.width, window_size.height });

        assert(window_size.width < 10_000 and window_size.height < 10_000);

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

    log.info("Swapchain images: {d}", .{app.swapchain_images.len});

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
        // image_view = try zvk.createImageView(app.logical_device, image_view_create_info);
    }

    assert(vertices_range_index_begin + vertices_range_size <= memory_size);

    // Memory used to store vertices and indices

    var mesh_memory = try app.device_dispatch.allocateMemory(app.logical_device, &vk.MemoryAllocateInfo{
        .s_type = vk.StructureType.memory_allocate_info,
        .allocation_size = memory_size,
        .memory_type_index = 0, // TODO: Audit
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

    // if (vk.vkCreateCommandPool(app.logical_device, &command_pool_create_info, null, &app.command_pool) != .success) {
    // return error.CreateCommandPoolFailed;
    // }

    // {
    // const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
    // .s_type = vk.StructureType.command_buffer_allocate_info,
    // .command_pool = app.command_pool,
    // .level = .primary,
    // .command_buffer_count = @intCast(u32, app.swapchain_images.len),
    // .p_next = null,
    // };

    // app.command_buffers = try allocator.alloc(vk.CommandBuffer, app.swapchain_images.len);
    // try app.device_dispatch.allocateCommandBuffers(app.logical_device, &command_buffer_allocate_info, app.command_buffers.ptr);
    // }

    // app.command_buffers = try zvk.allocateCommandBuffers(allocator, app.logical_device, vk.CommandBufferAllocateInfo{
    // .s_type = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
    // .commandPool = app.command_pool,
    // .level = .PRIMARY,
    // .commandBufferCount = @intCast(u32, app.swapchain_images.len),
    // .p_next = null,
    // });

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

    log.info("Setting up pipeline", .{});

    app.vertex_shader_module = try createVertexShaderModule(app.*);
    app.fragment_shader_module = try createFragmentShaderModule(app.*);

    log.info(" Creating command buffers", .{});
    assert(app.swapchain_images.len > 0);
    app.command_buffers = try allocateCommandBuffers(allocator, app.*, @intCast(u32, app.swapchain_images.len));

    log.info(" Creating render pass", .{});
    app.render_pass = try createRenderPass(app.*);

    log.info(" Creating descriptor set layouts", .{});

    app.descriptor_set_layouts = try createDescriptorSetLayouts(allocator, app.*);
    app.pipeline_layout = try createPipelineLayout(app.*, app.descriptor_set_layouts);
    app.descriptor_pool = try createDescriptorPool(app.*);
    app.descriptor_sets = try createDescriptorSets(allocator, app.*, app.descriptor_set_layouts);
    app.graphics_pipeline = try createGraphicsPipeline(app.*, app.pipeline_layout, app.render_pass);
    app.framebuffers = try createFramebuffers(allocator, app.*);

    log.info("Application initialized", .{});
}

fn swapTexture(app: *GraphicsContext) !void {
    log.info("SwapTexture begin", .{});

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

        log.info("SwapTexture copy", .{});

        // TODO
        const second_image: []RGBA(f32) = undefined;
        @memcpy(image_memory_map + texture_size_bytes, @ptrCast([*]u8, second_image.?), texture_size_bytes);
    }

    log.info("SwapTexture end", .{});

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

// fn glfwTextCallback(window: *vk.GLFWwindow, codepoint: u32) callconv(.C) void {}

var color_list: FixedBuffer(RGBA(f32), 30) = undefined;

fn customActions(action_id: u16) void {
    if (action_id == 1) {
        // update_image = true;
    }
}

var track_metadatas: FixedBuffer(audio.TrackMetadata, 20) = undefined;
var audio_files: FixedBuffer([:0]const u8, 20) = undefined;
var update_media_icon_action_id_opt: ?u32 = null;

fn toUpper(string: *[]u8) void {
    for (string.*) |*char| {
        char.* = std.ascii.toUpper(char.*);
    }
}

fn handleAudioPlay(allocator: Allocator, action_payload: ActionPayloadAudioPlay) !void {

    // TODO: If track is already set, update
    const audio_track_name = audio_files.items[action_payload.id];

    // TODO: Don't hardcode, or put in a definition
    var current_path_buffer: [128]u8 = undefined;
    const current_path = try current_directory.realpath(".", current_path_buffer[0..]);

    const paths: [2][]const u8 = .{ current_path, audio_track_name };
    const full_path = std.fs.path.joinZ(allocator, paths[0..]) catch null;
    defer allocator.free(full_path.?);

    const kind = loaded_media_items.items[action_payload.id].kind;

    log.info("Playing track {s}", .{loaded_media_items.items[action_payload.id].name.toSlice()});
    log.info("Playing path {s}", .{full_path});

    switch (kind) {
        .mp3 => {
            audio.mp3.playFile(allocator, full_path.?) catch |err| {
                log.err("Failed to play music: {s}", .{err});
            };
        },
        .flac => {
            audio.flac.playFile(allocator, full_path.?) catch |err| {
                log.err("Failed to play music: {s}", .{err});
            };
        },
        else => {
            unreachable;
        },
    }

    // TODO:
    std.time.sleep(std.time.ns_per_s * 1);
    // assert(audio.output.getState() == .playing);
}

fn handleUpdateVertices(allocator: Allocator, action_payload: *ActionPayloadVerticesUpdate) !void {
    const vertices = @ptrCast([*]GenericVertex, @alignCast(16, &mapped_device_memory[vertices_range_index_begin]));

    // TODO: All added for consistency but some variables not used
    // TODO: Updated members of update_vertices to reflect values are for quads, not vertices
    const loaded_vertex_begin = @intCast(u32, action_payload.loaded_vertex_begin) * 4;
    // const alternate_vertex_begin = action_payload.alternate_vertex_begin * 4;

    // const loaded_quad_begin = @intCast(u32, action_payload.loaded_vertex_begin);
    const alternate_quad_begin = action_payload.alternate_vertex_begin;

    const loaded_vertex_count = action_payload.loaded_vertex_count * 4;
    const alternate_vertex_count = action_payload.alternate_vertex_count * 4;

    // const loaded_vertex_quad_count = action_payload.loaded_vertex_count;
    // const alternate_vertex_quad_count = action_payload.alternate_vertex_count;

    var alternate_base_vertex: [*]GenericVertex = &inactive_vertices_attachments.items[alternate_quad_begin];

    const largest_range_vertex_count = if (alternate_vertex_count > loaded_vertex_count) alternate_vertex_count else loaded_vertex_count;

    var temp_swap_buffer = try allocator.alloc(GenericVertex, largest_range_vertex_count);
    defer allocator.free(temp_swap_buffer);

    {
        var i: u32 = 0;
        while (i < (largest_range_vertex_count)) : (i += 1) {
            temp_swap_buffer[i] = vertices[loaded_vertex_begin + i];
            vertices[loaded_vertex_begin + i] = if (i < alternate_vertex_count)
                alternate_base_vertex[i]
            else
                GenericVertex.nullFace()[0];
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

    const triggered_events_buffer_size = 10;
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
                    log.err("Failed to play audio : {s}", .{err});
                };

                //
                // If the media icon is set to `resume` (I.e Triangle) we need to update it to `pause`
                //

                if (is_media_icon_resume) {
                    if (update_media_icon_action_id_opt) |update_media_icon_action_id| {
                        handleUpdateVertices(allocator, &system_actions.items[update_media_icon_action_id].payload.update_vertices) catch |err| {
                            log.err("Failed to update vertices for animation: {s}", .{err});
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
                        log.info("Failed to resume audio track: {s}", .{err});
                    };
                    std.time.sleep(10000000);
                    assert(audio.output.getState() == .playing);
                    system_actions.items[media_button_toggle_audio_action_id].action_type = .audio_pause;
                    // text_buffer_dirty = true;
                }
            },
            .directory_select => {
                log.info("Handling directory_select event", .{});

                const directory_id = action.payload.directory_select.directory_id;

                const new_directory_name = if (directory_id == parent_directory_id) ".." else loaded_media_items.items[directory_id].name.toSlice();

                current_directory = current_directory.openDir(new_directory_name, .{ .iterate = true }) catch |err| {
                    log.err("Failed to change directory: {s}", .{err});
                    break;
                };

                text_buffer_dirty = true;
                loaded_media_items.clear();

                // TODO: Duplicated code

                const max_media_items: u32 = 10;

                var iterator = current_directory.iterate();
                var entry = iterator.next() catch |err| {
                    log.err("Failed to iterate directory: {s}", .{err});
                    break;
                };

                track_metadatas.clear();
                audio_files.clear();

                // TODO
                const allocator = std.heap.c_allocator;

                while (entry != null and loaded_media_items.count < max_media_items) {
                    const item_name = entry.?.name;

                    var media_item: MediaItem = undefined;
                    media_item.kind = blk: {
                        if (entry.?.kind == .Directory) {
                            break :blk .directory;
                        }

                        if (item_name.len > 4) {
                            var extension_label: []u8 = allocator.dupe(u8, item_name[item_name.len - 4 ..]) catch |err| {
                                log.err("Failed to copy file extension: {s}", .{err});
                                return;
                            };
                            defer allocator.free(extension_label);

                            toUpper(&extension_label);

                            if (std.mem.eql(u8, extension_label, "FLAC")) {
                                break :blk .flac;
                            } else if (std.mem.eql(u8, extension_label, ".MP3")) {
                                break :blk .mp3;
                            } else {
                                break :blk .unknown;
                            }
                        } else {
                            break :blk .unknown;
                        }
                    };

                    if (media_item.kind != .unknown) {
                        media_item.name.fromSlice(item_name) catch |err| {
                            log.err("Failed load media item paths: {s}", .{err});
                            return;
                        };
                        _ = loaded_media_items.append(media_item);

                        if (media_item.kind != .directory) {
                            const new_name = allocator.dupeZ(u8, entry.?.name) catch |err| {
                                log.err("Failed load media items: {s}", .{err});
                                return;
                            };

                            var current_path_buffer: [128]u8 = undefined;
                            const current_path = current_directory.realpath(".", current_path_buffer[0..]) catch |err| {
                                log.err("Failed load media items: {s}", .{err});
                                return;
                            };

                            const paths: [2][]const u8 = .{ current_path, item_name };
                            const full_path = std.fs.path.joinZ(allocator, paths[0..]) catch null;
                            defer allocator.free(full_path.?);

                            log.info("Full path: {s}", .{full_path});

                            // TODO:
                            const track_metadata = blk: {
                                if (media_item.kind == .mp3) {
                                    break :blk audio.mp3.extractTrackMetadata(full_path.?) catch |err| {
                                        log.err("Failed load media item metadata: {s}", .{err});
                                        return;
                                    };
                                } else if (media_item.kind == .flac) {
                                    break :blk audio.flac.extractTrackMetadata(full_path.?) catch |err| {
                                        log.err("Failed load media item metadata: {s}", .{err});
                                        return;
                                    };
                                } else {
                                    unreachable;
                                }
                                unreachable;
                            };

                            log.info("Track title: {s}", .{track_metadata.title});

                            _ = track_metadatas.append(track_metadata);
                            _ = audio_files.append(new_name);
                        }

                        log.info("Media item: '{s}' {s}", .{ media_item.name.toSlice(), media_item.kind });
                    }
                    entry = iterator.next() catch |err| {
                        log.err("Failed to increment directory entry: {s}", .{err});
                        return;
                    };
                }
            },
            .update_vertices => {
                // TODO:
                var gpa = std.heap.GeneralPurposeAllocator(.{}){};
                defer _ = gpa.deinit();
                const allocator = gpa.allocator();

                handleUpdateVertices(allocator, &system_actions.items[event_id].payload.update_vertices) catch |err| {
                    log.err("Failed to update vertices for animation: {s}", .{err});
                    return;
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
    directory_select,
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

const ActionPayloadDirectorySelect = packed struct {
    directory_id: u16,
    dummy: u8,
};

const ActionPayload = packed union {
    color_set: ActionPayloadColorSet,
    audio_play: ActionPayloadAudioPlay,
    audio_pause: ActionPayloadAudioPause,
    audio_resume: ActionPayloadAudioResume,
    update_vertices: ActionPayloadVerticesUpdate,
    redirect: ActionPayloadRedirect,
    directory_select: ActionPayloadDirectorySelect,
    custom: ActionPayloadCustom,
};

// NOTE: Making this struct packed appears to trigger a compile bug that prevents
//       arrays from being indexed properly. Probably the alignment is incorrect
const Action = struct {
    action_type: ActionType,
    payload: ActionPayload,
};

var system_actions: FixedBuffer(Action, 50) = .{};

fn mouseButtonCallback(window: *glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
    _ = action;
    _ = mods;

    if (glfw.getCursorPos(window)) |cursor_position| {
        handleMouseEvents(cursor_position.x, cursor_position.y, button == glfw.MouseButton.left and action == glfw.Action.press, button == glfw.MouseButton.left and action == glfw.Action.press);
    } else |err| {
        log.warn("Failed to get cursor position : {s}", .{err});
    }
}

fn mousePositionCallback(window: *glfw.Window, x_position: f64, y_position: f64) void {
    _ = window;
    handleMouseEvents(x_position, y_position, false, false);
}

fn glfwKeyCallback(window: *glfw.Window, key: i32, scancode: i32, action: i32, mods: i32) callconv(.C) void {
    _ = window;
    _ = key;
    _ = scancode;
    _ = action;
    _ = mods;
}

fn calculateQuadIndex(base: [*]align(16) GenericVertex, widget_faces: []QuadFace(GenericVertex)) u16 {
    return @intCast(u16, (@ptrToInt(&widget_faces[0]) - @ptrToInt(base)) / @sizeOf(QuadFace(GenericVertex)));
}

// TODO: move
var media_button_toggle_audio_action_id: u32 = undefined;
const parent_directory_id = std.math.maxInt(u16);

fn renderCurrentTrackDetails(face_writer: *QuadFaceWriter(GenericVertex), scale_factor: geometry.ScaleFactor2D(f32)) !void {
    assert(audio.output.getState() != .stopped);
    if (audio.output.getState() != .stopped) {
        const track_name = audio.current_track.title[0..audio.current_track.title_length];
        const artist_name = audio.current_track.artist[0..audio.current_track.artist_length];

        {
            const placement = geometry.Coordinates2D(ScreenNormalizedBaseType){ .x = -0.95, .y = 0.9 };
            _ = try gui.generateText(GenericVertex, face_writer, track_name, placement, scale_factor, glyph_set, theme.track_title_text, null, texture_layer_dimensions);
        }

        {
            const placement = geometry.Coordinates2D(ScreenNormalizedBaseType){ .x = -0.95, .y = 0.85 };
            _ = try gui.generateText(GenericVertex, face_writer, artist_name, placement, scale_factor, glyph_set, theme.track_artist_text, null, texture_layer_dimensions);
        }
    }
}

fn update(allocator: Allocator, app: *GraphicsContext) !void {
    _ = app;
    _ = allocator;

    var vertices = @ptrCast([*]GenericVertex, @alignCast(16, &mapped_device_memory[vertices_range_index_begin]));

    log.info("Update called", .{});

    assert(screen_dimensions.width > 0);
    assert(screen_dimensions.height > 0);

    vertex_buffer_count = 0;

    const scale_factor = geometry.ScaleFactor2D(f32){
        .horizontal = (2.0 / @intToFloat(f32, screen_dimensions.width)),
        .vertical = (2.0 / @intToFloat(f32, screen_dimensions.height)),
    };

    // Reset event system
    color_list.clear();
    system_actions.clear();
    event_system.clearEvents();
    vertex_range_attachments.clear();
    inactive_vertices_attachments.clear();

    var face_writer = quad_face_writer_pool.create(0, vertices_range_size / @sizeOf(GenericVertex));

    const top_header = blk: {
        const extent = geometry.Extent2D(ScreenNormalizedBaseType){
            .x = -1.0,
            .y = -1.0 + 0.2,
            .width = 2.0,
            .height = 0.2,
        };

        var faces = try face_writer.allocate(1);
        faces[0] = graphics.generateQuadColored(GenericVertex, extent, theme.header_background);

        break :blk faces;
    };
    _ = top_header;

    const top_header_label = blk: {
        const label = "MUSIC PLAYER -- DEMO APPLICATION";
        const rendered_label_dimensions = try gui.calculateRenderedTextDimensions(label, glyph_set, scale_factor, 0.0, 4 * scale_factor.horizontal);
        const label_origin = geometry.Coordinates2D(ScreenNormalizedBaseType){
            .x = 0.0 - (rendered_label_dimensions.width / 2.0),
            .y = -0.9 + (rendered_label_dimensions.height / 2.0),
        };

        break :blk try gui.generateText(GenericVertex, &face_writer, label, label_origin, scale_factor, glyph_set, theme.header_text, null, texture_layer_dimensions);
    };
    _ = top_header_label;

    const footer = blk: {
        const extent = geometry.Extent2D(ScreenNormalizedBaseType){
            .x = -1.0,
            .y = 1.0,
            .width = 2.0,
            .height = 0.3,
        };
        var faces = try face_writer.allocate(1);
        faces[0] = graphics.generateQuadColored(GenericVertex, extent, theme.footer_background);

        break :blk faces;
    };
    _ = footer;

    const progress_bar_width: f32 = 1.0;
    const progress_bar_margin: f32 = (2.0 - progress_bar_width) / 2.0;
    const progress_bar_extent = geometry.Extent2D(ScreenNormalizedBaseType){
        .x = -1.0 + progress_bar_margin,
        .y = 0.8,
        .width = progress_bar_width,
        .height = 8 * scale_factor.vertical,
    };

    const audio_progress_bar_background = blk: {
        var faces = try face_writer.allocate(1);
        faces[0] = graphics.generateQuadColored(GenericVertex, progress_bar_extent, theme.progress_bar_background);
        break :blk faces;
    };
    _ = audio_progress_bar_background;

    {
        const track_length_seconds: u32 = audio.output.trackLengthSeconds() catch 1;
        const track_played_seconds: u32 = audio.output.secondsPlayed() catch 0;
        const progress_percentage: f32 = @intToFloat(f32, track_played_seconds) / @intToFloat(f32, track_length_seconds);

        const width: f32 = 1.0;
        const margin: f32 = (2.0 - width) / 2.0;

        const inner_margin_horizontal: f32 = 0.005;
        const inner_margin_vertical: f32 = 1 * scale_factor.vertical;

        const extent = geometry.Extent2D(ScreenNormalizedBaseType){
            .x = -1.0 + margin + inner_margin_horizontal,
            .y = 0.8 - inner_margin_vertical,
            .width = width - (inner_margin_horizontal * 2.0),
            .height = 6 * scale_factor.vertical,
        };

        const faces = try generateAudioProgressBar(&face_writer, progress_percentage, theme.progress_bar_foreground, extent);
        audio_progress_bar_faces_quad_index = calculateQuadIndex(vertices, faces);

        log.info("Progress bar index: {d}", .{audio_progress_bar_faces_quad_index});
    }

    if (audio.output.getState() != .stopped) {
        try renderCurrentTrackDetails(&face_writer, scale_factor);
    }

    const return_button = blk: {
        const button_placement = geometry.Coordinates2D(ScreenNormalizedBaseType){ .x = -0.95, .y = -0.92 };
        const button_dimensions = geometry.Dimensions2D(ScreenPixelBaseType){ .width = 50, .height = 25 };

        const button_extent = geometry.Extent2D(ScreenNormalizedBaseType){
            .x = button_placement.x,
            .y = button_placement.y,
            .width = geometry.pixelToNativeDeviceCoordinateRight(button_dimensions.width, scale_factor.horizontal),
            .height = geometry.pixelToNativeDeviceCoordinateRight(button_dimensions.height, scale_factor.vertical),
        };

        const faces = try gui.button.generate(
            GenericVertex,
            &face_writer,
            glyph_set,
            "<",
            button_extent,
            scale_factor,
            theme.return_button_background,
            theme.return_button_foreground,
            .center,
            texture_layer_dimensions,
        );

        const button_color_index = color_list.append(theme.return_button_background);
        const on_hover_color_index = color_list.append(theme.return_button_background_hovered);

        // Index of the quad face (I.e Mulples of 4 faces) within the face allocator
        const widget_index = calculateQuadIndex(vertices, faces);

        // NOTE: system_actions needs to correspond to given on_hover_event_ids here
        {
            const on_hover_event_ids = event_system.registerMouseHoverReflexiveEnterAction(button_extent);

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

            assert(on_hover_event_ids[0] == system_actions.append(on_hover_enter_action));
            assert(on_hover_event_ids[1] == system_actions.append(on_hover_exit_action));
        }

        {

            //
            // When back button is clicked, change to parent directory
            //

            const on_click_event = event_system.registerMouseLeftPressAction(button_extent);

            const directory_select_parent_action_payload = ActionPayloadDirectorySelect{ .directory_id = parent_directory_id, .dummy = 0 };
            const directory_select_parent_action = Action{ .action_type = .directory_select, .payload = .{ .directory_select = directory_select_parent_action_payload } };

            assert(on_click_event == system_actions.append(directory_select_parent_action));
        }

        break :blk faces;
    };
    _ = return_button;

    //
    // Dimensions for media pause / play button
    //
    // We need to add it here because we'll be adding an action to all of the
    // track list items that will update the media button from paused to resume
    //

    log.info("Rending media button", .{});

    const media_button_placement = geometry.Coordinates2D(ScreenNormalizedBaseType){ .x = 0.0, .y = 0.9 };
    const media_button_paused_dimensions = geometry.Dimensions2D(ScreenPixelBaseType){ .width = 20, .height = 20 };
    const media_button_resumed_dimensions = geometry.Dimensions2D(ScreenPixelBaseType){ .width = 4, .height = 15 };

    const media_button_paused_width = geometry.pixelToNativeDeviceCoordinateRight(media_button_paused_dimensions.width, scale_factor.horizontal);

    const media_button_paused_extent = geometry.Extent2D(ScreenNormalizedBaseType){
        .x = media_button_placement.x - (media_button_paused_width / 2.0),
        .y = media_button_placement.y,
        .width = media_button_paused_width,
        .height = geometry.pixelToNativeDeviceCoordinateRight(media_button_paused_dimensions.height, scale_factor.vertical),
    };

    const media_button_resumed_inner_gap: f32 = geometry.pixelToNativeDeviceCoordinateRight(6, scale_factor.horizontal);
    const media_button_resumed_width: f32 = geometry.pixelToNativeDeviceCoordinateRight(media_button_resumed_dimensions.width, scale_factor.horizontal);
    const media_button_resumed_x_offset: f32 = media_button_resumed_width + (media_button_resumed_inner_gap / 2.0);

    const media_button_resumed_left_extent = geometry.Extent2D(ScreenNormalizedBaseType){
        .x = media_button_placement.x - media_button_resumed_x_offset,
        .y = media_button_placement.y,
        .width = media_button_resumed_width,
        .height = geometry.pixelToNativeDeviceCoordinateRight(media_button_resumed_dimensions.height, scale_factor.vertical),
    };

    const media_button_resumed_right_extent = geometry.Extent2D(ScreenNormalizedBaseType){
        .x = media_button_placement.x + media_button_resumed_width + media_button_resumed_inner_gap - media_button_resumed_x_offset,
        .y = media_button_placement.y,
        .width = media_button_resumed_width,
        .height = geometry.pixelToNativeDeviceCoordinateRight(media_button_resumed_dimensions.height, scale_factor.vertical),
    };

    var playing_icon_faces: [2]QuadFace(GenericVertex) = undefined;
    playing_icon_faces[0] = graphics.generateQuadColored(GenericVertex, media_button_resumed_left_extent, theme.media_button);
    playing_icon_faces[1] = graphics.generateQuadColored(GenericVertex, media_button_resumed_right_extent, theme.media_button);

    _ = inactive_vertices_attachments.append(playing_icon_faces[0]);
    _ = inactive_vertices_attachments.append(playing_icon_faces[1]);

    //
    // Generate our Media (pause / resume) button
    //

    // TODO: Generate a different version if audio is playing
    // assert(audio.output.getState() != .playing);

    // NOTE: Even though we only need one face to generate a triangle,
    //       we need to reserve a second for the resumed icon
    var media_button_paused_faces = try face_writer.allocate(2);

    media_button_paused_faces[0] = graphics.generateTriangleColored(GenericVertex, media_button_paused_extent, theme.media_button);
    media_button_paused_faces[1] = GenericVertex.nullFace();

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

    const is_tracks: bool = blk: {
        for (loaded_media_items.toSlice()) |media_item| {
            if (media_item.kind == .mp3 or media_item.kind == .flac) break :blk true;
        }
        break :blk false;
    };

    // TODO:
    var addicional_vertices: usize = 0;

    if (!is_tracks) {
        for (loaded_media_items.items[0..loaded_media_items.count]) |*media_item, media_i| {
            const directory_name = media_item.name.toSlice();

            const row_colomn: u32 = 2;
            const x: u32 = @intCast(u32, media_i) % row_colomn;
            const y: u32 = @intCast(u32, media_i) / row_colomn;

            const margin: f32 = 0.3;
            const horizontal_spacing: f32 = 0.2;
            const vertical_spacing: f32 = 0.04;
            const item_width: f32 = 0.6;
            const item_height: f32 = 0.15;
            const x_increment: f32 = item_width + horizontal_spacing;

            const media_item_placement = geometry.Coordinates2D(ScreenNormalizedBaseType){ .x = (-1.0 + margin) + @intToFloat(f32, x) * x_increment, .y = -0.6 + (@intToFloat(f32, y) * (item_height + vertical_spacing)) };
            // const media_item_dimensions = geometry.Dimensions2D(ScreenPixelBaseType){ .width = 300, .height = 30 };

            const media_item_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = media_item_placement.x,
                .y = media_item_placement.y,
                .width = item_width, // geometry.pixelToNativeDeviceCoordinateRight(media_item_dimensions.width, scale_factor.horizontal),
                .height = item_height, // geometry.pixelToNativeDeviceCoordinateRight(media_item_dimensions.height, scale_factor.vertical),
            };

            const media_item_faces = try gui.button.generate(GenericVertex, &face_writer, glyph_set, directory_name, media_item_extent, scale_factor, theme.folder_background, theme.folder_text, .center, texture_layer_dimensions);

            const media_item_on_left_click_event_id = event_system.registerMouseLeftPressAction(media_item_extent);

            const directory_select_action_payload = ActionPayloadDirectorySelect{
                .directory_id = @intCast(u16, media_i),
                .dummy = 0,
            };

            const directory_select_action = Action{ .action_type = .directory_select, .payload = .{ .directory_select = directory_select_action_payload } };
            assert(media_item_on_left_click_event_id == system_actions.append(directory_select_action));

            addicional_vertices += media_item_faces.len;
        }
    }

    if (is_tracks) {
        for (track_metadatas.items[0..track_metadatas.count]) |track_metadata, track_index| {
            const track_name = track_metadata.title[0..track_metadata.title_length];

            log.info("Track name: '{s}'", .{track_name});
            assert(track_name.len > 0);

            const track_item_placement = geometry.Coordinates2D(ScreenNormalizedBaseType){ .x = -0.8, .y = -0.6 + (@intToFloat(f32, track_index) * 0.075) };
            const track_item_dimensions = geometry.Dimensions2D(ScreenPixelBaseType){ .width = 600, .height = 30 };

            const track_item_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = track_item_placement.x,
                .y = track_item_placement.y,
                .width = geometry.pixelToNativeDeviceCoordinateRight(track_item_dimensions.width, scale_factor.horizontal),
                .height = geometry.pixelToNativeDeviceCoordinateRight(track_item_dimensions.height, scale_factor.vertical),
            };

            const track_item_faces = try gui.button.generate(
                GenericVertex,
                &face_writer,
                glyph_set,
                track_name,
                track_item_extent,
                scale_factor,
                theme.track_background,
                theme.track_text,
                .left,
                texture_layer_dimensions,
            );

            const track_item_on_left_click_event_id = event_system.registerMouseLeftPressAction(track_item_extent);

            const track_item_audio_play_action_payload = ActionPayloadAudioPlay{
                .id = @intCast(u16, track_index),
                .dummy = 0,
            };

            const track_item_audio_play_action = Action{ .action_type = .audio_play, .payload = .{ .audio_play = track_item_audio_play_action_payload } };
            assert(track_item_on_left_click_event_id == system_actions.append(track_item_audio_play_action));

            const track_item_background_color_index = color_list.append(theme.track_background);
            const track_item_on_hover_color_index = color_list.append(theme.track_background_hovered);

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
    }

    //
    // Duration of audio played
    //

    {
        //
        // Track Duration Label
        //

        if (audio.output.getState() != .stopped) {
            try generateDurationLabels(&face_writer, scale_factor);
        }
    }

    vertex_buffer_count = face_writer.used;

    text_buffer_dirty = false;
    is_render_requested = true;

    log.info("Update completed", .{});
}

fn generateDurationLabels(face_writer: *QuadFaceWriter(GenericVertex), scale_factor: geometry.ScaleFactor2D(f32)) !void {
    const quads_required_count: u32 = 10;
    assert(face_writer.remaining() >= quads_required_count);

    //
    // Track Duration Label
    //

    assert(audio.output.getState() != .stopped);

    const vertices = @ptrCast([*]GenericVertex, @alignCast(16, &mapped_device_memory[vertices_range_index_begin]));

    const progress_bar_width: f32 = 1.0;
    const progress_bar_margin: f32 = (2.0 - progress_bar_width) / 2.0;
    const progress_bar_extent = geometry.Extent2D(ScreenNormalizedBaseType){
        .x = -1.0 + progress_bar_margin,
        .y = 0.8,
        .width = progress_bar_width,
        .height = 8 * scale_factor.vertical,
    };

    const track_duration_total = secondsToAudioDurationTime(@intCast(u16, try audio.output.trackLengthSeconds()));
    const track_duration_played = secondsToAudioDurationTime(@intCast(u16, try audio.output.secondsPlayed()));
    const text_color = RGBA(f32){ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 };
    const margin_from_progress_bar: f32 = 0.02;
    var buffer: [5]u8 = undefined;

    //
    // Duration Total
    //

    const duration_total_label = try std.fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2}", .{ track_duration_total.minutes, track_duration_total.seconds });
    const duration_total_label_placement = geometry.Coordinates2D(ScreenNormalizedBaseType){ .x = progress_bar_extent.x + progress_bar_extent.width + margin_from_progress_bar, .y = progress_bar_extent.y + (progress_bar_extent.height / 2.0) };

    const duration_total_label_faces = try gui.generateText(GenericVertex, face_writer, duration_total_label, duration_total_label_placement, scale_factor, glyph_set, text_color, null, texture_layer_dimensions);

    assert(duration_total_label_faces.len == 5);

    //
    // Duration Played
    //

    const duration_played_label = try std.fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2}", .{ track_duration_played.minutes, track_duration_played.seconds });
    const duration_played_label_placement = geometry.Coordinates2D(ScreenNormalizedBaseType){ .x = progress_bar_extent.x - margin_from_progress_bar - 0.08, .y = progress_bar_extent.y + (progress_bar_extent.height / 2.0) };
    const duration_played_label_faces = try gui.generateText(GenericVertex, face_writer, duration_played_label, duration_played_label_placement, scale_factor, glyph_set, text_color, null, texture_layer_dimensions);

    assert(duration_played_label_faces.len == 5);

    // TODO
    audio_progress_label_faces_quad_index = calculateQuadIndex(vertices, duration_total_label_faces);
}

var audio_progress_label_faces_quad_index: u32 = undefined;
var audio_progress_bar_faces_quad_index: u32 = undefined;

fn generateAudioProgressBar(
    face_writer: *QuadFaceWriter(GenericVertex),
    progress: f32,
    color: RGBA(f32),
    extent: geometry.Extent2D(ScreenNormalizedBaseType),
) ![]QuadFace(GenericVertex) {
    assert(progress >= 0.0 and progress <= 1.0);
    const progress_extent = geometry.Extent2D(ScreenNormalizedBaseType){
        .x = extent.x,
        .y = extent.y,
        .width = extent.width * progress,
        .height = extent.height,
    };

    var faces = try face_writer.allocate(1);
    faces[0] = graphics.generateQuadColored(GenericVertex, progress_extent, color);
    return faces;
}

const AudioDuractionTime = packed struct {
    seconds: u16,
    minutes: u16,
};

fn secondsToAudioDurationTime(seconds: u16) AudioDuractionTime {
    var current_seconds: u16 = seconds;
    const current_minutes = blk: {
        var minutes: u16 = 0;
        while (current_seconds >= 60) {
            minutes += 1;
            current_seconds -= 60;
        }
        break :blk minutes;
    };

    return .{
        .seconds = current_seconds,
        .minutes = current_minutes,
    };
}

// fn updateAudioDurationLabel(current_point_seconds: u32, track_duration_seconds: u32, vertices: []GenericVertex) !void {
// // Wrap our fixed-size buffer in allocator interface to be generic

// var face_writer = quad_face_writer_pool.create(vertices,

// var fixed_buffer_allocator = FixedBufferAllocator.init(@ptrCast([*]u8, vertices), vertices_range_size);
// var face_allocator = fixed_buffer_allocator.allocator();

// assert(current_point_seconds <= (1 << 16));

// const track_duration_total = secondsToAudioDurationTime(@intCast(u16, track_duration_seconds));
// const track_duration_played = secondsToAudioDurationTime(@intCast(u16, current_point_seconds));

// const scale_factor = geometry.ScaleFactor2D(f32){
// .horizontal = (2.0 / @intToFloat(f32, screen_dimensions.width)),
// .vertical = (2.0 / @intToFloat(f32, screen_dimensions.height)),
// };

// var buffer: [13]u8 = undefined;
// const audio_progress_label_text = try std.fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2} / {d:0>2}:{d:0>2}", .{ track_duration_played.minutes, track_duration_played.seconds, track_duration_total.minutes, track_duration_total.seconds });
// const audio_progress_label_placement = geometry.Coordinates2D(ScreenNormalizedBaseType){ .x = -0.9, .y = 0.9 };
// const audio_progress_text_color = RGBA(f32){ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 };

// _ = try gui.generateText(GenericVertex, face_allocator, audio_progress_label_text, audio_progress_label_placement, scale_factor, glyph_set, audio_progress_text_color, null, texture_layer_dimensions);

// is_render_requested = true;
// }

fn handleAudioStopped() void {
    log.info("Audio stopped event triggered", .{});
    const progress_percentage: f32 = 0.0;
    var face_writer = quad_face_writer_pool.create(audio_progress_bar_faces_quad_index, 1);
    const scale_factor = geometry.ScaleFactor2D(f32){
        .horizontal = (2.0 / @intToFloat(f32, screen_dimensions.width)),
        .vertical = (2.0 / @intToFloat(f32, screen_dimensions.height)),
    };

    const width: f32 = 1.0;
    const margin: f32 = (2.0 - width) / 2.0;

    const inner_margin_horizontal: f32 = 0.005;
    const inner_margin_vertical: f32 = 1 * scale_factor.vertical;

    const extent = geometry.Extent2D(ScreenNormalizedBaseType){
        .x = -1.0 + margin + inner_margin_horizontal,
        .y = 0.8 - inner_margin_vertical,
        .width = (width - (inner_margin_horizontal * 2.0)),
        .height = 6 * scale_factor.vertical,
    };

    const color = RGBA(f32).fromInt(u8, 150, 50, 80, 255);
    _ = generateAudioProgressBar(&face_writer, progress_percentage, color, extent) catch |err| {
        log.warn("Failed to draw audio progress bar : {s}", .{err});
        return;
    };

    vertex_buffer_count -= (5 * 2);
    is_render_requested = true;
}

fn handleAudioStarted() void {
    const max_title_length: u32 = 16;
    const max_artist_length: u32 = 16;
    const charactor_count: u32 = 10;
    const maximum_quad_count = charactor_count + max_artist_length + max_title_length;

    var face_writer = quad_face_writer_pool.create(vertex_buffer_count, maximum_quad_count);
    const scale_factor = geometry.ScaleFactor2D(f32){
        .horizontal = (2.0 / @intToFloat(f32, screen_dimensions.width)),
        .vertical = (2.0 / @intToFloat(f32, screen_dimensions.height)),
    };

    generateDurationLabels(&face_writer, scale_factor) catch |err| {
        log.warn("Failed to draw audio duration label : {s}", .{err});
        return;
    };

    log.info("Rendering track details", .{});
    renderCurrentTrackDetails(&face_writer, scale_factor) catch |err| {
        log.warn("Failed to render current track details : {s}", .{err});
        return;
    };

    vertex_buffer_count += face_writer.used;
    is_render_requested = true;
}

fn appLoop(allocator: Allocator, app: *GraphicsContext) !void {
    const target_fps = 30;
    const target_ms_per_frame: u32 = 1000 / target_fps;

    log.info("Target MS / frame: {d}", .{target_ms_per_frame});

    // Timestamp in milliseconds since last update of audio duration label
    var audio_duration_last_update_ts: i64 = std.time.milliTimestamp();
    const audio_duraction_update_interval_ms: u64 = 1000;

    glfw.setCursorPosCallback(app.window, mousePositionCallback);
    glfw.setMouseButtonCallback(app.window, mouseButtonCallback);

    while (!glfw.shouldClose(app.window)) {
        glfw.pollEvents();

        const screen = glfw.getFramebufferSize(app.window);

        if (screen_dimensions.width <= 0 or screen_dimensions.height <= 0) {
            return error.InvalidScreenDimensions;
        }

        if (screen.width != screen_dimensions.width or
            screen.height != screen_dimensions.height)
        {
            framebuffer_resized = true;
            screen_dimensions.width = screen.width;
            screen_dimensions.height = screen.height;
        }

        if (!audio.output_event_buffer.empty()) {
            for (audio.output_event_buffer.collect()) |event| {
                switch (event) {
                    .stopped => handleAudioStopped(),
                    .started => handleAudioStarted(),
                    .duration_calculated => {
                        // log.info("Track duration seconds: {d}", .{audio.mp3.track_length});
                    },
                    else => {
                        log.warn("Unhandled default audio event", .{});
                    },
                }
            }
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
            try app.device_dispatch.deviceWaitIdle(app.logical_device);

            // log.info("Resetting command pool", .{});
            try app.device_dispatch.resetCommandPool(app.logical_device, app.command_pool, .{});

            // log.info("Recording render pass", .{});
            try recordRenderPass(app.*, vertex_buffer_count * 6);

            // log.info("Rendering frame", .{});
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

        // Replace this with audio events to save loading each frame
        const is_playing = audio.output.getState() == .playing;

        // Each second update the audio duration
        if (is_playing and frame_start_ms >= (audio_duration_last_update_ts + audio_duraction_update_interval_ms)) {
            const track_length_seconds: u32 = audio.output.trackLengthSeconds() catch 0;
            const track_played_seconds: u32 = audio.output.secondsPlayed() catch 0;

            // {
            // const vertices_begin_index: usize = audio_progress_label_faces_quad_index * 4;
            // try updateAudioDurationLabel(track_played_seconds, track_length_seconds, vertices[vertices_begin_index .. vertices_begin_index + (11 * 4)]);
            // audio_duration_last_update_ts = frame_start_ms;
            // }

            //
            // Update progress bar too
            //

            {
                const scale_factor = geometry.ScaleFactor2D(f32){
                    .horizontal = (2.0 / @intToFloat(f32, screen_dimensions.width)),
                    .vertical = (2.0 / @intToFloat(f32, screen_dimensions.height)),
                };

                const progress_percentage: f32 = @intToFloat(f32, track_played_seconds) / @intToFloat(f32, track_length_seconds);
                if (progress_percentage > 0.0 and progress_percentage <= 1.0) {
                    const width: f32 = 1.0;
                    const margin: f32 = (2.0 - width) / 2.0;

                    const inner_margin_horizontal = 4 * scale_factor.horizontal;
                    const inner_margin_vertical = 1 * scale_factor.vertical;

                    const extent = geometry.Extent2D(ScreenNormalizedBaseType){
                        .x = -1.0 + margin + inner_margin_horizontal,
                        .y = 0.8 - inner_margin_vertical,
                        .width = (width - (inner_margin_horizontal * 2.0)),
                        .height = 6 * scale_factor.vertical,
                    };

                    const color = RGBA(f32).fromInt(u8, 150, 50, 80, 255);
                    var face_writer = quad_face_writer_pool.create(audio_progress_bar_faces_quad_index, 1);

                    _ = try generateAudioProgressBar(&face_writer, progress_percentage, color, extent);
                }

                {
                    var face_writer = quad_face_writer_pool.create(audio_progress_label_faces_quad_index, 10);
                    try generateDurationLabels(&face_writer, scale_factor);
                }
                is_render_requested = true;
            }
        }

        assert(target_ms_per_frame > frame_duration_ms);
        const remaining_ms: u32 = target_ms_per_frame - @intCast(u32, frame_duration_ms);
        std.time.sleep(remaining_ms * 1000 * 1000);
    }

    try app.device_dispatch.deviceWaitIdle(app.logical_device);
}

fn recordRenderPass(
    app: GraphicsContext,
    indices_count: u32,
) !void {
    assert(app.command_buffers.len > 0);
    assert(app.swapchain_images.len == app.command_buffers.len);
    assert(app.screen_dimensions.width == app.swapchain_extent.width);
    assert(app.screen_dimensions.height == app.swapchain_extent.height);

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
        log.info("Swapchain out of date; Recreating..", .{});
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
