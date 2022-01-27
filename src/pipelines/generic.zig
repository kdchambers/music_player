// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const vk = @import("vulkan");
const zvk = @import("../vulkan_wrapper.zig");
const RGBA = @import("graphics").RGBA(f32);
const log = std.log;

fn norm(unnorm: u16, comptime max: u16) f32 {
    return @intToFloat(f32, unnorm) / @intToFloat(f32, max);
}

const vertex_input_binding_descriptions = vk.VertexInputBindingDescription{
    .binding = 0,
    .stride = 32,
    .inputRate = .VERTEX,
};

var descriptor_pool: vk.DescriptorPool = undefined;

const vertex_input_attribute_descriptions = [_]vk.VertexInputAttributeDescription{
    // inPosition
    vk.VertexInputAttributeDescription{
        .binding = 0,
        .location = 0,
        .format = .R32G32_SFLOAT,
        .offset = 0,
    },
    // inTexCoord
    vk.VertexInputAttributeDescription{
        .binding = 0,
        .location = 1,
        .format = .R32G32_SFLOAT,
        .offset = 8,
    },
    // inColor
    vk.VertexInputAttributeDescription{
        .binding = 0,
        .location = 2,
        .format = .R32G32B32A32_SFLOAT,
        .offset = 16,
    },
};

const vertex_shader_path = "../../shaders/generic.vert.spv";
const fragment_shader_path = "../../shaders/generic.frag.spv";

var vertex_shader_module: vk.ShaderModule = undefined;
var fragment_shader_module: vk.ShaderModule = undefined;
var pipeline_layout: vk.PipelineLayout = undefined;

const texture_layers: u8 = 2;

const texture_layout_bindings = [_]vk.DescriptorSetLayoutBinding{vk.DescriptorSetLayoutBinding{
    .binding = 0,
    .descriptorCount = 1,
    .descriptorType = .COMBINED_IMAGE_SAMPLER,
    .pImmutableSamplers = null,
    .stageFlags = .{ .fragment = true },
}};

var descriptor_set_layouts: []vk.DescriptorSetLayout = undefined;
var descriptor_sets: []vk.DescriptorSet = undefined;

const shader_vertex_spv align(4) = @embedFile(vertex_shader_path);
const shader_fragment_spv align(4) = @embedFile(fragment_shader_path);

var is_first_creation: bool = true;

var previous_swapchain_images_count: u32 = 0;

pub const GenericPipeline = struct {
    render_pass: vk.RenderPass,
    graphics_pipeline: vk.Pipeline,
    framebuffers: []vk.Framebuffer,
    texture_sampler: vk.Sampler,

    pub fn init(self: *GenericPipeline, logical_device: vk.Device) !void {
        vertex_shader_module = try zvk.createShaderModule(logical_device, @alignCast(32, shader_vertex_spv));
        fragment_shader_module = try zvk.createShaderModule(logical_device, @alignCast(32, shader_fragment_spv));
    }

    pub fn deinit(self: *GenericPipeline, allocator: *Allocator) void {
        allocator.free(descriptor_set_layouts);
        allocator.free(descriptor_sets);
        allocator.free(self.framebuffers);
    }

    const clear_color = RGBA.fromInt(u8, 47, 48, 48, 255);

    pub fn recordRenderPass(
        self: *GenericPipeline,
        command_buffers: []vk.CommandBuffer,
        vertex_buffer: vk.Buffer,
        index_buffer: vk.Buffer,
        extent: vk.Extent2D,
        indices_count: u32,
    ) !void {
        const clear_colors = [1]vk.ClearValue{
            vk.ClearValue{
                .color = vk.ClearColorValue{
                    .float32 = @bitCast([4]f32, clear_color),
                },
            },
        };

        for (command_buffers) |command_buffer, i| {
            try zvk.beginCommandBuffer(command_buffer, .{
                .sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
                .pInheritanceInfo = null,
                .flags = .{},
                .pNext = null,
            });

            vk.vkCmdBeginRenderPass(command_buffer, &vk.RenderPassBeginInfo{
                .sType = vk.StructureType.RENDER_PASS_BEGIN_INFO,
                .renderPass = self.render_pass,
                .framebuffer = self.framebuffers[i],
                .renderArea = vk.Rect2D{
                    .offset = vk.Offset2D{
                        .x = 0,
                        .y = 0,
                    },
                    .extent = extent,
                },
                .clearValueCount = 1,
                .pClearValues = &clear_colors,
                .pNext = null,
            }, .INLINE);

            vk.vkCmdBindPipeline(command_buffer, .GRAPHICS, self.graphics_pipeline);
            vk.vkCmdBindVertexBuffers(command_buffer, 0, 1, &[1]vk.Buffer{vertex_buffer}, &[1]vk.DeviceSize{0});
            vk.vkCmdBindIndexBuffer(command_buffer, index_buffer, 0, .UINT16);
            vk.vkCmdBindDescriptorSets(command_buffer, .GRAPHICS, pipeline_layout, 0, 1, &[1]vk.DescriptorSet{descriptor_sets[i]}, 0, undefined);

            vk.vkCmdDrawIndexed(command_buffer, indices_count, 1, 0, 0, 0);

            vk.vkCmdEndRenderPass(command_buffer);
            try zvk.endCommandBuffer(command_buffer);
        }
    }

    pub fn create(self: *GenericPipeline, allocator: *Allocator, logical_device: vk.Device, format: vk.Format, extent: vk.Extent2D, swapchain_image_views: []vk.ImageView, texture_image_view: vk.ImageView) !void {
        self.render_pass = try zvk.createRenderPass(logical_device, vk.RenderPassCreateInfo{
            .sType = vk.StructureType.RENDER_PASS_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &[1]vk.AttachmentDescription{
                .{
                    .format = format,
                    .samples = .{ .t1 = true },
                    .loadOp = .CLEAR,
                    .storeOp = .STORE,
                    .stencilLoadOp = .DONT_CARE,
                    .stencilStoreOp = .DONT_CARE,
                    .initialLayout = .UNDEFINED,
                    .finalLayout = .PRESENT_SRC_KHR,
                    .flags = .{},
                },
            },
            .subpassCount = 1,
            .pSubpasses = &[1]vk.SubpassDescription{
                .{
                    .pipelineBindPoint = .GRAPHICS,
                    .colorAttachmentCount = 1,
                    .pColorAttachments = &[1]vk.AttachmentReference{
                        vk.AttachmentReference{
                            .attachment = 0,
                            .layout = .COLOR_ATTACHMENT_OPTIMAL,
                        },
                    },
                    .inputAttachmentCount = 0,
                    .pInputAttachments = undefined,
                    .pResolveAttachments = null,
                    .pDepthStencilAttachment = null,
                    .preserveAttachmentCount = 0,
                    .pPreserveAttachments = undefined,
                    .flags = .{},
                },
            },
            .dependencyCount = 1,
            .pDependencies = &[1]vk.SubpassDependency{
                .{
                    .srcSubpass = vk.SUBPASS_EXTERNAL,
                    .dstSubpass = 0,
                    .srcStageMask = .{ .colorAttachmentOutput = true },
                    .dstStageMask = .{ .colorAttachmentOutput = true },
                    .srcAccessMask = .{},
                    .dstAccessMask = .{ .colorAttachmentRead = true, .colorAttachmentWrite = true },
                    .dependencyFlags = .{},
                },
            },
            .flags = .{},
            .pNext = null,
        });

        const vertex_shader_stage_info = vk.PipelineShaderStageCreateInfo{
            .sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = .{ .vertex = true },
            .module = vertex_shader_module,
            .pName = "main",
            .pSpecializationInfo = null,
            .flags = .{},
            .pNext = null,
        };

        const fragment_shader_stage_info = vk.PipelineShaderStageCreateInfo{
            .sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = .{ .fragment = true },
            .module = fragment_shader_module,
            .pName = "main",
            .pSpecializationInfo = null,
            .flags = .{},
            .pNext = null,
        };

        const shader_stages = [2]vk.PipelineShaderStageCreateInfo{
            vertex_shader_stage_info,
            fragment_shader_stage_info,
        };

        const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
            .sType = vk.StructureType.PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = @intCast(u32, 1),
            .vertexAttributeDescriptionCount = @intCast(u32, 3),
            .pVertexBindingDescriptions = @ptrCast([*]const vk.VertexInputBindingDescription, &vertex_input_binding_descriptions),
            .pVertexAttributeDescriptions = @ptrCast([*]const vk.VertexInputAttributeDescription, &vertex_input_attribute_descriptions),
            .flags = .{},
            .pNext = null,
        };

        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .sType = vk.StructureType.PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = .TRIANGLE_LIST,
            .primitiveRestartEnable = vk.FALSE,
            .flags = .{},
            .pNext = null,
        };

        const viewports = [1]vk.Viewport{
            vk.Viewport{
                .x = 0.0,
                .y = 0.0,
                .width = @intToFloat(f32, extent.width),
                .height = @intToFloat(f32, extent.height),
                .minDepth = 0.0,
                .maxDepth = 1.0,
            },
        };

        const scissors = [1]vk.Rect2D{
            vk.Rect2D{
                .offset = vk.Offset2D{
                    .x = 0,
                    .y = 0,
                },
                .extent = extent,
            },
        };

        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .sType = vk.StructureType.PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .pViewports = &viewports,
            .scissorCount = 1,
            .pScissors = &scissors,
            .flags = .{},
            .pNext = null,
        };

        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .sType = vk.StructureType.PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .depthClampEnable = vk.FALSE,
            .rasterizerDiscardEnable = vk.FALSE,
            .polygonMode = .FILL,
            .lineWidth = 1.0,
            .cullMode = .{ .back = true },
            .frontFace = .CLOCKWISE,
            .depthBiasEnable = vk.FALSE,
            .depthBiasConstantFactor = 0.0,
            .depthBiasClamp = 0.0,
            .depthBiasSlopeFactor = 0.0,
            .flags = .{},
            .pNext = null,
        };

        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .sType = vk.StructureType.PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .sampleShadingEnable = vk.FALSE,
            .rasterizationSamples = .{ .t1 = true },
            .minSampleShading = 0.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = vk.FALSE,
            .alphaToOneEnable = vk.FALSE,
            .flags = .{},
            .pNext = null,
        };

        const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
            .colorWriteMask = .{ .r = true, .g = true, .b = true, .a = true },
            .blendEnable = vk.TRUE,
            .alphaBlendOp = .ADD,
            .colorBlendOp = .ADD,
            .dstAlphaBlendFactor = .ZERO,
            .srcAlphaBlendFactor = .ONE,
            .dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
            .srcColorBlendFactor = .SRC_ALPHA,
        };

        const blend_constants = [1]f32{0.0} ** 4;

        const color_blending = vk.PipelineColorBlendStateCreateInfo{
            .sType = vk.StructureType.PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = vk.FALSE,
            .logicOp = .COPY,
            .attachmentCount = 1,
            .pAttachments = @ptrCast([*]const vk.PipelineColorBlendAttachmentState, &color_blend_attachment),
            .blendConstants = blend_constants,
            .flags = .{},
            .pNext = null,
        };

        const layout_info = vk.DescriptorSetLayoutCreateInfo{
            .sType = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = 1,
            .pBindings = @ptrCast([*]const vk.DescriptorSetLayoutBinding, &texture_layout_bindings[0]),
            .pNext = null,
            .flags = .{},
        };

        std.debug.assert(swapchain_image_views.len != 0);

        // Only modify descriptor_set_layouts allocated memory if swapchain image count has been modified
        // (Or this is the first time being invoked and need to be allocated)
        if (previous_swapchain_images_count != swapchain_image_views.len) {
            if (previous_swapchain_images_count == 0) {
                descriptor_set_layouts = try allocator.alloc(vk.DescriptorSetLayout, swapchain_image_views.len);
            } else {
                descriptor_set_layouts = try allocator.realloc(descriptor_set_layouts, swapchain_image_views.len);
            }
        }

        if (vk.vkCreateDescriptorSetLayout(logical_device, &layout_info, null, &descriptor_set_layouts[0]) != .SUCCESS) {
            return error.CreateDescriptorSetLayoutFailed;
        }

        //
        // We create one descriptorSetLayout with vkCreateDescriptorSetLayout and copy it for each swapchain image
        //

        var x: u32 = 1;
        while (x < swapchain_image_views.len) : (x += 1) {
            descriptor_set_layouts[x] = descriptor_set_layouts[0];
        }

        var pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .sType = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1,
            .pSetLayouts = descriptor_set_layouts.ptr,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = undefined,
            .flags = .{},
            .pNext = null,
        };

        if (vk.vkCreatePipelineLayout(logical_device, &pipeline_layout_info, null, &pipeline_layout) != .SUCCESS) {
            return error.CreatePipelineLayoutFailed;
        }

        const sampler_create_info = vk.SamplerCreateInfo{
            .sType = vk.StructureType.SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = .{},
            .magFilter = .NEAREST,
            .minFilter = .NEAREST,
            .addressModeU = .REPEAT,
            .addressModeV = .REPEAT,
            .addressModeW = .REPEAT,
            .mipLodBias = 0.0,
            .anisotropyEnable = vk.FALSE,
            .maxAnisotropy = 16.0,
            .borderColor = .INT_OPAQUE_BLACK,
            .minLod = 0.0,
            .maxLod = 0.0,
            .unnormalizedCoordinates = vk.FALSE,
            .compareEnable = vk.FALSE,
            .compareOp = .ALWAYS,
            .mipmapMode = .LINEAR,
        };

        if (vk.vkCreateSampler(logical_device, &sampler_create_info, null, &self.texture_sampler) != .SUCCESS) {
            return error.CreateSamplerFailed;
        }

        // Check do we need to destroy a previous descriptor pool
        if (previous_swapchain_images_count != 0) {
            vk.vkDestroyDescriptorPool(logical_device, descriptor_pool, null);
        }

        const descriptor_pool_sizes = [_]vk.DescriptorPoolSize{ .{
            .inType = .SAMPLER,
            .descriptorCount = @intCast(u32, swapchain_image_views.len),
        }, .{
            .inType = .SAMPLED_IMAGE,
            .descriptorCount = @intCast(u32, swapchain_image_views.len) * 2,
        } };

        const create_pool_info = vk.DescriptorPoolCreateInfo{
            .sType = vk.StructureType.DESCRIPTOR_POOL_CREATE_INFO,
            .poolSizeCount = descriptor_pool_sizes.len,
            .pPoolSizes = &descriptor_pool_sizes,
            .maxSets = @intCast(u32, swapchain_image_views.len),
            .pNext = null,
            .flags = .{},
        };

        if (vk.vkCreateDescriptorPool(logical_device, &create_pool_info, null, &descriptor_pool) != .SUCCESS) {
            return error.CreateDescriptorPoolFailed;
        }

        const allocate_descriptor_info = vk.DescriptorSetAllocateInfo{
            .sType = vk.StructureType.DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = descriptor_pool,
            .descriptorSetCount = @intCast(u32, swapchain_image_views.len),
            .pSetLayouts = descriptor_set_layouts.ptr,
        };

        if (previous_swapchain_images_count != swapchain_image_views.len) {
            if (previous_swapchain_images_count == 0) {
                descriptor_sets = try allocator.alloc(vk.DescriptorSet, swapchain_image_views.len);
            } else {
                descriptor_sets = try allocator.realloc(descriptor_sets, swapchain_image_views.len);
            }
        }

        if (vk.vkAllocateDescriptorSets(logical_device, &allocate_descriptor_info, descriptor_sets.ptr) != .SUCCESS) {
            return error.AllocateDescriptorSetsFailed;
        }

        var i: u32 = 0;
        while (i < swapchain_image_views.len) : (i += 1) {
            const descriptor_image_info = [_]vk.DescriptorImageInfo{
                .{
                    .imageLayout = .SHADER_READ_ONLY_OPTIMAL,
                    .imageView = texture_image_view,
                    .sampler = self.texture_sampler,
                },
            };

            const write_descriptor_set = [_]vk.WriteDescriptorSet{.{
                .sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = descriptor_sets[i],
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorType = .COMBINED_IMAGE_SAMPLER,
                .descriptorCount = 1,
                .pImageInfo = &descriptor_image_info,
                .pBufferInfo = undefined,
                .pTexelBufferView = undefined,
            }};

            vk.vkUpdateDescriptorSets(logical_device, 1, &write_descriptor_set, 0, undefined);
        }

        var pipeline_create_infos = [1]vk.GraphicsPipelineCreateInfo{
            vk.GraphicsPipelineCreateInfo{
                .sType = vk.StructureType.GRAPHICS_PIPELINE_CREATE_INFO,
                .stageCount = 2,
                .pStages = &shader_stages,
                .pVertexInputState = &vertex_input_info,
                .pInputAssemblyState = &input_assembly,
                .pTessellationState = null,
                .pViewportState = &viewport_state,
                .pRasterizationState = &rasterizer,
                .pMultisampleState = &multisampling,
                .pDepthStencilState = null,
                .pColorBlendState = &color_blending,
                .pDynamicState = null,
                .layout = pipeline_layout,
                .renderPass = self.render_pass,
                .subpass = 0,
                .basePipelineHandle = null,
                .basePipelineIndex = 0,
                .flags = .{},
                .pNext = null,
            },
        };

        if (vk.vkCreateGraphicsPipelines(logical_device, null, 1, &pipeline_create_infos, null, @ptrCast([*]vk.Pipeline, &self.graphics_pipeline)) != .SUCCESS) {
            return error.CreateGraphicsPipelinesFailed;
        }

        // TODO: Does this need to be allocated?
        const framebuffer_create_infos = try allocator.alloc(vk.FramebufferCreateInfo, swapchain_image_views.len);
        defer allocator.free(framebuffer_create_infos);

        for (framebuffer_create_infos) |*framebuffer_create_info, j| {
            const attachments = [_]vk.ImageView{
                swapchain_image_views[j],
            };

            framebuffer_create_info.* = vk.FramebufferCreateInfo{
                .sType = vk.StructureType.FRAMEBUFFER_CREATE_INFO,
                .renderPass = self.render_pass,
                .attachmentCount = 1,
                .pAttachments = @ptrCast([*]vk.ImageView, &swapchain_image_views[j]),
                .width = extent.width,
                .height = extent.height,
                .layers = 1,
                .pNext = null,
                .flags = .{},
            };
        }

        if (previous_swapchain_images_count != 0) {
            allocator.free(self.framebuffers);
        }

        self.framebuffers = try zvk.createFrameBuffersAlloc(allocator, logical_device, framebuffer_create_infos);

        previous_swapchain_images_count = @intCast(u32, swapchain_image_views.len);
    }
};
