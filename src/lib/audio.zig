// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log;
const Allocator = std.mem.Allocator;
const memory = @import("memory");
const id3 = @import("id3.zig");
const event_system = @import("event_system");
const storage = @import("storage");
const String = storage.String;
const FixedAtomicEventQueue = @import("message_queue").FixedAtomicEventQueue;

pub var subsystem_index: event_system.SubsystemIndex = event_system.null_subsystem_index;

const mad = @cImport({
    @cInclude("mad.h");
});

const libflac = @cImport({
    @cInclude("FLAC/stream_decoder.h");
    @cInclude("FLAC/metadata.h");
});

const ao = @cImport({
    @cInclude("ao/ao.h");
});

const id3v2 = @cImport({
    @cInclude("id3v2lib.h");
});

pub const TrackMetadata = struct {
    title_length: u32,
    artist_length: u32,
    title: [60]u8,
    artist: [60]u8,
};

pub fn doAction(action_index: event_system.ActionIndex) void {
    if (action_list.items[action_index] == .play) {
        const path_index = loaded_tracks.items[action_index];
        const absolute_path = storage.SubPath.interface.absolutePathZ(path_index) catch |err| {
            std.log.err("Failed to create path to audio file: {s}", .{err});
            return;
        };
        mp3.playFile(std.heap.c_allocator, absolute_path) catch |err| {
            std.log.err("Failed to play audio file: {s} -> {s}", .{ absolute_path, err });
            return;
        };
    }
}

pub fn reset() void {
    loaded_tracks.clear();
    action_list.clear();
    _ = input_event_buffer.collect();
    _ = output_event_buffer.collect();
}

const toSlice = memory.sliceFromNullTerminatedString;

pub const TrackMetadataStorage = packed struct {
    const Self = @This();

    size: u16,
    artist_count: u8,
    title_count: u8,
    album_count: u8,
    padding: u8,

    // Layout
    // TagType, size, string, null
    // Size is size of string only

    fn print(mem: []const u8) void {
        var i: usize = 0;
        while (i < mem.len) {
            const tag = @intToEnum(TagType, mem[i]);
            const size = mem[i + 1];
            const value = mem[i + 2 .. i + 2 + size];
            std.debug.print("  {s} : {d} -> '{s}'\n", .{ tag, size, value });
            i += (size + 3);
        }
    }
};

var active_thread_handle: std.Thread = undefined;
var current_audio_buffer: []u8 = undefined;
var decoded_size: usize = 0;

pub const AudioEvent = enum(u8) {
    initialized,
    stopped,
    finished,
    started,
    resumed,
    paused,
    volume_up,
    volume_down,
    volume_mute,
    volume_unmute,
    duration_calculated,
};

pub const InputEvent = enum(u8) {
    deinitialization_requested,
    play_requested,
    stop_requested,
    pause_requested,
    audio_source_changed,
};

pub const Action = enum(u8) {
    play,
    pause,
    @"resume",
};

pub var input_event_buffer: FixedAtomicEventQueue(InputEvent, 10) = .{};
pub var output_event_buffer: FixedAtomicEventQueue(AudioEvent, 10) = .{};

var action_list: memory.FixedBuffer(Action, 20) = .{};
var loaded_tracks: memory.FixedBuffer(storage.SubPath.Index, 20) = .{};

pub var current_track: TrackMetadata = undefined;

// Hack to attempt to remove unsupported multibyte encoded charactors
fn ensureAscii(text: *[]u8) u32 {
    var write_index: u32 = 0;
    var read_index: u32 = 0;
    var last_was_null: bool = false;

    while (read_index < text.len) : (read_index += 1) {
        const char = text.*[read_index];

        if (!std.ascii.isPrint(char)) {
            if (char == 0) {
                if (last_was_null == true) {
                    return write_index;
                }
                last_was_null = true;
                continue;
            }
            last_was_null = false;
            continue;
        }
        last_was_null = false;

        text.*[write_index] = char;
        write_index += 1;
    }

    return write_index;
}

pub const TrackMetadataIndices = struct {
    const null_value = std.math.maxInt(u16);

    title: u16 = null_value,
    artist: u16 = null_value,
    album: u16 = null_value,
    duration: u16 = null_value,
};

const TagType = enum(u8) {
    album,
    artist,
    title,
};

fn find(mem: []const u8, tag_type: TagType, needle_text: []const u8, max_count: u16) ?u16 {
    var i: usize = 0;
    var element_count: u16 = 0;
    while (i < mem.len and element_count < max_count) {
        const tag = @intToEnum(TagType, mem[i]);
        const size = mem[i + 1];
        if (tag == tag_type) {
            element_count += 1;
            const current_text = mem[i + 2 .. i + 2 + size];
            if (std.mem.eql(u8, needle_text, current_text)) {
                return @intCast(u16, i);
            }
        }
        i += (size + 3);
    }
    return null;
}

fn add(arena: *memory.LinearArena, text: []const u8, tag_type: TagType) u16 {
    const result = arena.used;

    for (text) |char, i| {
        if (char != 0 and !std.ascii.isPrint(char)) {
            std.log.err("Found invalid char at index {d} '{d}'", .{ i, char });
            std.debug.assert(false);
        }
    }

    std.log.info("Adding text frame: '{s}'", .{text});
    var string_type = arena.create(TagType);

    std.debug.assert(arena.used == (result + 1));

    string_type.* = tag_type;
    var string_length = arena.create(u8);
    std.debug.assert(arena.used == (result + 2));

    string_length.* = @intCast(u8, text.len);
    var string = arena.allocate(u8, @intCast(u16, text.len + 1));
    std.mem.copy(u8, string, text);
    string[text.len] = 0;
    std.debug.print("  !{s}: {s}\n", .{ tag_type, string[0..text.len] });

    std.debug.print("CP: {d} New {d} Used {d}\n", .{ result, (text.len + 3), arena.used });
    std.debug.assert(result + (text.len + 3) == arena.used);

    return result;
}

pub const mp3 = struct {
    pub fn doPlayAudio(path: storage.SubPath.Index) event_system.ActionIndex {
        _ = loaded_tracks.append(path);
        return @intCast(event_system.ActionIndex, action_list.append(.play));
    }

    const LoadMetaFromFileFunctionConfig = struct {
        load_artist: bool = false,
        load_title: bool = false,
        load_genre: bool = false,
        load_album: bool = false,
    };

    pub fn loadMetaFromFileFunction(config: LoadMetaFromFileFunctionConfig) type {
        return struct {
            const IndexType = u16;
            const null_index = std.math.maxInt(u16);

            const Indices = struct {
                artist: if (config.load_artist) IndexType else void,
                title: if (config.load_title) IndexType else void,
                genre: if (config.load_genre) IndexType else void,
                album: if (config.load_album) IndexType else void,
            };

            pub fn loadMetaFromFile(arena: *memory.LinearArena, file: std.fs.File) !Indices {
                var indices: Indices = undefined;

                comptime var items_to_parse: comptime_int = 0;
                var items_parsed_count: u32 = 0;

                if (comptime config.load_artist) {
                    indices.artist = null_index;
                    items_to_parse += 1;
                }

                if (config.load_title) {
                    indices.title = null_index;
                    items_to_parse += 1;
                }

                if (config.load_genre) {
                    indices.genre = null_index;
                    items_to_parse += 1;
                }

                if (config.load_album) {
                    indices.album = null_index;
                    items_to_parse += 1;
                }

                var header: id3.Header = undefined;
                {
                    var header_buffer: []u8 = (@ptrCast([*]u8, &header)[0..@sizeOf(id3.Header)]);
                    var bytes_read: u64 = try file.read(header_buffer);

                    if (bytes_read < @sizeOf(id3.Header)) {
                        std.log.err("Failed to read id3 header. Skipping", .{});
                        return error.InvalidHeader;
                    }
                }

                header.decodeSize();

                if (header.identifier[0] != 'I' or header.identifier[1] != 'D' or header.identifier[2] != '3') {
                    std.log.err("ID3 header is invalid", .{});
                    return error.InvalidHeader;
                }

                // TODO: Implement
                std.debug.assert(header.flags == 0);

                const max_frame_size: u32 = 256;
                var frame_input_buffer: [max_frame_size]u8 = undefined;

                var i: u32 = 0;
                var frame: *id3.Frame = undefined;

                var is_album_parsed: bool = false;
                var is_title_parsed: bool = false;
                var is_artist_parsed: bool = false;

                const artist_tag = "TPE1";
                const album_tag = "TALB";
                const title_tag = "TIT2";

                while (i <= header.size) {
                    _ = try file.read(frame_input_buffer[0..@sizeOf(id3.Frame)]);
                    frame = @ptrCast(*id3.Frame, &frame_input_buffer[0]);

                    frame.size = std.mem.bigToNative(u32, frame.size);
                    if (header.version_major == '4') {
                        frame.size = id3.synchsafeToU32(frame.size);
                    }

                    if (frame.id[0] == 0) {
                        // Into post tag padding
                        break;
                    }

                    if (frame.size > header.size) {
                        std.log.err("Frame {d} is larger than entire header {d}", .{ frame.size, header.size });
                        return error.InvalidMp3Header;
                    }

                    if (comptime config.load_artist) {
                        if (!is_artist_parsed and std.mem.eql(u8, frame.id[0..], artist_tag)) {
                            is_artist_parsed = true;
                            items_parsed_count += 1;
                            var artist_value = frame_input_buffer[@sizeOf(id3.Frame) .. @sizeOf(id3.Frame) + frame.size];
                            _ = try file.read(artist_value);

                            const encoding = @intToEnum(id3.TextEncoding, artist_value[0]);

                            if (encoding != .iso_8859_1) {
                                std.log.warn("Unsupported text encoding: {s}", .{encoding});
                            }

                            indices.artist = try String.write(arena, artist_value[1..]);
                        }
                    }

                    if (comptime config.load_album) {
                        if (!is_album_parsed and std.mem.eql(u8, frame.id[0..], album_tag)) {
                            is_album_parsed = true;
                            items_parsed_count += 1;
                            var album_value = frame_input_buffer[@sizeOf(id3.Frame) .. @sizeOf(id3.Frame) + frame.size];

                            _ = try file.read(album_value);

                            const encoding = @intToEnum(id3.TextEncoding, album_value[0]);
                            if (encoding != .iso_8859_1) {
                                std.log.warn("Unsupported text encoding: {s}", .{encoding});
                            }

                            indices.album = try String.write(arena, album_value[1..]);
                        }
                    }

                    if (comptime config.load_title) {
                        if (!is_title_parsed and std.mem.eql(u8, frame.id[0..], title_tag)) {
                            is_title_parsed = true;
                            items_parsed_count += 1;
                            var title_value = frame_input_buffer[@sizeOf(id3.Frame) .. @sizeOf(id3.Frame) + frame.size];
                            _ = try file.read(title_value);

                            const encoding = @intToEnum(id3.TextEncoding, title_value[0]);
                            if (encoding != .iso_8859_1) {
                                std.log.warn("Unsupported text encoding: {s}", .{encoding});
                            }

                            indices.title = try String.write(arena, title_value[1..]);
                        }
                    }

                    if (items_parsed_count >= items_to_parse) {
                        break;
                    }

                    i += (frame.size + @sizeOf(id3.Frame));
                    try file.seekTo(@sizeOf(id3.Header) + i);
                }

                return indices;
            }
        };
    }

    pub fn loadMetaFromDirectory(arena: *memory.LinearArena, directory: std.fs.Dir) ![]TrackMetadataIndices {
        var file_count: u16 = 0;
        var files_buffer: [64]std.fs.File = undefined;

        {
            var iterator = directory.iterate();
            while (try iterator.next()) |entry| {
                if (entry.name.len <= 4) {
                    continue;
                }

                const extension = entry.name[entry.name.len - 3 .. entry.name.len];
                if (!std.mem.eql(u8, extension, "mp3")) {
                    continue;
                }

                std.log.info("Adding: {s}", .{entry.name});

                files_buffer[file_count] = directory.openFile(entry.name, .{}) catch |err| {
                    std.log.err("Failed to open file '{s}' with err {s}", .{ entry.name, err });
                    return err;
                };
                file_count += 1;
            }
        }

        var track_metadata_indices = arena.allocate(TrackMetadataIndices, file_count);
        const storage_base = @ptrCast([*]const u8, arena.peek());

        var metadata_header: TrackMetadataStorage = undefined;
        metadata_header.size = 0;
        metadata_header.artist_count = 0;
        metadata_header.title_count = 0;
        metadata_header.album_count = 0;

        const files = files_buffer[0..file_count];

        defer {
            for (files) |*file| {
                file.close();
            }
        }

        for (files) |file, file_i| {
            var header: id3.Header = undefined;
            {
                var header_buffer: []u8 = (@ptrCast([*]u8, &header)[0..@sizeOf(id3.Header)]);
                var bytes_read: u64 = try file.read(header_buffer);

                if (bytes_read < @sizeOf(id3.Header)) {
                    std.log.err("Failed to read id3 header. Skipping", .{});
                    continue;
                }
            }

            header.decodeSize();

            if (header.identifier[0] != 'I' or header.identifier[1] != 'D' or header.identifier[2] != '3') {
                std.log.err("ID3 header is invalid", .{});
                continue;
            }

            std.debug.print("Version {d}.{d}\n", .{ header.version_major, header.version_revision });
            std.debug.print("Flags {d}\n", .{header.flags});

            // TODO: Implement
            std.debug.assert(header.flags == 0);

            std.debug.print("Size {d}\n", .{header.size});

            const max_frame_size: u32 = 256;
            var frame_input_buffer: [max_frame_size]u8 = undefined;

            var i: u32 = 0;
            var frame: *id3.Frame = undefined;

            var is_album_parsed: bool = false;
            var is_title_parsed: bool = false;
            var is_artist_parsed: bool = false;
            // var is_duration_parsed: bool = false;

            const artist_tag = "TPE1";
            const album_tag = "TALB";
            const title_tag = "TIT2";
            // const duration_tag = "TLEN";

            while (i <= header.size) {
                // std.log.info("Index {d} Header {d}", .{ i, header.size });

                _ = try file.read(frame_input_buffer[0..@sizeOf(id3.Frame)]);
                frame = @ptrCast(*id3.Frame, &frame_input_buffer[0]);

                frame.size = std.mem.bigToNative(u32, frame.size);
                if (header.version_major == '4') {
                    frame.size = id3.synchsafeToU32(frame.size);
                }

                std.log.info("Frame {d} {s}", .{ frame.size, frame.id[0..] });

                if (frame.id[0] == 0) {
                    // Into post tag padding
                    break;
                }

                if (frame.size > header.size) {
                    std.log.err("Frame {d} is larger than entire header {d}", .{ frame.size, header.size });
                    return error.InvalidMp3Header;
                }

                // const tag_list = [4]const u8 { artist_tag, album_tag, title_tag, duration_tag };

                if (!is_artist_parsed and std.mem.eql(u8, frame.id[0..], artist_tag)) {
                    is_artist_parsed = true;
                    var artist_value = frame_input_buffer[@sizeOf(id3.Frame) .. @sizeOf(id3.Frame) + frame.size];
                    _ = try file.read(artist_value);

                    const encoding = @intToEnum(id3.TextEncoding, artist_value[0]);
                    std.log.info("Adding artist '{s}'", .{artist_value});

                    if (encoding != .iso_8859_1) {
                        std.log.warn("Unsupported text encoding: {s}", .{encoding});
                    }

                    track_metadata_indices[file_i].artist = blk: {
                        if (find(storage_base[0..metadata_header.size], .artist, artist_value[1..], metadata_header.artist_count)) |index| {
                            break :blk index;
                        }
                        metadata_header.artist_count += 1;
                        // NOTE: +3 is for additional tag_type, size, null terminator
                        metadata_header.size += @intCast(u16, frame.size + 3);
                        break :blk add(arena, artist_value[1..], .artist);
                    };
                } else if (std.mem.eql(u8, frame.id[0..], album_tag)) {
                    is_album_parsed = true;
                    var album_value = frame_input_buffer[@sizeOf(id3.Frame) .. @sizeOf(id3.Frame) + frame.size];

                    _ = try file.read(album_value);

                    const encoding = @intToEnum(id3.TextEncoding, album_value[0]);
                    if (encoding != .iso_8859_1) {
                        std.log.warn("Unsupported text encoding: {s}", .{encoding});
                    }

                    std.log.info("Adding album '{s}'", .{album_value[1..]});

                    track_metadata_indices[file_i].album = blk: {
                        if (find(storage_base[0..metadata_header.size], .album, album_value[1..], metadata_header.album_count)) |index| {
                            break :blk index;
                        }
                        metadata_header.album_count += 1;
                        metadata_header.size += @intCast(u16, frame.size + 3);
                        break :blk add(arena, album_value[1..], .album);
                    };
                } else if (std.mem.eql(u8, frame.id[0..], title_tag)) {
                    is_title_parsed = true;
                    var title_value = frame_input_buffer[@sizeOf(id3.Frame) .. @sizeOf(id3.Frame) + frame.size];
                    _ = try file.read(title_value);

                    const encoding = @intToEnum(id3.TextEncoding, title_value[0]);
                    if (encoding != .iso_8859_1) {
                        std.log.warn("Unsupported text encoding: {s}", .{encoding});
                    }

                    metadata_header.title_count += 1;
                    metadata_header.size += @intCast(u16, frame.size + 3);
                    track_metadata_indices[file_i].title = add(arena, title_value[1..], .title);
                }

                if (is_title_parsed and is_album_parsed and is_artist_parsed) {
                    break;
                }

                i += (frame.size + @sizeOf(id3.Frame));
                try file.seekTo(@sizeOf(id3.Header) + i);
            }
        }

        // print(storage_base[0..metadata_header.size]);

        return track_metadata_indices;
    }

    fn errorCallback(data: ?*anyopaque, stream: [*c]mad.mad_stream, frame: [*c]mad.mad_frame) callconv(.C) mad.mad_flow {
        _ = frame;
        _ = data;

        std.log.err("Failure in mp3 decoding '{s}'", .{mad.mad_stream_errorstr(stream)});
        return mad.MAD_FLOW_CONTINUE;
    }

    pub fn extractTrackMetadata(
        filename: [:0]const u8,
        arena: *memory.LinearArena,
    ) !TrackMetadataIndices {
        var track_metadata_indices = TrackMetadataIndices{};

        const max_field_length: u16 = 50;
        const tag_opt: [*c]id3v2.ID3v2_tag = id3v2.load_tag(filename);

        if (tag_opt == null) {
            return error.FailedToOpenFile;
        }

        const tag = tag_opt.?;

        {
            const title_frame = id3v2.tag_get_title(tag);
            var title_content = id3v2.parse_text_frame_content(title_frame);

            // TODO: title_content is sometimes null and causes a crash
            var title_length = @intCast(u32, title_content.*.size);
            title_length = ensureAscii(&title_content.*.data[0 .. title_length + 1]);

            if (title_length > max_field_length) {
                title_length = max_field_length;
                title_content.*.data[max_field_length - 1] = '.';
                title_content.*.data[max_field_length - 2] = '.';
                title_content.*.data[max_field_length - 3] = '.';
                std.log.warn("'{s}' has been elided", .{title_content.*.data[0..title_length]});
            }

            track_metadata_indices.title = arena.used;
            if (title_length > 0) {
                var title = arena.allocate(u8, @intCast(u16, title_length) + 1);
                std.mem.copy(u8, title, title_content.*.data[0..title_length]);
                title[title_length] = 0;
            } else {
                var title = arena.allocate(u8, 8);
                std.mem.copy(u8, title, "Unknown");
                title[7] = 0;
            }
        }

        {
            const artist_frame = id3v2.tag_get_artist(tag);
            var artist_content = id3v2.parse_text_frame_content(artist_frame);
            var artist_length = @intCast(u32, artist_content.*.size);
            artist_length = ensureAscii(&artist_content.*.data[0 .. artist_length + 1]);

            if (artist_length > max_field_length) {
                artist_length = max_field_length;
                artist_content.*.data[max_field_length - 1] = '.';
                artist_content.*.data[max_field_length - 2] = '.';
                artist_content.*.data[max_field_length - 3] = '.';
                std.log.warn("'{s}' has been elided", .{artist_content.*.data[0..artist_length]});
            }

            track_metadata_indices.artist = arena.used;

            if (artist_length > 0) {
                var artist = arena.allocate(u8, @intCast(u16, artist_length) + 1);
                std.mem.copy(u8, artist, artist_content.*.data[0..artist_length]);
                artist[artist_length] = 0;
            } else {
                var artist = arena.allocate(u8, 8);
                std.mem.copy(u8, artist, "Unknown");
                artist[7] = 0;
            }
        }

        return track_metadata_indices;
    }

    fn scale(sample: mad.mad_fixed_t) i16 {
        const MAD_F_ONE = 0x10000000;

        // round
        var new_sample = sample + (1 << (mad.MAD_F_FRACBITS - 16));

        // clip
        if (new_sample >= MAD_F_ONE) {
            new_sample = MAD_F_ONE - 1;
        } else if (new_sample < -MAD_F_ONE) {
            new_sample = -MAD_F_ONE;
        }

        // quantize
        return @truncate(i16, new_sample >> (mad.MAD_F_FRACBITS + 1 - 16));
    }

    fn outputCallback(data: ?*anyopaque, header: [*c]const mad.mad_header, pcm: [*c]mad.mad_pcm) callconv(.C) mad.mad_flow {
        _ = data;
        _ = header;

        const channels_count: u32 = pcm.*.channels;
        const samples_count: u32 = pcm.*.length;
        var channel_left: [*]const mad.mad_fixed_t = @ptrCast([*]const mad.mad_fixed_t, &pcm.*.samples[0][0]);
        var channel_right: [*]const mad.mad_fixed_t = @ptrCast([*]const mad.mad_fixed_t, &pcm.*.samples[1][0]);

        assert(channels_count == 2);
        assert(pcm.*.samplerate == 44100);

        const bytes_per_sample: u16 = 4;
        const output_buffer_size: u32 = bytes_per_sample * 128;
        var output_buffer: [output_buffer_size]u8 = undefined;
        var output_buffer_position: u32 = 0;

        var sample_index: u32 = 0;
        while (sample_index < samples_count) : (sample_index += 1) {
            for (input_event_buffer.collect()) |event| {
                switch (event) {
                    .stop_requested => return mad.MAD_FLOW_STOP,
                    .pause_requested => output.playback_state = .paused,
                    .audio_source_changed => {
                        //
                    },
                    else => {
                        log.warn("Unhandled input event in audio: {s}", .{event});
                    },
                }
            }

            const playback_state = output.getState();
            while (playback_state == .paused) {
                std.time.sleep(100000 * 1000);
                continue;
            }

            if (playback_state == .stopped) {
                return mad.MAD_FLOW_STOP;
            }

            if (playback_state != .playing) {
                std.log.warn("Playback state not .playing", .{});
            }

            const left_block = @bitCast(u16, scale(channel_left[sample_index]));

            //
            // Note: Write to buffer in little endian format
            //

            output_buffer[output_buffer_position] = @truncate(u8, left_block);
            output_buffer[output_buffer_position + 1] = @truncate(u8, left_block >> 8);

            const right_block = @bitCast(u16, scale(channel_right[sample_index]));

            output_buffer[output_buffer_position + 2] = @truncate(u8, right_block);
            output_buffer[output_buffer_position + 3] = @truncate(u8, right_block >> 8);

            output_buffer_position += 4;
            decoded_size += 4;

            if (output_buffer_position == output_buffer_size or sample_index == (samples_count - 1)) {
                _ = ao.ao_play(output.device, &output_buffer, @intCast(c_uint, output_buffer_position));
                output.audio_index += output_buffer_position;
                output_buffer_position = 0;
            }
        }

        return mad.MAD_FLOW_CONTINUE;
    }

    var decoded_mp3_buffer = OutputBuffer{
        .position = 0,
        .buffer = undefined,
    };

    pub fn calculateDurationSecondsFromFile(input_buffer: *[]const u8) u32 {
        var decoder: mad.mad_decoder = undefined;
        output.audio_duration = 0.0;
        mad.mad_decoder_init(&decoder, @ptrCast(*anyopaque, input_buffer), inputCallback, headerCallback, null, null, errorCallback, null);
        _ = mad.mad_decoder_run(&decoder, mad.MAD_DECODER_MODE_SYNC);
        _ = mad.mad_decoder_finish(&decoder);
        is_decoded = false;
        return @floatToInt(u32, output.audio_duration);
    }

    fn decode(input_buffer: *[]const u8) void {
        var decoder: mad.mad_decoder = undefined;
        // Initial decode to read headers and calculate length
        output.audio_length = 0;
        output.audio_duration = 0;
        const get_track_length_start_ts: i64 = std.time.milliTimestamp();

        mad.mad_decoder_init(&decoder, @ptrCast(*anyopaque, input_buffer), inputCallback, headerCallback, null, null, errorCallback, null);
        _ = mad.mad_decoder_run(&decoder, mad.MAD_DECODER_MODE_SYNC);
        _ = mad.mad_decoder_finish(&decoder);

        // TODO: Don't hardcode these values
        output.audio_length = @floatToInt(u32, output.audio_duration * 2.0 * 2.0 * 44100.0);

        std.log.info("Audio duration: {d}", .{output.audio_duration});
        std.log.info("Audio length: {d}", .{output.audio_length});
        is_decoded = false;

        const get_track_length_end_ts: i64 = std.time.milliTimestamp();

        log.info("Decoded audio size: {d}", .{output.audio_length});

        assert(get_track_length_end_ts >= get_track_length_start_ts);
        log.info("Track length decoded in {d} ms", .{get_track_length_end_ts - get_track_length_start_ts});

        output_event_buffer.add(.duration_calculated) catch |err| {
            log.err("Failed to add output event: {s}", .{err});
        };

        output.playback_state = .playing;

        output_event_buffer.add(.started) catch |err| {
            log.err("Failed to add output event: {s}", .{err});
        };

        event_system.internalEventHandle(.{ .subsystem = subsystem_index, .index = @intCast(event_system.ActionIndex, @enumToInt(AudioEvent.started)) });

        mad.mad_decoder_init(&decoder, @ptrCast(*anyopaque, input_buffer), inputCallback, null, null, outputCallback, errorCallback, null);
        _ = mad.mad_decoder_run(&decoder, mad.MAD_DECODER_MODE_SYNC);
        _ = mad.mad_decoder_finish(&decoder);

        if (output.audio_index >= output.audio_length) {
            output_event_buffer.add(.finished) catch |err| {
                std.log.err("Failed to add .finished Audio event : {s}", .{err});
            };
        } else {
            std.log.info("Emitting .stopped event", .{});
            output_event_buffer.add(.stopped) catch |err| {
                std.log.err("Failed to add .stopped Audio event : {s}", .{err});
            };
        }

        output.audio_duration = 0;
        output.audio_index = 0;
        output.audio_length = 0;
    }

    var is_decoded = false;

    fn inputCallback(data: ?*anyopaque, stream: [*c]mad.mad_stream) callconv(.C) mad.mad_flow {
        var input_buffer: *[]u8 = @ptrCast(*[]u8, @alignCast(8, data.?));

        if (is_decoded == true) {
            return mad.MAD_FLOW_STOP;
        }

        const size: usize = if (is_decoded) 0 else input_buffer.len;
        mad.mad_stream_buffer(stream, input_buffer.ptr, size);

        is_decoded = true;

        return mad.MAD_FLOW_CONTINUE;
    }

    pub var track_length: u64 = 0;

    fn headerCallback(data: ?*anyopaque, header: [*c]const mad.mad_header) callconv(.C) mad.mad_flow {
        _ = data;
        assert(header[0].duration.seconds != 0 or header[0].duration.fraction != 0);

        output.audio_duration += @intToFloat(f64, header[0].duration.seconds) + @intToFloat(f64, header[0].duration.fraction) * (1.0 / @intToFloat(f64, mad.MAD_TIMER_RESOLUTION));
        const channel_count: u32 = blk: {
            switch (header[0].mode) {
                mad.MAD_MODE_SINGLE_CHANNEL => break :blk 1,
                mad.MAD_MODE_DUAL_CHANNEL,
                mad.MAD_MODE_STEREO,
                mad.MAD_MODE_JOINT_STEREO,
                => break :blk 2,
                else => {
                    log.warn("Unsupported MAD MODE index {d}, defaulting to 2 channels", .{header[0].mode});
                    break :blk 2;
                },
            }
            unreachable;
        };
        _ = channel_count;

        return mad.MAD_FLOW_CONTINUE;
    }

    pub fn playFile(allocator: Allocator, file_path: [:0]const u8) !void {
        if (output.playback_state != .stopped) {
            output.playback_state = .stopped;
            active_thread_handle.join();

            allocator.free(decoded_mp3_buffer.buffer);
            decoded_mp3_buffer.position = 0;
            is_decoded = false;
            decoded_size = 0;

            std.log.info("Audio thread terminated", .{});
        }

        output.audio_length = 0;
        output.audio_index = 0;
        output.audio_duration = 0.0;

        const file = try std.fs.openFileAbsolute(file_path, .{ .mode = .read_only });
        defer file.close();

        const file_stat = try file.stat();
        const file_size = file_stat.size;

        log.info("Encoded size: {d}", .{file_size});

        current_audio_buffer = try allocator.alloc(u8, file_size);
        // TODO: Memory leak
        // defer allocator.free(current_audio_buffer);

        const bytes_read = try file.readAll(current_audio_buffer);

        if (bytes_read != file_size) {
            log.err("Read {} of total {} bytes", .{ bytes_read, file_size });
            return error.ReadFileFailed;
        }

        std.log.info("Initializing aolib..", .{});
        try output.init();
        active_thread_handle = try std.Thread.spawn(.{}, decode, .{&current_audio_buffer});
    }
};

pub const flac = struct {
    pub fn playFile(allocator: Allocator, file_path: [:0]const u8) !void {
        if (output.playback_state != .stopped) {
            output.playback_state = .stopped;
        }

        var metadata_info: libflac.FLAC__StreamMetadata = undefined;
        _ = libflac.FLAC__metadata_get_streaminfo(file_path.ptr, &metadata_info);
        const metadata_type: libflac.FLAC__MetadataType = metadata_info.@"type";

        if (metadata_type != libflac.FLAC__METADATA_TYPE_STREAMINFO) {
            return error.ReadMetadataFailed;
        }

        // const stream_info = metadata_info.data.stream_info;

        // const total_samples = stream_info.total_samples;
        // const sample_rate = stream_info.sample_rate;
        // const channels = stream_info.channels;
        // const bits_per_sample = stream_info.bits_per_sample;

        // const total_size: u64 = (total_samples * channels * (bits_per_sample / 8));
        var decoded_audio = try decode(allocator, file_path.ptr);

        _ = decoded_audio;
        // _ = try std.Thread.spawn(.{}, output.play, decoded_audio);

        current_track = try extractTrackMetadata(file_path);
    }

    pub fn decode(allocator: Allocator, input_file_path: [*:0]const u8) ![]u8 {
        var metadata_info: libflac.FLAC__StreamMetadata = undefined;
        _ = libflac.FLAC__metadata_get_streaminfo(input_file_path, &metadata_info);

        const metadata_type: libflac.FLAC__MetadataType = metadata_info.@"type";
        _ = metadata_type;

        if (metadata_type != libflac.FLAC__METADATA_TYPE_STREAMINFO) {
            return error.ReadMetadataFailed;
        }

        const stream_info = metadata_info.data.stream_info;

        const total_samples = stream_info.total_samples;
        const sample_rate = stream_info.sample_rate;
        const channels = stream_info.channels;
        const bits_per_sample = stream_info.bits_per_sample;

        const total_size: u64 = (total_samples * channels * (bits_per_sample / 8));

        log.info("Sample rate: {}\nChannels: {}\nBits / Sample: {}\nTotal Samples: {}", .{ sample_rate, channels, bits_per_sample, total_samples });

        var output_buffer: OutputBuffer = undefined;
        output_buffer.position = 0;
        output_buffer.buffer = try allocator.alloc(u8, total_size);

        var ok: libflac.FLAC__bool = 1;
        var decoder: ?*libflac.FLAC__StreamDecoder = null;
        var init_status: libflac.FLAC__StreamDecoderInitStatus = undefined;

        decoder = libflac.FLAC__stream_decoder_new();

        if (decoder == null) {
            return error.CreateStreamDecoderFailed;
        }

        _ = libflac.FLAC__stream_decoder_set_md5_checking(decoder, 1);

        init_status = libflac.FLAC__stream_decoder_init_file(decoder, input_file_path, writeCallback, metaCallback, errorCallback, &output_buffer);

        if (init_status != libflac.FLAC__STREAM_DECODER_INIT_STATUS_OK) {
            _ = libflac.FLAC__stream_decoder_delete(decoder);
            return error.DecoderInitFileFailed;
        }

        ok = libflac.FLAC__stream_decoder_process_until_end_of_stream(decoder);

        if (init_status != libflac.FLAC__STREAM_DECODER_INIT_STATUS_OK) {
            return error.DecodeAudioFailed;
        }

        return output_buffer.buffer;
    }

    pub fn errorCallback(decoder: [*c]const libflac.FLAC__StreamDecoder, status: libflac.FLAC__StreamDecoderErrorStatus, client_data: ?*anyopaque) callconv(.C) void {
        _ = decoder;
        _ = status;
        _ = client_data;
        log.info("Warning: Error occurred in audio processing", .{});
    }

    pub fn writeCallback(decoder: [*c]const libflac.FLAC__StreamDecoder, frame: [*c]const libflac.FLAC__Frame, buffer: [*c]const [*c]const libflac.FLAC__int32, client_data: ?*anyopaque) callconv(.C) libflac.FLAC__StreamDecoderWriteStatus {
        _ = decoder;
        var output_buffer = @ptrCast(*OutputBuffer, @alignCast(8, client_data));

        var block_index: u32 = 0;
        while (block_index < frame.*.header.blocksize) : (block_index += 1) {
            const left_block = @bitCast(u16, @truncate(i16, buffer[0][block_index]));

            //
            // Note: Write to buffer in little endian format
            //

            output_buffer.*.buffer[output_buffer.position] = @truncate(u8, left_block);
            output_buffer.*.buffer[output_buffer.position + 1] = @truncate(u8, left_block >> 8);

            const right_block = @bitCast(u16, @truncate(i16, buffer[1][block_index]));

            output_buffer.*.buffer[output_buffer.position + 2] = @truncate(u8, right_block);
            output_buffer.*.buffer[output_buffer.position + 3] = @truncate(u8, right_block >> 8);

            output_buffer.position += 4;
        }

        return libflac.FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
    }

    pub fn metaCallback(decoder: [*c]const libflac.FLAC__StreamDecoder, metadata: [*c]const libflac.FLAC__StreamMetadata, client_data: ?*anyopaque) callconv(.C) void {
        _ = decoder;
        _ = metadata;
        _ = client_data;
    }

    pub fn extractTrackMetadata(filename: [:0]const u8) !TrackMetadata {
        var vorbis_comment_block_opt: ?*libflac.FLAC__StreamMetadata = null;
        _ = libflac.FLAC__metadata_get_tags(filename, &vorbis_comment_block_opt);

        var track_metadata: TrackMetadata = .{
            .title_length = 0,
            .artist_length = 0,
            .title = [1]u8{0} ** 60,
            .artist = [1]u8{0} ** 60,
        };

        if (vorbis_comment_block_opt) |*vorbis_comment_block| {
            const vorbis_comments = vorbis_comment_block.*.data.vorbis_comment.comments;
            const vorbis_comment_count: u32 = vorbis_comment_block.*.data.vorbis_comment.num_comments;
            var comment_index: u32 = 0;

            while (comment_index < vorbis_comment_count) : (comment_index += 1) {
                const vorbis_comment = vorbis_comments[comment_index];

                // TODO: Make case insensitive
                const vorbis_title_tag = "title";
                const vorbis_artist_tag = "Artist";

                if (std.mem.eql(u8, vorbis_title_tag, vorbis_comment.entry[0..vorbis_title_tag.len])) {
                    const vorbis_title_tag_preamble: u32 = vorbis_title_tag.len + 1;
                    assert(vorbis_title_tag_preamble == 6);

                    const entry_length = vorbis_comment.length - vorbis_title_tag_preamble;
                    track_metadata.title_length = entry_length;
                    std.mem.copy(u8, track_metadata.title[0..], vorbis_comment.entry[vorbis_title_tag_preamble .. vorbis_title_tag_preamble + entry_length]);

                    continue;
                }

                if (std.mem.eql(u8, vorbis_artist_tag, vorbis_comment.entry[0..vorbis_artist_tag.len])) {
                    const vorbis_artist_tag_preamble: u32 = vorbis_artist_tag.len + 1;
                    assert(vorbis_artist_tag_preamble == 7);

                    const entry_length = vorbis_comment.length - vorbis_artist_tag_preamble;
                    track_metadata.artist_length = entry_length;
                    std.mem.copy(u8, track_metadata.artist[0..], vorbis_comment.entry[vorbis_artist_tag_preamble .. vorbis_artist_tag_preamble + entry_length]);

                    continue;
                }

                // log.info("VORBIS COMMENT: {s}", .{vorbis_comment.entry});
            }

            defer libflac.FLAC__metadata_object_delete(vorbis_comment_block_opt.?);
        } else {
            log.warn("Failed to find vorbis comment", .{});
        }

        return track_metadata;
    }
};

pub fn lengthOfAudio(size: usize, bits_per_sample: u16, channel_count: u16, playback_rate: u32) u32 {
    const bytes_per_sample = bits_per_sample / 8;
    return @intCast(u32, size / (bytes_per_sample * channel_count * playback_rate));
}

pub const output = struct {
    pub const PlaybackState = enum {
        stopped,
        paused,
        playing,
    };

    var playback_state: PlaybackState = .stopped;
    var device: ?*ao.ao_device = null;
    var audio_index: u32 = 0;
    var audio_length: u32 = 0;
    var audio_duration: f64 = 0.0;

    pub fn getState() PlaybackState {
        return playback_state;
    }

    pub fn progress() !f32 {
        std.log.info("Progress called", .{});
        if (playback_state == .stopped) {
            return error.NoAudioSource;
        }

        std.debug.assert(audio_length >= 0);
        if (audio_index >= audio_length) {
            return 1.0;
        }

        // TODO: audio_length exceeds audio_index at the end of a track
        //       Probably the last sample to be added is incomplete
        std.debug.assert(audio_length >= audio_index);

        return @intToFloat(f32, audio_index) / @intToFloat(f32, audio_length);
    }

    pub fn trackLengthSeconds() !u32 {
        if (playback_state == .stopped) {
            return error.NoAudioSource;
        }

        return lengthOfAudio(audio_length, 16, 2, 44100);
    }

    pub fn secondsPlayed() !u32 {
        if (playback_state == .stopped) {
            return error.NoAudioSource;
        }

        return lengthOfAudio(audio_index, 16, 2, 44100);
    }

    pub fn init() !void {
        if (device == null) {
            var format: ao.ao_sample_format = .{
                .matrix = 0,
                .bits = 16,
                .channels = 2,
                .rate = 44100,
                .byte_format = ao.AO_FMT_LITTLE,
            };

            ao.ao_initialize();

            device = blk: {
                var dev: ?*ao.ao_device = null;
                var driver: i32 = undefined;

                driver = ao.ao_default_driver_id();
                if (driver >= 0) {
                    dev = ao.ao_open_live(driver, &format, null);
                    if (dev != null) {
                        break :blk dev;
                    }
                }

                driver = ao.ao_driver_id("pulse");
                if (driver >= 0) {
                    dev = ao.ao_open_live(driver, &format, null);
                    if (dev != null) {
                        break :blk dev;
                    }
                }

                driver = ao.ao_driver_id("alsa");
                if (driver >= 0) {
                    dev = ao.ao_open_live(driver, &format, null);
                    if (dev != null) {
                        break :blk dev;
                    }
                }
                driver = ao.ao_driver_id("sndio");
                if (driver >= 0) {
                    dev = ao.ao_open_live(driver, &format, null);
                    if (dev != null) {
                        break :blk dev;
                    }
                }
                driver = ao.ao_driver_id("oss");
                if (driver >= 0) {
                    dev = ao.ao_open_live(driver, &format, null);
                    if (dev != null) {
                        break :blk dev;
                    }
                }

                return error.FailedToOpenDriver;
            };

            // TODO:
            // const driver_info = ao.ao_driver_info(driver);
            // std.log.info("Audio driver: {s}", .{driver_info[0].name});

            try output_event_buffer.add(.initialized);
        }
    }

    pub fn play(audio_buffer: []u8) !void {
        if (playback_state == .playing) {
            return error.AlreadyPlayingAudio;
        }

        audio_index = 0;
        audio_length = @intCast(u32, audio_buffer.len);

        if (device == null) {
            var format: ao.ao_sample_format = .{
                .matrix = 0,
                .bits = 16,
                .channels = 2,
                .rate = 44100,
                .byte_format = ao.AO_FMT_LITTLE,
            };
            var default_driver: i32 = 0;

            ao.ao_initialize();
            default_driver = ao.ao_default_driver_id();

            device = ao.ao_open_live(default_driver, &format, null);
            if (device == null) {
                log.err("Failed to open ao library", .{});
                return error.InitializeAoFailed;
            }

            try output_event_buffer.add(.initialized);
        }

        const track_length_seconds = lengthOfAudio(audio_buffer.len, 16, 2, 44100);
        log.info("Track length seconds: {}", .{track_length_seconds});

        const segment_size: u32 = 2 * 2 * 44100;

        playback_state = .playing;
        try output_event_buffer.add(.started);

        while (audio_index < audio_buffer.len and playback_state != .stopped) {

            // Stop playback if state has been changed to .stopped
            if (playback_state == .stopped) break;

            if (playback_state == .paused) {
                std.time.sleep(100000 * 1000);
                continue;
            }
            const segment_start = &audio_buffer[audio_index];

            assert(audio_buffer.len > audio_index);
            const remaining = audio_buffer.len - audio_index;

            // At the end of the audio playback, truncate the normal
            // buffer size to what remains in the audio buffer
            const buffer_size = if (remaining < segment_size) remaining else segment_size;

            _ = ao.ao_play(device, segment_start, @intCast(c_uint, buffer_size));
            audio_index += segment_size;
        }

        _ = ao.ao_close(device);
        ao.ao_shutdown();
        device = null;

        playback_state = .stopped;
        try output_event_buffer.add(.finished);
        log.info("Audio finished..", .{});
    }

    pub fn stop() void {
        if (playback_state != .stopped) {
            playback_state = .stopped;
            output_event_buffer.add(.stopped) catch unreachable;
        }
    }

    pub fn pause() void {
        if (playback_state != .paused) {
            playback_state = .paused;
            _ = output_event_buffer.add(.paused) catch unreachable;
        }
    }

    pub fn @"resume"() !void {
        if (playback_state == .stopped) {
            return error.AudioResumeWithoutSource;
        }

        if (playback_state != .playing) {
            playback_state = .playing;
            try output_event_buffer.add(.started);
        }
    }

    pub fn toggle() !void {
        if (playback_state == .stopped) {
            return error.AudioResumeWithoutSource;
        }

        if (playback_state == .playing) playback_state = .paused;
        if (playback_state == .paused) playback_state = .playing;
    }
};

var input_index: u32 = 0;
var keep_playing: bool = true;

pub const OutputBuffer = struct {
    buffer: []u8,
    position: u32,
};
