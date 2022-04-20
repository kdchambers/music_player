// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const graphics = @import("graphics");
const Color = graphics.RGBA(f32);
const gui = @import("gui");
const GenericVertex = graphics.GenericVertex;
const QuadFaceWriter = gui.QuadFaceWriter;
const QuadFace = graphics.QuadFace;
const FixedBuffer = @import("memory").FixedBuffer;

pub const action = @This();

pub const set_color = struct {
    color_list: []Color,
};

// NOTE: You can have a "Complex" Action type that supports non-primative actions + flags
//       That will atleast give us the property of not paying for what we don't use.

// THINK:
// You need to be able to configure all the valid actions at comptime and then have each widget be
// able to return

// Or maybe I can expose a global that is used by the library layer

pub const ActionType = enum(u8) {
    none,
    color_set,
    update_vertices,
    custom,
    audio_play,
    audio_pause,
    audio_resume,
    directory_select,
    // multi
};

// Limit of 64 is based on alternate_vertex_count being u6
pub var inactive_vertices_attachments: FixedBuffer(QuadFace(GenericVertex), 64) = .{};

pub const VertexRange = packed struct {
    vertex_begin: u24,
    vertex_count: u8,
};

// 2 * 20 = 40 bytes
pub var vertex_range_attachments: FixedBuffer(VertexRange, 40) = .{};
pub const PayloadColorSet = packed struct {
    vertex_range_begin: u8,
    vertex_range_span: u8,
    color_index: u8,
};

pub const PayloadColorSet2 = packed struct {
    vertex_range_begin: u8,
    vertex_range_span: u7,
    reflexive: bool,
    color_index: u8,
};

pub const PayloadSetAction = packed struct {
    action_type: ActionType,
    index: u16,
};

pub const PayloadVerticesUpdate = packed struct {
    loaded_vertex_begin: u10,
    alternate_vertex_begin: u6,
    loaded_vertex_count: u4,
    alternate_vertex_count: u4,
};

pub const PayloadRedirect = packed struct {
    action_1: u12,
    action_2: u12,
};

pub const PayloadAudioResume = packed struct {
    dummy: u24 = undefined,
};

pub const PayloadAudioPause = packed struct {
    dummy: u24 = undefined,
};

pub const PayloadCustom = packed struct {
    id: u16,
    dummy: u8 = undefined,
};

pub const PayloadAudioPlay = packed struct {
    id: u16,
    dummy: u8 = undefined,
};

pub const PayloadDirectorySelect = packed struct {
    directory_id: u16,
    dummy: u8 = undefined,
};

pub const Payload = packed union {
    color_set: PayloadColorSet,
    audio_play: PayloadAudioPlay,
    audio_pause: PayloadAudioPause,
    audio_resume: PayloadAudioResume,
    update_vertices: PayloadVerticesUpdate,
    redirect: PayloadRedirect,
    directory_select: PayloadDirectorySelect,
    custom: PayloadCustom,
};

// NOTE: Making this struct packed appears to trigger a compile bug that prevents
//       arrays from being indexed properly. Probably the alignment is incorrect
pub const Action = struct {
    action_type: ActionType,
    payload: Payload,
};

pub var color_list: FixedBuffer(Color, 30) = undefined;
pub var color_list_mutable: FixedBuffer(Color, 10) = undefined;
pub var system_actions: FixedBuffer(Action, 100) = .{};
