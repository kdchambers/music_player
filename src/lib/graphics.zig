// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const geometry = @import("geometry.zig");
const ScaleFactor2D = geometry.ScaleFactor2D;

const constants = @import("constants");
const TextureNormalizedBaseType = constants.TextureNormalizedBaseType;
const ScreenNormalizedBaseType = constants.ScreenNormalizedBaseType;

// TODO: Should not be FaceQuad? To namespace sub types under 'Face'
pub fn TriFace(comptime VertexType: type) type {
    return [3]VertexType;
}
pub fn QuadFace(comptime VertexType: type) type {
    return [4]VertexType;
}

pub fn RGBA(comptime BaseType: type) type {
    return packed struct {
        const This = @This();

        pub fn fromInt(comptime IntType: type, r: IntType, g: IntType, b: IntType, a: IntType) This {
            return .{
                .r = @intToFloat(BaseType, r) / 255.0,
                .g = @intToFloat(BaseType, g) / 255.0,
                .b = @intToFloat(BaseType, b) / 255.0,
                .a = @intToFloat(BaseType, a) / 255.0,
            };
        }

        r: BaseType,
        g: BaseType,
        b: BaseType,
        a: BaseType,
    };
}

pub fn Color(comptime Type: type) type {
    return struct {
        pub fn clear() Type {
            return .{
                .r = 0,
                .g = 0,
                .b = 0,
                .a = 0,
            };
        }
    };
}

pub fn generateTexturedQuad(comptime VertexType: type, placement: geometry.Coordinates2D(ScreenNormalizedBaseType), dimensions: geometry.Dimensions2D(ScreenNormalizedBaseType), texture_extent: geometry.Extent2D(TextureNormalizedBaseType)) QuadFace(VertexType) {
    return [_]VertexType{
        .{
            // Top Left
            .x = placement.x,
            .y = placement.y - dimensions.height,
            .tx = texture_extent.x,
            .ty = texture_extent.y,
        },
        .{
            // Top Right
            .x = placement.x + dimensions.width,
            .y = placement.y - dimensions.height,
            .tx = texture_extent.x + texture_extent.width,
            .ty = texture_extent.y,
        },
        .{
            // Bottom Right
            .x = placement.x + dimensions.width,
            .y = placement.y,
            .tx = texture_extent.x + texture_extent.width,
            .ty = texture_extent.y + texture_extent.height,
        },
        .{
            // Bottom Left
            .x = placement.x,
            .y = placement.y,
            .tx = texture_extent.x,
            .ty = texture_extent.y + texture_extent.height,
        },
    };
}

pub fn generateQuadColored(comptime VertexType: type, extent: geometry.Extent2D(ScreenNormalizedBaseType), quad_color: RGBA(f32)) QuadFace(VertexType) {
    return [_]VertexType{
        .{
            // Top Left
            .x = extent.x,
            .y = extent.y - extent.height,
            .color = quad_color,
        },
        .{
            // Top Right
            .x = extent.x + extent.width,
            .y = extent.y - extent.height,
            .color = quad_color,
        },
        .{
            // Bottom Right
            .x = extent.x + extent.width,
            .y = extent.y,
            .color = quad_color,
        },
        .{
            // Bottom Left
            .x = extent.x,
            .y = extent.y,
            .color = quad_color,
        },
    };
}

// TODO: Rotation
pub fn generateTriangleColored(comptime VertexType: type, extent: geometry.Extent2D(ScreenNormalizedBaseType), quad_color: RGBA(f32)) QuadFace(VertexType) {
    return [_]VertexType{
        .{
            // Top Left
            .x = extent.x,
            .y = extent.y - extent.height,
            .color = quad_color,
        },
        .{
            // Top Right
            .x = extent.x + extent.width,
            .y = extent.y - (extent.height / 2.0),
            .color = quad_color,
        },
        .{
            // Bottom Right
            .x = extent.x,
            .y = extent.y,
            .color = quad_color,
        },
        .{
            // Bottom Left
            .x = extent.x,
            .y = extent.y,
            .color = quad_color,
        },
    };
}
