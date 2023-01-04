// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const memory = @import("memory.zig");

const LibraryNavigator = @This();

const parent_directory_id = std.math.maxInt(u16);
const media_item_buffer_size: u16 = 32;

const OutputEvent = enum(u8) {
    initialized,
    directory_change,
    load_complete,
    play_audio,
};

const Playlist = struct {
    allocator: std.mem.Allocator,
    audio_files: *[*:0]const u8,
    current_index: u32,

    pub fn next() ?[*:0]const u8 {
        //
    }
};

const DirectoryContents = struct {
    // root_dir
    // depth_index
    // count
    // [] dir_name
    //
    // up()
    // down()
    //
};

// onClick(index)
//  - directoryChanged
//  - audioInvoked
// onAudioFinished
// onDirectoryChanged(new_items)

current_directory: std.fs.Dir,
loaded_media_items: memory.FixedBuffer(MediaItem, media_item_buffer_size) = .{},
root_depth: u16 = 0,

pub const MediaItem = struct {
    const Self = @This();

    const FileType = enum(u8) {
        unknown,
        directory,
        mp3,
        flac,
    };

    const max_filename_length: u16 = 62;

    name_length: u8,
    extension_length: u8,
    name: [max_filename_length]u8,

    pub fn root(self: Self) []const u8 {
        return self.name[0..self.name_length];
    }

    pub fn fileName(self: Self) []const u8 {
        return self.name[0 .. self.name_length + 1 + self.extension_length];
    }

    pub inline fn fileType(self: Self) FileType {
        if (self.extension_length == 0) {
            return .directory;
        }

        var upper_extension: [4]u8 = undefined;
        for (self.name[self.name_length + 1 .. self.name_length + 1 + self.extension_length]) |*char, i| {
            upper_extension[i] = std.ascii.toUpper(char.*);
        }

        if (std.mem.eql(u8, "FLAC", upper_extension[0..4])) return .flac;
        if (std.mem.eql(u8, "MP3", upper_extension[0..3])) return .mp3;

        return .unknown;
    }

    pub inline fn isFile(self: Self) bool {
        return (self.extension_length == std.math.maxInt(u8));
    }

    pub inline fn isDirectory(self: Self) bool {
        return (self.extension_length != std.math.maxInt(u8));
    }
};

pub fn containsAudio(self: LibraryNavigator) bool {
    if (self.loaded_media_items.count == 0) {
        std.debug.assert(false);
        return false;
    }

    const file_type = self.loaded_media_items.items[0].fileType();
    return (file_type == .mp3 or file_type == .flac);
}

pub fn up(self: *LibraryNavigator) bool {
    if (self.root_depth > 0) {
        self.current_directory = self.current_directory.openDir("..", .{ .iterate = true }) catch return false;
        self.root_depth -= 1;
        return true;
    }
    return false;
}

fn parseExtension(file_name: []const u8) ![]const u8 {
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

fn matchExtension(extension: []const u8, string: []const u8) bool {
    if (string.len < extension.len) return false;
    for (extension) |char, i| {
        if (char != std.ascii.toUpper(string[i])) {
            return false;
        }
    }
    return true;
}

pub fn down(
    self: *LibraryNavigator,
    directory_index: u16,
) void {
    std.debug.assert(directory_index < self.loaded_media_items.items.len);
    const new_directory_name = blk: {
        const media_item = self.loaded_media_items.items[directory_index];
        std.debug.assert(media_item.name_length > 0);
        break :blk media_item.name[0..media_item.name_length];
    };

    self.current_directory = self.current_directory.openDir(new_directory_name, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to open new directory '{s}' : {}", .{ new_directory_name, err });
        return;
    };

    self.root_depth += 1;
}

pub fn load(
    self: *LibraryNavigator,
    max_items_count: u16,
    item_offset: u16,
) !void {
    _ = item_offset;

    //
    // TODO: Rewrite to only iterate over files once
    //

    const contains_audio: bool = blk: {
        var iterator = self.current_directory.iterate();
        while (try iterator.next()) |entry| {
            if (entry.name.len > MediaItem.max_filename_length) {
                std.log.err("'{s}' ({d} charactors) is too long", .{ entry.name, entry.name.len });
                std.debug.assert(entry.name.len <= MediaItem.max_filename_length);
            }

            if (entry.kind == .File) {
                const extension = parseExtension(entry.name) catch "";
                if (matchExtension("MP3", extension) or matchExtension("FLAC", extension)) {
                    break :blk true;
                }
            }
        }
        break :blk false;
    };

    const item_count: u32 = blk: {
        var count: u32 = 0;
        var iterator = self.current_directory.iterate();
        while (try iterator.next()) |entry| {
            if (!contains_audio and entry.kind == .Directory) {
                count += 1;
                // TODO: Removed hardcoded limit
                if (count == 20) break :blk count;

                continue;
            }

            if (contains_audio and entry.kind == .File) {
                const extension = parseExtension(entry.name) catch "";
                if (matchExtension("MP3", extension) or matchExtension("FLAC", extension)) {
                    count += 1;
                }
            }

            // TODO: Removed hardcoded limit
            if (count == 20) break :blk count;
        }
        break :blk count;
    };

    std.debug.assert(item_count <= media_item_buffer_size);
    self.loaded_media_items.count = item_count;

    var iterator = self.current_directory.iterate();
    var i: u32 = 0;
    while (try iterator.next()) |entry| {
        if (i == max_items_count) return;

        if (!contains_audio and entry.kind != .Directory) {
            continue;
        }

        if (contains_audio) {
            const extension = parseExtension(entry.name) catch "";
            if (!(matchExtension("MP3", extension) or matchExtension("FLAC", extension))) {
                continue;
            }
        }

        var media_items = &self.loaded_media_items.items;
        std.mem.copy(u8, media_items[i].name[0..MediaItem.max_filename_length], entry.name);
        media_items[i].name_length = @intCast(u8, entry.name.len);
        media_items[i].extension_length = 0;
        if (contains_audio) {
            const extension = parseExtension(entry.name) catch "";
            media_items[i].extension_length = @intCast(u8, extension.len);
            media_items[i].name_length = @intCast(u8, entry.name.len - (extension.len + 1));
            std.log.info("Added media item '{s}' with extension '{s}'", .{
                media_items[i].name[0..media_items[i].name_length],
                extension,
            });
        } else {
            std.log.info("Added media item '{s}'", .{media_items[i].root()});
        }

        i += 1;
    }
}

pub fn create(initial_directory: std.fs.Dir) LibraryNavigator {
    return LibraryNavigator{
        .current_directory = initial_directory,
    };
}
