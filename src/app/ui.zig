// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const geometry = @import("geometry");
const graphics = @import("graphics");
const gui = @import("gui");
const GenericVertex = graphics.GenericVertex;
const Theme = @import("Theme.zig");
const QuadFaceWriter = gui.QuadFaceWriter;
const ScreenNormalizedBaseType = @import("constants").ScreenNormalizedBaseType;
const ScreenPixelBaseType = @import("constants").ScreenPixelBaseType;
const TexturePixelBaseType = @import("constants").TexturePixelBaseType;
const GlyphSet = @import("text").GlyphSet;
const action = @import("action");
const event_system = @import("event_system");

const ui = @This();

const parent_directory_id = std.math.maxInt(u16);

pub const footer = struct {
    pub fn draw(face_writer: *QuadFaceWriter(GenericVertex), theme: Theme) !void {
        const extent = geometry.Extent2D(ScreenNormalizedBaseType){
            .x = -1.0,
            .y = 1.0,
            .width = 2.0,
            .height = 0.2,
        };
        var faces = try face_writer.allocate(1);
        faces[0] = graphics.generateQuadColored(GenericVertex, extent, theme.footer_background);
    }
};

pub const directory_up_button = struct {
    pub fn draw(
        face_writer: *QuadFaceWriter(GenericVertex),
        glyph_set: GlyphSet,
        scale_factor: geometry.ScaleFactor2D(ScreenNormalizedBaseType),
        texture_layer_dimensions: geometry.Dimensions2D(TexturePixelBaseType),
        theme: Theme,
    ) !void {
        const button_placement = geometry.Coordinates2D(ScreenNormalizedBaseType){ .x = -0.95, .y = -0.72 };
        const button_dimensions = geometry.Dimensions2D(ScreenPixelBaseType){ .width = 50, .height = 25 };

        const button_extent = geometry.Extent2D(ScreenNormalizedBaseType){
            .x = button_placement.x,
            .y = button_placement.y,
            .width = geometry.pixelToNativeDeviceCoordinateRight(button_dimensions.width, scale_factor.horizontal),
            .height = geometry.pixelToNativeDeviceCoordinateRight(button_dimensions.height, scale_factor.vertical),
        };

        const widget_index = face_writer.indexFromBase();

        _ = try gui.button.generate(
            GenericVertex,
            face_writer,
            glyph_set,
            "<",
            button_extent,
            scale_factor,
            theme.return_button_background,
            theme.return_button_foreground,
            .center,
            texture_layer_dimensions,
        );

        const button_color_index = action.color_list.append(theme.return_button_background);
        const on_hover_color_index = action.color_list.append(theme.return_button_background_hovered);

        // Index of the quad face (I.e Mulples of 4 faces) within the face allocator
        // const widget_index = calculateQuadIndex(vertices, faces);

        // NOTE: system_actions needs to correspond to given on_hover_event_ids here
        {
            const on_hover_event_ids = event_system.registerMouseHoverReflexiveEnterAction(button_extent);
            const vertex_attachment_index = @intCast(u8, action.vertex_range_attachments.append(.{ .vertex_begin = @intCast(u24, widget_index), .vertex_count = gui.button.face_count }));

            const on_hover_enter_action_payload = action.PayloadColorSet{
                .vertex_range_begin = vertex_attachment_index,
                .vertex_range_span = 1,
                .color_index = @intCast(u8, on_hover_color_index),
            };

            const on_hover_exit_action_payload = action.PayloadColorSet{
                .vertex_range_begin = vertex_attachment_index,
                .vertex_range_span = 1,
                .color_index = @intCast(u8, button_color_index),
            };

            const on_hover_exit_action = action.Action{ .action_type = .color_set, .payload = .{ .color_set = on_hover_exit_action_payload } };
            const on_hover_enter_action = action.Action{ .action_type = .color_set, .payload = .{ .color_set = on_hover_enter_action_payload } };

            std.debug.assert(on_hover_event_ids[0] == action.system_actions.append(on_hover_enter_action));
            std.debug.assert(on_hover_event_ids[1] == action.system_actions.append(on_hover_exit_action));
        }

        {
            //
            // When back button is clicked, change to parent directory
            //

            const on_click_event = event_system.registerMouseLeftPressAction(button_extent);

            const directory_select_parent_action_payload = action.PayloadDirectorySelect{ .directory_id = parent_directory_id };
            const directory_select_parent_action = action.Action{ .action_type = .directory_select, .payload = .{ .directory_select = directory_select_parent_action_payload } };

            std.debug.assert(on_click_event == action.system_actions.append(directory_select_parent_action));
        }
    }
};

pub const header = struct {
    pub fn draw(
        face_writer: *QuadFaceWriter(GenericVertex),
        glyph_set: GlyphSet,
        scale_factor: geometry.ScaleFactor2D(ScreenNormalizedBaseType),
        texture_layer_dimensions: geometry.Dimensions2D(TexturePixelBaseType),
        theme: Theme,
    ) !void {
        const extent = geometry.Extent2D(ScreenNormalizedBaseType){
            .x = -1.0,
            .y = -1.0 + 0.2,
            .width = 2.0,
            .height = 0.2,
        };
        (try face_writer.create()).* = graphics.generateQuadColored(GenericVertex, extent, theme.header_background);

        const label = "MUSIC PLAYER -- DEMO APPLICATION";
        const rendered_label_dimensions = try gui.calculateRenderedTextDimensions(label, glyph_set, scale_factor, 0.0, 4 * scale_factor.horizontal);
        const label_origin = geometry.Coordinates2D(ScreenNormalizedBaseType){
            .x = 0.0 - (rendered_label_dimensions.width / 2.0),
            .y = -0.9 + (rendered_label_dimensions.height / 2.0),
        };

        _ = try gui.generateText(GenericVertex, face_writer, label, label_origin, scale_factor, glyph_set, theme.header_text, null, texture_layer_dimensions);
    }
};

pub const progress_bar = struct {
    pub const background = struct {
        pub fn draw(
            face_writer: *QuadFaceWriter(GenericVertex),
            scale_factor: geometry.ScaleFactor2D(ScreenNormalizedBaseType),
            theme: Theme,
        ) !void {
            const progress_bar_width: f32 = 1.0;
            const progress_bar_margin: f32 = (2.0 - progress_bar_width) / 2.0;
            const progress_bar_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = -1.0 + progress_bar_margin,
                .y = 0.87,
                .width = progress_bar_width,
                .height = 8 * scale_factor.vertical,
            };
            (try face_writer.create()).* = graphics.generateQuadColored(GenericVertex, progress_bar_extent, theme.progress_bar_background);
        }
    };
};
