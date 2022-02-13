// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const graphics = @import("graphics.zig");
const RGBA = graphics.RGBA;
const geometry = @import("geometry");

const zigimg = @import("zigimg");

const image = @This();

pub fn copy(comptime T: type, source_image: []T, source_extent: geometry.Extent2D(.carthesian), destination_image: *[]T, destination_placement: geometry.Coordinates2D(.carthesian), destination_dimensions: geometry.Dimensions2D(.carthesian)) void {
    assert(destination_image.len >= source_image.len);
    var y: u32 = 0;
    while (y < source_extent.height) : (y += 1) {
        var x: u32 = 0;
        while (x < source_extent.width) : (x += 1) {
            destination_image.*[(y + destination_placement.y) * destination_dimensions.width + (x + destination_placement.x)] = source_image[y * source_extent.width + x];
        }
    }
}

pub fn crop(allocator: *Allocator, source_image: []RGBA(f32), source_dimensions: geometry.Dimensions2D(.carthesian), extent: geometry.Extent2D(.carthesian)) ![]RGBA(f32) {
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
            if (y < source_dimensions.height and x < source_dimensions.width) {
                dest_image[dest_i] = source_image[x + (y * source_dimensions.width)];
            } else {
                // Fill in out of bounds pixels black
                dest_image[dest_i] = RGBA(f32){
                    .r = 0.0,
                    .g = 0.0,
                    .b = 0.0,
                    .a = 1.0,
                };
            }
            dest_i += 1;
        }
    }

    assert(dest_image.len == (extent.width * extent.height));
    log.info("Image cropped to {}x{} {} pixels", .{ extent.width, extent.height, dest_image.len });

    return dest_image;
}

pub fn shrink(allocator: *Allocator, source_image: []RGBA(f32), old_dimensions: geometry.Dimensions2D(.carthesian), new_dimensions: geometry.Dimensions2D(.carthesian)) ![]RGBA(f32) {
    assert(new_dimensions.width < old_dimensions.width);
    assert(new_dimensions.height < old_dimensions.height);

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
    log.info("Pixels to merge count: {} {d}x{d}", .{ pixels_to_merge_count, compression_ratio_x, compression_ratio_y });

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

            new_image[dst_x + (dst_y * new_dimensions.width)].r = average_r / (@intToFloat(f32, pixels_to_merge_count) / 4);
            new_image[dst_x + (dst_y * new_dimensions.width)].g = average_g / (@intToFloat(f32, pixels_to_merge_count) / 4);
            new_image[dst_x + (dst_y * new_dimensions.width)].b = average_b / (@intToFloat(f32, pixels_to_merge_count) / 4);
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

pub fn convertImageRgba32(allocator: *Allocator, source_image: []zigimg.color.Rgba32) ![]RGBA(f32) {
    var new_image = try allocator.alloc(RGBA(f32), source_image.len);
    for (source_image) |source_pixel, i| {
        new_image[i].r = @intToFloat(f32, source_pixel.R) / 255.0;
        new_image[i].g = @intToFloat(f32, source_pixel.G) / 255.0;
        new_image[i].b = @intToFloat(f32, source_pixel.B) / 255.0;
        new_image[i].a = 1.0;
    }
    return new_image;
}

pub fn convertImageRgb24(allocator: *Allocator, source_image: []zigimg.color.Rgb24) ![]RGBA(f32) {
    var new_image = try allocator.alloc(RGBA(f32), source_image.len);
    for (source_image) |source_pixel, i| {
        new_image[i].r = @intToFloat(f32, source_pixel.R) / 255.0;
        new_image[i].g = @intToFloat(f32, source_pixel.G) / 255.0;
        new_image[i].b = @intToFloat(f32, source_pixel.B) / 255.0;
        new_image[i].a = 1.0;
    }
    return new_image;
}
