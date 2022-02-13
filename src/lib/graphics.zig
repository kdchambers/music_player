// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const geometry = @import("geometry.zig");
const ScaleFactor2D = geometry.ScaleFactor2D;

// TODO: Color channel hard coded to 9.0 both here and in shader
pub const GenericVertex = packed struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    tx: f32 = 9.0,
    ty: f32 = 9.0,
    color: RGBA(f32) = .{
        .r = 1.0,
        .g = 1.0,
        .b = 1.0,
        .a = 0.0,
    },

    pub fn nullFace() QuadFace(GenericVertex) {
        return .{ .{}, .{}, .{}, .{} };
    }
};

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

fn TypeOfField(t: anytype, field_name: []const u8) type {
    for (@typeInfo(t).Struct.fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            return field.field_type;
        }
    }
    unreachable;
}

pub fn generateTexturedQuad(
    comptime VertexType: type,
    placement: geometry.Coordinates2D(TypeOfField(VertexType, "x")),
    dimensions: geometry.Dimensions2D(TypeOfField(VertexType, "x")),
    texture_extent: geometry.Extent2D(TypeOfField(VertexType, "tx")),
) QuadFace(VertexType) {
    std.debug.assert(TypeOfField(VertexType, "x") == TypeOfField(VertexType, "y"));
    std.debug.assert(TypeOfField(VertexType, "tx") == TypeOfField(VertexType, "ty"));

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

pub fn generateQuadColored(comptime VertexType: type, extent: geometry.Extent2D(TypeOfField(VertexType, "x")), quad_color: RGBA(f32)) QuadFace(VertexType) {
    std.debug.assert(TypeOfField(VertexType, "x") == TypeOfField(VertexType, "y"));

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
pub fn generateTriangleColored(comptime VertexType: type, extent: geometry.Extent2D(TypeOfField(VertexType, "x")), quad_color: RGBA(f32)) QuadFace(VertexType) {
    std.debug.assert(TypeOfField(VertexType, "x") == TypeOfField(VertexType, "y"));

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
