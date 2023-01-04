// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const memory = @import("memory.zig");
const event_system = @import("event_system.zig");
const FixedAtomicEventQueue = @import("message_queue.zig").FixedAtomicEventQueue;
const Playlist = @import("Playlist.zig");
const Storage = Playlist.Storage;
const audio = @import("audio.zig");

const DirectoryContents = struct {
    arena_index: u16 = 0,
    count: u16 = 0,
    size: u16 = 0,

    /// Adds a new path / file
    /// The first entry is treated as the directory path,
    /// while the following are interpreted as files within that directory
    // NOTE: parent path should include final '/'
    pub fn add(self: *@This(), arena: *memory.LinearArena, name: []const u8) void {
        std.log.info("Adding: {s}", .{name});

        std.debug.assert(name.len < std.math.maxInt(u8));
        arena.create(u8).* = @intCast(u8, name.len);
        var entry = arena.allocate(u8, @intCast(u16, name.len + 1));
        std.mem.copy(u8, entry, name);
        entry[entry.len - 1] = 0;
        self.size += @intCast(u16, name.len + 2);

        self.count += 1;
    }

    pub inline fn directoryCount(self: @This()) u16 {
        if (self.count < 1) return 0;
        return self.count - 1;
    }

    /// Returns the path of the parent directory
    pub fn parent(self: @This()) []const u8 {
        const base = @intToPtr([*]const u8, @ptrToInt(&self) + @sizeOf(@This()));
        const length: usize = @intCast(usize, base[0]);
        return base[1 .. 1 + length];
    }

    /// Returns the name of the file at the index given
    pub fn filename(self: @This(), index: u8) []const u8 {
        std.debug.assert(index < self.count);
        const base = @intToPtr([*]const u8, @ptrToInt(&self) + @sizeOf(@This()));

        var i: u16 = 0;
        var offset: u16 = 0;
        var length: u8 = 0;
        while (i <= index) : (i += 1) {
            std.debug.assert(i < self.size);
            length = base[offset];
            offset += (length + 2);
        }
        const begin = offset + 1;
        return base[begin .. begin + base[offset]];
    }

    /// Returns the name of the file at the index given
    pub fn filenameZ(self: @This(), index: u8) [:0]const u8 {
        const base = @intToPtr([*]const u8, @ptrToInt(&self) + @sizeOf(@This()));
        var i: u16 = 0;
        var offset: u16 = 0;
        var length: u8 = 0;
        while (i < (index + 1)) : (i += 1) {
            length = base[offset];
            offset += (length + 2);
        }
        const begin = offset + 1;
        return base[begin .. begin + base[offset] + 1];
    }

    pub fn fullPathZ(self: @This(), index: u8, output_buffer: []u8) ![:0]const u8 {
        const parent_path = self.parent();
        const file_name = self.filename(index);
        const total_length = parent_path.len + file_name.len;
        if (output_buffer.len < total_length) {
            return error.InsufficientMemoryAllocated;
        }
        std.mem.copy(u8, output_buffer, parent_path);
        std.mem.copy(u8, output_buffer[parent_path.len..], file_name);
        return output_buffer[0 .. total_length + 1];
    }

    pub fn fullPath(self: @This(), index: u8, output_buffer: []u8) ![]const u8 {
        const parent_path = self.parent();
        const file_name = self.filename(index);
        const total_length = parent_path.len + file_name.len;
        if (output_buffer.len < total_length) {
            return error.InsufficientMemoryAllocated;
        }
        std.mem.copy(u8, output_buffer, parent_path);
        std.mem.copy(u8, output_buffer[parent_path.len..], file_name);
        return output_buffer[0..total_length];
    }

    pub fn contentsPrint(self: @This()) void {
        const print = std.debug.print;
        var i: u8 = 1;
        const count: usize = self.count - 1;
        print("DIRECTORY CONTENTS: {d}\n", .{count});
        while (i < count) : (i += 1) {
            print("  {d}: '{s}'\n", .{ i, self.filename(i) });
        }
    }

    // TODO: Does this makes sense?
    pub inline fn reset(self: *@This()) void {
        self.arena_index = 0;
        self.count = 0;
        self.size = 0;
    }
};

const Command = struct {
    // Opens a trackview using index of current directory
    const invoke_directory_base_index: u8 = 0;
    const invoke_directory_range: u8 = 64;

    const command_base_index: u8 = 200;
    const cd_up: u8 = command_base_index + 0;
    const reset: u8 = command_base_index + 1;
};

pub const navigation = struct {
    const Event = enum(u8) {
        directory_changed,
        trackview_opened,
        duration_calculated,
    };

    pub fn calculateDurationsWrapper(storage: *Storage) void {
        calculateDurations(storage) catch |err| {
            std.log.err("Failed to calculate durations. Error -> {}", .{err});
        };
    }

    pub fn calculateDurations(storage: *Storage) !void {
        const entries_count = storage.track_entry_count;
        std.debug.assert(entries_count <= 64);

        var file_handle_buffer: [64]std.fs.File = undefined;
        var max_size: usize = 0;

        for (storage.entries()) |entry, entry_i| {
            const absolute_path = try entry.absolutePathZ();
            file_handle_buffer[entry_i] = try std.fs.openFileAbsolute(absolute_path, .{ .mode = .read_only });
            errdefer file_handle_buffer[entry_i].close();

            const file_stat = try file_handle_buffer[entry_i].stat();
            const file_size = file_stat.size;

            if (file_size > max_size) {
                max_size = file_size;
            }
        }

        var buffer = try std.heap.page_allocator.alloc(u8, max_size);
        defer std.heap.page_allocator.free(buffer);

        for (storage.entriesMut()) |*entry, entry_i| {
            var file_handle = file_handle_buffer[entry_i];
            const bytes_read = try file_handle.readAll(buffer);
            entry.duration_seconds = audio.mp3.calculateDurationSecondsFromFile(buffer[0..bytes_read]);
            try navigation.message_queue.add(.duration_calculated);
            file_handle.close();
        }
    }

    pub fn isPlaylistAlsoTrackview() bool {
        if (Playlist.storage_opt) |playlist_storage| {
            if (trackview_storage_opt) |trackview_storage| {
                return playlist_storage == trackview_storage;
            }
        }
        return false;
    }

    pub var subsystem_index: event_system.SubsystemIndex = undefined;

    pub var directoryview_storage: *DirectoryContents = undefined;
    pub var trackview_storage_opt: ?*Storage = null;

    pub var directoryview_path: std.fs.IterableDir = undefined;
    pub var trackview_path_opt: ?std.fs.IterableDir = null;

    pub var message_queue: FixedAtomicEventQueue(Event, 10) = .{};
    pub var root_depth: u16 = 0;
    pub var contains_audio: bool = false;

    var calculate_durations_thread: std.Thread = undefined;

    var arena_opt: ?*memory.LinearArena = undefined;

    // pub fn trackViewOpen(index: u8) !void {
    //     if (arena_opt) |arena| {
    //         std.log.info("Opening trackview", .{});
    //         const subpath = directoryview_storage.filename(index);
    //         trackview_path_opt = try directoryview_path.openDir(subpath, .{ .iterate = true });
    //         const offset: u32 = 0;
    //         const max_entries: u16 = 20;
    //         trackview_storage = try Storage.create(arena, trackview_path_opt.?, offset, max_entries);

    //         calculate_durations_thread = try std.Thread.spawn(.{}, calculateDurationsWrapper, .{trackview_storage});
    //         try message_queue.add(.trackview_opened);
    //     } else {
    //         return error.InvalidArenaReference;
    //     }
    // }

    // pub fn doOpenTrackView(directory_index: u8) !event_system.ActionIndex {
    //     if (directory_index >= directoryview_storage.directoryCount()) {
    //         std.log.err(
    //             \\Attempt to create a OpenTrackView command with invalid directory index {d}.
    //             \\Valid indices are 0 - {d}
    //         , .{ directory_index, directoryview_storage.directoryCount() - 1 });
    //         return error.InvalidDirectoryIndex;
    //     }
    //     std.debug.assert(directory_index < Command.open_view_range);
    //     return @intCast(event_system.ActionIndex, directory_index + Command.open_view_base_index);
    // }

    pub inline fn doDirectorySelect(directory_index: u8) event_system.ActionIndex {
        std.debug.assert(directory_index < Command.invoke_directory_range);
        return @intCast(event_system.ActionIndex, directory_index + Command.invoke_directory_base_index);
    }

    pub inline fn doDirectoryUp() event_system.ActionIndex {
        return @intCast(event_system.ActionIndex, Command.cd_up);
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

    // You could allocate some space for the path of the playlist path
    // Other submodules can take a u16 to it and read
    pub fn init(arena: *memory.LinearArena, path: std.fs.IterableDir) !void {
        arena_opt = arena;
        directoryview_path = path;

        var path_buffer: [512]u8 = undefined;
        var path_string = try path.dir.realpath(".", path_buffer[0..]);

        if (path_string.len == 512) {
            return error.InsufficientMemoryAllocated;
        }

        path_buffer[path_string.len] = '/';

        std.log.info("PATH: '{s}'", .{path_string});
        directoryview_storage = arena.create(DirectoryContents);
        directoryview_storage.*.count = 0;
        directoryview_storage.*.size = 0;
        directoryview_storage.*.arena_index = 0;

        directoryview_storage.add(arena, path_buffer[0 .. path_string.len + 1]);

        contains_audio = blk: {
            var iterator = path.iterate();
            var count: u32 = 0;
            while (try iterator.next()) |entry| {
                if (entry.kind == .File) {
                    const extension = parseExtension(entry.name) catch "";
                    if (matchExtension("MP3", extension) or matchExtension("FLAC", extension)) {
                        break :blk true;
                    }
                }
                count += 1;
                if (count == 20) break;
            }
            break :blk false;
        };

        var iterator = path.iterate();
        var count: u32 = 0;
        while (try iterator.next()) |entry| {
            // TODO: You need to know whether to add only audio or directories
            if (contains_audio and entry.kind == .File) {
                const extension = parseExtension(entry.name) catch "";
                if (matchExtension("MP3", extension) or matchExtension("FLAC", extension)) {
                    directoryview_storage.add(arena, entry.name);
                    count += 1;
                }
            } else if (!contains_audio and entry.kind == .Directory) {
                directoryview_storage.add(arena, entry.name);
                count += 1;
            }

            if (count == 20) break;
        }

        navigation.directoryview_storage.contentsPrint();
    }

    pub inline fn directoryUp() void {
        // NOTE: This action will invalidate most of the state / memory of the application
        //       As a result this action is passed up so that memory can be managed by a higher system
        if (root_depth > 0) {
            directoryview_path = directoryview_path.dir.openIterableDir("..", .{}) catch |err| {
                std.log.err("Failed to change to parent directory. Error: {}", .{err});
                return;
            };
            message_queue.add(.directory_changed) catch |err| {
                std.log.err("Failed to add .directory_changed event to message queue. Error -> {}", .{err});
                return;
            };
            root_depth -= 1;
        }
    }

    pub inline fn directoryDown(directory_index: u8) void {
        // NOTE: This action will invalidate most of the state / memory of the application
        //       As a result this action is passed up so that memory can be managed by a higher system

        const directory_count = directoryview_storage.directoryCount();
        if (directory_count == 0) {
            std.log.err("No subdirectories loaded to change into", .{});
            return;
        }

        const maximum_valid_index = directory_count - 1;
        if (directory_index > maximum_valid_index) {
            std.log.err("Attempt to change directory using invalid index {d}. Maximum valid index is {d}", .{
                directory_index,
                maximum_valid_index,
            });
            return;
        }

        const subpath = directoryview_storage.filename(directory_index);
        const new_path = directoryview_path.dir.openIterableDir(subpath, .{}) catch |err| {
            std.log.err("Failed to open subpath '{s}'. Error: {}", .{ subpath, err });
            return;
        };

        const has_audio = blk: {
            var iterator = new_path.iterate();
            // TODO:
            while (iterator.next() catch break :blk false) |entry| {
                if (entry.kind == .File) {
                    const extension = parseExtension(entry.name) catch "";
                    if (matchExtension("MP3", extension) or matchExtension("FLAC", extension)) {
                        break :blk true;
                    }
                }
            }
            break :blk false;
        };

        if (has_audio) {
            trackview_path_opt = new_path;
            message_queue.add(.trackview_opened) catch |err| {
                std.log.err("Failed to emit .trackview_opened event. Error: {}", .{err});
            };
        } else {
            directoryview_path = new_path;
            root_depth += 1;
            message_queue.add(.directory_changed) catch |err| {
                std.log.err("Failed to emit .directory_changed event. Error: {}", .{err});
            };
        }
    }

    pub fn doAction(index: event_system.ActionIndex) void {
        std.log.info("navigation doAction invoked", .{});

        const invoke_directory_max = Command.invoke_directory_base_index + Command.invoke_directory_range;
        if (index >= Command.invoke_directory_base_index and index < invoke_directory_max) {
            std.log.info("Invoking invoke_directory", .{});
            directoryDown(@intCast(u8, index - Command.invoke_directory_base_index));
            return;
        }

        switch (index) {
            Command.cd_up => directoryUp(),
            else => unreachable,
        }
    }
};
