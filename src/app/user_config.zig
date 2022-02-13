// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const graphics = @import("graphics");
const RGBA = graphics.RGBA;

const user_config = @This();

pub const background_color = RGBA(f32).fromInt(u8, 30, 30, 35, 255);
