// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

// The purpose of this is to have a reduced memory space where you can use 16bit "pointers"

// Traits
// 1. Comptime casting
// 2. Global
// 3. Events for warnings, hints, etc ?
// 4. Read only

const std = @import("std");
const memory = @import("memory");

/// Secondary semi-global address space that uses 16-bit "pointers"
const storage = @This();

pub const PointerBaseType: type = u16;
pub const nullptr: u16 = std.math.maxInt(u16);

pub fn Pointer(comptime Type: type) type {
    return struct {
        address: u16,

        pub inline fn get(self: @This()) Type {
            return .{
                .addr = @ptrCast(@TypeOf(Type.addr), &memory_space[self.address]),
            };
        }
    };
}

// pub const Pointer = u16;

pub var memory_space: []u8 = undefined;

// TODO: Maybe I should allocate from here and then use it to back allocators
// Can verify address space is <= 65k
pub fn init(mem: []u8) void {
    std.log.info("Storage initialized", .{});
    memory_space = mem;
}

pub inline fn get(comptime Type: type, address: PointerBaseType) *const Type {
    return @ptrCast(*const Type, &memory_space[address]);
}

pub inline fn indexFor(arena: *memory.LinearArena, slice: []const u8) u16 {
    const ptr = @ptrCast(*const u8, slice.ptr);
    const offset = @ptrToInt(&arena.memory[0]) - @ptrToInt(&memory_space[0]);
    return @intCast(u16, arena.indexFor(ptr) + offset);
}

pub const String = struct {
    pub const Index = u16;
    pub const null_index: u16 = std.math.maxInt(u16);

    const length_index: u32 = 0;
    const string_index: u32 = 2;

    // FORMAT:
    //
    // [0..2] length
    // [2..N-1] string
    // [N] null terminator

    pub inline fn write(arena: *memory.LinearArena, string: []const u8) !String.Index {
        var data = arena.allocateAligned(u8, 2, @intCast(u16, string.len + 3));
        std.debug.assert(data.len > string.len);

        @ptrCast(*u16, @alignCast(2, data.ptr)).* = @intCast(u16, string.len);
        var dest_slice = data[string_index .. string_index + string.len];

        std.debug.assert(dest_slice.len == string.len);
        std.debug.assert((dest_slice.len + 3) == data.len);

        std.mem.copy(u8, dest_slice, string);

        data[data.len - 1] = 0;
        const result_index = indexFor(arena, data);

        // Sanity check
        std.debug.assert(String.length(result_index) == string.len);
        std.debug.assert(std.mem.eql(u8, String.value(result_index), string));

        return result_index;
    }

    pub inline fn calculateSpaceRequired(string_len: usize) u16 {
        return @intCast(u16, string_len) + 2;
    }

    pub inline fn length(index: String.Index) u16 {
        std.debug.assert(@ptrToInt(&storage.memory_space[index]) % 2 == 0);
        const base_ptr = @ptrCast([*]const u8, @alignCast(2, &storage.memory_space[index]));
        return @ptrCast(*const u16, @alignCast(2, &base_ptr[length_index])).*;
    }

    pub inline fn value(index: String.Index) []const u8 {
        const len = String.length(index);
        const base_ptr = @ptrCast([*]const u8, @alignCast(2, &storage.memory_space[index]));
        return base_ptr[string_index .. string_index + len];
    }
};

pub const AbsolutePath = struct {
    const length_index: u32 = 0;
    const writable_memory_size_index: u32 = 2;
    const path_index: u32 = 4;

    pub const Index = u16;

    pub fn write(
        arena: *memory.LinearArena,
        path_string: []const u8,
        reserved_memory_opt: ?u16,
    ) !AbsolutePath.Index {

        // Allocate space for the following
        // - Size of path string (u16)
        // - Reserved writable space (u16)
        // - Path string
        // - Path string null terminator

        // Trailing '/' is required for this type. We add if needed
        const is_terminator_required = if (path_string[path_string.len - 1] == '/') false else true;
        const additional_space: u32 = blk: {
            if (is_terminator_required) {
                break :blk 2;
            } else {
                break :blk 1;
            }
        };

        const allocation_size_bytes = path_string.len + @sizeOf(u16) + @sizeOf(u16) + additional_space;
        var allocation = arena.allocateAligned(u8, 2, @intCast(u16, allocation_size_bytes));

        const base_length = @intCast(u16, path_string.len);
        @ptrCast(*u16, @alignCast(2, &allocation[length_index])).* = if (is_terminator_required) base_length + 1 else base_length;
        @ptrCast(*u16, @alignCast(2, &allocation[writable_memory_size_index])).* = reserved_memory_opt orelse 0;

        allocation[allocation.len - 2] = '/';
        allocation[allocation.len - 1] = 0;

        var dest_slice = allocation[path_index .. path_index + path_string.len];
        std.mem.copy(u8, dest_slice, path_string);

        std.debug.assert(allocation[allocation.len - 2] == '/');

        if (reserved_memory_opt) |reserved_memory| {
            _ = arena.allocate(u8, reserved_memory);
        }

        return indexFor(arena, allocation);
    }

    pub const interface = struct {
        pub inline fn writableSpaceSize(index: AbsolutePath.Index) u16 {
            const base_ptr = @ptrCast([*]const u8, @alignCast(2, &storage.memory_space[index]));
            return @ptrCast(*const u16, @alignCast(2, &base_ptr[writable_memory_size_index])).*;
        }

        pub inline fn absolutePath(self: @This(), sub_path: []const u8) ![]const u8 {
            const writable_space = self.writableSpaceSize();
            if ((sub_path.len + 1) > writable_space) {
                return error.InsuffientMemoryAllocated;
            }
            const len = self.length();
            const start_index = path_index + len + 1;
            self.data[start_index - 1] = '/';
            var dest_slice = self.data[start_index .. start_index + sub_path.len];
            std.debug.assert(dest_slice.len == sub_path.len);
            std.mem.copy(u8, dest_slice, sub_path);
            return self.data[path_index .. start_index + sub_path.len];
        }

        pub inline fn value(index: AbsolutePath.Index) []const u8 {
            const root_len = length(index);
            return storage.memory_space[index + path_index .. index + path_index + root_len];
        }

        pub inline fn absolutePathZ(index: AbsolutePath.Index, sub_path: []const u8) ![:0]const u8 {
            const writable_space = writableSpaceSize(index);
            if ((sub_path.len + 1) > writable_space) {
                return error.InsuffientMemoryAllocated;
            }
            const root_len = length(index);

            const root_slice = storage.memory_space[index + path_index .. index + path_index + root_len];
            std.debug.assert(root_slice[root_slice.len - 1] == '/');

            const absolute_path_len: usize = root_len + sub_path.len + 1;
            const base_slice = storage.memory_space[index + path_index .. index + path_index + absolute_path_len];

            var dest_slice = base_slice[root_len .. root_len + sub_path.len];
            std.debug.assert(dest_slice.len == sub_path.len);
            std.mem.copy(u8, dest_slice, sub_path);
            base_slice[base_slice.len - 1] = 0;

            std.debug.assert(base_slice.len > 1);
            std.debug.assert(base_slice[base_slice.len - 1] == 0);

            const terminated_path: [:0]const u8 = base_slice[0 .. base_slice.len - 1 :0];

            return terminated_path;
        }

        // pub inline fn absolutePathBuffer(self: @This(), sub_path: []const u8, output_buffer: []u8) ![]const u8 {
        // //
        // }

        pub inline fn length(index: AbsolutePath.Index) u16 {
            const base_ptr = @ptrCast([*]const u8, @alignCast(2, &storage.memory_space[index]));
            return @ptrCast(*const u16, @alignCast(2, &base_ptr[length_index])).*;
        }

        pub inline fn path(index: AbsolutePath.Index) []const u8 {
            const len = length(index);
            const base_ptr = @ptrCast([*]const u8, @alignCast(2, &storage.memory_space[index]));
            return base_ptr[path_index .. path_index + len];
        }
    };
};

pub fn assertIndexAlignment(index: u16, comptime alignment: u29) void {
    std.debug.assert(@ptrToInt(&storage.memory_space[index]) % alignment == 0);
}

pub const SubPath = struct {
    pub const Index = u16;
    pub const null_index: u16 = std.math.maxInt(u16);

    const parent_path_index_index: u32 = 0;
    const length_index: u32 = 2;
    const path_index: u32 = 4;

    pub fn write(
        arena: *memory.LinearArena,
        sub_path: []const u8,
        parent_path: AbsolutePath.Index,
    ) !SubPath.Index {

        // Allocate space for the following:
        // - Sub string E.g "this/is/subpath"
        // - Length of substring as u16
        // - Parent path index
        const allocation_size_bytes = sub_path.len + @sizeOf(AbsolutePath.Index) + @sizeOf(u16);

        var allocated_memory = arena.allocateAligned(u8, 2, @intCast(u16, allocation_size_bytes));
        const result_index = indexFor(arena, allocated_memory);

        std.debug.assert(@ptrToInt(&storage.memory_space[result_index]) % 2 == 0);
        assertIndexAlignment(result_index, 2);

        @ptrCast(
            *AbsolutePath.Index,
            @alignCast(2, &allocated_memory[parent_path_index_index]),
        ).* = parent_path;

        @ptrCast(*u16, @alignCast(2, &allocated_memory[length_index])).* = @intCast(u16, sub_path.len);
        std.mem.copy(u8, allocated_memory[path_index..], sub_path);

        return result_index;
    }

    pub const interface = struct {
        pub inline fn length(index: SubPath.Index) u16 {
            const base_ptr = @ptrCast([*]const u8, &storage.memory_space[index]);
            return @ptrCast(*const u16, @alignCast(2, &base_ptr[length_index])).*;
        }

        pub inline fn path(index: SubPath.Index) []const u8 {
            const len = length(index);
            const base_ptr = @ptrCast([*]const u8, @alignCast(2, &storage.memory_space[index]));
            return base_ptr[path_index .. path_index + len];
        }

        pub inline fn parentIndex(index: SubPath.Index) AbsolutePath.Index {
            const base_ptr = @ptrCast([*]const u8, @alignCast(2, &storage.memory_space[index]));
            return @ptrCast(*const AbsolutePath.Index, base_ptr).*;
        }

        pub inline fn absolutePathZ(index: SubPath.Index) ![:0]const u8 {
            const subpath = @This().path(index);
            const parent_index = @This().parentIndex(index);
            return try AbsolutePath.interface.absolutePathZ(parent_index, subpath);
        }
    };
};
