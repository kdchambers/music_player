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
const LibraryNavigator = @import("LibraryNavigator");
const audio = @import("audio");
const memory = @import("memory");
const navigation = @import("navigation.zig").navigation;

const ScreenScaleFactor = graphics.ScreenScaleFactor(.{ .NDCRightType = ScreenNormalizedBaseType, .PixelType = ScreenPixelBaseType });

const ui = @This();

// bind(event, action_list);

// const toggle_button = playlist_buttons.toggle.create(extent, theme);
// toggle_button_widget = try toggle_button.draw(&face_writer, scale_factor);
//
// event_system.bind(toggle_button_widget.onClickedLeft(), toggle_button_widget.doToggle());

// Things that would force a redraw but not change event bindings..

// 1. Screen resize
// 2.

// Ok, well how should I not bind actions to events?
//

pub const Widget = struct {
    face_index: u16,
    face_count: u16,
    extent: geometry.Extent2D(ScreenNormalizedBaseType),
};

pub const ActionChangeColor = struct {
    color_index: u8,
    face_count: u8,
    face_index: u16,
};

const Action = enum(u8) {
    none = 0,
    set_color,
};

var arena: memory.LinearArena = undefined;

pub fn reset() void {
    gui.reset();
}

pub const playlist_buttons = struct {
    pub const toggle = struct {
        pub fn draw(
            face_writer: *QuadFaceWriter(GenericVertex),
            scale_factor: ScreenScaleFactor,
            theme: Theme,
        ) !Widget {
            const start_face_index = face_writer.used;
            const media_button_placement = geometry.Coordinates2D(ScreenNormalizedBaseType){
                .x = 0.0 - (10 * scale_factor.horizontal),
                .y = 0.935,
            };

            const media_button_paused_dimensions = geometry.Dimensions2D(ScreenNormalizedBaseType){
                .width = 20 * scale_factor.horizontal,
                .height = 20 * scale_factor.vertical,
            };
            // const media_button_resumed_dimensions = geometry.Dimensions2D(ScreenNormalizedBaseType){
            // .width = 4 * scale_factor.horizontal,
            // .height = 15 * scale_factor.vertical,
            // };

            const media_button_paused_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = media_button_placement.x,
                .y = media_button_placement.y,
                .width = media_button_paused_dimensions.width,
                .height = media_button_paused_dimensions.height,
            };

            // const media_button_resumed_inner_gap: f32 = 6 * scale_factor.horizontal;
            // const media_button_resumed_width: f32 = media_button_resumed_dimensions.width;

            // const media_button_resumed_left_extent = geometry.Extent2D(ScreenNormalizedBaseType){
            // .x = media_button_placement.x,
            // .y = media_button_placement.y,
            // .width = media_button_resumed_width,
            // .height = media_button_resumed_dimensions.height,
            // };

            // const media_button_resumed_right_extent = geometry.Extent2D(ScreenNormalizedBaseType){
            // .x = media_button_placement.x + media_button_resumed_width + media_button_resumed_inner_gap,
            // .y = media_button_placement.y,
            // .width = media_button_resumed_width,
            // .height = media_button_resumed_dimensions.height,
            // };

            // var playing_icon_faces: [2]graphics.QuadFace(GenericVertex) = undefined;
            // playing_icon_faces[0] = graphics.generateQuadColored(GenericVertex, media_button_resumed_left_extent, theme.media_button);
            // playing_icon_faces[1] = graphics.generateQuadColored(GenericVertex, media_button_resumed_right_extent, theme.media_button);

            // _ = action.inactive_vertices_attachments.append(playing_icon_faces[0]);
            // _ = action.inactive_vertices_attachments.append(playing_icon_faces[1]);

            // Generate our Media (pause / resume) button

            // const media_button_paused_quad_index = face_writer.used;

            // NOTE: Even though we only need one face to generate a triangle,
            // we need to reserve a second for the resumed icon
            var media_button_paused_faces = try face_writer.allocate(2);

            media_button_paused_faces[0] = graphics.generateTriangleColoredRight(GenericVertex, media_button_paused_extent, theme.media_button);
            media_button_paused_faces[1] = GenericVertex.nullFace();

            // TODO:
            // _ = action.system_actions.append(undefined);
            // return event_system.registerMouseLeftPressAction(media_button_paused_extent);

            // Let's add a second left_click event emitter to change the icon
            // const media_button_on_left_click_event_id = event_system.registerMouseLeftPressAction(media_button_paused_extent);
            // _ = media_button_on_left_click_event_id;

            // // Needs to fit into a u10
            // std.debug.assert(media_button_paused_quad_index <= std.math.pow(u32, 2, 10));

            // const media_button_update_icon_action_payload = action.PayloadVerticesUpdate{
            // .loaded_vertex_begin = @intCast(u10, media_button_paused_quad_index),
            // .loaded_vertex_count = 1,
            // .alternate_vertex_begin = 0,
            // .alternate_vertex_count = 2, // Number of faces
            // };

            // // Action type set to .none so that action is disabled initially
            // const media_button_update_icon_action = action.Action{
            // .action_type = .none,
            // .payload = .{ .update_vertices = media_button_update_icon_action_payload },
            // };
            // const update_icon_action_id = action.system_actions.append(media_button_update_icon_action);
            // std.log.info("Update icon action id: {d}", .{update_icon_action_id});

            // // Setup a Pause Action

            // // TODO: Change extent
            // const media_button_on_left_click_event_id_2 = event_system.registerMouseLeftPressAction(media_button_paused_extent);
            // const media_button_audio_pause_action_payload = action.PayloadAudioPause{};

            // const media_button_audio_pause_action = action.Action{
            // .action_type = .none,
            // .payload = .{ .audio_pause = media_button_audio_pause_action_payload },
            // };
            // std.debug.assert(media_button_on_left_click_event_id_2 == action.system_actions.append(media_button_audio_pause_action));

            return Widget{
                .face_index = start_face_index,
                .face_count = face_writer.used - start_face_index,
                .extent = media_button_paused_extent,
            };
        }
    };

    pub const next = struct {
        pub fn draw(
            face_writer: *QuadFaceWriter(GenericVertex),
            scale_factor: ScreenScaleFactor,
            theme: Theme,
        ) !void {
            var faces = try face_writer.allocate(2);
            {
                const extent = geometry.Extent2D(ScreenNormalizedBaseType){
                    .x = 0.0 + (35 * scale_factor.horizontal),
                    .y = 0.93,
                    .width = 10 * scale_factor.horizontal,
                    .height = 12 * scale_factor.vertical,
                };
                faces[0] = graphics.generateTriangleColoredRight(GenericVertex, extent, theme.media_button);
            }
            {
                const extent = geometry.Extent2D(ScreenNormalizedBaseType){
                    .x = 0.0 + (45 * scale_factor.horizontal),
                    .y = 0.93,
                    .width = 3 * scale_factor.horizontal,
                    .height = 12 * scale_factor.vertical,
                };
                faces[1] = graphics.generateQuadColored(GenericVertex, extent, theme.media_button, .center);
            }
        }
    };

    pub const previous = struct {
        pub fn draw(
            face_writer: *QuadFaceWriter(GenericVertex),
            scale_factor: ScreenScaleFactor,
            theme: Theme,
        ) !void {
            var faces = try face_writer.allocate(2);
            {
                const extent = geometry.Extent2D(ScreenNormalizedBaseType){
                    .x = 0.0 - (50 * scale_factor.horizontal),
                    .y = 0.93,
                    .width = 10 * scale_factor.horizontal,
                    .height = 12 * scale_factor.vertical,
                };
                faces[0] = graphics.generateTriangleColoredLeft(GenericVertex, extent, theme.media_button);
            }
            {
                const extent = geometry.Extent2D(ScreenNormalizedBaseType){
                    .x = 0.0 - (50 * scale_factor.horizontal) - (3 * scale_factor.horizontal),
                    .y = 0.93,
                    .width = 3 * scale_factor.horizontal,
                    .height = 12 * scale_factor.vertical,
                };
                faces[1] = graphics.generateQuadColored(GenericVertex, extent, theme.media_button, .center);
            }
        }
    };
};

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
        faces[0] = graphics.generateQuadColored(GenericVertex, extent, theme.footer_background, .bottom_left);
    }
};

pub const track_view = struct {
    pub fn draw(
        face_writer: *QuadFaceWriter(GenericVertex),
        track_title_list: []const []const u8,
        glyph_set: GlyphSet,
        scale_factor: ScreenScaleFactor,
        theme: Theme,
    ) !void {
        // const track_item_background_color_index = action.color_list.append(theme.track_background);
        // const track_item_on_hover_color_index = action.color_list.append(theme.track_background_hovered);

        for (track_title_list) |track_title, track_index| {
            const track_name = track_title; // track_metadata.title[0..track_metadata.title_length];

            std.debug.assert(track_name.len > 0);
            std.log.info("Track name: '{s}'", .{track_name});

            const track_item_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = 0.2,
                .y = -0.7 + (@intToFloat(f32, track_index) * (30 * scale_factor.vertical)),
                .width = 600 * scale_factor.horizontal,
                .height = 30 * scale_factor.vertical,
            };

            var action_config = gui.button.ActionConfig{
                .on_hover_color_opt = @intCast(u8, gui.color_list.append(theme.track_background_hovered)),
            };

            // const track_item_quad_index = face_writer.*.used;

            const track_item_faces = try gui.button.generate(
                GenericVertex,
                face_writer,
                glyph_set,
                track_name,
                track_item_extent,
                scale_factor,
                theme.track_background,
                theme.track_text,
                .left,
                action_config,
                .top_left,
            );
            _ = track_item_faces;

            // const track_item_on_left_click_event_id = event_system.registerMouseLeftPressAction(track_item_extent);

            // const track_item_audio_play_action_payload = action.PayloadAudioPlay{
            // .id = @intCast(u16, track_index),
            // };

            // const track_item_audio_play_action = action.Action{ .action_type = .audio_play, .payload = .{ .audio_play = track_item_audio_play_action_payload } };
            // std.debug.assert(track_item_on_left_click_event_id == action.system_actions.append(track_item_audio_play_action));

            // const track_item_on_hover_event_ids = event_system.registerMouseHoverReflexiveEnterAction(track_item_extent);

            // // Index of the quad face (I.e Mulples of 4 faces) within the face allocator
            // // const track_item_quad_index = calculateQuadIndex(vertices, track_item_faces);

            // const track_item_update_color_vertex_attachment_index = @intCast(u8, action.vertex_range_attachments.append(
            // .{ .vertex_begin = track_item_quad_index, .vertex_count = gui.button.face_count },
            // ));

            // const track_item_update_color_enter_action_payload = action.PayloadColorSet{
            // .vertex_range_begin = track_item_update_color_vertex_attachment_index,
            // .vertex_range_span = 1,
            // .color_index = @intCast(u8, track_item_on_hover_color_index),
            // };

            // const track_item_update_color_exit_action_payload = action.PayloadColorSet{
            // .vertex_range_begin = track_item_update_color_vertex_attachment_index,
            // .vertex_range_span = 1,
            // .color_index = @intCast(u8, track_item_background_color_index),
            // };

            // const track_item_update_color_enter_action = action.Action{ .action_type = .color_set, .payload = .{ .color_set = track_item_update_color_enter_action_payload } };
            // const track_item_update_color_exit_action = action.Action{ .action_type = .color_set, .payload = .{ .color_set = track_item_update_color_exit_action_payload } };

            // std.debug.assert(track_item_on_hover_event_ids[0] == action.system_actions.append(track_item_update_color_enter_action));
            // std.debug.assert(track_item_on_hover_event_ids[1] == action.system_actions.append(track_item_update_color_exit_action));
        }
    }
};

const ScreenUnitTag = enum {
    pixel,
    percentage,
};

const ScreenUnit = union(ScreenUnitTag) {
    pixel: ScreenPixelBaseType,
    percentage: f32,
};

const ScreenExtent = struct {
    x: ScreenUnit,
    y: ScreenUnit,
    width: ScreenUnit,
    height: ScreenUnit,
};

pub const directory_view = struct {
    pub fn draw(
        face_writer: *QuadFaceWriter(GenericVertex),
        directory_name_list: [][]const u8,
        glyph_set: GlyphSet,
        scale_factor: ScreenScaleFactor,
        theme: Theme,
        max_extent: geometry.Extent2D(ScreenNormalizedBaseType),
        anchor_point: graphics.AnchorPoint,
    ) !void {
        const max_dimensions_pixels = scale_factor.ndcRightDimensionsToPixel(.{
            .width = max_extent.width,
            .height = max_extent.height,
        });

        if (max_dimensions_pixels.width < 200 or max_dimensions_pixels.height < 200) {
            return error.InvalidScreenSpaceConstaint;
        }

        const item_width_pixels: u32 = 200;
        const item_height_pixels: u32 = 100;

        const item_width = scale_factor.convertLength(.pixel, .ndc_right, .horizontal, item_width_pixels);
        const item_height = scale_factor.convertLength(.pixel, .ndc_right, .vertical, item_height_pixels);

        const items_per_row = @floatToInt(u32, max_extent.width / (item_width));
        const used_horizontal_space = item_width * @intToFloat(f32, items_per_row);
        std.debug.assert(used_horizontal_space <= max_extent.width);
        const remaining_space_horizontal = max_extent.width - used_horizontal_space;
        const horizontal_margin: f32 = remaining_space_horizontal / @intToFloat(f32, items_per_row + 1);

        const x_increment: f32 = horizontal_margin + item_width;
        const vertical_spacing: f32 = scale_factor.convertLength(.pixel, .ndc_right, .vertical, 30);

        var action_config = gui.button.ActionConfig{
            .on_hover_color_opt = @intCast(u8, gui.color_list.append(theme.folder_hovered)),
        };

        const do_select_directory = try navigation.doDirectorySelect();

        std.log.info("Actions created: {d}. Directories {d}", .{ do_select_directory.action_count, directory_name_list.len });
        std.debug.assert(do_select_directory.action_count == directory_name_list.len);

        for (directory_name_list) |directory_name, directory_name_i| {
            // TODO:
            const directory_name_full = directory_name;
            var temp_name_buffer: [20]u8 = undefined;

            // Elide directory paths to 20 charactors
            const directory_name_elipsed = blk: {
                if (directory_name_full.len > 20) {
                    std.mem.copy(u8, temp_name_buffer[0..], directory_name_full[0..17]);
                    temp_name_buffer[17] = '.';
                    temp_name_buffer[18] = '.';
                    temp_name_buffer[19] = '.';
                    break :blk temp_name_buffer[0..20];
                }
                break :blk directory_name_full;
            };

            const x: u32 = @intCast(u32, directory_name_i) % items_per_row;
            const y: u32 = @intCast(u32, directory_name_i) / items_per_row;

            const media_item_placement = geometry.Coordinates2D(ScreenNormalizedBaseType){
                .x = horizontal_margin + max_extent.x + @intToFloat(f32, x) * x_increment,
                .y = max_extent.y + (@intToFloat(f32, y) * (item_height + vertical_spacing)),
            };

            const media_item_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = media_item_placement.x,
                .y = media_item_placement.y,
                .width = item_width,
                .height = item_height,
            };

            action_config.on_click_left_action_list[0] = event_system.SubsystemActionIndex{
                .index = @intCast(event_system.ActionIndex, do_select_directory.base_action_index + directory_name_i),
                .subsystem = do_select_directory.subsystem,
            };

            _ = try gui.button.generate(
                GenericVertex,
                face_writer,
                glyph_set,
                directory_name_elipsed,
                media_item_extent,
                scale_factor,
                theme.folder_background,
                theme.folder_text,
                .center,
                action_config,
                anchor_point,
            );
        }
    }
};

pub const directory_up_button = struct {
    pub fn draw(
        face_writer: *QuadFaceWriter(GenericVertex),
        glyph_set: GlyphSet,
        scale_factor: ScreenScaleFactor,
        theme: Theme,
    ) !void {
        const button_extent = geometry.Extent2D(ScreenNormalizedBaseType){
            .x = -0.95,
            .y = -0.72,
            .width = 50 * scale_factor.horizontal,
            .height = 25 * scale_factor.vertical,
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
            .{},
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
        scale_factor: ScreenScaleFactor,
        theme: Theme,
    ) !void {
        const extent = geometry.Extent2D(ScreenNormalizedBaseType){
            .x = -1.0,
            .y = -1.0,
            .width = 2.0,
            .height = 0.2,
        };
        (try face_writer.create()).* = graphics.generateQuadColored(GenericVertex, extent, theme.header_background, .top_left);

        const label = "MUSIC PLAYER -- DEMO APPLICATION";
        const rendered_label_dimensions = try gui.calculateRenderedTextDimensions(label, glyph_set, scale_factor, 0.0, 4 * scale_factor.horizontal);
        const label_origin = geometry.Coordinates2D(ScreenNormalizedBaseType){
            .x = 0.0 - (rendered_label_dimensions.width / 2.0),
            .y = -0.9 + (rendered_label_dimensions.height / 2.0),
        };

        _ = try gui.generateText(
            GenericVertex,
            face_writer,
            label,
            label_origin,
            scale_factor,
            glyph_set,
            theme.header_text,
            null,
        );
    }
};

pub const progress_bar = struct {
    pub const background = struct {
        pub fn draw(
            face_writer: *QuadFaceWriter(GenericVertex),
            scale_factor: ScreenScaleFactor,
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
            (try face_writer.create()).* = graphics.generateQuadColored(GenericVertex, progress_bar_extent, theme.progress_bar_background, .bottom_left);
        }
    };

    pub const foreground = struct {
        pub fn draw(
            face_writer: *QuadFaceWriter(GenericVertex),
            progress_percentage: f32,
            scale_factor: ScreenScaleFactor,
            theme: Theme,
        ) !u16 {
            const width: f32 = 1.0;
            const margin: f32 = (2.0 - width) / 2.0;

            const inner_margin_horizontal: f32 = 0.005;
            const inner_margin_vertical: f32 = 1 * scale_factor.vertical;

            const extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = -1.0 + margin + inner_margin_horizontal,
                .y = 0.8 - inner_margin_vertical,
                .width = width - (inner_margin_horizontal * 2.0),
                .height = 6 * scale_factor.vertical,
            };

            const audio_progress_bar_faces_quad_index: u16 = face_writer.*.used;

            std.debug.assert(progress_percentage >= 0.0 and progress_percentage <= 1.0);
            const progress_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = extent.x,
                .y = extent.y,
                .width = extent.width * progress_percentage,
                .height = extent.height,
            };

            var faces = try face_writer.allocate(1);
            faces[0] = graphics.generateQuadColored(GenericVertex, progress_extent, theme.progress_bar_foreground, .bottom_left);
            return audio_progress_bar_faces_quad_index;
        }
    };
};
