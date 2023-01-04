// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");
const ScaleFactor2D = geometry.ScaleFactor2D;
const graphics = @import("graphics.zig");
const QuadFace = graphics.QuadFace;
const text = @import("text.zig");
const util = @import("utility.zig");
const RGBA = graphics.RGBA;
const Color = RGBA(f32);
const memory = @import("memory.zig");
const GenericVertex = graphics.GenericVertex;
const constants = @import("constants.zig");
const event_system = @import("event_system.zig");
const FixedAtomicEventQueue = @import("message_queue.zig").FixedAtomicEventQueue;

const TextureNormalizedBaseType = constants.TextureNormalizedBaseType;
const TexturePixelBaseType = constants.TexturePixelBaseType;
const ScreenNormalizedBaseType = constants.ScreenNormalizedBaseType;
const ScreenPixelBaseType = constants.ScreenPixelBaseType;

const ScreenScaleFactor = graphics.ScreenScaleFactor(.{ .NDCRightType = ScreenNormalizedBaseType, .PixelType = ScreenPixelBaseType });

pub const ActionType = enum(u8) {
    none,
    color_set,
    update_vertices,
};

// Limit of 64 is based on alternate_vertex_count being u6
pub var inactive_vertices_attachments: memory.FixedBuffer(QuadFace(GenericVertex), 64) = .{};
pub var color_list: memory.FixedBuffer(Color, 30) = .{};
pub var color_list_mutable: memory.FixedBuffer(Color, 10) = .{};
pub var system_actions: memory.FixedBuffer(Action, 100) = .{};
pub var vertex_range_attachments: memory.FixedBuffer(VertexRange, 40) = .{};

pub var vertex_buffer: []GenericVertex = undefined;
pub var subsystem_index: event_system.SubsystemIndex = undefined;

pub const InternalEvent = enum(u8) {
    vertices_modified,
};

pub var message_queue: FixedAtomicEventQueue(InternalEvent, 32) = undefined;

pub fn reset() void {
    // TODO: Create a reset / clear function
    _ = message_queue.collect();
    inactive_vertices_attachments.clear();
    color_list.clear();
    system_actions.clear();
    vertex_range_attachments.clear();
}

pub fn init(
    vertices: []GenericVertex,
) void {
    vertex_buffer = vertices;
}

pub fn doColorSet(payload: PayloadColorSet) void {
    const color = color_list.items[payload.color_index];
    const vertices_begin = vertex_range_attachments.items[payload.vertex_range_begin].vertex_begin * 4;
    const vertices_end = vertices_begin + (vertex_range_attachments.items[payload.vertex_range_begin].vertex_count * 4);

    std.debug.assert(vertices_end > vertices_begin);

    for (vertex_buffer[vertices_begin..vertices_end]) |*vertex| {
        vertex.color = color;
    }

    // TODO: Only add event if it is unique
    message_queue.add(.vertices_modified) catch |err| {
        std.log.err("Failed to add .vertices_modified event to gui internal message queue: '{}'", .{err});
    };
}

fn doUpdateVertices(payload: *PayloadVerticesUpdate) void {
    const loaded_vertex_begin = @intCast(u32, payload.loaded_vertex_begin) * 4;
    const alternate_quad_begin = payload.alternate_vertex_begin;
    const loaded_vertex_count = payload.loaded_vertex_count * 4;
    const alternate_vertex_count = payload.alternate_vertex_count * 4;

    var alternate_base_vertex: [*]GenericVertex = &inactive_vertices_attachments.items[alternate_quad_begin];

    const largest_range_vertex_count = if (alternate_vertex_count > loaded_vertex_count) alternate_vertex_count else loaded_vertex_count;
    std.debug.assert(largest_range_vertex_count <= 256);
    var temp_swap_buffer: [256]GenericVertex = undefined;

    {
        var i: u32 = 0;
        while (i < (largest_range_vertex_count)) : (i += 1) {
            temp_swap_buffer[i] = vertex_buffer[loaded_vertex_begin + i];
            vertex_buffer[loaded_vertex_begin + i] = if (i < alternate_vertex_count)
                alternate_base_vertex[i]
            else
                GenericVertex.nullFace()[0];
        }
    }

    // Now we need to copy back our swapped out loaded vertices into the alternate vertices buffer
    for (temp_swap_buffer) |vertex, i| {
        alternate_base_vertex[i] = vertex;
    }

    const temporary_vertex_count = payload.loaded_vertex_count;
    payload.loaded_vertex_count = payload.alternate_vertex_count;
    payload.alternate_vertex_count = temporary_vertex_count;
}

pub fn doAction(action_index: event_system.ActionIndex) void {
    var action = &system_actions.items[@intCast(usize, action_index)];
    switch (action.action_type) {
        .color_set => doColorSet(action.payload.color_set),
        .update_vertices => doUpdateVertices(&action.payload.update_vertices),
        else => {},
    }
}

pub const Payload = packed union {
    color_set: PayloadColorSet,
    update_vertices: PayloadVerticesUpdate,
};

// NOTE: Making this struct packed appears to trigger a compile bug that prevents
//       arrays from being indexed properly. Probably the alignment is incorrect
pub const Action = struct {
    action_type: ActionType,
    payload: Payload,
};

pub const VertexRange = packed struct {
    vertex_begin: u24,
    vertex_count: u8,
};

pub const PayloadColorSet = packed struct {
    vertex_range_begin: u8,
    vertex_range_span: u8,
    color_index: u8,
};

pub const PayloadSetAction = packed struct {
    action_type: ActionType,
    index: u16,
};

pub const PayloadVerticesUpdate = packed struct {
    loaded_vertex_begin: u10,
    alternate_vertex_begin: u6,
    loaded_vertex_count: u4,
    alternate_vertex_count: u4,
};

/// Used to allocate QuadFaceWriters that share backing memory
pub fn QuadFaceWriterPool(comptime VertexType: type) type {
    return struct {
        const Self = @This();

        memory_ptr: [*]QuadFace(VertexType),
        memory_quad_range: u32,

        pub fn initialize(start: [*]align(@alignOf(VertexType)) u8, memory_quad_range: u32) Self {
            return .{
                .memory_ptr = @ptrCast([*]QuadFace(VertexType), start),
                .memory_quad_range = memory_quad_range,
            };
        }

        pub fn create(self: *Self, quad_index: u16, quad_size: u16) QuadFaceWriter(VertexType) {
            std.debug.assert((quad_index + quad_size) <= self.memory_quad_range);
            return QuadFaceWriter(VertexType).initialize(self.memory_ptr, quad_index, quad_size);
        }
    };
}

pub fn QuadFaceWriter(comptime VertexType: type) type {
    return struct {
        const Self = @This();

        memory_ptr: [*]QuadFace(VertexType),

        quad_index: u16,
        pool_index: u16,
        capacity: u16,
        used: u16 = 0,

        pub fn initialize(base: [*]QuadFace(VertexType), quad_index: u16, quad_size: u16) Self {
            return .{
                .memory_ptr = @ptrCast([*]QuadFace(VertexType), &base[quad_index]),
                .pool_index = 0,
                .quad_index = quad_index,
                .capacity = quad_size,
                .used = 0,
            };
        }

        pub fn child(self: *Self, start_index: u16, count: u16) QuadFaceWriter(VertexType) {
            return .{
                .memory_ptr = @ptrCast([*]QuadFace(VertexType), self.memory_ptr[start_index]),
                .used = 0,
                .capacity = count,
                .quad_index = 0,
                .pool_index = 0,
            };
        }

        pub fn indexFromBase(self: Self) u32 {
            return self.quad_index + self.used;
        }

        pub fn remaining(self: *Self) u16 {
            std.debug.assert(self.capacity >= self.used);
            return @intCast(u16, self.capacity - self.used);
        }

        pub fn reset(self: *Self) void {
            self.used = 0;
        }

        pub fn create(self: *Self) !*QuadFace(VertexType) {
            if (self.used == self.capacity) return error.OutOfMemory;
            defer self.used += 1;
            return &self.memory_ptr[self.used];
        }

        pub fn allocate(self: *Self, amount: u16) ![]QuadFace(VertexType) {
            if ((self.used + amount) > self.capacity) return error.OutOfMemory;
            defer self.used += amount;
            return self.memory_ptr[self.used .. self.used + amount];
        }
    };
}

const DrawReceipt = struct {
    extent: geometry.Extent2D(ScreenNormalizedBaseType),
    face_index: u16,
    face_count: u16,
};

pub const Alignment = enum { left, right, center };

pub const grid = struct {
    pub fn generate(
        comptime VertexType: type,
        face_writer: *QuadFaceWriter(VertexType),
        extent: geometry.Extent2D(ScreenNormalizedBaseType),
        color: RGBA(f32),
        layout: geometry.Dimensions2D(u32),
        line_width: f32,
    ) ![]QuadFace(VertexType) {
        const x_increment_scaled: f32 = extent.width / @intToFloat(f32, layout.width);
        const y_increment_scaled: f32 = extent.height / @intToFloat(f32, layout.height);

        std.debug.assert(layout.height > 0);
        std.debug.assert(layout.width > 0);

        var faces = try face_writer.allocate(layout.height + layout.width - 2);

        var y: u32 = 0;
        while (y < (layout.height - 1)) : (y += 1) {
            const line_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .y = extent.y - (y_increment_scaled * @intToFloat(f32, y + 1)),
                .x = extent.x,
                .width = extent.width,
                .height = line_width,
            };

            faces[y] = graphics.generateQuadColored(VertexType, line_extent, color, .bottom_left);
        }

        var x: u32 = 0;
        while (x < (layout.width - 1)) : (x += 1) {
            const line_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .y = extent.y,
                .x = extent.x + (x_increment_scaled * @intToFloat(f32, x + 1)),
                .width = line_width,
                .height = extent.height,
            };

            faces[layout.height - 1 + x] = graphics.generateQuadColored(VertexType, line_extent, color, .bottom_left);
        }

        return faces;
    }
};

pub const button = struct {
    pub const ActionConfig = struct {
        pub const null_value = [1]event_system.SubsystemActionIndex{event_system.SubsystemActionIndex.null_value};

        on_hover_color_opt: ?u8 = null,
        on_hover_action_list: [4]event_system.SubsystemActionIndex = null_value ** 4,
        on_click_left_action_list: [4]event_system.SubsystemActionIndex = null_value ** 4,
        on_click_right_action_list: [4]event_system.SubsystemActionIndex = null_value ** 4,
    };

    pub const face_count: u32 = 1;

    pub fn generate(
        comptime VertexType: type,
        face_writer: *QuadFaceWriter(VertexType),
        glyph_set: text.GlyphSet,
        label: []const u8,
        extent_value: geometry.Extent2D(ScreenNormalizedBaseType),
        scale_factor: ScreenScaleFactor,
        color: RGBA(f32),
        label_color: RGBA(f32),
        text_alignment: Alignment,
        action_config: ActionConfig,
        anchor_point: graphics.AnchorPoint,
    ) ![]QuadFace(VertexType) {

        // TODO: Implement right align
        std.debug.assert(text_alignment != .right);

        const extent = switch (anchor_point) {
            .bottom_left => extent_value,
            .top_left => geometry.Extent2D(ScreenNormalizedBaseType){
                .x = extent_value.x,
                .y = extent_value.y + extent_value.height,
                .width = extent_value.width,
                .height = extent_value.height,
            },
            else => unreachable,
        };

        const background_face_index = face_writer.used;
        var background_face: *QuadFace(VertexType) = try face_writer.create();

        // Background has to be generated first so that it doesn't cover the label text
        background_face.* = graphics.generateQuadColored(VertexType, extent, color, .bottom_left);

        const line_height = 18.0 * scale_factor.vertical;
        const space_width = 4.0 * scale_factor.horizontal;
        const label_dimensions = try calculateRenderedTextDimensions(label, glyph_set, scale_factor, line_height, space_width);

        const horizontal_margin = blk: {
            switch (text_alignment) {
                .left => break :blk 0.01,
                .center => break :blk (extent.width - label_dimensions.width) / 2,
                .right => unreachable,
            }
            unreachable;
        };

        const vertical_margin = (extent.height - label_dimensions.height) / 2;

        const label_origin = geometry.Coordinates2D(ScreenNormalizedBaseType){
            .x = extent.x + horizontal_margin,
            .y = extent.y - vertical_margin,
        };

        // TODO: Check if there is > 1 action before creating
        var action_writer = event_system.mouse_event_writer.addExtent(extent);

        {
            var count: u32 = 0;
            while (count <= 4 and !action_config.on_click_left_action_list[count].isNull()) {
                count += 1;
            }
            if (count > 0) {
                action_writer.onClickLeft(action_config.on_click_left_action_list[0..count]);
            }
        }

        if (action_config.on_hover_color_opt) |on_hover_color| {
            const vertex_range_entry_index = vertex_range_attachments.append(.{
                .vertex_begin = background_face_index,
                .vertex_count = 1,
            });

            const normal_color_index: u8 = blk: {
                for (color_list.toSlice()) |current_color, i| {
                    if (current_color.isEqual(color)) {
                        break :blk @intCast(u8, i);
                    }
                }
                break :blk @intCast(u8, color_list.append(color));
            };

            const hover_enter_action = Action{
                .action_type = .color_set,
                .payload = .{
                    .color_set = .{
                        .color_index = on_hover_color,
                        .vertex_range_begin = @intCast(u8, vertex_range_entry_index),
                        .vertex_range_span = 1,
                    },
                },
            };

            const hover_exit_action = Action{
                .action_type = .color_set,
                .payload = .{
                    .color_set = .{
                        .color_index = normal_color_index,
                        .vertex_range_begin = @intCast(u8, vertex_range_entry_index),
                        .vertex_range_span = 1,
                    },
                },
            };

            const hover_enter_action_index = system_actions.append(hover_enter_action);
            const hover_exit_action_index = system_actions.append(hover_exit_action);

            std.debug.assert(hover_exit_action_index == (hover_enter_action_index + 1));

            const hover_enter_global_action = [1]event_system.SubsystemActionIndex{.{
                .subsystem = subsystem_index,
                .index = @intCast(event_system.ActionIndex, hover_enter_action_index),
            }};

            const hover_exit_global_action = [1]event_system.SubsystemActionIndex{.{
                .subsystem = subsystem_index,
                .index = @intCast(event_system.ActionIndex, hover_exit_action_index),
            }};

            action_writer.onHoverReflexive(hover_enter_global_action[0..], hover_exit_global_action[0..]);
        }

        const label_faces = try generateText(VertexType, face_writer, label, label_origin, scale_factor, glyph_set, label_color, null);

        // Memory for background_face and label_face should be contigious
        std.debug.assert(@ptrToInt(background_face) == @ptrToInt(label_faces.ptr) - @sizeOf(QuadFace(VertexType)));

        // allocator is guaranteed to allocate linearly, therefore we can create/return
        // a new slice that extends from our background_face to the end of our label_faces
        return @ptrCast([*]QuadFace(VertexType), background_face)[0 .. label_faces.len + 1];
    }

    /// Returns the maximum number of quads that would be required to
    /// render a butten with given label
    pub fn requirements(label: []const u8) u32 {
        // TODO: Rely on text.requirements. Will need to check for whitespace
        return label.len + 1;
    }
};

pub const image = struct {
    pub fn generate(
        comptime VertexType: type,
        face_writer: *QuadFaceWriter(VertexType),
        image_id: f32,
        extent: geometry.Extent2D(ScreenNormalizedBaseType),
    ) ![]QuadFace(VertexType) {
        std.debug.assert(image_id == 1 or image_id == 2);
        var image_faces = try face_writer.allocate(1);

        image_faces[0][0] =
            .{
            // Top Left
            .x = extent.x,
            .y = extent.y - extent.height,
            .tx = 0.0 + image_id,
            .ty = 0.0,
            .color = .{
                .r = 1.0,
                .g = 1.0,
                .b = 1.0,
                .a = 1.0,
            },
        };

        image_faces[0][1] =
            .{
            // Top Right
            .x = extent.x + extent.width,
            .y = extent.y - extent.height,
            .tx = 0.0 + 1.0 + image_id,
            .ty = 0.0,
            .color = .{
                .r = 1.0,
                .g = 1.0,
                .b = 1.0,
                .a = 1.0,
            },
        };

        image_faces[0][2] =
            .{
            // Bottom Right
            .x = extent.x + extent.width,
            .y = extent.y,
            .tx = 0.0 + 1.0 + image_id,
            .ty = 0.0 + 1.0,
            .color = .{
                .r = 1.0,
                .g = 1.0,
                .b = 1.0,
                .a = 1.0,
            },
        };

        image_faces[0][3] =
            .{
            // Bottom Left
            .x = extent.x,
            .y = extent.y,
            .tx = 0.0 + image_id,
            .ty = 0.0 + 1.0,
            .color = .{
                .r = 1.0,
                .g = 1.0,
                .b = 1.0,
                .a = 1.0,
            },
        };

        return image_faces[0..];
    }
};

pub fn calculateRenderedTextDimensions(
    text_buffer: []const u8,
    glyph_set: text.GlyphSet,
    scale_factor: ScreenScaleFactor,
    line_height: f32,
    space_width: f32,
) !geometry.Dimensions2D(ScreenNormalizedBaseType) {
    var dimensions = geometry.Dimensions2D(ScreenNormalizedBaseType){
        .width = 0,
        .height = 0,
    };

    // While looping though text, keep track of the highest glyph
    // If no newline is encountered, this will be used for the line height
    var highest_height: f32 = 0;

    for (text_buffer) |char| {
        if (char == '\n') {
            dimensions.height += line_height;
            highest_height = 0;
            continue;
        }

        if (char != ' ') {
            const glyph_index = blk: {
                for (glyph_set.character_list) |c, x| {
                    if (c == char) {
                        break :blk x;
                    }
                }
                std.log.err("Charactor not in set '{c}':{d} '{s}'", .{ char, char, text_buffer });
                continue;
                // return error.CharacterNotInSet;
            };

            dimensions.width += (@intToFloat(f32, glyph_set.glyph_information[glyph_index].advance)) * scale_factor.horizontal;
            const glyph_height = @intToFloat(f32, glyph_set.glyph_information[glyph_index].dimensions.height) * scale_factor.vertical;

            if (glyph_height > highest_height) {
                highest_height = glyph_height;
            }
        } else {
            dimensions.width += space_width;
        }
    }
    dimensions.height = highest_height;

    return dimensions;
}

// TODO: Audit
pub fn generateText(
    comptime VertexType: type,
    face_writer: *QuadFaceWriter(VertexType),
    text_buffer: []const u8,
    origin: geometry.Coordinates2D(ScreenNormalizedBaseType),
    scale_factor: ScreenScaleFactor,
    glyph_set: text.GlyphSet,
    color: RGBA(f32),
    line_height_opt: ?f32,
) ![]QuadFace(VertexType) {
    const glyph_length: u16 = blk: {
        var i: u16 = 0;
        for (text_buffer) |c| {
            if (c != ' ' and c != '\n') {
                i += 1;
            }
        }
        break :blk i;
    };

    var vertices = try face_writer.allocate(glyph_length);

    var cursor = geometry.Coordinates2D(u16){ .x = 0, .y = 0 };
    var skipped_count: u32 = 0;
    const line_height: f32 = if (line_height_opt != null) line_height_opt.? else 0;

    var x_increment: f32 = 0.0;

    for (text_buffer) |char, i| {
        if (char == '\n') {
            // If line_height_opt was not set, we're not expecting new lines in text_buffer
            // Otherwise x_cursor would get reset to 0 and start overwritting previous text
            if (line_height_opt == null) {
                return error.InvalidLineHeightNotSet;
            }

            cursor.y += 1;
            cursor.x = 0;
            skipped_count += 1;
            continue;
        }

        if (char == 0 or char == 255 or char == 254) {
            skipped_count += 1;
            continue;
        }

        if (char != ' ') {
            const glyph_index = blk: {
                var default_char_index: usize = 0;
                for (glyph_set.character_list) |c, x| {
                    if (c == char) {
                        break :blk x;
                    }
                    if (c == '?') {
                        default_char_index = x;
                    }
                }
                std.log.err("Charactor not in set '{c}' (ascii {d}) in '{s}'", .{ char, char, text_buffer });
                break :blk default_char_index;
                // return error.InvalidCharacter;
            };

            const texture_extent = try glyph_set.imageRegionForGlyph(glyph_index, constants.texture_layer_dimensions);
            const glyph_dimensions = glyph_set.glyph_information[glyph_index].dimensions;

            // Positive offset (Glyphs with a descent get shift down)
            const y_offset = @intToFloat(f32, glyph_set.glyph_information[glyph_index].vertical_offset) * scale_factor.vertical;

            const placement = geometry.Coordinates2D(ScreenNormalizedBaseType){
                .x = origin.x + x_increment,
                .y = origin.y + y_offset + (line_height * @intToFloat(f32, cursor.y)),
            };

            const char_extent = geometry.Dimensions2D(ScreenNormalizedBaseType){
                .width = @intToFloat(f32, glyph_dimensions.width) * scale_factor.horizontal,
                .height = @intToFloat(f32, glyph_dimensions.height) * scale_factor.vertical,
            };

            vertices[i - skipped_count] = graphics.generateTexturedQuad(VertexType, placement, char_extent, texture_extent, .bottom_left);
            for (vertices[i - skipped_count]) |*vertex| {
                vertex.color = color;
            }
            x_increment += @intToFloat(f32, glyph_set.glyph_information[glyph_index].advance) * scale_factor.horizontal;
        } else {
            // TODO: Space hardcoded to 4 pixels
            x_increment += 4 * scale_factor.horizontal;
            skipped_count += 1;
        }

        cursor.x += 1;
    }

    return vertices;
}

pub fn generateLineMargin(
    comptime VertexType: type,
    face_writer: *QuadFaceWriter(VertexType),
    glyph_set: text.GlyphSet,
    coordinates: geometry.Coordinates2D(ScreenNormalizedBaseType),
    scale_factor: ScreenScaleFactor,
    line_start: u16,
    line_count: u16,
    line_height: f32,
) ![]QuadFace(VertexType) {

    // Loop through lines to calculate how many vertices will be required
    const quads_required_count = blk: {
        var count: u32 = 0;
        var i: u32 = 1;
        while (i <= line_count) : (i += 1) {
            count += util.digitCount(line_start + i);
        }
        break :blk count;
    };

    std.log.assert(line_count > 0);
    const chars_wide_count: u32 = util.digitCount(line_start + line_count);

    var vertex_faces = try face_writer.allocate(quads_required_count);

    var i: u32 = 1;
    var faces_written_count: u32 = 0;
    while (i <= line_count) : (i += 1) {
        const line_number = line_start + i;
        const digit_count = util.digitCount(line_number);

        std.log.assert(digit_count < 6);

        var digit_index: u16 = 0;
        // Traverse digits from least to most significant
        while (digit_index < digit_count) : (digit_index += 1) {
            const digit_char: u8 = blk: {
                const divisors = [5]u16{ 1, 10, 100, 1000, 10000 };
                break :blk '0' + @intCast(u8, (line_number / divisors[digit_index]) % 10);
            };

            const glyph_index = blk: {
                for (glyph_set.character_list) |c, x| {
                    if (c == digit_char) {
                        break :blk @intCast(u8, x);
                    }
                }
                return error.CharacterNotInSet;
            };

            const texture_extent = try glyph_set.imageRegionForGlyph(glyph_index);

            const glyph_dimensions = glyph_set.glyph_information[glyph_index].dimensions;
            const base_x_increment = (@intToFloat(f32, glyph_set.glyph_information[glyph_index].advance) / 64.0) * scale_factor.horizontal;

            const x_increment = (base_x_increment * @intToFloat(f32, chars_wide_count - 1 - digit_index));

            const origin: geometry.Coordinates2D(ScreenNormalizedBaseType) = .{
                .x = coordinates.x + x_increment,
                .y = coordinates.y + (line_height * @intToFloat(f32, i - 1)),
            };

            const char_extent = geometry.Dimensions2D(ScreenNormalizedBaseType){
                .width = @intToFloat(f32, glyph_dimensions.width) * scale_factor.horizontal,
                .height = @intToFloat(f32, glyph_dimensions.height) * scale_factor.vertical,
            };

            vertex_faces[faces_written_count] = graphics.generateTexturedQuad(VertexType, origin, char_extent, texture_extent, .bottom_left);
            for (vertex_faces[faces_written_count]) |*vertex| {
                vertex.color = .{ .r = 1.0, .g = 1.0, .b = 0.0, .a = 1.0 };
            }
            faces_written_count += 1;
        }
    }

    return vertex_faces;
}
