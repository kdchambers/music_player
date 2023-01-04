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

        pub inline fn isEqual(self: @This(), color: @This()) bool {
            return (self.r == color.r and self.g == color.g and self.b == color.b and self.a == color.a);
        }

        r: BaseType,
        g: BaseType,
        b: BaseType,
        a: BaseType,
    };
}

pub const ScreenUnitTag = enum {
    pixel,
    ndc_right,
    percent,
};

pub const ScreenUnit = union(ScreenUnitTag) {
    pixel: u16,
    ndc_right: f32,
    percent: f32,
};

pub inline fn downFromTop(distance: ScreenUnit) f32 {
    return switch (distance) {
        .percent => |value| 1.0 - (value * 2.0),
        .ndc_right => |value| 1.0 - value,
        else => unreachable,
    };
}

pub inline fn upFromBottom(distance: ScreenUnit) f32 {
    return switch (distance) {
        .percent => |value| -1.0 + (value * 2.0),
        .ndc_right => |value| -1.0 + value,
        else => unreachable,
    };
}

const ScreenScaleFactorConfig = struct {
    NDCRightType: type,
    PixelType: type,
};

const ScreenCoordinate = enum {
    ndc_right,
    percentage,
    pixel,
};

const ScreenMeasurementType = enum {
    length,
    point,
};

/// Holds a scaling value that is used to covert between pixels and ndc right (Vulkan coordinate system)
pub fn ScreenScaleFactor(comptime config: ScreenScaleFactorConfig) type {
    return struct {
        horizontal: f32,
        vertical: f32,

        fn Type(comptime coordinate: ScreenCoordinate) type {
            return switch (coordinate) {
                .ndc_right => config.NDCRightType,
                .pixel => config.PixelType,
                else => unreachable,
            };
        }

        pub fn create(screen_dimensions: geometry.Dimensions2D(config.PixelType)) @This() {
            return .{
                .horizontal = 2.0 / @intToFloat(f32, screen_dimensions.width),
                .vertical = 2.0 / @intToFloat(f32, screen_dimensions.height),
            };
        }

        pub inline fn convertLength(
            self: @This(),
            comptime Input: ScreenCoordinate,
            comptime Output: ScreenCoordinate,
            comptime axis: geometry.Axis,
            length: Type(Input),
        ) Type(Output) {
            std.debug.assert(Input != Output);
            std.debug.assert(axis == .horizontal or axis == .vertical);
            const horizontal = (axis == .horizontal);
            switch (Input) {
                .ndc_right => {
                    switch (Output) {
                        .pixel => {
                            if (horizontal) {
                                return self.ndcRightLengthToPixelHorizontal(length);
                            } else {
                                return self.ndcRightLengthToPixelVertical(length);
                            }
                        },
                        else => unreachable,
                    }
                },
                .pixel => {
                    switch (Output) {
                        .ndc_right => {
                            if (horizontal) {
                                return self.pixelLengthToNDCRightHorizontal(length);
                            } else {
                                return self.pixelLengthToNDCRightVertical(length);
                            }
                        },
                        else => unreachable,
                    }
                },
                else => unreachable,
            }
        }

        pub inline fn convertPoint(
            self: @This(),
            comptime Input: ScreenCoordinate,
            comptime Output: ScreenCoordinate,
            point: geometry.Coordinates2D(Type(Input)),
        ) geometry.Coordinates2D(Type(Output)) {
            std.debug.assert(Input != Output);
            switch (Input) {
                .ndc_right => {
                    switch (Output) {
                        .pixel => {
                            return self.ndcRightPointToPixel(point);
                        },
                        else => unreachable,
                    }
                },
                .pixel => {
                    switch (Output) {
                        .ndc_right => {
                            return self.pixelPointToNDCRight(point);
                        },
                        else => unreachable,
                    }
                },
                else => unreachable,
            }
        }

        pub inline fn ndcRightPointToPixel(
            self: @This(),
            point: geometry.Coordinates2D(config.NDCRightType),
        ) geometry.Coordinates2D(config.PixelType) {
            return .{
                .x = @floatToInt(config.PixelType, ((point.x + 1.0) / self.horizontal)),
                .y = @floatToInt(config.PixelType, ((point.y + 1.0) / self.vertical)),
            };
        }

        pub inline fn ndcRightDimensionsToPixel(
            self: @This(),
            dimensions: geometry.Dimensions2D(config.NDCRightType),
        ) geometry.Dimensions2D(config.PixelType) {
            return .{
                .width = @floatToInt(config.PixelType, dimensions.width / self.horizontal),
                .height = @floatToInt(config.PixelType, dimensions.height / self.vertical),
            };
        }

        pub inline fn pixelPointToNDCRightHorizontal(
            self: @This(),
            value: config.PixelType,
        ) config.NDCRightType {
            return -1.0 + (@intToFloat(f32, value) * self.horizontal);
        }

        pub inline fn pixelPointToNDCRightVertical(
            self: @This(),
            value: config.PixelType,
        ) config.NDCRightType {
            return -1.0 + (@intToFloat(f32, value) * self.vertical);
        }

        pub inline fn pixelPointToNDCRight(
            self: @This(),
            point: geometry.Coordinates2D(config.PixelType),
        ) geometry.Coordinates2D(config.NDCRightType) {
            return .{
                .x = self.pixelPointToNDCRightHorizontal(point.x),
                .y = self.pixelPointToNDCRightVertical(point.y),
            };
        }

        pub inline fn ndcRightLengthToPixelHorizontal(
            self: @This(),
            value: config.NDCRightType,
        ) config.PixelType {
            std.debug.assert(value >= 0.0);
            std.debug.assert(value <= 2.0);
            return @floatToInt(config.PixelType, value / self.horizontal);
        }

        pub inline fn ndcRightLengthToPixelVertical(
            self: @This(),
            value: config.NDCRightType,
        ) config.PixelType {
            std.debug.assert(value >= 0.0);
            std.debug.assert(value <= 2.0);
            return @floatToInt(config.PixelType, value / self.vertical);
        }

        pub inline fn pixelLengthToNDCRightHorizontal(
            self: @This(),
            value: config.PixelType,
        ) config.NDCRightType {
            return @intToFloat(f32, value) * self.horizontal;
        }

        pub inline fn pixelLengthToNDCRightVertical(
            self: @This(),
            value: config.PixelType,
        ) config.NDCRightType {
            return @intToFloat(f32, value) * self.vertical;
        }
    };
}

test "ScreenScaleFactor" {
    const screen_dimensions = geometry.Dimensions2D(u16){
        .width = 200,
        .height = 400,
    };

    const scale_factor = ScreenScaleFactor(.{ .NDCRightType = f32, .PixelType = u16 }).create(screen_dimensions);

    {
        const point1 = scale_factor.convertPoint(.ndc_right, .pixel, .{ .x = 0.5, .y = 0.5 });
        try std.testing.expect(point1.x == 150);
        try std.testing.expect(point1.y == 300);

        const point2 = scale_factor.convertPoint(.ndc_right, .pixel, .{ .x = -1.0, .y = 1.0 });
        try std.testing.expect(point2.x == 0);
        try std.testing.expect(point2.y == 400);
    }

    {
        const mid_width = scale_factor.convertLength(.ndc_right, .pixel, .horizontal, 0.5);
        std.testing.expect(mid_width == 50) catch {
            try std.testing.expectFmt("mid_width == 50", "mid_width = {d}", .{mid_width});
        };

        const upper_width = scale_factor.convertLength(.ndc_right, .pixel, .horizontal, 2.0);
        std.testing.expect(upper_width == 200) catch {
            try std.testing.expectFmt("upper_width == 200", "upper_width = {d}", .{upper_width});
        };

        const lower_width = scale_factor.convertLength(.ndc_right, .pixel, .horizontal, 0.0);
        std.testing.expect(lower_width == 0) catch {
            try std.testing.expectFmt("lower_width == 0", "lower_width = {d}", .{lower_width});
        };

        const mid_width_vertical = scale_factor.convertLength(.ndc_right, .pixel, .vertical, 1.0);
        std.testing.expect(mid_width_vertical == 200) catch {
            try std.testing.expectFmt("mid_width_vertical == 200", "mid_width_vertical = {d}", .{mid_width_vertical});
        };
    }
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

fn TypeOfField(comptime t: anytype, comptime field_name: []const u8) type {
    for (@typeInfo(t).Struct.fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            return field.type;
        }
    }
    unreachable;
}

pub fn generateTexturedQuad(
    comptime VertexType: type,
    placement: geometry.Coordinates2D(TypeOfField(VertexType, "x")),
    dimensions: geometry.Dimensions2D(TypeOfField(VertexType, "x")),
    texture_extent: geometry.Extent2D(TypeOfField(VertexType, "tx")),
    comptime anchor_point: AnchorPoint,
) QuadFace(VertexType) {
    std.debug.assert(TypeOfField(VertexType, "x") == TypeOfField(VertexType, "y"));
    std.debug.assert(TypeOfField(VertexType, "tx") == TypeOfField(VertexType, "ty"));
    const extent = geometry.Extent2D(TypeOfField(VertexType, "x")){
        .x = placement.x,
        .y = placement.y,
        .width = dimensions.width,
        .height = dimensions.height,
    };
    var base_quad = generateQuad(VertexType, extent, anchor_point);
    base_quad[0].tx = texture_extent.x;
    base_quad[0].ty = texture_extent.y;

    base_quad[1].tx = texture_extent.x + texture_extent.width;
    base_quad[1].ty = texture_extent.y;

    base_quad[2].tx = texture_extent.x + texture_extent.width;
    base_quad[2].ty = texture_extent.y + texture_extent.height;

    base_quad[3].tx = texture_extent.x;
    base_quad[3].ty = texture_extent.y + texture_extent.height;
    return base_quad;
}

pub const AnchorPoint = enum {
    center,
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

pub fn generateQuad(
    comptime VertexType: type,
    extent: geometry.Extent2D(TypeOfField(VertexType, "x")),
    comptime anchor_point: AnchorPoint,
) QuadFace(VertexType) {
    std.debug.assert(TypeOfField(VertexType, "x") == TypeOfField(VertexType, "y"));
    return switch (anchor_point) {
        .top_left => [_]VertexType{
            .{
                // Top Left
                .x = extent.x,
                .y = extent.y,
            },
            .{
                // Top Right
                .x = extent.x + extent.width,
                .y = extent.y,
            },
            .{
                // Bottom Right
                .x = extent.x + extent.width,
                .y = extent.y + extent.height,
            },
            .{
                // Bottom Left
                .x = extent.x,
                .y = extent.y + extent.height,
            },
        },
        .bottom_left => [_]VertexType{
            .{
                // Top Left
                .x = extent.x,
                .y = extent.y - extent.height,
            },
            .{
                // Top Right
                .x = extent.x + extent.width,
                .y = extent.y - extent.height,
            },
            .{
                // Bottom Right
                .x = extent.x + extent.width,
                .y = extent.y,
            },
            .{
                // Bottom Left
                .x = extent.x,
                .y = extent.y,
            },
        },
        .center => [_]VertexType{
            .{
                // Top Left
                .x = extent.x - (extent.width / 2.0),
                .y = extent.y + (extent.height / 2.0),
            },
            .{
                // Top Right
                .x = extent.x + (extent.width / 2.0),
                .y = extent.y + (extent.height / 2.0),
            },
            .{
                // Bottom Right
                .x = extent.x + (extent.width / 2.0),
                .y = extent.y - (extent.height / 2.0),
            },
            .{
                // Bottom Left
                .x = extent.x - (extent.width / 2.0),
                .y = extent.y - (extent.height / 2.0),
            },
        },
        else => @compileError("Invalid AnchorPoint"),
    };
}

pub fn generateQuadColored(
    comptime VertexType: type,
    extent: geometry.Extent2D(TypeOfField(VertexType, "x")),
    quad_color: RGBA(f32),
    comptime anchor_point: AnchorPoint,
) QuadFace(VertexType) {
    std.debug.assert(TypeOfField(VertexType, "x") == TypeOfField(VertexType, "y"));
    var base_quad = generateQuad(VertexType, extent, anchor_point);
    base_quad[0].color = quad_color;
    base_quad[1].color = quad_color;
    base_quad[2].color = quad_color;
    base_quad[3].color = quad_color;
    return base_quad;
}

// pub fn generateTriangleColored(comptime VertexType: type, center: geometry.Coordinates2D(TypeOfField(VertexType, "x")), size: f32, rotation: f32, quad_color: RGBA(f32)) QuadFace(VertexType) {

// const T = @TypeOf(center.x);
// const bl = geometry.Coordinates2D(T){ .x = center.x - size, .y = center.y + size };
// const tl = geometry.Coordinates2D(T){ .x = center.x - size, .y = center.y - size };
// const br = geometry.Coordinates2D(T){ .x = center.x + size, .y = center.y + size };
// const tr = geometry.Coordinates2D(T){ .x = center.x + size, .y = center.y - size };

// return [_]VertexType{
// .{
// // Top Left
// .x = (tl.x - center.x) * @cos(rotation) - (tl.y - center.y) * @sin(rotation) + center.x,
// .y = (tl.y - center.y) * @cos(rotation) + (tl.x - center.x) * @sin(rotation) + center.y,
// .color = quad_color,
// },
// .{
// // Top Right
// .x = (tr.x - center.x) * @cos(rotation) - (tr.y - center.y) * @sin(rotation) + center.x,
// .y = (tr.y - center.y) * @cos(rotation) + (tr.x - center.x) * @sin(rotation) + center.y,
// .color = quad_color,
// },
// .{
// // Bottom Right
// .x = (br.x - center.x) * @cos(rotation) - (br.y - center.y) * @sin(rotation) + center.x,
// .y = (br.y - center.y) * @cos(rotation) + (br.x - center.x) * @sin(rotation) + center.y,
// .color = quad_color,
// },
// .{
// // Bottom Left
// .x = (bl.x - center.x) * @cos(rotation) - (bl.y - center.y) * @sin(rotation) + center.x,
// .y = (bl.y - center.y) * @cos(rotation) + (bl.x - center.x) * @sin(rotation) + center.y,
// .color = quad_color,
// },
// };
// }

pub fn generateTriangleColoredRight(comptime VertexType: type, extent: geometry.Extent2D(TypeOfField(VertexType, "x")), quad_color: RGBA(f32)) QuadFace(VertexType) {
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
            .x = extent.x + extent.width,
            .y = extent.y - (extent.height / 2.0),
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

pub fn generateTriangleColoredLeft(comptime VertexType: type, extent: geometry.Extent2D(TypeOfField(VertexType, "x")), quad_color: RGBA(f32)) QuadFace(VertexType) {
    std.debug.assert(TypeOfField(VertexType, "x") == TypeOfField(VertexType, "y"));

    return [_]VertexType{
        .{
            // Top Left
            .x = extent.x,
            .y = extent.y - (extent.height / 2.0),
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
            .y = extent.y - (extent.height / 2.0),
            .color = quad_color,
        },
    };
}
