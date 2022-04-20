// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const navigation = @import("navigation.zig");
const memory = @import("memory");
const event_system = @import("event_system");
const audio = @import("audio");
const storage = @import("storage");

var play_list: memory.FixedBuffer([]const u8, 60) = .{};

const ActionType = enum(u8) {
    play,
    stop,
    pause,
    next,
    previous,
};

var submodule_index: event_system.SubsystemIndex = undefined;

pub fn init(track_id_list: []u16) void {
    //
}

pub fn doPlayTrack() event_system.SubsystemActionRange {

    //
}

pub fn doAction(action_index: event_system.ActionIndex) void {
    const action_id: u32 = 0;
    audio.mp3.play(storage.getPath(action_id).fullPath());
}

const Playlist = struct {
    track_count: u16,
    track_ids: [*]u16,

    pub fn init(arena: memory.LinearArena) void {
        //
    }
};
