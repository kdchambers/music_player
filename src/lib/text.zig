// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const log = std.log;
const c = std.c;

const warn = std.debug.warn;
const info = std.debug.warn;

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const geometry = @import("geometry");
const graphics = @import("graphics");
const font = @import("font");

const Mesh = graphics.Mesh;
const RGBA = graphics.RGBA;
const GenericVertex = graphics.GenericVertex;
const ScaleFactor2D = geometry.ScaleFactor2D;
const QuadFace = graphics.QuadFace;

const utility = @import("utility");
const digitCount = utility.digitCount;

const constants = @import("constants");

const TexturePixelBaseType = constants.TexturePixelBaseType;
const TextureNormalizedBaseType = constants.TextureNormalizedBaseType;

// TODO
const Scale2D = geometry.Scale2D;
// TODO: Remove circ dependency
const Dimensions2D = font.Dimensions2D;

pub const GlyphMeta = packed struct {
    advance: u16,
    vertical_offset: i16,
    dimensions: geometry.Dimensions2D(u16),
};

// TODO: Sort characters and use binary search
pub const GlyphSet = struct {
    // TODO:
    // Once the image is created and sent to the GPU, it's no longer needed
    // Therefore, create a generateBitmapImage function instead of storing it here
    // NOTE: This is already being deallocated in core.zig
    image: []RGBA(f32),
    character_list: []u8,
    glyph_information: []GlyphMeta,
    cells_per_row: u8,
    cell_width: u16,
    cell_height: u16,

    pub fn deinit(self: GlyphSet, allocator: Allocator) void {
        allocator.free(self.character_list);
        allocator.free(self.glyph_information);
    }

    // TODO: Rename
    pub fn cellRowCount(self: GlyphSet) u32 {
        return self.cells_per_row;
    }

    pub fn cellColumnsCount(self: GlyphSet) u32 {
        return blk: {
            if (@mod(self.character_list.len, self.cells_per_row) == 0) {
                break :blk self.cells_per_row * @intCast(u32, (self.character_list.len / self.cells_per_row));
            } else {
                break :blk self.cells_per_row * @intCast(u32, ((self.character_list.len / self.cells_per_row) + 1));
            }
        };
    }

    pub fn width(self: GlyphSet) u32 {
        return self.cells_per_row * self.cell_width;
    }

    pub fn height(self: GlyphSet) u32 {
        return blk: {
            if (@mod(self.character_list.len, self.cells_per_row) == 0) {
                break :blk @intCast(u32, ((self.character_list.len / (self.cells_per_row + 1)) + 1)) * @intCast(u32, self.cell_height);
            } else {
                break :blk @intCast(u32, ((self.character_list.len / (self.cells_per_row)) + 1)) * @intCast(u32, self.cell_height);
            }
        };
    }

    pub fn imageRegionForGlyph(self: GlyphSet, char_index: usize, texture_dimensions: geometry.Dimensions2D(TexturePixelBaseType)) !geometry.Extent2D(TextureNormalizedBaseType) {
        if (char_index >= self.character_list.len) return error.InvalidIndex;
        return geometry.Extent2D(TextureNormalizedBaseType){
            .width = @intToFloat(f32, self.glyph_information[char_index].dimensions.width) / @intToFloat(f32, texture_dimensions.width),
            .height = @intToFloat(f32, self.glyph_information[char_index].dimensions.height) / @intToFloat(f32, texture_dimensions.height),
            .x = @intToFloat(f32, (char_index % self.cells_per_row) * self.cell_width) / @intToFloat(f32, texture_dimensions.width),
            .y = @intToFloat(f32, (char_index / self.cells_per_row) * self.cell_height) / @intToFloat(f32, texture_dimensions.height),
        };
    }
};

// TODO: Separate image generation to own function
pub fn createGlyphSet(allocator: Allocator, character_list: []const u8, texture_dimensions: geometry.Dimensions2D(TexturePixelBaseType)) !GlyphSet {
    assert(texture_dimensions.height == 512);
    assert(texture_dimensions.width == 512);

    // TODO:
    // Use zig stdlib for loading files
    // Use allocator instead of hardcoded array
    // Don't use hardcoded system installed font
    const font_path: [:0]const u8 = "/usr/share/fonts/TTF/Hack-Regular.ttf";
    var ttf_buffer: [1024 * 300]u8 align(64) = undefined;

    const file_handle = c.fopen(font_path, "rb");
    if (file_handle == null) {
        return error.FailedToOpenFontFile;
    }

    if (c.fread(&ttf_buffer, 1, 1024 * 300, file_handle.?) != (1024 * 300)) {
        return error.FailedToLoadFont;
    }
    _ = c.fclose(file_handle.?);

    assert(font.getFontOffsetForIndex(ttf_buffer[0..], 0) == 0);
    var font_info = try font.initializeFont(allocator, ttf_buffer[0..]);

    const scale = Scale2D(f32){
        // TODO
        .x = font.scaleForPixelHeight(font_info, 18),
        .y = font.scaleForPixelHeight(font_info, 18),
    };

    var glyph_set: GlyphSet = undefined;

    glyph_set.character_list = try allocator.alloc(u8, character_list.len);
    for (character_list) |char, i| {
        glyph_set.character_list[i] = char;
    }

    glyph_set.glyph_information = try allocator.alloc(GlyphMeta, character_list.len);
    glyph_set.cells_per_row = @floatToInt(u8, @sqrt(@intToFloat(f64, character_list.len)));

    assert(glyph_set.cells_per_row == 9);

    assert(glyph_set.cells_per_row > 0);

    var max_width: u32 = 0;
    var max_height: u32 = 0;

    const font_ascent = @intToFloat(f32, font.getAscent(font_info)) * scale.y;
    _ = font_ascent;
    const font_descent = @intToFloat(f32, font.getDescent(font_info)) * scale.y;
    _ = font_descent;

    // In order to not waste space on our texture, we loop through each glyph and find the largest dimensions required
    // We then use the largest width and height to form the cell size that each glyph will be put into
    for (character_list) |char, i| {
        const dimensions = try font.getRequiredDimensions(font_info, char, scale);

        assert(dimensions.width > 0);
        assert(dimensions.height > 0);

        const width = dimensions.width;
        const height = dimensions.height;
        if (width > max_width) max_width = width;
        if (height > max_height) max_height = height;

        const bounding_box = try font.getCodepointBitmapBox(font_info, char, scale);

        glyph_set.glyph_information[i].vertical_offset = @intCast(i16, bounding_box.y1);
        glyph_set.glyph_information[i].advance = @intCast(u16, dimensions.width) + 2;

        glyph_set.glyph_information[i].dimensions = .{
            .width = @intCast(u16, dimensions.width),
            .height = @intCast(u16, dimensions.height),
        };
    }

    // The glyph texture is divided into fixed size cells. However, there may not be enough characters
    // to completely fill the rectangle.
    // Therefore, we need to compute required_cells_count to allocate enough space for the full texture
    const required_cells_count = glyph_set.cellColumnsCount();

    glyph_set.image = try allocator.alloc(RGBA(f32), @intCast(u64, texture_dimensions.height) * texture_dimensions.width);
    errdefer allocator.free(glyph_set.image);

    var i: u16 = 0;
    while (i < required_cells_count) : (i += 1) {
        const cell_position = geometry.Coordinates2D(TexturePixelBaseType){
            .x = @mod(i, glyph_set.cells_per_row),
            .y = @intCast(TexturePixelBaseType, (i * max_width) / (max_width * glyph_set.cells_per_row)),
        };

        // Trailing cells (Once we've rasterized all our characters) filled in as transparent pixels
        if (i >= character_list.len) {
            var x: u16 = 0;
            var y: u16 = 0;
            while (y < max_height) : (y += 1) {
                while (x < max_width) : (x += 1) {
                    const texture_position = geometry.Coordinates2D(u16){
                        .x = @intCast(u16, cell_position.x * max_width + x),
                        .y = @intCast(u16, cell_position.y * max_height + y),
                    };

                    const pixel_index: usize = @intCast(u64, texture_position.y) * (texture_dimensions.width) + texture_position.x;
                    glyph_set.image[pixel_index] = .{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 0.0 };
                }
                x = 0;
            }
            continue;
        }

        const bitmap = try font.getCodepointBitmap(allocator, font_info, scale, character_list[i]);
        defer allocator.free(bitmap.pixels);

        const width = @intCast(u16, bitmap.width);
        const height = @intCast(u16, bitmap.height);

        // Don't keep a bitmap buffer for ' '
        // We want the meta details though
        if (character_list[i] == ' ') continue;

        // Buffer is 8-bit pixel greyscale
        // Will need to be converted into RGBA, etc
        // const buffer = @ptrCast([*]u8, face.*.glyph.*.bitmap.buffer);
        const buffer = @ptrCast([*]u8, bitmap.pixels);

        assert(width <= max_width);
        assert(width > 0);
        assert(height <= max_height);
        assert(height > 0);

        var y: u32 = 0;
        var texture_index: u32 = 0;

        while (y < max_height) : (y += 1) {
            var x: u32 = 0;
            while (x < max_width) : (x += 1) {
                const background_pixel = (y >= height or x >= width);
                const texture_position = geometry.Coordinates2D(TexturePixelBaseType){
                    .x = @intCast(TexturePixelBaseType, cell_position.x * max_width + x),
                    .y = @intCast(TexturePixelBaseType, cell_position.y * max_height + y),
                };

                const pixel_index: usize = (@intCast(u64, texture_position.y) * texture_dimensions.width) + texture_position.x;

                assert(i < glyph_set.cells_per_row or pixel_index > texture_dimensions.width);

                if (!background_pixel) {
                    glyph_set.image[pixel_index] = .{
                        .r = 1.0, // @intToFloat(f32, buffer[texture_index]) / 255.0,
                        .g = 1.0, // @intToFloat(f32, buffer[texture_index]) / 255.0,
                        .b = 1.0, // @intToFloat(f32, buffer[texture_index]) / 255.0,
                        .a = @intToFloat(f32, buffer[texture_index]) / 255.0,
                    };
                    assert(texture_index < (height * width));
                    texture_index += 1;
                } else {
                    glyph_set.image[pixel_index] = graphics.Color(RGBA(f32)).clear();
                }
            }
        }
    }

    glyph_set.cell_height = @intCast(u16, max_height);
    glyph_set.cell_width = @intCast(u16, max_width);

    return glyph_set;
}

// pub fn writeText(face_allocator: Allocator, glyph_set: GlyphSet, placement: geometry.Coordinates2D(.ndc_right), scale_factor: ScaleFactor2D, text: []const u8) ![]QuadFace(GenericVertex) {
// // TODO: Don't hardcode line height to XX pixels
// const line_height = 18.0 * scale_factor.vertical;
// const color = RGBA(f32){ .r = 0.8, .g = 0.2, .b = 0.7, .a = 1.0 };
// return try gui.generateText(GenericVertex, face_allocator, text, placement, scale_factor, glyph_set, color, line_height);
// }
