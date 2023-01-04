// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");

pub fn FixedAtomicEventQueue(comptime T: type, comptime Capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [Capacity]T = undefined,
        mutex: std.Thread.Mutex = .{},
        count: u16 = 0,

        /// Called by the producer
        pub fn add(self: *@This(), element: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count >= Capacity) {
                self.mutex.unlock();
                return error.NoSpace;
            }

            self.buffer[self.count] = element;
            self.count += 1;
        }

        pub fn empty(self: *@This()) bool {
            return (self.count == 0);
        }

        /// Called by the consumer
        pub fn collect(self: *@This()) []T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const event_count: u16 = self.count;
            self.count = 0;
            return self.buffer[0..event_count];
        }
    };
}
