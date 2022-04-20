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

/// Secondary semi-global address space that uses 16-bit "pointers"
const storage = @This();

pub const PointerBaseType: type = u16;
pub const nullptr: u16 = std.math.maxInt(u16);

pub fn Pointer(comptime Type: type) type {
    return struct {
        address: u16,

        pub fn get(self: @This()) Type {
            return .{
                .addr = @ptrCast(@TypeOf(Type.addr), &memory_space[self.address]),
            };
        }
    };
}

// pub const Pointer = u16;

var memory_space: []const u8 = undefined;

// TODO: Maybe I should allocate from here and then use it to back allocators
// Can verify address space is <= 65k
pub fn init(memory: []const u8) void {
    memory_space = memory;
}

pub inline fn get(comptime Type: type, address: PointerBaseType) *const Type {
    return @ptrCast(*const Type, &memory_space[address]);
}
