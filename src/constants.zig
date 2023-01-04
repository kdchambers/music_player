// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");
const RGBA = graphics.RGBA;

pub const ScreenPixelBaseType = u16;
pub const ScreenNormalizedBaseType = f32;

pub const TexturePixelBaseType = u16;
pub const TextureNormalizedBaseType = f32;

/// This determines the size of charactors that will be
/// rendered to the font texture atlas.
/// It can be scaled down but to scale up will cause loss of quality
pub const max_font_size_pixels: u32 = 16;
pub const default_font_path: [:0]const u8 = "assets/Hack-Regular.ttf";

/// Application title (Not same as executable name) 
/// To be used in window decoration, etc
pub const application_title: [:0]const u8 = "music player demo";

/// These are the initial dimensions that glfw will be requested to create the window with
/// If it is not possible (E.g Due to being created within a tiling window manager) 
/// glfw will immediate change it
pub const initial_window_dimensions = geometry.Dimensions2D(ScreenPixelBaseType){
    .width = 800,
    .height = 600,
};

/// Dimensions of each element in the texture array 
/// NOTE 1: This will determine the maximum size of images that can be rendered 
/// NOTE 2: Maximum value for vulkan should be 4096
pub const texture_layer_dimensions = geometry.Dimensions2D(TexturePixelBaseType){
    .width = 512,
    .height = 512,
};

/// Size in bytes of each texture layer (Not including padding, etc)
pub const texture_layer_size: usize = @sizeOf(RGBA(f32)) * @intCast(u64, texture_layer_dimensions.width) * texture_layer_dimensions.height;
