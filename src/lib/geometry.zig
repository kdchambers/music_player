// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");

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

pub inline fn Pixel(comptime Type: type) type {
    // TODO: Add error checking to type
    return Type;
}

pub inline fn Normalized(comptime Type: type) type {
    // TODO: Add error checking to type
    return Type;
}

pub fn TypeFor(comptime coordinate_system: CoordinateSystem) type {
    return switch (coordinate_system) {
        .percentage, .ndc_right, .normalized => f32,
        .pixel, .millimeter, .carthesian => u32,
        .pixel16 => u16,
    };
}

pub fn Coordinates2D(comptime BaseType: type) type {
    return packed struct {
        x: BaseType,
        y: BaseType,
    };
}

pub fn Dimensions2D(comptime BaseType: type) type {
    return packed struct {
        height: BaseType,
        width: BaseType,
    };
}

pub fn Extent2D(comptime BaseType: type) type {
    return packed struct {
        x: BaseType,
        y: BaseType,
        height: BaseType,
        width: BaseType,
    };
}

pub fn ScaleFactor2D(comptime BaseType: type) type {
    return packed struct {
        horizontal: BaseType,
        vertical: BaseType,
    };
}

pub const Axis = enum(u8) {
    none,
    horizontal,
    vertical,
    diagnal,
};

pub const AnchorType = enum(u8) {
    center,
    bottom_left,
    bottom_right,
    top_left,
    top_right,
};

pub const ScreenReference = enum(u8) {
    left,
    right,
    top,
    bottom,
};

// pub inline fn axis(distance: f32, comptime reference: ScreenReference) f32 {
// //
// }

pub fn Scale2D(comptime BaseType: type) type {
    return packed struct {
        x: BaseType,
        y: BaseType,
    };
}

pub fn Shift2D(comptime BaseType: type) type {
    return packed struct {
        x: BaseType,
        y: BaseType,
    };
}

// TODO: Remove
pub const percentage = percentageToNativeDeviceCoordinates;
pub const pixel = pixelToNativeDeviceCoordinateRight;

pub fn percentageToNativeDeviceCoordinates(percent: f32) f32 {
    std.debug.assert(percent >= -1.0 and percent <= 1.0);
    return percent / 2.0;
}

/// Converts a Coordinates2D structure using absolute pixel values to one
/// that uses Native Device Coordinates, normalized between -1.0 and 1.0
/// The scale factor can be calculated using the absolute screen dimensions as follows:
/// scale_factor = ScaleFactor2D{ .horizontal = 2.0 / screen_dimensions.width, .veritical = 2.0 / screen_dimensions.height};
fn coordinates2DPixelToNativeDeviceCoordinateRight(
    coordinates: Coordinates2D(.pixel),
    scale_factor: ScaleFactor2D,
) Coordinates2D {
    return .{
        .x = coordinates.x * scale_factor.horizontal,
        .y = coordinates.y * scale_factor.vertical,
    };
}

/// Converts an absolute pixel value into a Native Device Coordinates value that is
/// normalized between -1.0 and 1.0
/// The scale factor can be calculated using the absolute screen dimensions as follows:
/// scale_factor = ScaleFactor2D{ .horizontal = 2.0 / screen_dimensions.width, .veritical = 2.0 / screen_dimensions.height};
pub fn pixelToNativeDeviceCoordinateRight(pixel_value: u32, scale_factor: f32) f32 {
    return -1.0 + @intToFloat(f32, pixel_value) * scale_factor;
}
