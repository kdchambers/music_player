// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const graphics = @import("graphics");
const Color = graphics.RGBA(f32);

pub const Theme = @This();

navigation_background: Color,
progress_bar_background: Color,
progress_bar_foreground: Color,
header_background: Color,
footer_background: Color,
folder_background: Color,
folder_hovered: Color,
folder_text: Color,
track_background: Color,
track_background_hovered: Color,
track_text: Color,
media_button: Color,
header_text: Color,
track_artist_text: Color,
track_title_text: Color,
track_hover: Color,
return_button_background: Color,
return_button_background_hovered: Color,
return_button_foreground: Color,

pub const default = @import("themes/default.zig").theme;
