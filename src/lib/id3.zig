// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");

const Flag = packed struct {
    reserved_bit_0: u1,
    reserved_bit_1: u1,
    reserved_bit_2: u1,
    footer_present: u1,
    experimental: u1,
    extended_header: u1,
    unsynchronisation: u1,
};

pub inline fn synchsafeToU32(value: u32) u32 {
    var result: u32 = value & 0xFF;
    var b: u32 = (value >> 8) & 0xFF;
    var c: u32 = (value >> 16) & 0xFF;
    var d: u32 = (value >> 24) & 0xFF;

    result |= (b << 7);
    result |= (c << 14);
    result |= (d << 21);

    return result;
}

pub const Header = packed struct {
    const Self = @This();

    identifier: [3]u8,
    version_major: u8,
    version_revision: u8,
    flags: u8,
    size: u32,

    pub fn decodeSize(self: *Self) void {
        self.size = std.mem.bigToNative(u32, self.size);
        self.size = synchsafeToU32(self.size);
    }
};

pub const TextEncoding = enum(u8) {
    iso_8859_1 = 0,
    utf_16,
    utf_16_big_endian,
    utf_8,
};

pub const Frame = packed struct {
    const Self = @This();

    id: [4]u8,
    size: u32,
    flags: u16,

    pub fn decodeSize(self: *Self) void {
        self.size = std.mem.bigToNative(u32, self.size);
        // self.size = synchsafeToU32(self.size);
    }
};

const ExtendedHeader = packed struct {
    size: u32,
    flag_bytes_count: u8,
    extended_flags: u8,
};

test "synchsafeToU32" {
    const expect = std.testing.expect;
    try expect(synchsafeToU32(0) == 0);
    try expect(synchsafeToU32(0b0111_1111) == 0b0111_1111);
    try expect(synchsafeToU32(0b0000_0001_0111_1111) == 0b1111_1111);
    try expect(synchsafeToU32(0b0111_1111_0111_1111_0111_1111_0111_1111) == 0b0000_1111_1111_1111_1111_1111_1111_1111);
}

const ChannelMode = enum(u2) {
    stereo,
    joint_stereo,
    dual,
    mono,
};

const Version = enum(u2) {
    mpeg_2_5,
    reserved,
    mpeg_1,
    mpeg_2,
};

pub fn main() !void {
    const print = std.debug.print;
    const allocator = std.heap.c_allocator;

    const start_time = std.time.milliTimestamp();

    const directory_path = std.os.argv[1];
    const directory_path_len = blk: {
        var i: u32 = 0;
        while (i < 2048) : (i += 1) {
            if (directory_path[i] == 0) {
                break :blk i;
            }
        }
        unreachable;
    };

    const directory = std.fs.openDirAbsoluteZ(directory_path, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to open '{s}' with error {s}", .{ directory_path, err });
        return err;
    };

    var iterator = directory.iterate();
    while (try iterator.next()) |entry| {
        const name = entry.name;
        const extension = name[name.len - 3 .. name.len];
        if (std.mem.eql(u8, extension, "mp3")) {
            // print("{s}\n", .{name});
            const join_list = [_][]const u8{ directory_path[0..directory_path_len], name };
            const full_path = try std.mem.join(allocator, "/", join_list[0..]);
            print("{s}\n", .{full_path});

            const file = std.fs.openFileAbsolute(full_path, .{}) catch |err| {
                std.log.err("Failed to open file '{s}' with err {s}", .{ full_path, err });
                return err;
            };
            allocator.free(full_path);

            var file_bytes: []u8 = try file.readToEndAlloc(allocator, 1024 * 1024 * 40);
            defer allocator.free(file_bytes);
            file.close();

            var header: *Header = @ptrCast(*Header, file_bytes.ptr);
            header.size = std.mem.bigToNative(u32, header.size);
            header.size = synchsafeToU32(header.size);

            // print("Bytes read: {d}\n", .{file_bytes.len});
            // print("TAG: '{s}'\n", .{header.identifier});

            if (header.identifier[0] != 'I' or header.identifier[1] != 'D' or header.identifier[2] != '3') {
                std.log.err("ID3 header is invalid", .{});
                return;
            }

            // print("Version {d}.{d}\n", .{ header.version_major, header.version_revision });
            // print("Flags {d}\n", .{header.flags});
            // print("Size {d}\n", .{header.size});

            var frame_start: [*]u8 = @ptrCast([*]u8, &file_bytes[@sizeOf(Header)]);

            std.debug.assert(@sizeOf(Header) == 10);

            // var i: u32 = 0;
            // var frame: *Frame = undefined;
            // while (i < header.size) {
            // frame = @ptrCast(*Frame, frame_start);
            // if (frame.id[0] == 0) {
            // break;
            // }

            // frame.size = std.mem.bigToNative(u32, frame.size);
            // frame.size = synchsafeToU32(frame.size);
            // // print("{s} -- {d}\n", .{ frame.id, frame.size });

            // const tabl = "TALB";
            // if (std.mem.eql(u8, frame.id[0..], tabl)) {
            // // print("  Album: {s}\n", .{frame_start[10 .. 10 + frame.size]});
            // }

            // const tit2 = "TIT2";
            // if (std.mem.eql(u8, frame.id[0..], tit2)) {
            // // print("  Title: {s}\n", .{frame_start[10 .. 10 + frame.size]});
            // }

            // const trck = "TRCK";
            // if (std.mem.eql(u8, frame.id[0..], trck)) {
            // // print("  Track #: {s}\n", .{frame_start[10 .. 10 + frame.size]});
            // }

            // const tpub = "TPUB";
            // if (std.mem.eql(u8, frame.id[0..], tpub)) {
            // // print("  Publisher: {s}\n", .{frame_start[10 .. 10 + frame.size]});
            // }

            // const tlen = "TLEN";
            // if (std.mem.eql(u8, frame.id[0..], tlen)) {
            // print("  Length: {s}ms\n", .{frame_start[10 .. 10 + frame.size]});
            // }

            // const tpe1 = "TPE1";
            // if (std.mem.eql(u8, frame.id[0..], tpe1)) {
            // // print("  Artist: {s}\n", .{frame_start[10 .. 10 + frame.size]});
            // }

            // frame_start += (frame.size + 10);
            // i += (frame.size + 10);
            // }

            var byte: [*]u8 = @ptrCast([*]u8, &frame_start[header.size]);
            var x: u32 = 0;
            while (x < 1024 * 10) : (x += 1) {
                if (byte[x] == 255 and byte[x + 1] != 255) {
                    break;
                }
            }

            if (x == 1024 * 10) {
                std.log.err("Failed to find first frame", .{});
                return error.InvalidMp3Format;
            }

            var frame_count: u32 = 0;
            while (x < file_bytes.len) : (frame_count += 1) {
                const version_id_mask = 0b00011000;
                const version_id: u8 = (byte[x + 1] & version_id_mask) >> 3;
                const version: Version = switch (version_id) {
                    0b00 => .mpeg_2_5,
                    0b01 => .reserved,
                    0b10 => .mpeg_2,
                    0b11 => .mpeg_1,
                    else => unreachable,
                };

                const layer_mask = 0b00000110;
                const layer: u8 = (byte[x + 1] & layer_mask) >> 1;
                switch (layer) {
                    0b00 => print("Reserved\n", .{}),
                    0b01 => print("Layer III\n", .{}),
                    0b10 => print("Layer II\n", .{}),
                    0b11 => print("Layer I\n", .{}),
                    else => unreachable,
                }
                const crc_protection_mask = 0b00000001;
                const is_crc_protected = (byte[x + 1] & crc_protection_mask) > 0;
                print("Crc protection: {s}\n", .{is_crc_protected});

                const sample_rate_mask = 0b00001100;
                const sample_rate_index: u8 = (byte[x + 2] & sample_rate_mask) >> 2;
                const sample_rate: u32 = switch (sample_rate_index) {
                    0b00 => 44100,
                    0b01 => 48000,
                    0b10 => 32000,
                    0b11 => std.math.maxInt(u32),
                    else => unreachable,
                };

                if (sample_rate == std.math.maxInt(u32)) {
                    std.log.err("Reserved bit set for sample rate. Invalid mp3 frame", .{});
                    return error.InvalidMp3Frame;
                }

                print("Sample rate: {d}\n", .{sample_rate});

                const bitrate_mask = 0b11110000;
                const bitrate_index = (byte[x + 2] & bitrate_mask) >> 4;
                const bitrate: u32 = switch (bitrate_index) {
                    0b0000 => 0,
                    0b0001 => 32 * 1000,
                    0b0010 => 40 * 1000,
                    0b0011 => 48 * 1000,
                    0b0100 => 56 * 1000,
                    0b0101 => 64 * 1000,
                    0b0110 => 80 * 1000,
                    0b0111 => 96 * 1000,
                    0b1000 => 112 * 1000,
                    0b1001 => 124 * 1000,
                    0b1010 => 160 * 1000,
                    0b1011 => 192 * 1000,
                    0b1100 => 224 * 1000,
                    0b1101 => 256 * 1000,
                    0b1110 => 320 * 1000,
                    0b1111 => std.math.maxInt(u32),
                    else => unreachable,
                };

                if (bitrate == 0) {
                    print("Bitrate: Free\n", .{});
                } else if (bitrate == std.math.maxInt(u32)) {
                    print("Bitrate: Bad\n", .{});
                } else {
                    print("Bitrate: {d}\n", .{bitrate});
                }

                const is_padding_mask = 0b00000010;
                const padding_bytes: u8 = (byte[x + 2] & is_padding_mask) >> 1;
                print("Added padding: {d}\n", .{padding_bytes});

                const channel_mode_mask = 0b11000000;
                const channel_mode_index = (byte[x + 3] & channel_mode_mask) >> 6;

                const channel_mode: ChannelMode = switch (channel_mode_index) {
                    0b00 => .stereo,
                    0b01 => .joint_stereo,
                    0b10 => .dual,
                    0b11 => .mono,
                    else => unreachable,
                };

                const frame_length: u32 = ((144 * bitrate) / sample_rate) + padding_bytes;
                print("Frame length: {d}\n", .{frame_length});

                // 36-39		"Xing" for MPEG and CHANNEL != mono (mostly used)
                // 21-24		"Xing" for MPEG1 and CHANNEL == mono
                // 21-24		"Xing" for MPEG2 and CHANNEL != mono
                // 13-16		"Xing" for MPEG2 and CHANNEL == mono

                const vbr_indicator_index_2: u32 = blk: {
                    if (channel_mode == .mono) {
                        if (version == .mpeg_2) {
                            break :blk 13;
                        }
                    }

                    if (version == .mpeg_1) {
                        break :blk 36;
                    }

                    break :blk 21;
                };
                _ = vbr_indicator_index_2;

                // TODO: Different values for layer 1
                const sample_count_per_frame: u32 = 1152;
                const slot_size: u8 = 1;

                // const vbr_indicator_tag = "Xing";
                // const vbr_indicator_start: u32 = 4 + vbr_indicator_index;

                // const is_vbr = std.mem.eql(u8, vbr_indicator_tag, byte[vbr_indicator_start .. vbr_indicator_start + 4]);

                const is_vbr = blk: {
                    var i: u32 = 0;
                    const b = @ptrCast([*]u8, &byte[4]);
                    while (i <= 36) : (i += 1) {
                        if (b[i] == 'X' and b[i + 1] == 'i' and b[i + 2] == 'n' and b[i + 3] == 'g') {
                            break :blk true;
                        }
                    }
                    break :blk false;
                };

                print("VBR: {s}\n", .{is_vbr});

                if (!is_vbr) {

                    // 113 = frame_count * 0.026;
                    // frame_count = 4346

                    const duration = (@intToFloat(f64, file_bytes.len) / @intToFloat(f64, frame_length)) * 0.026;
                    print("Duration of audio: {d} seconds\n", .{duration});
                }
                x += frame_length * sample_count_per_frame * slot_size;

                if (frame_count == 4) {
                    break;
                }
            }

            print("Frame count: {d}\n", .{frame_count});
        }
    }
    const end_time = std.time.milliTimestamp();
    print("Duration {d}ms\n", .{end_time - start_time});
}
