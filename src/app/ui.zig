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
const Playlist = @import("Playlist");

const ScreenScaleFactor = graphics.ScreenScaleFactor(.{
    .NDCRightType = ScreenNormalizedBaseType,
    .PixelType = ScreenPixelBaseType,
});

const ui = @This();

pub var subsystem_index: event_system.SubsystemIndex = undefined;

pub const ActionChangeColor = struct {
    color_index: u8,
    face_count: u8,
    face_index: u16,
};

const Action = enum(u8) {
    none = 0,
    set_color,
    progress_bar_start,
    progress_bar_stop,
};

var action_list: memory.FixedBuffer(Action, 20) = .{};
const parent_directory_id = std.math.maxInt(u16);

pub fn doStartProgressBar() event_system.ActionIndex {
    return @intCast(event_system.ActionIndex, action_list.append(.progress_bar_start));
}

pub fn doAction(index: event_system.ActionIndex) void {
    const act = action_list.items[index];
    switch (act) {
        .progress_bar_start => progress_bar.start(),
        .progress_bar_stop => progress_bar.stop(),
        else => unreachable,
    }
}

var arena: memory.LinearArena = undefined;

pub fn reset() void {
    gui.reset();
    action_list.clear();
}

pub const playlist_buttons = struct {
    pub const toggle = struct {
        pub fn draw(
            face_writer: *QuadFaceWriter(GenericVertex),
            scale_factor: ScreenScaleFactor,
            theme: Theme,
        ) !void {
            const media_button_placement = geometry.Coordinates2D(ScreenNormalizedBaseType){
                .x = 0.0 - (10 * scale_factor.horizontal),
                .y = 0.935,
            };

            const media_button_paused_dimensions = geometry.Dimensions2D(ScreenNormalizedBaseType){
                .width = 20 * scale_factor.horizontal,
                .height = 20 * scale_factor.vertical,
            };

            const media_button_paused_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = media_button_placement.x,
                .y = media_button_placement.y,
                .width = media_button_paused_dimensions.width,
                .height = media_button_paused_dimensions.height,
            };

            // NOTE: Even though we only need one face to generate a triangle,
            // we need to reserve a second for the resumed icon
            var media_button_paused_faces = try face_writer.allocate(2);

            media_button_paused_faces[0] = graphics.generateTriangleColoredRight(GenericVertex, media_button_paused_extent, theme.media_button);
            media_button_paused_faces[1] = GenericVertex.nullFace();
        }
    };

    pub const next = struct {
        pub fn draw(
            face_writer: *QuadFaceWriter(GenericVertex),
            scale_factor: ScreenScaleFactor,
            theme: Theme,
        ) !void {
            const combined_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = 0.0 + scale_factor.convertLength(.pixel, .ndc_right, .horizontal, 35),
                .y = 0.93,
                .width = scale_factor.convertLength(.pixel, .ndc_right, .horizontal, 45 + 3),
                .height = scale_factor.convertLength(.pixel, .ndc_right, .vertical, 12),
            };

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

            var action_writer = event_system.mouse_event_writer.addExtent(combined_extent);
            const next_track_command = [1]event_system.SubsystemActionIndex{.{
                .subsystem = Playlist.subsystem_index,
                .index = Playlist.doNextTrackPlay(),
            }};

            action_writer.onClickLeft(next_track_command[0..]);
        }
    };

    pub const previous = struct {
        pub fn draw(
            face_writer: *QuadFaceWriter(GenericVertex),
            scale_factor: ScreenScaleFactor,
            theme: Theme,
        ) !void {
            const combined_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = 0.0 - scale_factor.convertLength(.pixel, .ndc_right, .horizontal, 50),
                .y = 0.93,
                .width = scale_factor.convertLength(.pixel, .ndc_right, .horizontal, 10 + 3 + 6),
                .height = scale_factor.convertLength(.pixel, .ndc_right, .vertical, 12),
            };

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

            var action_writer = event_system.mouse_event_writer.addExtent(combined_extent);
            const previous_track_command = [1]event_system.SubsystemActionIndex{.{
                .subsystem = Playlist.subsystem_index,
                .index = Playlist.doPreviousTrackPlay(),
            }};

            action_writer.onClickLeft(previous_track_command[0..]);
        }
    };
};

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
        // NOTE: model_interface interface
        // entries() Entry
        //     title() []const u8
        //     artist() []const u8
        //     duration() []const u8
        //     path_index: SubPath.Index
        model_interface: anytype,
        glyph_set: GlyphSet,
        scale_factor: ScreenScaleFactor,
        theme: Theme,
        title: []const u8,
        draw_region: geometry.Extent2D(ScreenPixelBaseType),
    ) !void {
        std.debug.assert(draw_region.width >= 200);
        std.debug.assert(draw_region.height >= 200);

        const top_margin_pixels: u16 = 50;
        const top_margin = scale_factor.convertLength(.pixel, .ndc_right, .vertical, top_margin_pixels);

        const button_margin_pixels: u16 = 10;
        const button_margin = scale_factor.convertLength(.pixel, .ndc_right, .horizontal, button_margin_pixels);
        const text_region_width: u16 = draw_region.width - (button_margin_pixels * 2);

        const top_left_normalized = scale_factor.convertPoint(.pixel, .ndc_right, .{ .x = draw_region.x, .y = draw_region.y });

        const draw_region_normalized = geometry.Extent2D(ScreenNormalizedBaseType){
            .x = top_left_normalized.x,
            .y = top_left_normalized.y,
            .width = scale_factor.convertLength(.pixel, .ndc_right, .horizontal, draw_region.width),
            .height = scale_factor.convertLength(.pixel, .ndc_right, .vertical, draw_region.height),
        };

        const background_color = graphics.RGBA(f32){
            .r = 0.6,
            .g = 0.4,
            .b = 0.6,
            .a = 1.0,
        };

        (try face_writer.create()).* = graphics.generateQuadColored(GenericVertex, draw_region_normalized, background_color, .top_left);

        // TODO: Remove sanity checks when more stable
        std.debug.assert(model_interface.entries().len < 20);

        var duration_label_buffer: [10]u8 = undefined;
        const label_width = scale_factor.convertLength(.pixel, .ndc_right, .horizontal, text_region_width);

        for (model_interface.entries()) |track_entry, track_index| {
            const duration = Playlist.secondsToAudioDurationTime(track_entry.duration_seconds);
            const duration_label = try std.fmt.bufPrint(duration_label_buffer[0..], "{d:0>2}:{d:0>2}", .{ duration.minutes, duration.seconds });

            const button_label = track_entry.title();
            std.debug.assert(button_label.len > 0);

            const track_item_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = top_left_normalized.x + button_margin,
                .y = top_left_normalized.y + top_margin + (@intToFloat(f32, track_index) * (30 * scale_factor.vertical)),
                .width = label_width,
                .height = 30 * scale_factor.vertical,
            };

            // If the playlist isn't initialized, we want to initialize
            // and play track at the same time.
            const command_index = if (Playlist.storage_opt != null)
                Playlist.doPlayIndex(@intCast(u16, track_index))
            else
                Playlist.doInitAndPlayIndex(@intCast(u16, track_index));

            const play_track_action = event_system.SubsystemActionIndex{
                .subsystem = Playlist.subsystem_index,
                .index = command_index,
            };

            const null_action = event_system.SubsystemActionIndex.null_value;
            var action_config = gui.button.ActionConfig{
                .on_hover_color_opt = @intCast(u8, gui.color_list.append(theme.track_background_hovered)),
                .on_click_left_action_list = [4]event_system.SubsystemActionIndex{
                    play_track_action,
                    null_action,
                    null_action,
                    null_action,
                },
            };

            const track_item_faces = try gui.button.generate(
                GenericVertex,
                face_writer,
                glyph_set,
                button_label,
                track_item_extent,
                scale_factor,
                theme.track_background,
                theme.track_text,
                .left,
                action_config,
                .top_left,
            );
            _ = track_item_faces;

            // TODO: Fix dirty 0.0425 vertical alignment hack
            const duration_label_extent = try gui.calculateRenderedTextDimensions(duration_label, glyph_set, scale_factor, 0.1, 0);
            const duration_label_placement = geometry.Coordinates2D(ScreenNormalizedBaseType){
                .x = top_left_normalized.x + label_width - duration_label_extent.width,
                .y = top_left_normalized.y + 0.0425 + top_margin + (@intToFloat(f32, track_index) * (30 * scale_factor.vertical)),
            };

            _ = try gui.generateText(
                GenericVertex,
                face_writer,
                duration_label,
                duration_label_placement,
                scale_factor,
                glyph_set,
                theme.track_text,
                null,
            );
        }

        const title_placement = scale_factor.convertPoint(
            .pixel,
            .ndc_right,
            .{ .x = draw_region.x + 10, .y = draw_region.y + 30 },
        );

        _ = try gui.generateText(
            GenericVertex,
            face_writer,
            title,
            title_placement,
            scale_factor,
            glyph_set,
            theme.track_text,
            null,
        );
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

            if (media_item_extent.y + media_item_extent.height > (max_extent.y + max_extent.height)) {
                std.log.warn("Directory view item outside of render extent. Skipping", .{});
                continue;
            }

            action_config.on_click_left_action_list[0] = event_system.SubsystemActionIndex{
                .index = navigation.doDirectorySelect(@intCast(u8, directory_name_i)),
                .subsystem = navigation.subsystem_index,
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
    var progress_bar_face_quad_opt: ?*graphics.QuadFace(GenericVertex) = null;

    // TODO: Make global
    var stored_scale_factor: ?ScreenScaleFactor = null;
    // var stored_background_color: graphics.RGBA(f32) = undefined;
    // TODO: You have access to the existing color
    var stored_forground_color: graphics.RGBA(f32) = undefined;
    var stored_update_event_id: u16 = 0;

    const Config = struct {
        progress_bar_update_interval_milliseconds: u32 = 200,
        background_color: graphics.RGBA(f32) = undefined,
        foreground_color: graphics.RGBA(f32) = undefined,
    };

    pub fn update() void {
        if (progress_bar_face_quad_opt) |progress_bar_face_quad| {
            const progress = audio.output.progress() catch 0.0;
            std.log.info("Progress bar update: {d}", .{progress});
            foreground.draw(progress_bar_face_quad, progress, stored_scale_factor.?, stored_forground_color);
        } else {
            std.log.warn("Cannot update progress bar: Hasn't been initially created", .{});
        }
    }

    pub fn start() void {
        event_system.timeIntervalEventBegin(stored_update_event_id);
    }

    pub fn stop() void {
        std.debug.assert(false);
    }

    pub fn create(
        faces: []graphics.QuadFace(GenericVertex),
        scale_factor: ScreenScaleFactor,
        theme: Theme,
    ) void {
        std.debug.assert(faces.len == 2);
        stored_scale_factor = scale_factor;
        stored_forground_color = theme.progress_bar_foreground;

        const progress = audio.output.progress() catch 0.0;
        background.draw(&faces[0], scale_factor, theme.progress_bar_background);
        foreground.draw(&faces[1], progress, scale_factor, theme.progress_bar_foreground);
        progress_bar_face_quad_opt = &faces[1];
        stored_update_event_id = event_system.timeIntervalEventRegister(.{
            .interval_milliseconds = 300,
            .callback = &update,
        });
    }

    const progress_bar_width_pixels: u32 = 600;
    const progress_bar_height_pixels: u32 = 6;

    const background = struct {
        pub fn draw(
            face_quad: *graphics.QuadFace(GenericVertex),
            scale_factor: ScreenScaleFactor,
            color: graphics.RGBA(f32),
        ) void {
            const progress_bar_width: f32 = scale_factor.convertLength(.pixel, .ndc_right, .horizontal, progress_bar_width_pixels);
            const progress_bar_margin: f32 = (2.0 - progress_bar_width) / 2.0;
            const progress_bar_height = scale_factor.convertLength(.pixel, .ndc_right, .vertical, progress_bar_height_pixels);

            std.debug.assert(progress_bar_width + (progress_bar_margin * 2) == 2.0);

            const progress_bar_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = -1.0 + progress_bar_margin,
                .y = 0.87,
                .width = progress_bar_width,
                .height = progress_bar_height,
            };
            face_quad.* = graphics.generateQuadColored(GenericVertex, progress_bar_extent, color, .bottom_left);
        }
    };

    const foreground = struct {
        pub fn draw(
            face_quad: *graphics.QuadFace(GenericVertex),
            progress_percentage: f32,
            scale_factor: ScreenScaleFactor,
            color: graphics.RGBA(f32),
        ) void {
            const progress_bar_width: f32 = scale_factor.convertLength(.pixel, .ndc_right, .horizontal, progress_bar_width_pixels - 4);
            const progress_bar_margin: f32 = (2.0 - progress_bar_width) / 2.0;
            const vertical_margin_pixels: u32 = 1;
            const vertical_margin = scale_factor.convertLength(.pixel, .ndc_right, .vertical, vertical_margin_pixels);
            const progress_bar_height = scale_factor.convertLength(.pixel, .ndc_right, .vertical, progress_bar_height_pixels - (vertical_margin_pixels * 2));

            const extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = -1.0 + progress_bar_margin,
                .y = 0.87 - vertical_margin,
                .width = progress_bar_width,
                .height = progress_bar_height,
            };

            std.debug.assert(progress_percentage >= 0.0);
            std.debug.assert(progress_percentage <= 1.0);

            const progress_extent = geometry.Extent2D(ScreenNormalizedBaseType){
                .x = extent.x,
                .y = extent.y,
                .width = extent.width * progress_percentage,
                .height = extent.height,
            };

            face_quad.* = graphics.generateQuadColored(GenericVertex, progress_extent, color, .bottom_left);
        }
    };
};
