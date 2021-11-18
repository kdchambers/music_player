// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const expect = std.testing.expect;
const print = std.debug.print;
const geometry = @import("geometry.zig");

pub const TextCursor = struct {
    const Self: type = @This();

    coordinates: geometry.Coordinates2D(.carthesian),
    text_buffer_index: u32,

    pub fn down(self: *Self, text_buffer: []const u8) bool {
        // Jump to start of next line
        var text_buffer_index = blk: {
            var index = self.text_buffer_index;
            while (index != text_buffer.len) : (index += 1) {
                if (text_buffer[index] == '\n') break :blk index + 1;
            } else return false;
        };

        var length: u32 = 0;
        while (true) : (text_buffer_index += 1) {
            // Loop until end of (line or buffer)
            // Note: End of buffer is one past last charactor (next place to add new character)
            if (text_buffer_index == text_buffer.len or text_buffer[text_buffer_index] == '\n') {
                // If the new line is shorter, we need to reduce the cursor x value to point to the
                // end of the new line
                const x_index = if (length > self.coordinates.x) self.coordinates.x else length;
                self.text_buffer_index = (text_buffer_index - length) + x_index;
                self.coordinates.y += 1;
                self.coordinates.x = x_index;
                return true;
            }
            length += 1;
        }
        unreachable;
    }

    pub fn left(self: *Self, text_buffer: []const u8) bool {
        if (self.coordinates.x > 0) {
            self.coordinates.x -= 1;
            self.text_buffer_index -= 1;
            return true;
        }
        return false;
    }

    pub fn right(self: *Self, text_buffer: []const u8) bool {
        if (self.text_buffer_index == text_buffer.len) return false;
        if (text_buffer[self.text_buffer_index] != '\n') {
            self.text_buffer_index += 1;
            self.coordinates.x += 1;
            return true;
        }
        return false;
    }

    pub fn up(self: *Self, text_buffer: []const u8) bool {
        if (self.coordinates.y == 0) return false;

        // Jump to end of previous line (First character after newline)
        var text_buffer_index: i64 = blk: {
            var index: i64 = self.text_buffer_index - 1;
            while (index >= 0) : (index -= 1) {
                if (text_buffer[@intCast(usize, index)] == '\n') break :blk index - 1;
            } else {
                return false;
            }
        };

        if (text_buffer_index < 0) {
            // Line exists, but is empty
            //
            self.text_buffer_index = 0;
            self.coordinates.y = 0;
            self.coordinates.x = 0;
            return true;
        }

        var length: u32 = 0;
        while (text_buffer_index >= 0) : (text_buffer_index -= 1) {
            // Loop until end of line or buffer
            if (text_buffer[@intCast(usize, text_buffer_index)] == '\n') {
                text_buffer_index += 1;
                break;
            }
            length += 1;
        }

        if (text_buffer_index < 0) text_buffer_index = 0;

        // If the new line is shorter, we need to reduce the cursor x value to point to the
        // end of the new line
        const x_index = if (length > self.coordinates.x) self.coordinates.x else length;
        self.text_buffer_index = @intCast(u32, text_buffer_index) + x_index;
        self.coordinates.y -= 1;
        self.coordinates.x = x_index;

        return true;
    }
};

test "cursor" {
    const buffer =
        \\#include <stdio.h>
        \\
        \\int main(int argc, char *argv[]) {
        \\    printf("Hello, world\n");
        \\    return 0;
        \\}
    ;
    var cursor: TextCursor = .{
        .coordinates = .{
            .x = 0,
            .y = 0,
        },
        .text_buffer_index = 0,
    };

    _ = cursor.right(buffer);

    expect(cursor.coordinates.x == 1);
    expect(cursor.coordinates.y == 0);
    expect(cursor.text_buffer_index == 1);
    expect(buffer[cursor.text_buffer_index] == 'i');

    _ = cursor.down(buffer);

    expect(cursor.coordinates.x == 0);
    expect(cursor.coordinates.y == 1);
    expect(cursor.text_buffer_index == 19);
    expect(buffer[cursor.text_buffer_index] == '\n');
    expect(buffer[cursor.text_buffer_index + 1] == 'i');
    expect(buffer[cursor.text_buffer_index - 1] == '\n');

    _ = cursor.down(buffer);

    expect(cursor.coordinates.x == 0);
    expect(cursor.coordinates.y == 2);
    expect(cursor.text_buffer_index == 20);
    expect(buffer[cursor.text_buffer_index] == 'i');

    var i: u32 = 5;
    while (i > 0) : (i -= 1) _ = cursor.right(buffer);

    expect(cursor.coordinates.x == 5);
    expect(cursor.coordinates.y == 2);
    expect(cursor.text_buffer_index == 25);
    expect(buffer[cursor.text_buffer_index] == 'a');

    _ = cursor.up(buffer);

    expect(cursor.coordinates.x == 0);
    expect(cursor.coordinates.y == 1);
    expect(cursor.text_buffer_index == 19);
    expect(buffer[cursor.text_buffer_index] == '\n');

    // Empty line (Left and right movement should do nothing)

    _ = cursor.right(buffer);

    expect(cursor.coordinates.x == 0);
    expect(cursor.coordinates.y == 1);
    expect(cursor.text_buffer_index == 19);
    expect(buffer[cursor.text_buffer_index] == '\n');

    _ = cursor.left(buffer);

    expect(cursor.coordinates.x == 0);
    expect(cursor.coordinates.y == 1);
    expect(cursor.text_buffer_index == 19);
    expect(buffer[cursor.text_buffer_index] == '\n');

    // Back to start of text

    _ = cursor.up(buffer);

    expect(cursor.coordinates.x == 0);
    expect(cursor.coordinates.y == 0);
    expect(cursor.text_buffer_index == 0);
    expect(buffer[cursor.text_buffer_index] == '#');

    i = 18;
    while (i > 0) : (i -= 1) _ = cursor.right(buffer);

    expect(cursor.coordinates.x == 18);
    expect(cursor.coordinates.y == 0);
    expect(cursor.text_buffer_index == 18);
    expect(buffer[cursor.text_buffer_index] == '\n');

    // Expect: No change
    _ = cursor.right(buffer);

    expect(cursor.coordinates.x == 18);
    expect(cursor.coordinates.y == 0);
    expect(cursor.text_buffer_index == 18);
    expect(buffer[cursor.text_buffer_index] == '\n');

    i = 10;
    while (i > 0) : (i -= 1) _ = cursor.left(buffer);

    expect(cursor.coordinates.x == 8);
    expect(cursor.coordinates.y == 0);
    expect(cursor.text_buffer_index == 8);
    expect(buffer[cursor.text_buffer_index] == ' ');

    _ = cursor.down(buffer);

    expect(cursor.coordinates.x == 0);
    expect(cursor.coordinates.y == 1);
    expect(cursor.text_buffer_index == 19);
    expect(buffer[cursor.text_buffer_index] == '\n');

    _ = cursor.down(buffer);

    expect(cursor.coordinates.x == 0);
    expect(cursor.coordinates.y == 2);
    expect(cursor.text_buffer_index == 20);
    expect(buffer[cursor.text_buffer_index] == 'i');

    i = 15;
    while (i > 0) : (i -= 1) _ = cursor.right(buffer);

    expect(cursor.coordinates.x == 15);
    expect(cursor.coordinates.y == 2);
    expect(cursor.text_buffer_index == 35);
    expect(buffer[cursor.text_buffer_index] == 'g');

    _ = cursor.down(buffer);

    expect(cursor.coordinates.x == 15);
    expect(cursor.coordinates.y == 3);
    expect(cursor.text_buffer_index == 70);
    expect(buffer[cursor.text_buffer_index] == 'l');

    _ = cursor.down(buffer);

    expect(cursor.coordinates.x == 13);
    expect(cursor.coordinates.y == 4);
    expect(cursor.text_buffer_index == 98);
    expect(buffer[cursor.text_buffer_index] == '\n');
}
