// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log;

const geometry = @import("geometry.zig");
const ScaleFactor2D = geometry.ScaleFactor2D;
const graphics = @import("graphics.zig");
const QuadFace = graphics.QuadFace;
const text = @import("text.zig");
const util = @import("utility.zig");
const RGBA = graphics.RGBA;

const event_system = @import("event_system.zig");

var next_widget_id: u32 = 0;

pub fn Widget(comptime VertexType: type) type {
    return struct {
        faces: []QuadFace(VertexType),
        id: u32,
    };
}

pub const WidgetSelection = []u32;

fn nextWidgetId() u32 {
    next_widget_id += 1;
    return next_widget_id;
}

pub const Context = struct {
    allocator: *Allocator,
    vertices_count: u32,
};

pub const Alignment = enum { left, right, center };

pub const button = struct {
    pub const face_count: u32 = 1;

    // TODO: Support eliding if button dimensions are too small for label
    // TODO: Don't hardcode non-center alignment, maybe split function
    pub fn generate(
        comptime VertexType: type,
        allocator: *Allocator,
        glyph_set: text.GlyphSet,
        label: []const u8,
        extent: geometry.Extent2D(.ndc_right),
        scale_factor: ScaleFactor2D,
        color: RGBA(f32),
        label_color: RGBA(f32),
        text_alignment: Alignment,
    ) ![]QuadFace(VertexType) {

        // TODO: Implement right align
        assert(text_alignment != .right);

        var background_face: *QuadFace(VertexType) = try allocator.create(QuadFace(VertexType));

        // Background has to be generated first so that it doesn't cover the label text
        background_face.* = graphics.generateQuadColored(VertexType, extent, color);

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

        const label_origin = geometry.Coordinates2D(.ndc_right){
            .x = extent.x + horizontal_margin,
            .y = extent.y - vertical_margin,
        };

        const label_faces = try generateText(VertexType, allocator, label, label_origin, scale_factor, glyph_set, label_color, null);

        // Memory for background_face and label_face should be contigious
        assert(@ptrToInt(background_face) == @ptrToInt(label_faces.ptr) - @sizeOf(QuadFace(VertexType)));

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
        allocator: *Allocator,
        image_id: f32,
        extent: geometry.Extent2D(.ndc_right),
    ) ![]QuadFace(VertexType) {
        assert(image_id == 1 or image_id == 2);
        var image_faces = try allocator.alloc(QuadFace(VertexType), 1);

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
    scale_factor: ScaleFactor2D,
    line_height: f32,
    space_width: f32,
) !geometry.Dimensions2D(.ndc_right) {
    var dimensions = geometry.Dimensions2D(.ndc_right){
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
                log.err("Charactor not in set '{c}' '{s}'", .{ char, text_buffer });
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
    face_allocator: *Allocator,
    text_buffer: []const u8,
    origin: geometry.Coordinates2D(.ndc_right),
    scale_factor: ScaleFactor2D,
    glyph_set: text.GlyphSet,
    color: RGBA(f32),
    line_height_opt: ?f32,
) ![]QuadFace(VertexType) {
    const glyph_length: u32 = blk: {
        var i: u32 = 0;
        for (text_buffer) |c| {
            if (c != ' ' and c != '\n') {
                i += 1;
            }
        }
        break :blk i;
    };

    var vertices = try face_allocator.alloc(QuadFace(VertexType), glyph_length);
    var cursor = geometry.Coordinates2D(.carthesian){ .x = 0, .y = 0 };
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

        if (char != ' ') {
            const glyph_index = blk: {
                for (glyph_set.character_list) |c, x| {
                    if (c == char) {
                        break :blk x;
                    }
                }
                log.err("Charactor not in set '{c}' (ascii {d}) in '{s}'", .{ char, char, text_buffer });
                return error.InvalidCharacter;
            };

            const texture_extent = try glyph_set.imageRegionForGlyph(glyph_index);
            const glyph_dimensions = glyph_set.glyph_information[glyph_index].dimensions;

            // Positive offset (Glyphs with a descent get shift down)
            const y_offset = @intToFloat(f32, glyph_set.glyph_information[glyph_index].vertical_offset) * scale_factor.vertical;

            const placement = geometry.Coordinates2D(.ndc_right){
                .x = origin.x + x_increment,
                .y = origin.y + y_offset + (line_height * @intToFloat(f32, cursor.y)),
            };

            const char_extent = geometry.Dimensions2D(.ndc_right){
                .width = @intToFloat(f32, glyph_dimensions.width) * scale_factor.horizontal,
                .height = @intToFloat(f32, glyph_dimensions.height) * scale_factor.vertical,
            };

            vertices[i - skipped_count] = graphics.generateTexturedQuad(VertexType, placement, char_extent, texture_extent);
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

pub fn generateLineMargin(comptime VertexType: type, allocator: *Allocator, glyph_set: text.GlyphSet, coordinates: geometry.Coordinates2D(.ndc_right), scale_factor: ScaleFactor2D, line_start: u16, line_count: u16, line_height: f32) ![]QuadFace(VertexType) {

    // Loop through lines to calculate how many vertices will be required
    const quads_required_count = blk: {
        var count: u32 = 0;
        var i: u32 = 1;
        while (i <= line_count) : (i += 1) {
            count += util.digitCount(line_start + i);
        }
        break :blk count;
    };

    assert(line_count > 0);
    const chars_wide_count: u32 = util.digitCount(line_start + line_count);

    var vertex_faces = try allocator.alloc(QuadFace(VertexType), quads_required_count);

    var i: u32 = 1;
    var faces_written_count: u32 = 0;
    while (i <= line_count) : (i += 1) {
        const line_number = line_start + i;
        const digit_count = util.digitCount(line_number);

        assert(digit_count < 6);

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

            const origin: geometry.Coordinates2D(.ndc_right) = .{
                .x = coordinates.x + x_increment,
                .y = coordinates.y + (line_height * @intToFloat(f32, i - 1)),
            };

            const char_extent = geometry.Dimensions2D(.ndc_right){
                .width = @intToFloat(f32, glyph_dimensions.width) * scale_factor.horizontal,
                .height = @intToFloat(f32, glyph_dimensions.height) * scale_factor.vertical,
            };

            vertex_faces[faces_written_count] = graphics.generateTexturedQuad(VertexType, origin, char_extent, texture_extent);
            for (vertex_faces[faces_written_count]) |*vertex| {
                vertex.color = .{ .r = 1.0, .g = 1.0, .b = 0.0, .a = 1.0 };
            }
            faces_written_count += 1;
        }
    }

    return vertex_faces;
}
