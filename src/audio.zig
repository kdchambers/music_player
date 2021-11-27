const std = @import("std");
const assert = std.debug.assert;
const log = std.log;
const Allocator = std.mem.Allocator;

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
    title: [64]u8,
    artist: [64]u8,
};

pub const mp3 = struct {
    fn errorCallback(data: ?*c_void, stream: [*c]mad.mad_stream, frame: [*c]mad.mad_frame) callconv(.C) mad.mad_flow {
        log.err("Failure in mp3 decoding '{s}'", .{mad.mad_stream_errorstr(stream)});
        return @intToEnum(mad.enum_mad_flow, mad.MAD_FLOW_CONTINUE);
    }

    pub fn extractTrackMetadata(filename: [:0]const u8) !TrackMetadata {
        var result: TrackMetadata = undefined;

        const tag_opt: [*c]id3v2.ID3v2_tag = id3v2.load_tag(filename);
        if (tag_opt) |tag| {
            const artist_frame = id3v2.tag_get_artist(tag);
            const artist_content = id3v2.parse_text_frame_content(artist_frame);
            const artist_content_length = @intCast(u32, artist_content.*.size);

            std.mem.copy(u8, result.artist[0..], artist_content.*.data[0..artist_content_length]);
            result.artist_length = @intCast(u32, artist_content_length);

            const title_frame = id3v2.tag_get_title(tag);
            const title_content = id3v2.parse_text_frame_content(title_frame);
            const title_content_length = @intCast(u32, title_content.*.size);

            std.mem.copy(u8, result.title[0..], title_content.*.data[0..title_content_length]);
            result.title_length = @intCast(u32, title_content_length);
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

    fn outputCallback(data: ?*c_void, header: [*c]const mad.mad_header, pcm: [*c]mad.mad_pcm) callconv(.C) mad.mad_flow {
        // log.info("Called output callback", .{});

        const channels_count: u32 = pcm.*.channels;
        const samples_count: u32 = pcm.*.length;
        var channel_left: [*]const mad.mad_fixed_t = @ptrCast([*]const mad.mad_fixed_t, &pcm.*.samples[0][0]);
        var channel_right: [*]const mad.mad_fixed_t = @ptrCast([*]const mad.mad_fixed_t, &pcm.*.samples[1][0]);

        assert(channels_count == 2);
        assert(pcm.*.samplerate == 44100);

        var output_buffer = &decoded_mp3_buffer;

        var sample_index: u32 = 0;
        while (sample_index < samples_count) : (sample_index += 1) {
            const left_block = @bitCast(u16, scale(channel_left[sample_index]));

            //
            // Note: Write to buffer in little endian format
            //

            output_buffer.*.buffer[output_buffer.position] = @truncate(u8, left_block);
            output_buffer.*.buffer[output_buffer.position + 1] = @truncate(u8, left_block >> 8);

            const right_block = @bitCast(u16, scale(channel_right[sample_index]));

            output_buffer.*.buffer[output_buffer.position + 2] = @truncate(u8, right_block);
            output_buffer.*.buffer[output_buffer.position + 3] = @truncate(u8, right_block >> 8);

            output_buffer.position += 4;
        }

        return @intToEnum(mad.enum_mad_flow, mad.MAD_FLOW_CONTINUE);
    }

    var decoded_mp3_buffer: OutputBuffer = undefined;

    fn decode(input_buffer: *[]const u8) i32 {
        var decoder: mad.mad_decoder = undefined;
        mad.mad_decoder_init(&decoder, @ptrCast(*c_void, input_buffer), inputCallback, null, null, outputCallback, errorCallback, null);
        var result = mad.mad_decoder_run(&decoder, @intToEnum(mad.enum_mad_decoder_mode, mad.MAD_DECODER_MODE_SYNC));
        _ = mad.mad_decoder_finish(&decoder);
        return result;
    }

    var is_decoded = false;

    fn inputCallback(data: ?*c_void, stream: [*c]mad.mad_stream) callconv(.C) mad.mad_flow {
        var input_buffer: *[]u8 = @ptrCast(*[]u8, @alignCast(8, data.?));

        if (is_decoded == true) {
            return @intToEnum(mad.enum_mad_flow, mad.MAD_FLOW_STOP);
        }

        log.info("Running input callback", .{});

        const size: usize = if (is_decoded) 0 else input_buffer.len;
        mad.mad_stream_buffer(stream, input_buffer.ptr, size);

        is_decoded = true;

        return @intToEnum(mad.enum_mad_flow, mad.MAD_FLOW_CONTINUE);
    }

    pub fn playFile(allocator: *Allocator, file_path: [:0]const u8) !void {
        const file = try std.fs.openFileAbsolute(file_path, .{ .read = true });

        const file_stat = try file.stat();
        const file_size = file_stat.size;

        var input_buffer = try allocator.alloc(u8, file_size);
        const bytes_read = try file.readAll(input_buffer);

        if (bytes_read != file_size) {
            log.err("Read {} of total {} bytes", .{ bytes_read, file_size });
            return error.ReadFileFailed;
        }

        decoded_mp3_buffer.position = 0;

        // TODO(keith): Read id tags to determine uncompressed length
        decoded_mp3_buffer.buffer = try allocator.alloc(u8, input_buffer.len * 5);

        _ = decode(&input_buffer);

        _ = try std.Thread.spawn(output.play, decoded_mp3_buffer.buffer);
    }
};

pub const flac = struct {
    pub fn playFile(allocator: *Allocator, file_path: [:0]const u8) !void {
        if (output.playback_state != .stopped) {
            output.playback_state = .stopped;
        }

        std.time.sleep(std.time.ns_per_ms * 250);

        var metadata_info: libflac.FLAC__StreamMetadata = undefined;
        const result = libflac.FLAC__metadata_get_streaminfo(file_path.ptr, &metadata_info);
        const metadata_type: libflac.FLAC__MetadataType = metadata_info.@"type";

        if (metadata_type != @intToEnum(libflac.FLAC__MetadataType, libflac.FLAC__METADATA_TYPE_STREAMINFO)) {
            return error.ReadMetadataFailed;
        }

        const stream_info = metadata_info.data.stream_info;

        const total_samples = stream_info.total_samples;
        const sample_rate = stream_info.sample_rate;
        const channels = stream_info.channels;
        const bits_per_sample = stream_info.bits_per_sample;

        const total_size: u64 = (total_samples * channels * (bits_per_sample / 8));
        var decoded_audio = try decode(allocator, file_path.ptr);

        _ = try std.Thread.spawn(output.play, decoded_audio);
    }

    pub fn extractTrackMetadata(filename: [:0]const u8) !TrackMetadata {
        var vorbis_comment_block_opt: ?*libflac.FLAC__StreamMetadata = null;
        _ = libflac.FLAC__metadata_get_tags(filename, &vorbis_comment_block_opt);

        var track_metadata: TrackMetadata = .{
            .title_length = 0,
            .artist_length = 0,
            .title = [1]u8{0} ** 64,
            .artist = [1]u8{0} ** 64,
        };

        if (vorbis_comment_block_opt) |*vorbis_comment_block| {
            // log.info("Vorbis vender: {s}", .{vorbis_comment_block.*.data.vorbis_comment.vendor_string.entry});

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
    return @intCast(u32, size / ((bits_per_sample / 8) * channel_count * playback_rate));
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
            const sample: i32 = 256;
            const frequency: f32 = 440.0;
            var i: i32 = 0;

            ao.ao_initialize();

            default_driver = ao.ao_default_driver_id();

            device = ao.ao_open_live(default_driver, &format, null);
            if (device == null) {
                log.err("Failed to open ao library", .{});
                return error.InitializeAoFailed;
            }
        }

        const track_length_seconds = lengthOfAudio(audio_buffer.len, 16, 2, 44100);
        log.info("Track length seconds: {}", .{track_length_seconds});

        const segment_size: u32 = 2 * 2 * 44100;

        playback_state = .playing;

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

        playback_state = .stopped;
        log.info("Audio finished..", .{});
    }

    pub fn stop() void {
        playback_state = .stopped;
    }

    pub fn pause() void {
        playback_state = .paused;
    }

    pub fn @"resume"() !void {
        if (playback_state == .stopped) {
            return error.AudioResumeWithoutSource;
        }
        playback_state = .playing;
    }

    pub fn toggle() !void {
        if (playback_state == .stopped) {
            return error.AudioResumeWithoutSource;
        }

        if (playback_state == .playing) playback_state = .paused;
        if (playback_state == .paused) playback_state = .playing;
    }
};

// pub fn playFlacFile(allocator: *Allocator, file_path: [:0]const u8) !void {}

var input_index: u32 = 0;

var keep_playing: bool = true;

pub const OutputBuffer = struct {
    buffer: []u8,
    position: u32,
};

pub fn decode(allocator: *Allocator, input_file_path: [*:0]const u8) ![]u8 {
    var metadata_info: libflac.FLAC__StreamMetadata = undefined;
    const result = libflac.FLAC__metadata_get_streaminfo(input_file_path, &metadata_info);
    const metadata_type: libflac.FLAC__MetadataType = metadata_info.@"type";

    if (metadata_type != @intToEnum(libflac.FLAC__MetadataType, libflac.FLAC__METADATA_TYPE_STREAMINFO)) {
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

    if (init_status != @intToEnum(libflac.FLAC__StreamDecoderInitStatus, libflac.FLAC__STREAM_DECODER_INIT_STATUS_OK)) {
        _ = libflac.FLAC__stream_decoder_delete(decoder);
        return error.DecoderInitFileFailed;
    }

    ok = libflac.FLAC__stream_decoder_process_until_end_of_stream(decoder);

    if (init_status != @intToEnum(libflac.FLAC__StreamDecoderInitStatus, libflac.FLAC__STREAM_DECODER_INIT_STATUS_OK)) {
        return error.DecodeAudioFailed;
    }

    return output_buffer.buffer;
}

pub fn writeCallback(decoder: [*c]const libflac.FLAC__StreamDecoder, frame: [*c]const libflac.FLAC__Frame, buffer: [*c]const [*c]const libflac.FLAC__int32, client_data: ?*c_void) callconv(.C) libflac.FLAC__StreamDecoderWriteStatus {
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

    return @intToEnum(libflac.FLAC__StreamDecoderWriteStatus, libflac.FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE);
}

pub fn metaCallback(decoder: [*c]const libflac.FLAC__StreamDecoder, metadata: [*c]const libflac.FLAC__StreamMetadata, client_data: ?*c_void) callconv(.C) void {
    //
}

fn writeLittleEndianU16(output_file: *c.FILE, value: u16) bool {
    return c.fputc(value, output_file) != c.EOF and c.fputc(value >> 8, output_file) != c.EOF;
}

fn writeLittleEndianI16(output_file: *c.FILE, value: i16) bool {
    return writeLittleEndianU16(output_file, @bitCast(u16, value));
}

fn writeLittleEndianU32(output_file: *c.FILE, value: u32) bool {
    return c.fputc(@intCast(i32, value), output_file) != c.EOF and
        c.fputc(@intCast(i32, value >> 8), output_file) != c.EOF and
        c.fputc(@intCast(i32, value >> 16), output_file) != c.EOF and
        c.fputc(@intCast(i32, value >> 24), output_file) != c.EOF;
}

var final_size: u32 = 0;

pub fn errorCallback(decoder: [*c]const libflac.FLAC__StreamDecoder, status: libflac.FLAC__StreamDecoderErrorStatus, client_data: ?*c_void) callconv(.C) void {
    log.info("Warning: Error occurred in audio processing", .{});
}
