// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const os = std.os;
const assert = std.debug.assert;
const log = std.log;

/// Returns the number of digits in a given number
pub fn digitCount(number: u32) u16 {
    var count: u16 = 1;
    var divisor: u16 = 10;
    while ((number / divisor) >= 1) : (count += 1) {
        divisor *= 10;
    }
    return count;
}

pub fn logMemoryUsage(allocator: *Allocator) !void {
    const pid = os.linux.getpid();
    const proc_path = try fmt.allocPrint(allocator, "/proc/{d}/", .{pid});
    defer allocator.free(proc_path);

    const proc_dir = try fs.openDirAbsolute(proc_path, .{ .access_sub_paths = true });

    var statm_buffer: [64]u8 = undefined;
    const statm_contents = try proc_dir.readFile("statm", statm_buffer[0..]);

    var number_digit_count: u32 = 0;
    var number_begin_index: u32 = 0;
    var number_parsed_count: u32 = 0;

    for (statm_buffer) |char, i| {
        if (char == ' ') {
            const value = try fmt.parseInt(u32, statm_buffer[number_begin_index .. number_begin_index + number_digit_count], 10);

            // From: https://man7.org/linux/man-pages/man5/proc.5.html on statm
            //
            // size       (1) total program size
            //             (same as VmSize in /proc/[pid]/status)
            // resident   (2) resident set size
            //             (inaccurate; same as VmRSS in /proc/[pid]/status)
            // shared     (3) number of resident shared pages
            //             (i.e., backed by a file)
            //             (inaccurate; same as RssFile+RssShmem in
            //             /proc/[pid]/status)
            // text       (4) text (code)
            // lib        (5) library (unused since Linux 2.6; always 0)
            // data       (6) data + stack
            // dt         (7) dirty pages (unused since Linux 2.6; always 0)

            const page_size: u32 = std.mem.page_size;

            switch (number_parsed_count) {
                // zig fmt: off
                0 => { log.info("  Size:     {d} {Bi:.2}", .{ value, value * page_size }); },
                1 => { log.info("  Resident: {d} {Bi:.2}", .{ value, value * page_size }); },
                3 => { log.info("  Text:     {d} {Bi:.2}", .{ value, value * page_size }); },
                5 => { log.info("  Data:     {d} {Bi:.2}", .{ value, value * page_size }); },
                // zig fmt: on
                else => {},
            }

            number_begin_index = @intCast(u32, i) + 1;
            number_digit_count = 0;
            number_parsed_count += 1;
        } else {
            number_digit_count += 1;
        }
    }
}

// TODO: Rename / refactor
pub fn lineRange(buffer: []const u8, line_start: u16, line_length_opt: ?u16) []const u8 {
    assert(line_length_opt == null or line_length_opt.? > 0);
    const begin_index: u32 = blk: {
        if (line_start == 0) {
            break :blk 0;
        }

        var line_count: u32 = 0;
        for (buffer) |char, i| {
            if (char == '\n') {
                line_count += 1;
                if (line_count == line_start) {
                    break :blk @intCast(u32, i + 1);
                }
            }
        }

        log.warn("line_start is not valid in lineRange", .{});
        // line_start is greater than amount of lines in buffer
        return buffer[0..0];
    };

    if (line_length_opt) |line_length| {
        var line_count: u32 = 0;
        for (buffer[begin_index..]) |char, i| {
            if (char == '\n') {
                line_count += 1;
                if (line_count == line_length) {
                    return buffer[begin_index .. begin_index + i];
                }
            }
        }
        return buffer[begin_index..];
    } else return buffer[begin_index..];

    unreachable;
}

// TODO: Replace with std library
pub fn strlen(cstring: [*:0]const u8) u32 {
    var i: u32 = 0;
    while (cstring[i] != 0) {
        i += 1;
    }
    return i;
}

// TODO: Rename
pub fn reverseLength(string: []u8, separator: u8) u32 {
    if (string.len == 0) {
        return 0;
    }

    var i: u32 = @intCast(u32, string.len);
    while (i >= 1) : (i -= 1) {
        if (string[i - 1] == separator) {
            return @intCast(u32, string.len) - i;
        }
    }
    return @intCast(u32, string.len);
}

/// Shift every element in a slice to the left
/// The first element in the array will be overwritten
pub fn sliceShiftLeft(comptime Type: type, slice: []Type) void {
    if (slice.len == 0) return;
    const shift_range: usize = slice.len - 1;
    var i: usize = 0;
    while (i < shift_range) : (i += 1) {
        slice[i] = slice[i + 1];
    }
}

/// Shift every element in a slice to the right
/// The last element in the array will be overwritten
pub fn sliceShiftRight(comptime Type: type, slice: []Type) void {
    if (slice.len == 0) return;
    const shift_range: usize = slice.len - 1;
    var i: usize = 0;
    while (i < shift_range) : (i += 1) {
        slice[shift_range - i] = slice[shift_range - i - 1];
    }
}
