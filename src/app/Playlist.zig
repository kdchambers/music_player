// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const memory = @import("memory");
const audio = @import("audio");
const mini_addr = @import("storage");
const event_system = @import("event_system");
const String = mini_addr.String;
const AbsolutePath = mini_addr.AbsolutePath;
const SubPath = mini_addr.SubPath;
const FixedAtomicEventQueue = @import("message_queue").FixedAtomicEventQueue;
const navigation = @import("navigation.zig").navigation;

pub var subsystem_index: event_system.SubsystemIndex = undefined;

const Playlist = @This();

pub var storage_opt: ?*Storage = null;
var are_durations_available: bool = false;

const Event = enum(u8) {
    new_track_started,
    playlist_finished,
    duration_calculated,
    playlist_initialized,
};

const Command = struct {
    const play_audio_command_base: u8 = 0;
    const play_audio_range: u8 = 64;

    const init_and_play_audio_command_base: u8 = 64;
    const init_and_play_audio_range: u8 = 64;

    const command_base_index: u8 = 200;

    const track_next: u8 = command_base_index + 0;
    const track_previous: u8 = command_base_index + 1;
};

pub const AudioDurationTime = struct {
    seconds: u16,
    minutes: u16,
};

pub var output_events: FixedAtomicEventQueue(Event, 20) = .{};
var current_track_index_opt: ?u16 = null;

pub fn reset() void {
    _ = output_events.collect();
}

pub fn secondsToAudioDurationTime(seconds: u16) AudioDurationTime {
    var current_seconds: u16 = seconds;
    const current_minutes = blk: {
        var minutes: u16 = 0;
        while (current_seconds >= 60) {
            minutes += 1;
            current_seconds -= 60;
        }
        break :blk minutes;
    };

    return .{
        .seconds = current_seconds,
        .minutes = current_minutes,
    };
}

pub fn trackCount() u16 {
    //
}

fn calculateDurations(storage_arg: *Storage) void {
    for (storage_arg.entriesMut()) |*entry| {
        const absolute_path = entry.absolutePathZ() catch |err| {
            std.log.err("Failed to create absolute path for opening: Error -> {s}. Skipping", .{err});
            continue;
        };
        const file = std.fs.openFileAbsolute(absolute_path, .{ .mode = .read_only }) catch |err| {
            std.log.err("Failed to open file: {s} with err code {s}. Skipping", .{ absolute_path, err });
            continue;
        };
        errdefer file.close();

        const file_stat = file.stat() catch |err| {
            std.log.err("Failed to stat file {s}. Error -> {s}. Skipping", .{ absolute_path, err });
            continue;
        };

        const file_size = file_stat.size;
        var file_buffer = std.heap.page_allocator.alloc(u8, file_size) catch |err| {
            std.log.err("Failed to allocate {d} bytes for file {s}. Error -> {s}. Skipping", .{ file_size, absolute_path, err });
            continue;
        };
        errdefer std.heap.page_allocator.free(file_buffer);

        const bytes_read = file.readAll(file_buffer) catch |err| {
            std.log.err("Failed to read from file {s}. Error -> {s}. Skipping", .{ absolute_path, err });
            continue;
        };

        // TODO: Handle this case
        if (bytes_read < file_size) {
            std.log.err("Failed to read all bytes of {s}. Skipping", .{absolute_path});
            continue;
        }

        entry.duration_seconds = @intCast(u16, audio.mp3.calculateDurationSecondsFromFile(&file_buffer));
        std.log.info("Track length: {d} seconds for {s}", .{ entry.duration_seconds, absolute_path });

        // TODO: Reuse allocated memory
        file.close();
        std.heap.page_allocator.free(file_buffer);
    }

    std.log.info("Durations calculated for playlist", .{});
    are_durations_available = true;

    output_events.add(.duration_calculated) catch |err| {
        std.log.err("Failed to add .duration_calculated event to Playlist event queue -> {s}", .{err});
    };
}

pub fn trackNext() !void {
    if (storage_opt) |storage| {
        if (current_track_index_opt) |current_track_index| {
            const new_track_index: u16 = current_track_index + 1;
            if (new_track_index == storage.entries().len) {
                return;
            }

            std.debug.assert(new_track_index < storage.entries().len);

            const absolute_path = storage.entries()[new_track_index].absolutePathZ() catch |err| {
                std.log.err("Failed to create absolute path for playlist index {d}. Error -> {s}", .{ new_track_index, err });
                return;
            };

            try audio.input_event_buffer.add(.stop_requested);

            audio.mp3.playFile(std.heap.c_allocator, absolute_path) catch |err| {
                std.log.err("Failed to play track index {d} -> {s}", .{ new_track_index, err });
            };

            current_track_index_opt = new_track_index;
        } else {
            std.log.warn("Cannot invoke trackNext in inactive playlist", .{});
        }
    } else unreachable;
}

pub fn trackPrevious() !void {
    if (storage_opt) |storage| {
        if (current_track_index_opt) |current_track_index| {
            if (current_track_index == 0) {
                return;
            }

            const new_track_index: u16 = current_track_index - 1;
            const absolute_path = storage.entries()[new_track_index].absolutePathZ() catch |err| {
                std.log.err("Failed to create absolute path for playlist index {d}. Error -> {s}", .{ new_track_index, err });
                return;
            };

            try audio.input_event_buffer.add(.stop_requested);

            audio.mp3.playFile(std.heap.c_allocator, absolute_path) catch |err| {
                std.log.err("Failed to play track index {d} -> {s}", .{ new_track_index, err });
            };

            current_track_index_opt = new_track_index;
        } else {
            std.log.warn("Cannot invoke trackPrevious in inactive playlist", .{});
        }
    } else unreachable;
}

pub fn trackPause() !void {}

pub fn trackResume() !void {}

pub fn stop() void {}

var command_list: memory.FixedBuffer(Command, 64) = .{};

pub fn doPlayIndex(index: u16) event_system.ActionIndex {
    std.debug.assert(index < Command.command_base_index);
    return @intCast(event_system.ActionIndex, index + Command.play_audio_command_base);
}

pub fn doInitAndPlayIndex(index: u16) event_system.ActionIndex {
    std.debug.assert(index < Command.command_base_index);
    return @intCast(event_system.ActionIndex, index + Command.init_and_play_audio_command_base);
}

pub fn create(
    arena: *memory.LinearArena,
    directory: std.fs.Dir,
    entry_offset: u32,
    max_entries: u16,
) !void {
    storage_opt = try Storage.create(arena, directory, entry_offset, max_entries);
    _ = try std.Thread.spawn(.{}, calculateDurations, .{storage_opt.?});
}

pub inline fn doNextTrackPlay() event_system.ActionIndex {
    return @intCast(event_system.ActionIndex, Command.track_next);
}

pub inline fn doPreviousTrackPlay() event_system.ActionIndex {
    return @intCast(event_system.ActionIndex, Command.track_previous);
}

fn playIndex(index: u16) void {
    std.log.info("Index: {d}", .{index});
    std.debug.assert(index < storage_opt.?.entries().len);

    const absolute_path = storage_opt.?.entries()[index].absolutePathZ() catch |err| {
        std.log.err("Failed to create absolute path for playlist index {d}. Error -> {s}", .{ index, err });
        return;
    };
    audio.mp3.playFile(std.heap.c_allocator, absolute_path) catch |err| {
        std.log.err("Failed to play track index {d} -> {s}", .{ index, err });
    };
    current_track_index_opt = index;
}

pub fn doAction(index: event_system.ActionIndex) void {
    const init_and_play_max = Command.init_and_play_audio_command_base + Command.init_and_play_audio_range;
    const audio_play_max = Command.play_audio_command_base + Command.play_audio_range;
    if (index >= Command.init_and_play_audio_command_base and index < init_and_play_max) {
        storage_opt = navigation.trackview_storage_opt;
        playIndex(index - Command.init_and_play_audio_command_base);
        output_events.add(.playlist_initialized) catch |err| {
            std.log.err("Failed to add .playlist_initialized event to Playlist event queue -> {s}", .{err});
        };
    } else if (index >= Command.play_audio_command_base and index < audio_play_max) {
        // TODO: Will this ever be called?
        playIndex(index - Command.play_audio_command_base);
    } else {
        switch (index) {
            Command.track_next => trackNext() catch |err| std.log.err("Failed to play next track. Error -> {s}", .{err}),
            Command.track_previous => trackPrevious() catch |err| std.log.err("Failed to play previous track. Error -> {s}", .{err}),
            else => {
                std.log.warn("Invalid action index in Playlist submodule", .{});
                unreachable;
            },
        }
    }
}

pub const Storage = struct {
    const TrackEntry = struct {
        title_index: String.Index,
        artist_index: String.Index,
        path_index: SubPath.Index,
        duration_seconds: u16,

        pub fn title(self: @This()) []const u8 {
            std.debug.assert(self.title_index != String.null_index);
            return String.value(self.title_index);
        }

        pub fn artist(self: @This()) []const u8 {
            std.debug.assert(self.artist_index != String.null_index);
            return String.value(self.artist_index);
        }

        pub fn absolutePathZ(self: @This()) ![:0]const u8 {
            return try SubPath.interface.absolutePathZ(self.path_index);
        }
    };

    track_entry_count: u16 = 0,
    parent_path: AbsolutePath.Index,
    track_list_index: u16,

    pub fn entries(self: @This()) []const TrackEntry {
        if (self.track_entry_count == 0) return &[0]TrackEntry{};
        return @ptrCast([*]const TrackEntry, @alignCast(2, &mini_addr.memory_space[self.track_list_index]))[0..self.track_entry_count];
    }

    pub fn entriesMut(self: @This()) []TrackEntry {
        if (self.track_entry_count == 0) return &[0]TrackEntry{};
        return @ptrCast([*]TrackEntry, @alignCast(2, &mini_addr.memory_space[self.track_list_index]))[0..self.track_entry_count];
    }

    pub fn getTrackFilename(self: @This(), index: u8) []const u8 {
        std.debug.assert(index < self.entry_count);
        const entry_list = @intToPtr([*]TrackEntry, @ptrToInt(&self) + @sizeOf(@This()))[0..self.entry_count];
        return entry_list[index].path();
    }

    pub fn getTitle(self: @This(), index: u8) []const u8 {
        const track_list = @ptrCast([*]const TrackEntry, @alignCast(2, &mini_addr.memory_space[self.track_list_index]));
        return String.value(track_list[index].title_index);
    }

    pub fn parseExtension(file_name: []const u8) ![]const u8 {
        std.debug.assert(file_name.len > 0);
        if (file_name.len <= 4) {
            return error.NoExtension;
        }

        var i: usize = file_name.len - 1;
        while (i > 0) : (i -= 1) {
            if (file_name[i] == '.') {
                return file_name[i + 1 ..];
            }
        }
        return error.NoExtension;
    }

    pub fn matchExtension(extension: []const u8, string: []const u8) bool {
        if (string.len < extension.len) return false;
        for (extension) |char, i| {
            if (char != std.ascii.toUpper(string[i])) {
                return false;
            }
        }
        return true;
    }

    pub fn log(self: @This()) void {
        std.log.info("Parent path: \"{s}\"", .{AbsolutePath.interface.path(self.parent_path)});
        std.log.info("Tracks: {d}", .{self.track_entry_count});
        var track_i: u32 = 0;
        var track_list = @ptrCast([*]const TrackEntry, @alignCast(2, &mini_addr.memory_space[self.track_list_index]));

        while (track_i < self.track_entry_count) : (track_i += 1) {
            const track = track_list[track_i];
            const null_string = "null";

            {
                const file_path_value = if (track.path_index == String.null_index) null_string else SubPath.interface.path(track.path_index);
                std.log.info("  File Path: \"{s}\"", .{file_path_value});
            }

            {
                const title_value = if (track.title_index == String.null_index) null_string else String.value(track.title_index);
                std.log.info("  Title #{d}: \"{s}\"", .{ track_i + 1, title_value });
            }
        }
    }

    pub fn create(
        arena: *memory.LinearArena,
        directory: std.fs.Dir,
        entry_offset: u32,
        max_entries: u16,
    ) !*Storage {
        _ = entry_offset;

        var head = arena.create(@This());
        head.track_entry_count = 0;

        var output_buffer: [512]u8 = undefined;
        const source_parent_path = try directory.realpath(".", output_buffer[0..]);
        head.parent_path = try AbsolutePath.write(arena, source_parent_path, 256);

        var track_entries = arena.allocate(TrackEntry, max_entries);
        head.track_list_index = arena.indexFor(@ptrCast(*u8, track_entries.ptr));

        // Assert track_entries has alignment of 2
        std.debug.assert(@ptrToInt(track_entries.ptr) % 2 == 0);

        var iterator = directory.iterate();
        while (try iterator.next()) |entry| {
            if (head.track_entry_count >= max_entries) {
                std.log.warn("Hit max playlist size ({d}). Some tracks may be ignored", .{max_entries});
                break;
            }
            if (entry.kind == .File) {
                const extension = parseExtension(entry.name) catch "";
                if (matchExtension("MP3", extension) or matchExtension("FLAC", extension)) {
                    track_entries[head.track_entry_count].path_index = try SubPath.write(arena, entry.name, head.parent_path);

                    var file = directory.openFile(entry.name, .{}) catch |err| {
                        std.log.err("Failed to open file '{s}' with err {s}", .{ entry.name, err });
                        return err;
                    };
                    defer file.close();

                    const meta_values = try (audio.mp3.loadMetaFromFileFunction(.{
                        .load_artist = true,
                        .load_title = true,
                    }).loadMetaFromFile(arena, file));

                    track_entries[head.track_entry_count].title_index = meta_values.title;
                    track_entries[head.track_entry_count].artist_index = meta_values.artist;
                    track_entries[head.track_entry_count].duration_seconds = 0;

                    head.track_entry_count += 1;
                }
            }
        }

        return head;
    }
};
