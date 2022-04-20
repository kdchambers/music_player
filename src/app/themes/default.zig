// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const Color = @import("graphics").RGBA(f32);
const Theme = @import("../Theme.zig").Theme;

fn fromInt(r: u8, g: u8, b: u8) Color {
    return Color.fromInt(u8, r, g, b, 255);
}

pub const theme = Theme{
    .navigation_background = fromInt(100, 104, 105),
    .progress_bar_background = fromInt(88, 196, 195),
    .progress_bar_foreground = fromInt(40, 51, 51),
    .header_background = fromInt(40, 34, 49),
    .footer_background = fromInt(40, 34, 49),
    .folder_background = fromInt(80, 84, 85),
    .folder_hovered = fromInt(80, 184, 85),
    .folder_text = fromInt(200, 200, 200),
    .track_background = fromInt(158, 28, 76),
    .track_background_hovered = fromInt(158, 128, 76),
    .track_text = fromInt(58, 28, 76),
    .media_button = fromInt(255, 255, 255),
    .header_text = fromInt(230, 230, 230),
    .track_artist_text = fromInt(230, 230, 230),
    .track_title_text = fromInt(210, 210, 210),
    .track_hover = fromInt(230, 230, 230),
    .return_button_background = fromInt(111, 125, 112),
    .return_button_foreground = fromInt(20, 20, 20),
    .return_button_background_hovered = fromInt(80, 20, 80),
};
