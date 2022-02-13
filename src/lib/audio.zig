// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log;
const Allocator = std.mem.Allocator;

const memory = @import("memory");
const FixedBuffer = memory.FixedBuffer;
const FixedAtomicEventQueue = @import("message_queue").FixedAtomicEventQueue;

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

var active_thread_handle: std.Thread = undefined;
var current_audio_buffer: []u8 = undefined;
var decoded_size: usize = 0;

pub const AudioEvent = enum(u8) {
    initialized,
    stopped,
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
    stop_requested,
    pause_requested,
    audio_source_changed,
};

pub var input_event_buffer: FixedAtomicEventQueue(InputEvent, 10) = .{};

pub var events_buffer: FixedBuffer(AudioEvent, 10) = .{};
pub var current_track: TrackMetadata = undefined;

pub const mp3 = struct {
    fn errorCallback(data: ?*anyopaque, stream: [*c]mad.mad_stream, frame: [*c]mad.mad_frame) callconv(.C) mad.mad_flow {
        _ = frame;
        _ = data;

        log.err("Failure in mp3 decoding '{s}'", .{mad.mad_stream_errorstr(stream)});
        return mad.MAD_FLOW_CONTINUE;
    }

    pub fn extractTrackMetadata(filename: [:0]const u8) !TrackMetadata {
        var result: TrackMetadata = undefined;

        const tag_opt: [*c]id3v2.ID3v2_tag = id3v2.load_tag(filename);
        if (tag_opt) |tag| {
            const artist_frame = id3v2.tag_get_artist(tag);
            const artist_content = id3v2.parse_text_frame_content(artist_frame);

            result.artist_length = @intCast(u32, artist_content.*.size);
            std.mem.copy(u8, result.artist[0..], artist_content.*.data[0..result.artist_length]);

            const title_frame = id3v2.tag_get_title(tag);
            const title_content = id3v2.parse_text_frame_content(title_frame);

            result.title_length = @intCast(u32, title_content.*.size);
            std.mem.copy(u8, result.title[0..], title_content.*.data[0..result.title_length]);
        } else {
            std.mem.copy(u8, result.artist[0..], "Unknown");
            result.artist_length = 7;

            std.mem.copy(u8, result.title[0..], "Unknown");
            result.title_length = 7;
        }

        return result;
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
            for (input_event_buffer.collect_events()) |event| {
                switch (event) {
                    .stop_requested => {},
                    .pause_requested => {},
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

    fn decode(input_buffer: *[]const u8) void {
        var decoder: mad.mad_decoder = undefined;
        // Initial decode to read headers and calculate length
        output.audio_length = 0;
        const get_track_length_start_ts: i64 = std.time.milliTimestamp();

        mad.mad_decoder_init(&decoder, @ptrCast(*anyopaque, input_buffer), inputCallback, headerCallback, null, null, errorCallback, null);
        _ = mad.mad_decoder_run(&decoder, mad.MAD_DECODER_MODE_SYNC);
        _ = mad.mad_decoder_finish(&decoder);

        // TODO: Don't hardcode these values
        output.audio_length = @floatToInt(u32, output.audio_duration) * 2 * 2 * 44100;
        is_decoded = false;

        const get_track_length_end_ts: i64 = std.time.milliTimestamp();

        log.info("Decoded audio size: {d}", .{output.audio_length});

        assert(get_track_length_end_ts >= get_track_length_start_ts);
        log.info("Track length decoded in {d} ms", .{get_track_length_end_ts - get_track_length_start_ts});

        _ = events_buffer.append(.duration_calculated);

        output.playback_state = .playing;
        _ = events_buffer.append(.started);

        mad.mad_decoder_init(&decoder, @ptrCast(*anyopaque, input_buffer), inputCallback, null, null, outputCallback, errorCallback, null);
        _ = mad.mad_decoder_run(&decoder, mad.MAD_DECODER_MODE_SYNC);
        _ = mad.mad_decoder_finish(&decoder);
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
                mad.MAD_MODE_DUAL_CHANNEL, mad.MAD_MODE_STEREO => break :blk 2,
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
        }

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

        try output.init();
        active_thread_handle = try std.Thread.spawn(.{}, decode, .{&current_audio_buffer});

        current_track = try extractTrackMetadata(file_path);
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
        if (playback_state == .stopped) {
            return error.NoAudioSource;
        }

        return @intToFloat(f32, audio_length) / @intToFloat(f32, audio_index);
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
            var default_driver: i32 = 0;

            ao.ao_initialize();
            default_driver = ao.ao_default_driver_id();

            device = ao.ao_open_live(default_driver, &format, null);
            if (device == null) {
                log.err("Failed to open ao library", .{});
                return error.InitializeAoFailed;
            }

            _ = events_buffer.append(.initialized);
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

            _ = events_buffer.append(.initialized);
        }

        const track_length_seconds = lengthOfAudio(audio_buffer.len, 16, 2, 44100);
        log.info("Track length seconds: {}", .{track_length_seconds});

        const segment_size: u32 = 2 * 2 * 44100;

        playback_state = .playing;
        _ = events_buffer.append(.started);

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
        _ = events_buffer.append(.stopped);
        log.info("Audio finished..", .{});
    }

    pub fn stop() void {
        if (playback_state != .stopped) {
            playback_state = .stopped;
            _ = events_buffer.append(.stopped);
        }
    }

    pub fn pause() void {
        if (playback_state != .paused) {
            playback_state = .paused;
            _ = events_buffer.append(.paused);
        }
    }

    pub fn @"resume"() !void {
        if (playback_state == .stopped) {
            return error.AudioResumeWithoutSource;
        }

        if (playback_state != .playing) {
            playback_state = .playing;
            _ = events_buffer.append(.started);
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
