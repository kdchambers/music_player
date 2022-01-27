// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

// TODO: Revisit this concept
const CoordinateSystem = enum(u4) {
    percentage,
    pixel,
    pixel16, // TODO
    millimeter,
    normalized,

    // Generic unnormalized type
    carthesian,

    // Vulkan Native
    ndc_right,
};

/// Return the underlying type used to represent the given coordinate system
fn BaseType(comptime coordinate_system: CoordinateSystem) type {
    return switch (coordinate_system) {
        .percentage, .ndc_right, .normalized => f32,
        .pixel, .millimeter, .carthesian => u32,
        .pixel16 => u16,
    };
}

pub fn Coordinates2D(comptime coordinate_system: CoordinateSystem) type {
    return packed struct {
        x: BaseType(coordinate_system),
        y: BaseType(coordinate_system),
    };
}

pub fn Dimensions2D(comptime coordinate_system: CoordinateSystem) type {
    return packed struct {
        height: BaseType(coordinate_system),
        width: BaseType(coordinate_system),
    };
}

pub fn Extent2D(comptime coordinate_system: CoordinateSystem) type {
    return packed struct {
        x: BaseType(coordinate_system),
        y: BaseType(coordinate_system),
        height: BaseType(coordinate_system),
        width: BaseType(coordinate_system),
    };
}

pub const ScaleFactor2D = packed struct {
    horizontal: f32,
    vertical: f32,
};

pub fn Scale2D(comptime T: type) type {
    return packed struct {
        x: T,
        y: T,
    };
}

pub fn Shift2D(comptime T: type) type {
    return packed struct {
        x: T,
        y: T,
    };
}

pub fn translate(comptime coordinate_system: CoordinateSystem, comptime BaseType: type, coordinate_list: []BaseType, translation: geometry.Coordinates2D(coordinate_system)) void {
    for (coordinate_list) |*coordinate| {
        coordinate.x += translation.x;
        coordinate.y += translation.y;
    }
}

/// Converts a Coordinates2D structure using absolute pixel values to one
/// that uses Native Device Coordinates, normalized between -1.0 and 1.0
/// The scale factor can be calculated using the absolute screen dimensions as follows:
/// scale_factor = ScaleFactor2D{ .horizontal = 2.0 / screen_dimensions.width, .veritical = 2.0 / screen_dimensions.height};
fn coordinates2DPixelToNativeDeviceCoordinateRight(
    coordinates: Coordinates2D(.pixel),
    scale_factor: ScaleFactor2D,
) geometry.Coordinates2D {
    return .{
        .x = coordinates.x * scale_factor.horizontal,
        .y = coordinates.y * scale_factor.vertical,
    };
}

/// Converts an absolute pixel value into a Native Device Coordinates value that is
/// normalized between -1.0 and 1.0
/// The scale factor can be calculated using the absolute screen dimensions as follows:
/// scale_factor = ScaleFactor2D{ .horizontal = 2.0 / screen_dimensions.width, .veritical = 2.0 / screen_dimensions.height};
pub fn pixelToNativeDeviceCoordinateRight(pixel: u32, scale_factor: f32) f32 {
    return @intToFloat(f32, pixel) * scale_factor;
}
