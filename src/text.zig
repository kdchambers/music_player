// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");

const warn = std.debug.warn;
const info = std.debug.warn;

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const zvk = @import("vulkan_wrapper.zig");
const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");
const gui = @import("gui.zig");

const Mesh = graphics.Mesh;
const RGBA = graphics.RGBA;
const ScaleFactor2D = geometry.ScaleFactor2D;
const QuadFace = graphics.QuadFace;

const utility = @import("utility.zig");
const digitCount = utility.digitCount;

pub const ft = @cImport({
    @cInclude("freetype2/ft2build.h");
    @cDefine("FT_FREETYPE_H", {});
    @cInclude("freetype2/freetype/freetype.h");
});

// TODO: Color channel hard coded to 9.0 both here and in shader
pub const GenericVertex = packed struct { x: f32 = 0.0, y: f32 = 0.0, tx: f32 = 9.0, ty: f32 = 9.0, color: RGBA(f32) = .{
    .r = 1.0,
    .g = 1.0,
    .b = 1.0,
    .a = 0.0,
} };

pub const GlyphMeta = packed struct {
    advance: u16,
    vertical_offset: i16,
    dimensions: geometry.Dimensions2D(.pixel16),
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

    pub fn deinit(self: GlyphSet, allocator: *Allocator) void {
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

    pub fn imageRegionForGlyph(self: GlyphSet, char_index: usize) !geometry.Extent2D(.normalized) {
        if (char_index >= self.character_list.len) return error.InvalidIndex;
        return geometry.Extent2D(.normalized){
            .width = @intToFloat(f32, self.glyph_information[char_index].dimensions.width) / @intToFloat(f32, self.width()),
            .height = @intToFloat(f32, self.glyph_information[char_index].dimensions.height) / @intToFloat(f32, self.height()),
            .x = @intToFloat(f32, (char_index % self.cells_per_row) * self.cell_width) / @intToFloat(f32, self.width()),
            .y = @intToFloat(f32, (char_index / self.cells_per_row) * self.cell_height) / @intToFloat(f32, self.height()),
        };
    }
};

// TODO: Separate image generation to own function
pub fn createGlyphSet(allocator: *Allocator, face: ft.FT_Face, character_list: []const u8) !GlyphSet {
    var glyph_set: GlyphSet = undefined;

    glyph_set.character_list = try allocator.alloc(u8, character_list.len);
    for (character_list) |char, i| {
        glyph_set.character_list[i] = char;
    }

    glyph_set.glyph_information = try allocator.alloc(GlyphMeta, character_list.len);
    glyph_set.cells_per_row = @floatToInt(u8, @sqrt(@intToFloat(f64, character_list.len)));

    var max_width: u32 = 0;
    var max_height: u32 = 0;

    // In order to not waste space on our texture, we loop through each glyph and find the largest dimensions required
    // We then use the largest width and height to form the cell size that each glyph will be put into
    for (character_list) |char, i| {
        if (ft.FT_Load_Char(face, char, ft.FT_LOAD_RENDER) != ft.FT_Err_Ok) {
            warn("Failed to load char {}\n", .{char});
            return error.LoadFreeTypeCharFailed;
        }

        const width = face.*.glyph.*.bitmap.width;
        const height = face.*.glyph.*.bitmap.rows;
        if (width > max_width) max_width = width;
        if (height > max_height) max_height = height;

        // Also, we can extract additional glyph information
        glyph_set.glyph_information[i].vertical_offset = @intCast(i16, face.*.glyph.*.metrics.height - face.*.glyph.*.metrics.horiBearingY);
        glyph_set.glyph_information[i].advance = @intCast(u16, face.*.glyph.*.metrics.horiAdvance);

        glyph_set.glyph_information[i].dimensions = .{
            .width = @intCast(u16, @divTrunc(face.*.glyph.*.metrics.width, 64)),
            .height = @intCast(u16, @divTrunc(face.*.glyph.*.metrics.height, 64)),
        };
    }

    // The glyph texture is divided into fixed size cells. However, there may not be enough characters
    // to completely fill the rectangle.
    // Therefore, we need to compute required_cells_count to allocate enough space for the full texture
    const required_cells_count = glyph_set.cellColumnsCount();

    glyph_set.image = try allocator.alloc(RGBA(f32), required_cells_count * max_height * max_width);
    errdefer allocator.free(glyph_set.image);

    var i: u32 = 0;
    while (i < required_cells_count) : (i += 1) {
        const cell_position = geometry.Coordinates2D(.carthesian){
            .x = @mod(i, glyph_set.cells_per_row),
            .y = (i * max_width) / (max_width * glyph_set.cells_per_row),
        };

        // Trailing cells (Once we've rasterized all our characters) filled in as transparent pixels
        if (i >= character_list.len) {
            var x: u32 = 0;
            var y: u32 = 0;
            while (y < max_height) : (y += 1) {
                while (x < max_width) : (x += 1) {
                    const texture_position = geometry.Coordinates2D(.pixel){
                        .x = cell_position.x * max_width + x,
                        .y = cell_position.y * max_height + y,
                    };

                    const pixel_index: usize = texture_position.y * (max_width * glyph_set.cells_per_row) + texture_position.x;
                    glyph_set.image[pixel_index] = .{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 0.0 };
                }
                x = 0;
            }
            continue;
        }

        if (ft.FT_Load_Char(face, character_list[i], ft.FT_LOAD_RENDER) != ft.FT_Err_Ok) {
            warn("Failed to load char {}\n", .{character_list[i]});
            return error.LoadFreeTypeCharFailed;
        }

        const width = face.*.glyph.*.bitmap.width;
        const height = face.*.glyph.*.bitmap.rows;

        // Buffer is 8-bit pixel greyscale
        // Will need to be converted into RGBA, etc
        const buffer = @ptrCast([*]u8, face.*.glyph.*.bitmap.buffer);

        assert(width <= max_width);
        assert(width > 0);
        assert(height <= max_height);
        assert(height > 0);

        var x: u32 = 0;
        var y: u32 = 0;
        var texture_index: u32 = 0;

        while (y < max_height) : (y += 1) {
            while (x < max_width) : (x += 1) {
                const background_pixel = (y >= height or x >= width);
                const texture_position = geometry.Coordinates2D(.pixel){
                    .x = cell_position.x * max_width + x,
                    .y = cell_position.y * max_height + y,
                };

                const pixel_index: usize = texture_position.y * (max_width * glyph_set.cells_per_row) + texture_position.x;
                if (!background_pixel) {
                    glyph_set.image[pixel_index] = .{
                        .r = @intToFloat(f32, buffer[texture_index]) / 255.0,
                        .g = @intToFloat(f32, buffer[texture_index]) / 255.0,
                        .b = @intToFloat(f32, buffer[texture_index]) / 255.0,
                        .a = @intToFloat(f32, buffer[texture_index]) / 255.0,
                    };
                    assert(texture_index < (height * width));
                    texture_index += 1;
                } else {
                    glyph_set.image[pixel_index] = graphics.color(RGBA(f32)).clear();
                }
            }
            x = 0;
        }
    }

    glyph_set.cell_height = @intCast(u16, max_height);
    glyph_set.cell_width = @intCast(u16, max_width);

    return glyph_set;
}

pub fn writeText(face_allocator: *Allocator, glyph_set: GlyphSet, placement: geometry.Coordinates2D(.ndc_right), scale_factor: ScaleFactor2D, text: []const u8) ![]QuadFace(GenericVertex) {
    // TODO: Don't hardcode line height to XX pixels
    const line_height = 18.0 * scale_factor.vertical;
    const color = RGBA(f32){ .r = 0.8, .g = 0.2, .b = 0.7, .a = 1.0 };
    return try gui.generateText(GenericVertex, face_allocator, text, placement, scale_factor, glyph_set, color, line_height);
}
