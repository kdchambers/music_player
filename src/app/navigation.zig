// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const memory = @import("memory");
const event_system = @import("event_system");
const FixedAtomicEventQueue = @import("message_queue").FixedAtomicEventQueue;

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
        const base = @ptrCast([*]const u8, @ptrToInt(self) + @sizeOf(@This()));
        const length = base;
        return base[1 .. 1 + length];
    }

    /// Returns the name of the file at the index given
    pub fn filename(self: @This(), index: u8) []const u8 {
        const base = @intToPtr([*]const u8, @ptrToInt(&self) + @sizeOf(@This()));
        var i: u16 = 0;
        var offset: u16 = 0;
        var length: u8 = 0;
        while (i < (index + 1)) : (i += 1) {
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
        var i: u8 = 0;
        print("DIRECTORY CONTENTS: {d}\n", .{self.count});
        while (i < (self.count - 1)) : (i += 1) {
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

pub const navigation = struct {
    const Event = enum(u8) {
        directory_changed,
        playlist_opened,
    };

    pub var contents: *DirectoryContents = undefined;
    pub var message_queue: FixedAtomicEventQueue(Event, 10) = .{};
    pub var current_path: std.fs.Dir = undefined;
    pub var playlist_path_opt: ?std.fs.Dir = null;
    pub var root_depth: u16 = 0;
    pub var contains_audio: bool = false;
    pub var subsystem_index: event_system.SubsystemIndex = undefined;
    pub var action_list: memory.FixedBuffer(ParameterizedAction, 64) = undefined;

    pub fn reset() void {
        action_list.clear();
    }

    // All actions except none, cd_up and reset will reference a loaded directory
    // Therefore it makes sense to store them together
    pub const ParameterizedAction = packed struct {
        action: Action,
        directory_index: u8,
    };

    pub const Action = enum(u8) {
        cd_up,
        cd_down,
        reset,
    };

    pub const DoDirectorySelectReturn = struct {
        // First action index
        base_action_index: u8,
        // Number of actions
        action_count: u8,
        subsystem: event_system.SubsystemIndex,

        pub inline fn actionIndexFor(self: *@This(), action_index: u8) u8 {
            std.debug.assert(self.action_count > action_index);
            return self.base_action_index + action_index;
        }
    };

    // The return value is the first action index
    // Each subsequent action has a consequetive index
    pub fn doDirectorySelect() !DoDirectorySelectReturn {
        const remaining_space = action_list.remainingCount();
        const directory_count = @intCast(u8, contents.directoryCount());
        if (directory_count > remaining_space) {
            return error.InsufficientMemoryAllocated;
        }

        const next_action_index = @intCast(u8, action_list.count);
        var i: u32 = 0;
        var parameterized_action = ParameterizedAction{
            .action = .cd_down,
            .directory_index = undefined,
        };
        while (i < directory_count) : (i += 1) {
            std.debug.assert(i < std.math.maxInt(u8));
            parameterized_action.directory_index = @intCast(u8, i);
            _ = action_list.append(parameterized_action);
        }
        return DoDirectorySelectReturn{
            .base_action_index = next_action_index,
            .action_count = directory_count,
            .subsystem = subsystem_index,
        };
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

    pub const InitRet = struct {
        playlist_index: u16,
    };

    // You could allocate some space for the path of the playlist path
    // Other submodules can take a u16 to it and read
    pub fn init(arena: *memory.LinearArena, path: std.fs.Dir) !void {
        current_path = path;

        action_list.clear();

        var path_buffer: [512]u8 = undefined;
        var path_string = try path.realpath(".", path_buffer[0..]);

        if (path_string.len == 512) {
            return error.InsufficientMemoryAllocated;
        }

        path_buffer[path_string.len] = '/';

        std.log.info("PATH: '{s}'", .{path_string});
        contents = arena.create(DirectoryContents);
        contents.*.count = 0;
        contents.*.size = 0;
        contents.*.arena_index = 0;

        contents.add(arena, path_buffer[0 .. path_string.len + 1]);

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
                    contents.add(arena, entry.name);
                    count += 1;
                }
            } else if (!contains_audio and entry.kind == .Directory) {
                contents.add(arena, entry.name);
                count += 1;
            }

            if (count == 20) break;
        }

        navigation.contents.contentsPrint();
    }

    pub inline fn directoryUp() void {
        // NOTE: This action will invalidate most of the state / memory of the application
        //       As a result this action is passed up so that memory can be managed by a higher system
        if (root_depth > 0) {
            current_path = current_path.openDir("..", .{}) catch |err| {
                std.log.err("Failed to change to parent directory. Error: {s}", .{err});
                return;
            };
            root_depth -= 1;
        }
    }

    pub inline fn directoryDown(directory_index: u8) void {
        // NOTE: This action will invalidate most of the state / memory of the application
        //       As a result this action is passed up so that memory can be managed by a higher system

        const directory_count = contents.directoryCount();
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

        const subpath = contents.filename(directory_index);
        const new_path = current_path.openDir(subpath, .{ .iterate = true }) catch |err| {
            std.log.err("Failed to open subpath '{s}'. Error: {s}", .{ subpath, err });
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
            playlist_path_opt = new_path;
            message_queue.add(.playlist_opened) catch |err| {
                std.log.err("Failed to emit .playlist_opened event. Error: {s}", .{err});
            };
        } else {
            current_path = new_path;
            root_depth += 1;
            message_queue.add(.directory_changed) catch |err| {
                std.log.err("Failed to emit .directory_changed event. Error: {s}", .{err});
            };
        }
    }

    pub fn doAction(action_index: event_system.ActionIndex) void {
        const parameterized_action = action_list.items[action_index];
        std.log.info("Action triggered in navigation subsystem", .{});
        switch (parameterized_action.action) {
            .cd_up => directoryUp(),
            .cd_down => directoryDown(parameterized_action.directory_index),
            .reset => {},
        }
    }
};
