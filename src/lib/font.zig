// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const log = std.log;
const c = std.c;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const toNative = std.mem.toNative;
const bigToNative = std.mem.bigToNative;
const eql = std.mem.eql;
const assert = std.debug.assert;
const print = std.debug.print;

const geometry = @import("geometry.zig");
const Scale2D = geometry.Scale2D;
const Shift2D = geometry.Shift2D;

// TODO:
pub fn abs(value: f32) f32 {
    if (value < 0) {
        return value * -1;
    }
    return value;
}

pub fn getCodepointBitmap(allocator: Allocator, info: FontInfo, scale: Scale2D(f32), codepoint: i32) !Bitmap {
    const shift = Shift2D(f32){ .x = 0.0, .y = 0.0 };
    const offset = Offset2D(u32){ .x = 0, .y = 0 };
    return try getCodepointBitmapSubpixel(allocator, info, scale, shift, codepoint, offset);
}

pub fn getAscent(info: FontInfo) i16 {
    return bigToNative(i16, @intToPtr(*i16, @ptrToInt(info.data.ptr) + info.hhea.offset + 4).*);
}

pub fn getDescent(info: FontInfo) i16 {
    return bigToNative(i16, @intToPtr(*i16, @ptrToInt(info.data.ptr) + info.hhea.offset + 6).*);
}

const TableLookup = struct {
    offset: u32 = 0,
    length: u32 = 0,
};

pub const FontInfo = struct {
    // zig fmt: off
    userdata: *void,
    data: []u8,
    glyph_count: i32 = 0,
    loca: TableLookup,
    head: TableLookup,
    glyf: TableLookup,
    hhea: TableLookup,
    hmtx: TableLookup,
    kern: TableLookup,
    gpos: TableLookup,
    svg: TableLookup,
    maxp: TableLookup,
    index_map: i32 = 0, 
    index_to_loc_format: i32 = 0,
    cff: Buffer,
    char_strings: Buffer,
    gsubrs: Buffer,
    subrs: Buffer,
    font_dicts: Buffer,
    fd_select: Buffer,
    cmap_encoding_table_offset: u32 = 0,
// zig fmt: on
};

const Buffer = struct {
    data: []u8,
    cursor: u32 = 0,
    size: u32 = 0,
};

const FontType = enum { none, truetype_1, truetype_2, opentype_cff, opentype_1, apple };

fn fontType(font: []const u8) FontType {
    const TrueType1Tag: [4]u8 = .{ 49, 0, 0, 0 };
    const OpenTypeTag: [4]u8 = .{ 0, 1, 0, 0 };

    if (eql(u8, font, TrueType1Tag[0..])) return .truetype_1; // TrueType 1
    if (eql(u8, font, "typ1")) return .truetype_2; // TrueType with type 1 font -- we don't support this!
    if (eql(u8, font, "OTTO")) return .opentype_cff; // OpenType with CFF
    if (eql(u8, font, OpenTypeTag[0..])) return .opentype_1; // OpenType 1.0
    if (eql(u8, font, "true")) return .apple; // Apple specification for TrueType fonts

    return .none;
}

pub fn getFontOffsetForIndex(font_collection: []u8, index: i32) i32 {
    const font_type = fontType(font_collection);

    if (font_type == .none) {
        return if (index == 0) 0 else -1;
    }

    return -1;
}

pub fn printFontTags(data: []u8) void {
    const tables_count_addr: *u16 = @intToPtr(*u16, @ptrToInt(data.ptr) + 4);
    const tables_count = toNative(u16, tables_count_addr.*, .Big);
    const table_dir: u32 = 12;

    var i: u32 = 0;
    while (i < tables_count) : (i += 1) {
        const loc: u32 = table_dir + (16 * i);
        const tag: *[4]u8 = @intToPtr(*[4]u8, @ptrToInt(data.ptr) + loc);
        log.info("Tag: '{s}'", .{tag.*[0..]});
    }
}

const TableType = enum { cmap, loca, head, glyf, hhea, hmtx, kern, gpos, maxp };

const TableTypeList: [9]*const [4:0]u8 = .{
    "cmap",
    "loca",
    "head",
    "glyf",
    "hhea",
    "hmtx",
    "kern",
    "GPOS",
    "maxp",
};

pub fn Byte(comptime T: type) type {
    return T;
}

// Describe structure of TTF file
const offset_subtable_start: u32 = 0;
const offset_subtable_length: Byte(u32) = 12;

const table_directory_start: u32 = offset_subtable_length;
const table_directory_length: Byte(u32) = 16;

pub fn Dimensions2D(comptime T: type) type {
    return packed struct {
        width: T,
        height: T,
    };
}

const BoundingBox = packed struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
};

// TODO: Wrap in a function that lets you select pixel type
const Bitmap = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

const coordinate_types: []u8 = undefined;
const coordinates = []Point(i16);
const control_points = []Point(i16);

const Vertex = packed struct {
    x: i16,
    y: i16,
    cx: i16,
    cy: i16,
    cx1: i16,
    cy1: i16,
    kind: u8,
    padding: u8,
};

fn printVertices(vertices: []Vertex) void {
    for (vertices) |vertex, i| {
        assert(vertex.kind <= @enumToInt(VMove.cubic));
        print("{d} : {s} xy ({d}, {d}) cxcy ({d},{d})\n", .{ i, @intToEnum(VMove, vertex.kind), vertex.x, vertex.y, vertex.cx, vertex.cy });
    }
}

fn readBigEndian(comptime T: type, index: usize) T {
    return bigToNative(T, @intToPtr(*T, index).*);
}

fn getGlyfOffset(info: FontInfo, glyph_index: i32) !usize {
    var g1: usize = 0;
    var g2: usize = 0;

    assert(info.cff.size == 0);

    if (glyph_index >= info.glyph_count) return error.InvalidGlyphIndex;

    if (info.index_to_loc_format >= 2) return error.InvalidIndexToLocationFormat;

    const base_index = @ptrToInt(info.data.ptr) + info.loca.offset;

    if (info.index_to_loc_format == 0) {
        assert(false);
        g1 = @intCast(usize, info.glyf.offset) + readBigEndian(u16, base_index + (@intCast(usize, glyph_index) * 2) + 0) * 2;
        g2 = @intCast(usize, info.glyf.offset) + readBigEndian(u16, base_index + (@intCast(usize, glyph_index) * 2) + 2) * 2;
    } else {
        g1 = @intCast(usize, info.glyf.offset) + readBigEndian(u32, base_index + (@intCast(usize, glyph_index) * 4) + 0);
        g2 = @intCast(usize, info.glyf.offset) + readBigEndian(u32, base_index + (@intCast(usize, glyph_index) * 4) + 4);
    }

    if (g1 == g2) {
        return error.GlyphIndicesMatch;
    }

    return g1;
}

//
// https://docs.microsoft.com/en-us/typography/opentype/spec/glyf
//
const GlyphFlags = struct {
    const none: u8 = 0x00;
    const on_curve_point: u8 = 0x01;
    const x_short_vector: u8 = 0x02;
    const y_short_vector: u8 = 0x04;
    const repeat_flag: u8 = 0x08;
    const positive_x_short_vector: u8 = 0x10;
    const same_x: u8 = 0x10;
    const positive_y_short_vector: u8 = 0x20;
    const same_y: u8 = 0x20;
    const overlap_simple: u8 = 0x40;

    pub fn isFlagSet(value: u8, flag: u8) bool {
        return (value & flag) != 0;
    }
};

fn closeShape(vertices: []Vertex, vertices_count: u32, was_off: bool, start_off: bool, sx: i32, sy: i32, scx: i32, scy: i32, cx: i32, cy: i32) u32 {
    var vertices_count_local: u32 = vertices_count;

    if (start_off) {
        if (was_off) {
            setVertex(&vertices[vertices_count_local], .curve, (cx + scx) >> 1, (cy + scy) >> 1, cx, cy);
            vertices_count_local += 1;
        }
        setVertex(&vertices[vertices_count_local], .curve, sx, sy, scx, scy);
        vertices_count_local += 1;
    } else {
        if (was_off) {
            setVertex(&vertices[vertices_count_local], .curve, sx, sy, cx, cy);
            vertices_count_local += 1;
        } else {
            setVertex(&vertices[vertices_count_local], .line, sx, sy, 0, 0);
            vertices_count_local += 1;
        }
    }

    return vertices_count_local;
}

fn setVertex(vertex: *Vertex, kind: VMove, x: i32, y: i32, cx: i32, cy: i32) void {
    vertex.kind = @enumToInt(kind);
    vertex.x = @intCast(i16, x);
    vertex.y = @intCast(i16, y);
    vertex.cx = @intCast(i16, cx);
    vertex.cy = @intCast(i16, cy);
}

const VMove = enum(u8) {
    none,
    move = 1,
    line,
    curve,
    cubic,
};

fn isFlagSet(value: u8, bit_mask: u8) bool {
    return (value & bit_mask) != 0;
}

pub fn scaleForPixelHeight(info: FontInfo, height: f32) f32 {
    assert(info.hhea.offset != 0);

    const base_index: usize = @ptrToInt(info.data.ptr) + info.hhea.offset;

    const first = bigToNative(i16, @intToPtr(*i16, (base_index + 4)).*);
    const second = bigToNative(i16, @intToPtr(*i16, (base_index + 6)).*);

    const fheight = @intToFloat(f32, first - second);
    return height / fheight;
}

const GlyhHeader = packed struct {
    // See: https://docs.microsoft.com/en-us/typography/opentype/spec/glyf
    //
    //  If the number of contours is greater than or equal to zero, this is a simple glyph.
    //  If negative, this is a composite glyph — the value -1 should be used for composite glyphs.
    contour_count: i16,
    x_minimum: i16,
    y_minimum: i16,
    x_maximum: i16,
    y_maximum: i16,
};

// See: https://docs.microsoft.com/en-us/typography/opentype/spec/glyf
//      Simple Glyph Table
//

// const SimpleGlyphTable = packed struct {
// // Array of point indices for the last point of each contour, in increasing numeric order.
// end_points_of_contours: [contour_count]u16,
// instruction_length: u16,
// instructions: [instruction_length]u8,
// flags: [*]u8,
// // Contour point x-coordinates.
// // Coordinate for the first point is relative to (0,0); others are relative to previous point.
// x_coordinates: [*]u8,
// // Contour point y-coordinates.
// // Coordinate for the first point is relative to (0,0); others are relative to previous point.
// y_coordinates: [*]u8,
// };

fn getGlyphShape(allocator: Allocator, info: FontInfo, glyph_index: i32) ![]Vertex {

    // After Glyph Header is the following structure
    // See: https://docs.microsoft.com/en-us/typography/opentype/spec/glyf
    //
    // end_points_of_contours: [contour_count]u16,
    // instructions_size_bytes: u16,
    // instructions: [instruction_length]u8,
    // flags: [*]u8,
    // x_coordinates: [*]u8,
    // y_coordinates: [*]u8,

    if (info.cff.size != 0) {
        return error.CffFound;
    }

    const data = info.data;

    var vertices: []Vertex = undefined;
    var vertices_count: u32 = 0;

    // Find the byte offset of the glyh table
    const glyph_offset = try getGlyfOffset(info, glyph_index);
    const glyph_offset_index: usize = @ptrToInt(data.ptr) + glyph_offset;

    if (glyph_offset < 0) {
        return error.InvalidGlypOffset;
    }

    const contour_count_signed = readBigEndian(i16, glyph_offset_index);

    if (contour_count_signed > 0) {
        const contour_count: u32 = @intCast(u16, contour_count_signed);

        var i: usize = 0;
        var j: i32 = 0;
        var m: u32 = 0;
        var n: u16 = 0;

        // Index of the next point that begins a new contour
        // This will correspond to value after end_points_of_contours
        var next_move: i32 = 0;

        var was_off: bool = false;
        var off: usize = 0;
        var start_off: bool = false;

        var x: i16 = 0;
        var y: i16 = 0;
        var cx: i32 = 0;
        var cy: i32 = 0;
        var sx: i32 = 0;
        var sy: i32 = 0;
        var scx: i32 = 0;
        var scy: i32 = 0;

        // end_points_of_contours is located directly after GlyphHeader in the glyf table
        const end_points_of_contours = @intToPtr([*]u16, glyph_offset_index + @sizeOf(GlyhHeader));
        const end_points_of_contours_size = @intCast(usize, contour_count * @sizeOf(u16));

        const simple_glyph_table_index = glyph_offset_index + @sizeOf(GlyhHeader);

        // Get the size of the instructions so we can skip past them
        const instructions_size_bytes = readBigEndian(i16, simple_glyph_table_index + end_points_of_contours_size);

        var glyph_flags: [*]u8 = @intToPtr([*]u8, glyph_offset_index + @sizeOf(GlyhHeader) + (@intCast(usize, contour_count) * 2) + 2 + @intCast(usize, instructions_size_bytes));

        {
            var r: u32 = 0;
            while (r < contour_count) : (r += 1) {
                // print("END PT: {d}\n", .{bigToNative(u16, end_points_of_contours[r])});
            }
        }

        // NOTE: The number of flags is determined by the last entry in the endPtsOfContours array
        n = 1 + readBigEndian(u16, @ptrToInt(end_points_of_contours) + (@intCast(usize, contour_count) * 2) - 2);

        // What is m here?
        // Size of contours
        {
            m = n + (2 * contour_count);
            vertices = try allocator.alloc(Vertex, @intCast(usize, m) * @sizeOf(Vertex));

            assert((m - n) > 0);
            off = @intCast(usize, m - n); // starting offset for uninterpreted data, regardless of how m ends up being calculated
            assert(off == (2 * contour_count));
        }

        var flags: u8 = GlyphFlags.none;
        {
            var flag_count: u8 = 0;
            while (i < n) : (i += 1) {
                if (flag_count == 0) {
                    flags = glyph_flags[0];
                    glyph_flags = glyph_flags + 1;
                    if (isFlagSet(flags, GlyphFlags.repeat_flag)) {
                        // If `repeat_flag` is set, the next flag is the number of times to repeat
                        flag_count = glyph_flags[0];
                        glyph_flags = glyph_flags + 1;
                    }
                } else {
                    flag_count -= 1;
                }

                vertices[@intCast(usize, off) + @intCast(usize, i)].kind = flags;
            }
        }

        // now load x coordinates
        i = 0;
        while (i < n) : (i += 1) {
            flags = vertices[@intCast(usize, off) + @intCast(usize, i)].kind;
            if (isFlagSet(flags, GlyphFlags.x_short_vector)) {
                const dx: i16 = glyph_flags[0];
                glyph_flags += 1;
                x += if (isFlagSet(flags, GlyphFlags.positive_x_short_vector)) dx else -dx;
            } else {
                if (!isFlagSet(flags, GlyphFlags.same_x)) {

                    // The current x-coordinate is a signed 16-bit delta vector
                    const abs_x = (@intCast(i16, glyph_flags[0]) << 8) + glyph_flags[1];

                    x += abs_x;
                    glyph_flags += 2;
                }
            }

            // If: `!x_short_vector` and `same_x` then the same `x` value shall be appended
            vertices[off + i].x = x;
        }

        // now load y coordinates
        y = 0;
        i = 0;
        while (i < n) : (i += 1) {
            flags = vertices[off + i].kind;
            if (isFlagSet(flags, GlyphFlags.y_short_vector)) {
                const dy: i16 = glyph_flags[0];
                glyph_flags += 1;
                y += if (isFlagSet(flags, GlyphFlags.positive_y_short_vector)) dy else -dy;
            } else {
                if (!isFlagSet(flags, GlyphFlags.same_y)) {
                    // The current y-coordinate is a signed 16-bit delta vector
                    const abs_y = (@intCast(i16, glyph_flags[0]) << 8) + glyph_flags[1];
                    y += abs_y;
                    glyph_flags += 2;
                }
            }
            // If: `!y_short_vector` and `same_y` then the same `y` value shall be appended
            vertices[off + i].y = y;
        }

        assert(vertices_count == 0);

        i = 0;
        next_move = 0;
        while (i < n) : (i += 1) {
            flags = vertices[off + i].kind;
            x = vertices[off + i].x;
            y = vertices[off + i].y;
            if (next_move == i) {

                // End of contour
                if (i != 0) {
                    vertices_count = closeShape(vertices, vertices_count, was_off, start_off, sx, sy, scx, scy, cx, cy);
                }

                // on_curve ?
                start_off = ((flags & GlyphFlags.on_curve_point) == 0);
                if (start_off) {
                    scx = x;
                    scy = y;
                    if (!isFlagSet(vertices[off + i + 1].kind, GlyphFlags.on_curve_point)) {
                        sx = x + (vertices[off + i + 1].x >> 1);
                        sy = y + (vertices[off + i + 1].y >> 1);
                    } else {
                        sx = x + (vertices[off + i + 1].x);
                        sy = y + (vertices[off + i + 1].y);
                        i += 1;
                    }
                } else {
                    sx = x;
                    sy = y;
                }

                setVertex(&vertices[vertices_count], .move, sx, sy, 0, 0);
                vertices_count += 1;
                was_off = false;
                next_move = 1 + readBigEndian(i16, @ptrToInt(end_points_of_contours) + (@intCast(usize, j) * 2));
                j += 1;
            } else {

                // Continue current contour

                if (0 == (flags & GlyphFlags.on_curve_point)) {
                    // two off-curve control points in a row means interpolate an on-curve midpoint
                    if (was_off) {
                        setVertex(&vertices[vertices_count], .curve, (cx + x) >> 1, (cy + y) >> 1, cx, cy);
                        vertices_count += 1;
                    }
                    cx = x;
                    cy = y;
                    was_off = true;
                } else {
                    if (was_off) {
                        setVertex(&vertices[vertices_count], .curve, x, y, cx, cy);
                    } else {
                        setVertex(&vertices[vertices_count], .line, x, y, 0, 0);
                    }

                    vertices_count += 1;
                    was_off = false;
                }
            }
        }

        vertices_count = closeShape(vertices, vertices_count, was_off, start_off, sx, sy, scx, scy, cx, cy);
    } else if (contour_count_signed < 0) {
        return error.InvalidContourCount;
    } else {
        unreachable;
    }

    return allocator.shrink(vertices, vertices_count);
}

pub fn getRequiredDimensions(info: FontInfo, codepoint: i32, scale: Scale2D(f32)) !Dimensions2D(u32) {
    const glyph_index: i32 = @intCast(i32, findGlyphIndex(info, codepoint));
    const shift = Shift2D(f32){ .x = 0.0, .y = 0.0 };
    const bounding_box = try getGlyphBitmapBoxSubpixel(info, glyph_index, scale, shift);
    return Dimensions2D(u32){
        .width = @intCast(u32, bounding_box.x1 - bounding_box.x0),
        .height = @intCast(u32, bounding_box.y1 - bounding_box.y0),
    };
}

pub fn getVerticalOffset(info: FontInfo, codepoint: i32, scale: Scale2D(f32)) !i16 {
    const glyph_index: i32 = @intCast(i32, findGlyphIndex(info, codepoint));
    const shift = Shift2D(f32){ .x = 0.0, .y = 0.0 };
    const bounding_box = try getGlyphBitmapBoxSubpixel(info, glyph_index, scale, shift);
    return @intCast(i16, bounding_box.y1);
}

pub fn getCodepointBitmapBox(info: FontInfo, codepoint: i32, scale: Scale2D(f32)) !BoundingBox {
    const shift = Shift2D(f32){ .x = 0, .y = 0 };
    return try getCodepointBitmapBoxSubpixel(info, codepoint, scale, shift);
}

fn getCodepointBitmapBoxSubpixel(info: FontInfo, codepoint: i32, scale: Scale2D(f32), shift: Shift2D(f32)) !BoundingBox {
    const glyph_index = @intCast(i32, findGlyphIndex(info, codepoint));
    return try getGlyphBitmapBoxSubpixel(info, glyph_index, scale, shift);
}

fn getCodepointBitmapSubpixel(allocator: Allocator, info: FontInfo, scale: Scale2D(f32), shift: Shift2D(f32), codepoint: i32, offset: Offset2D(u32)) !Bitmap {
    const glyph_index: i32 = @intCast(i32, findGlyphIndex(info, codepoint));
    return try getGlyphBitmapSubpixel(allocator, info, scale, shift, glyph_index, offset);
}

fn getGlyphBitmapBoxSubpixel(info: FontInfo, glyph_index: i32, scale: Scale2D(f32), shift: Shift2D(f32)) !BoundingBox {
    const bounding_box_opt: ?BoundingBox = getGlyphBox(info, glyph_index);
    if (bounding_box_opt) |bounding_box| {
        return BoundingBox{
            .x0 = @floatToInt(i32, @floor(@intToFloat(f32, bounding_box.x0) * scale.x + shift.x)),
            .y0 = @floatToInt(i32, @floor(@intToFloat(f32, -bounding_box.y1) * scale.y + shift.y)),
            .x1 = @floatToInt(i32, @ceil(@intToFloat(f32, bounding_box.x1) * scale.x + shift.x)),
            .y1 = @floatToInt(i32, @ceil(@intToFloat(f32, -bounding_box.y0) * scale.y + shift.y)),
        };
    }

    return error.GetBitmapBoxFailed;
}

fn getGlyphBox(info: FontInfo, glyph_index: i32) ?BoundingBox {
    assert(info.cff.size == 0);

    const g: usize = getGlyfOffset(info, glyph_index) catch |err| {
        log.warn("Error in getGlyfOffset {s}", .{err});
        return null;
    };

    if (g == 0) {
        log.warn("Failed to get glyf offset", .{});
        return null;
    }

    const base_index: usize = @ptrToInt(info.data.ptr) + g;

    return BoundingBox{
        .x0 = bigToNative(i16, @intToPtr(*i16, base_index + 2).*),
        .y0 = bigToNative(i16, @intToPtr(*i16, base_index + 4).*),
        .x1 = bigToNative(i16, @intToPtr(*i16, base_index + 6).*),
        .y1 = bigToNative(i16, @intToPtr(*i16, base_index + 8).*),
    };
}

fn Offset2D(comptime T: type) type {
    return packed struct {
        x: T,
        y: T,
    };
}

fn getGlyphBitmapSubpixel(allocator: Allocator, info: FontInfo, desired_scale: Scale2D(f32), shift: Shift2D(f32), glyph_index: i32, offset: Offset2D(u32)) !Bitmap {
    _ = shift;
    _ = offset;

    var scale = desired_scale;

    var bitmap: Bitmap = undefined;
    const vertices = try getGlyphShape(allocator, info, glyph_index);
    // TODO: Allocated inside of getGlyphShape
    defer allocator.free(vertices);

    if (scale.x == 0) {
        scale.x = scale.y;
    }

    if (scale.y == 0) {
        if (scale.x == 0) {
            return error.WhoKnows;
        }
        scale.y = scale.x;
    }

    const bounding_box = try getGlyphBitmapBoxSubpixel(info, glyph_index, scale, shift);

    const dimensions = Dimensions2D(i32){
        .width = bounding_box.x1 - bounding_box.x0,
        .height = bounding_box.y1 - bounding_box.y0,
    };

    // TODO: bitmap should be created inside rasterize function
    bitmap.width = @intCast(u32, bounding_box.x1 - bounding_box.x0);
    bitmap.height = @intCast(u32, bounding_box.y1 - bounding_box.y0);

    if (bitmap.width != 0 and bitmap.height != 0) {
        const rasterize_offset = Offset2D(i32){
            .x = bounding_box.x0,
            .y = bounding_box.y0,
        };

        bitmap = try rasterize(allocator, 0.35, dimensions, vertices, scale, shift, rasterize_offset, true);
    }

    return bitmap;
}

fn Point(comptime T: type) type {
    return packed struct {
        x: T,
        y: T,
    };
}

fn tessellateCurve(points: *[]Point(f32), x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, objspace_flatness_squared: f32, n: i32) u32 {
    const mx: f32 = (x0 + (2 * x1) + x2) / 4.0;
    const my: f32 = (y0 + (2 * y1) + y2) / 4.0;

    const dx: f32 = ((x0 + x2) / 2.0) - mx;
    const dy: f32 = ((y0 + y2) / 2.0) - my;

    var points_count: u32 = 0;

    if (n > 16) {
        return 1;
    }

    if ((dx * dx) + (dy * dy) > objspace_flatness_squared) {
        points_count += tessellateCurve(points, x0, y0, (x0 + x1) / 2.0, (y0 + y1) / 2.0, mx, my, objspace_flatness_squared, n + 1);
        points_count += tessellateCurve(&points.*[points_count..], mx, my, (x1 + x2) / 2.0, (y1 + y2) / 2.0, x2, y2, objspace_flatness_squared, n + 1);
    } else {
        points_count += 1;

        points.*[0].x = x2;
        points.*[0].y = y2;
    }

    return points_count;
}

fn tessellateCubic(points: *[]Point(f32), x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, objspace_flatness_squared: f32, n: i32) u32 {
    assert(false);
    const dx0: f32 = x1 - x0;
    const dy0: f32 = y1 - y0;
    const dx1: f32 = x2 - x1;
    const dy1: f32 = y2 - y1;
    const dx2: f32 = x3 - x2;
    const dy2: f32 = y3 - y2;

    const dx: f32 = x3 - x0;
    const dy: f32 = y3 - y0;

    const longlen: f32 = @sqrt((dx0 * dx0) + (dy0 * dy0)) + @sqrt((dx1 * dx1) + (dy1 * dy1)) + @sqrt((dx2 * dx2) + (dy2 * dy2));
    const shortlen: f32 = @sqrt((dx * dx) + (dy * dy));
    const flatness_squared: f32 = (longlen * longlen) - (shortlen * shortlen);

    if (n > 16) {
        return 0;
    }

    var points_count: u32 = 0;

    if (flatness_squared > objspace_flatness_squared) {
        const x01: f32 = (x0 + x1) / 2;
        const y01: f32 = (y0 + y1) / 2;
        const x12: f32 = (x1 + x2) / 2;
        const y12: f32 = (y1 + y2) / 2;
        const x23: f32 = (x2 + x3) / 2;
        const y23: f32 = (y2 + y3) / 2;

        const xa: f32 = (x01 + x12) / 2;
        const ya: f32 = (y01 + y12) / 2;
        const xb: f32 = (x12 + x23) / 2;
        const yb: f32 = (y12 + y23) / 2;

        const mx: f32 = (xa + xb) / 2;
        const my: f32 = (ya + yb) / 2;

        points_count += tessellateCubic(points, x0, y0, x01, y01, xa, ya, mx, my, objspace_flatness_squared, n + 1);
        points_count += tessellateCubic(&points.*[points_count..], mx, my, xb, yb, x23, y23, x3, y3, objspace_flatness_squared, n + 1);
    } else {
        points.*[0].x = x3;
        points.*[0].y = y3;

        points_count += 1;
    }

    return points_count;
}

fn calculatePointsCount(vertices: []Vertex) u32 {
    var count: u32 = 0;
    for (vertices) |vertex| {
        if (vertex.kind == VMove.move or vertex.kind == VMove.line) {
            count += 1;
        } else if (vertex.kind == VMove.curve) {
            //
        } else if (vertex.kind == VMove.cubic) {
            //
        } else {
            unreachable;
        }
    }
}

fn flattenCurves(allocator: Allocator, vertices: []Vertex, objspace_flatness: f32, contour_lengths: *[]i32, windings: *u32) ![]Point(f32) {
    const objspace_flatness_squared: f32 = objspace_flatness * objspace_flatness;

    var move_count: usize = 0;
    for (vertices) |vertex| {
        if (vertex.kind == @enumToInt(VMove.move)) {
            move_count += 1;
        }
    }

    windings.* = @intCast(u32, move_count);

    if (move_count == 0) return error.NoMoves;

    contour_lengths.* = try allocator.alloc(i32, move_count);

    var points_count: u32 = 0;
    var start: i32 = 0;

    // TODO: Calculate required points
    const points = try allocator.alloc(Point(f32), 200);

    var x: f32 = 0;
    var y: f32 = 0;
    points_count = 0;
    var n: i32 = -1;
    for (vertices) |vertex| {
        switch (vertex.kind) {
            @enumToInt(VMove.move) => {
                if (n >= 0) {
                    contour_lengths.*[@intCast(usize, n)] = @intCast(i32, points_count) - start;
                }
                n += 1;
                start = @intCast(i32, points_count);
                x = @intToFloat(f32, vertex.x);
                y = @intToFloat(f32, vertex.y);
                points[@intCast(usize, points_count)].x = x;
                points[@intCast(usize, points_count)].y = y;
                points_count += 1;
            },
            @enumToInt(VMove.line) => {
                x = @intToFloat(f32, vertex.x);
                y = @intToFloat(f32, vertex.y);
                points[@intCast(usize, points_count)].x = x;
                points[@intCast(usize, points_count)].y = y;
                points_count += 1;
            },
            @enumToInt(VMove.curve) => {
                const fcx: f32 = @intToFloat(f32, vertex.cx);
                const fcy: f32 = @intToFloat(f32, vertex.cy);
                const fx: f32 = @intToFloat(f32, vertex.x);
                const fy: f32 = @intToFloat(f32, vertex.y);

                points_count += tessellateCurve(&points[points_count..], x, y, fcx, fcy, fx, fy, objspace_flatness_squared, 0);
                x = @intToFloat(f32, vertex.x);
                y = @intToFloat(f32, vertex.y);
            },
            @enumToInt(VMove.cubic) => {
                assert(false);

                const fcx: f32 = @intToFloat(f32, vertex.cx);
                const fcy: f32 = @intToFloat(f32, vertex.cy);
                const fcx1: f32 = @intToFloat(f32, vertex.cx1);
                const fcy1: f32 = @intToFloat(f32, vertex.cy1);
                const fx: f32 = @intToFloat(f32, vertex.x);
                const fy: f32 = @intToFloat(f32, vertex.y);

                points_count += tessellateCubic(&points[points_count..], fx, fy, fcx, fcy, fcx1, fcy1, fx, fy, objspace_flatness_squared, 0);

                x = @intToFloat(f32, vertex.x);
                y = @intToFloat(f32, vertex.y);

                // TODO:
                unreachable;
            },
            else => unreachable,
        }
    }
    contour_lengths.*[@intCast(usize, n)] = @intCast(i32, points_count) - @intCast(i32, start);

    // TODO: Memory leak
    return points[0..points_count];
}

fn printPoints(points: []Point(f32)) void {
    for (points) |point, i| {
        print("  {d:2} xy ({d}, {d})\n", .{ i, point.x, point.y });
    }
    print("Done\n", .{});
}

const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32, invert: bool };

fn printEdge(e: Edge) void {
    print("x0,y0 ({d}, {d}), x1,y1 ({d}, {d})\n", .{ e.x0, e.y0, e.x1, e.y1 });
}

fn printEdges(edges: []const Edge) void {
    for (edges) |e, i| {
        print("{d:2} ", .{i});
        printEdge(e);
    }
}

fn rasterize(allocator: Allocator, flatness_in_pixels: f32, dimensions: Dimensions2D(i32), vertices: []Vertex, scale: Scale2D(f32), shift: Shift2D(f32), offset: Offset2D(i32), invert: bool) !Bitmap {
    const scale_min = if (scale.x > scale.y) scale.y else scale.x;
    var winding_lengths: []i32 = undefined;

    var windings: u32 = undefined;
    const points: []Point(f32) = try flattenCurves(allocator, vertices, flatness_in_pixels / scale_min, &winding_lengths, &windings);
    // TODO: Allocated inside flattenCurves
    defer allocator.free(points);

    if (points.len == 0) {
        return error.NoPointsToRasterize;
    }

    const vsubsample: f32 = 1.0;
    const y_scale_inv: f32 = if (invert) -scale.y else scale.y;

    var n: usize = 0;
    var i: usize = 0;
    while (i < winding_lengths.len) : (i += 1) {
        n += @intCast(usize, winding_lengths[i]);
    }

    var edges = try allocator.alloc(Edge, n + 1);
    defer allocator.free(edges);

    n = 0;
    i = 0;

    var m: i32 = 0;

    var j: usize = 0;
    while (i < windings) : (i += 1) {

        // TODO: rename to plural
        const point = points[@intCast(usize, m)..];
        m += winding_lengths[@intCast(usize, i)];
        j = @intCast(usize, winding_lengths[@intCast(usize, i)] - 1);

        var k: u32 = 0;
        while (k < winding_lengths[@intCast(usize, i)]) : (k += 1) {
            var a = k;
            var b = j;

            if (point[@intCast(usize, j)].y == point[@intCast(usize, k)].y) {
                j = k;
                continue;
            }
            edges[@intCast(usize, n)].invert = false;

            if ((invert and (point[@intCast(usize, j)].y > point[@intCast(usize, k)].y)) or (!invert and point[@intCast(usize, j)].y < point[@intCast(usize, k)].y)) {
                edges[@intCast(usize, n)].invert = true;
                a = @intCast(u32, j);
                b = k;
            }

            edges[n].x0 = (point[a].x * scale.x) + shift.x;
            edges[n].y0 = ((point[a].y * y_scale_inv) + shift.y) * vsubsample;
            edges[n].x1 = (point[b].x * scale.x) + shift.x;
            edges[n].y1 = ((point[b].y * y_scale_inv) + shift.y) * vsubsample;

            n += 1;
            j = k;
        }
    }

    // TODO: This is allocated inside flattenCurves
    allocator.free(winding_lengths);

    //
    // Simple insertion sort is enough for this usecase
    //
    {
        var step: usize = 1;
        while (step < n) : (step += 1) {
            const key = edges[step];
            var x: i64 = @intCast(i64, step) - 1;
            while (x >= 0 and edges[@intCast(usize, x)].y0 > key.y0) {
                edges[@intCast(usize, x) + 1] = edges[@intCast(usize, x)];
                x -= 1;
            }
            edges[@intCast(usize, x + 1)] = key;
        }
    }

    return rasterizeSortedEdges(allocator, edges[0 .. n + 1], dimensions, offset);
}

const ActiveEdge = packed struct { next_index: u32, fx: f32, fdx: f32, fdy: f32, direction: f32, sy: f32, ey: f32 };

fn printActiveEdges(active_edges: []const ActiveEdge) void {
    print("Active edges\n", .{});
    for (active_edges) |e, i| {
        print("  {d:2}", .{
            i,
        });
        printActiveEdge(e);
    }
}

fn printActiveEdge(e: ActiveEdge) void {
    print("  fx {} fdx {} fdy {d} dir {} sy {} ey {}\n", .{ e.fx, e.fdx, e.fdy, e.direction, e.sy, e.ey });
}

const EdgeHeap = struct {
    pub const capacity: comptime_int = 50;

    edges: [@This().capacity]ActiveEdge,
    count: u32,

    pub fn remove(self: *@This(), index: u32) !void {
        assert(self.count > 0);
        assert(index < self.count);

        // Left shift all elements overwritting elements to be removed
        const elements_to_shift_count: u32 = self.count - index - 1;
        var i: u32 = 0;
        while (i < elements_to_shift_count) : (i += 1) {
            self.edges[index + i] = self.edges[index + i + 1];
        }

        self.count -= 1;
    }

    pub fn at(self: *@This(), index: u32) !void {
        assert(index < self.count);
        return self.edges[index];
    }

    pub fn insertFront(self: *@This(), active_edge: ActiveEdge) !void {
        assert(self.count < EdgeHeap.capacity);

        // Move to make space
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            // Right shift all elements starting from back
            self.edges[self.count - i] = self.edges[self.count - i - 1];
        }

        self.edges[0] = active_edge;
        self.count += 1;
    }
};

fn newActiveEdge(edge: Edge, off_x: i32, start_point: f32) ActiveEdge {
    const dxdy: f32 = (edge.x1 - edge.x0) / (edge.y1 - edge.y0);
    const active_edge = ActiveEdge{
        .fdx = dxdy,
        .fdy = if (dxdy != 0.0) (1.0 / dxdy) else 0.0,
        .fx = (edge.x0 + (dxdy * (start_point - edge.y0))) - @intToFloat(f32, off_x),
        .direction = if (edge.invert) 1.0 else -1.0, // TODO
        .sy = edge.y0,
        .ey = edge.y1,
        .next_index = 0,
    };

    return active_edge;
}

fn rasterizeSortedEdges(allocator: Allocator, edges: []Edge, dimensions: Dimensions2D(i32), offset: Offset2D(i32)) !Bitmap {
    assert(dimensions.width <= 64);
    assert(edges.len > 0);

    var scanline: [129]f32 = undefined;
    var scanline2: [*]f32 = undefined;
    var y: i32 = 0;
    var j: i32 = 0;
    var i: i32 = 0;

    var active_edges = EdgeHeap{
        .count = 0,
        .edges = undefined,
    };

    // var active_edge_index: u32 = 0;
    // var active: ?*ActiveEdge = null;

    var bitmap: Bitmap = .{
        .width = @intCast(u32, dimensions.width),
        .height = @intCast(u32, dimensions.height),
        .pixels = undefined,
    };

    scanline2 = @intToPtr([*]f32, @ptrToInt(&scanline) + (@intCast(usize, dimensions.width) * @sizeOf(f32)));

    y = offset.y;
    edges[edges.len - 1].y0 = (@intToFloat(f32, offset.y) + @intToFloat(f32, dimensions.height)) + 2.0;

    assert(bitmap.width > 0);
    assert(bitmap.height > 0);

    // TODO:
    bitmap.pixels = try allocator.alloc(u8, bitmap.height * bitmap.width);
    var edge_i: usize = 0;

    //
    // Assert edges are sorted ascending by y0
    //
    var max_y: f32 = -9999999.0;
    for (edges) |e| {
        assert(e.y0 >= max_y);
        max_y = e.y0;
    }

    while (j < dimensions.height) {
        const scan_y_top: f32 = @intToFloat(f32, y) + 0.0;
        const scan_y_bottom: f32 = @intToFloat(f32, y) + 1.0;

        // var step_index: ?u32 = null;
        // var step: ?ActiveEdge = null;

        @memset(@ptrCast([*]u8, &scanline), 0, 129 * @sizeOf(f32));

        var a: u32 = 0;
        while (a < active_edges.count) {
            const active_edge = active_edges.edges[a];
            if (active_edge.ey <= scan_y_top) {
                // If element is deleted, no need to increment a
                try active_edges.remove(a);
            } else {
                a += 1;
            }
        }

        assert(edge_i < edges.len);

        // Add new active edges
        while (edge_i < edges.len) {
            const edge = edges[edge_i];
            if (edge.y0 > scan_y_bottom) {
                break;
            }

            if (edge.y0 != edge.y1) {
                var active_edge = newActiveEdge(edge, offset.x, scan_y_top);
                if (j == 0 and offset.y != 0) {
                    if (active_edge.ey < scan_y_top) {
                        active_edge.ey = scan_y_top;
                    }
                }
                assert(active_edge.ey >= scan_y_top);
                try active_edges.insertFront(active_edge);
            } else {
                unreachable;
            }
            edge_i += 1;

            // All edges within scanlines are processed here
            // All edges that match are converted into ActiveEdges and should be removed
            // Otherwise Edges will keep getting converted to ActiveEdges over and over

        } else {
            unreachable;
        }

        if (active_edges.count > 0) {
            fillActiveEdgesNew(scanline[0..], scanline2 + 1, dimensions.width, active_edges.edges[0..active_edges.count], scan_y_top);
        }

        {
            var sum: f32 = 0.0;
            i = 0;
            while (i < dimensions.width) : (i += 1) {
                var k: f32 = 0.0;
                var m: i32 = 0;
                // sum = if (i == 0) 0.0 else -1.0;
                sum += scanline2[@intCast(usize, i)];

                k = scanline[@intCast(usize, i)] + sum;
                k = (abs(k) * 255) + 0.5;
                m = @floatToInt(i32, k);
                if (m > 255) {
                    m = 255;
                }

                const stride: usize = @intCast(usize, dimensions.width); // TODO
                bitmap.pixels[@intCast(usize, j) * stride + @intCast(usize, i)] = @intCast(u8, m);
            }
        }

        var v: u32 = 0;
        while (v < active_edges.count) : (v += 1) {
            active_edges.edges[v].fx += active_edges.edges[v].fdx;
        }

        y += 1;
        j += 1;
    }

    return bitmap;
}

fn handleClippedEdge(scanline: [*]f32, x: f32, edge: *ActiveEdge, x0_: f32, y0_: f32, x1_: f32, y1_: f32) void {
    if (y0_ == y1_) return;

    var x0 = x0_;
    var y0 = y0_;
    var x1 = x1_;
    var y1 = y1_;

    assert(y0 < y1);
    assert(edge.sy <= edge.ey);

    if (y0 > edge.ey) return;
    if (y1 < edge.sy) return;

    if (y0 < edge.sy) {
        x0 += (x1 - x0) * (edge.sy - y0) / (y1 - y0);
        y0 = edge.sy;
    }

    if (y1 > edge.ey) {
        x1 += (x1 - x0) * (edge.ey - y1) / (y1 - y0);
        y1 = edge.ey;
    }

    if (x0 == x) {
        assert(x1 <= x + 1);
    } else if (x0 == x + 1) {
        assert(x0 >= x);
    } else if (x0 <= x) {
        assert(x1 <= x);
    } else if (x0 >= x + 1) {
        assert(x1 >= x + 1);
    } else {
        assert(x1 >= x and x1 <= x + 1);
    }

    if (x0 <= x and x1 <= x) {
        scanline[@floatToInt(usize, x)] += edge.direction * (y1 - y0);
    } else if (x0 >= x + 1 and x1 >= x + 1) {
        // Do nothing
    } else {
        assert(x0 >= x and x0 <= x + 1 and x1 >= x and x1 <= x + 1);
        const increment = edge.direction * (y1 - y0) * (1 - ((x0 - x) + (x1 - x)) / 2);
        scanline[@floatToInt(usize, x)] += increment;
    }
}

fn fillActiveEdgesNew(scanline: [*]f32, scanline_fill: [*]f32, len: i32, active_edges: []ActiveEdge, y_top: f32) void {
    var y_bottom: f32 = y_top + 1.0;

    for (active_edges) |*edge| {
        assert(edge.ey >= y_top);

        if (edge.fdx == 0) {
            var x0: f32 = edge.fx;
            if (x0 < @intToFloat(f32, len)) {
                if (x0 >= 0) {
                    handleClippedEdge(scanline, @floor(x0), edge, x0, y_top, x0, y_bottom);
                    handleClippedEdge(scanline_fill - 1, @floor(x0) + 1.0, edge, x0, y_top, x0, y_bottom);
                } else {
                    handleClippedEdge(scanline_fill - 1, 0, edge, x0, y_top, x0, y_bottom);
                }
            }
        } else {
            var x0: f32 = edge.fx;
            var dx: f32 = edge.fdx;
            var xb: f32 = x0 + dx;
            var x_top: f32 = 0.0;
            var x_bottom: f32 = 0.0;
            var sy0: f32 = 0.0;
            var sy1: f32 = 0.0;
            var dy: f32 = edge.fdy;

            assert(edge.sy <= y_bottom and edge.ey >= y_top);

            if (edge.sy > y_top) {
                x_top = x0 + (dx * (edge.sy - y_top));
                sy0 = edge.sy;
            } else {
                x_top = x0;
                sy0 = y_top;
            }

            if (edge.ey < y_bottom) {
                x_bottom = x0 + (dx * (edge.ey - y_top));
                sy1 = edge.ey;
            } else {
                x_bottom = xb;
                sy1 = y_bottom;
            }

            if (x_top >= 0 and x_bottom >= 0 and x_top < @intToFloat(f32, len) and x_bottom < @intToFloat(f32, len)) {
                if (@floatToInt(i32, x_top) == @floatToInt(i32, x_bottom)) {
                    var height: f32 = 0.0;
                    var x: i32 = @floatToInt(i32, x_top);
                    height = sy1 - sy0;
                    assert(x >= 0 and x < len);

                    // e->direction * (1-((x_top - x) + (x_bottom-x))/2)  * height;
                    const value = edge.direction * (1.0 - ((x_top - @intToFloat(f32, x)) + (x_bottom - @intToFloat(f32, x))) / 2.0) * height;

                    scanline[@intCast(usize, x)] += value;
                    scanline_fill[@intCast(usize, x)] += edge.direction * height;
                } else {
                    var x: i32 = 0;
                    var x1: i32 = 0;
                    var x2: i32 = 0;
                    var y_crossing: f32 = 0.0;
                    var step: f32 = 0.0;
                    var sign: f32 = 0.0;
                    var area: f32 = 0.0;

                    if (x_top > x_bottom) {
                        var t: f32 = 0.0;
                        sy0 = y_bottom - (sy0 - y_top);
                        sy1 = y_bottom - (sy1 - y_top);
                        t = sy0;
                        sy0 = sy1;
                        sy1 = t;
                        t = x_bottom;
                        x_bottom = x_top;
                        x_top = t;
                        dx = -dx;
                        dy = -dy;
                        t = x0;
                        x0 = xb;
                        xb = t;
                    }

                    x1 = @floatToInt(i32, x_top);
                    x2 = @floatToInt(i32, x_bottom);
                    y_crossing = (@intToFloat(f32, x1) + 1.0 - x0) * dy + y_top;
                    sign = edge.direction;
                    area = sign * (y_crossing - sy0);
                    // TODO: x1 + 1 - x1 ???
                    const value = area * (1 - ((x_top - @intToFloat(f32, x1)) + (@intToFloat(f32, x1) + 1.0 - @intToFloat(f32, x1))) / 2.0);
                    scanline[@intCast(usize, x1)] += value;

                    step = sign * dy;
                    x = x1 + 1;
                    while (x < x2) : (x += 1) {
                        scanline[@intCast(usize, x)] += area + (step / 2.0);
                        area += step;
                    }

                    y_crossing += dy * (@intToFloat(f32, x2) - (@intToFloat(f32, x1) + 1.0));
                    assert(abs(area) <= 1.01);

                    // TODO: (x2 - x2) ???
                    scanline[@intCast(usize, x2)] += area + sign * (1 - (x_bottom - @intToFloat(f32, x2)) / 2.0) * (sy1 - y_crossing);
                    scanline_fill[@intCast(usize, x2)] += sign * (sy1 - sy0);
                }
            } else {
                // unreachable;
                var x: i32 = 0;
                while (x < len) : (x += 1) {
                    var y0: f32 = y_top;
                    var x1: f32 = @intToFloat(f32, x);
                    var x2: f32 = @intToFloat(f32, x + 1);
                    var x3: f32 = xb;
                    var y3: f32 = y_bottom;

                    var y1: f32 = ((@intToFloat(f32, x) - x0) / dx) + y_top;
                    var y2: f32 = ((@intToFloat(f32, x) + 1.0 - x0) / dx) + y_top;
                    const fx: f32 = @intToFloat(f32, x);

                    if (x0 < x1 and x3 > x2) {
                        handleClippedEdge(scanline, fx, edge, x0, y0, x1, y1);
                        handleClippedEdge(scanline, fx, edge, x1, y1, x2, y2);
                        handleClippedEdge(scanline, fx, edge, x2, y2, x3, y3);
                    } else if (x3 < x1 and x0 > x2) {
                        handleClippedEdge(scanline, fx, edge, x0, y0, x2, y2);
                        handleClippedEdge(scanline, fx, edge, x2, y2, x1, y1);
                        handleClippedEdge(scanline, fx, edge, x1, y1, x3, y3);
                    } else if (x0 < x1 and x3 > x1) {
                        handleClippedEdge(scanline, fx, edge, x0, y0, x1, y1);
                        handleClippedEdge(scanline, fx, edge, x1, y1, x3, y3);
                    } else if (x3 < x1 and x0 > x1) {
                        // TODO: Same as above
                        handleClippedEdge(scanline, fx, edge, x0, y0, x1, y1);
                        handleClippedEdge(scanline, fx, edge, x1, y1, x3, y3);
                    } else if (x0 < x2 and x3 > x2) {
                        handleClippedEdge(scanline, fx, edge, x0, y0, x2, y2);
                        handleClippedEdge(scanline, fx, edge, x2, y2, x3, y3);
                    } else if (x3 < x2 and x0 > x2) {
                        // TODO: Same as above
                        handleClippedEdge(scanline, fx, edge, x0, y0, x2, y2);
                        handleClippedEdge(scanline, fx, edge, x2, y2, x3, y3);
                    } else {
                        handleClippedEdge(scanline, fx, edge, x0, y0, x3, y3);
                    }
                }
            }
        }
    }
}

const OffsetSubtable = struct {
    scaler_type: u32,
    tables_count: u16,
    search_range: u16,
    entry_selector: u16,
    range_shift: u16,

    pub fn fromBigEndianBytes(bytes: *align(4) [@sizeOf(OffsetSubtable)]u8) @This() {
        var result = @ptrCast(*OffsetSubtable, bytes).*;

        result.scaler_type = toNative(u32, result.scaler_type, .Big);
        result.tables_count = toNative(u16, result.tables_count, .Big);
        result.search_range = toNative(u16, result.search_range, .Big);
        result.entry_selector = toNative(u16, result.entry_selector, .Big);
        result.range_shift = toNative(u16, result.range_shift, .Big);

        return result;
    }
};

// NOTE: This should be packed
const TableDirectory = struct {
    tag: [4]u8,
    checksum: u32,
    offset: u32,
    length: u32,

    pub fn isChecksumValid(self: @This()) bool {
        assert(@sizeOf(@This()) == 16);

        var sum: u32 = 0;
        var iteractions_count: u32 = @sizeOf(@This()) / 4;

        var bytes = @ptrCast(*const u32, &self);
        while (iteractions_count > 0) : (iteractions_count -= 1) {
            _ = @addWithOverflow(u32, sum, bytes.*, &sum);
            bytes = @intToPtr(*const u32, @ptrToInt(bytes) + @sizeOf(u32));
        }

        const checksum = self.checksum;

        return (sum == checksum);
    }

    pub fn fromBigEndianBytes(bytes: *align(4) [@sizeOf(TableDirectory)]u8) ?TableDirectory {
        var result: TableDirectory = @ptrCast(*align(4) TableDirectory, bytes).*;

        // Disabled as not working
        // if (!result.isChecksumValid()) {
        // return null;
        // }

        result.length = toNative(u32, result.length, .Big);
        result.offset = toNative(u32, result.offset, .Big);

        return result;
    }
};

const Head = packed struct {
    version: f32,
    font_revision: f32,
    checksum_adjustment: u32,
    magic_number: u32, // 0x5F0F3CF5
    flags: u16,
    units_per_em: u16,
    created: i64,
    modified: i64,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    mac_style: u16,
    lowest_rec_PPEM: u16,
    font_direction_hint: i16,
    index_to_loc_format: i16,
    glyph_data_format: i16,
};

const cff_magic_number: u32 = 0x5F0F3CF5;

const PlatformID = enum(u8) { unicode = 0, max = 1, iso = 2, microsoft = 3 };

const CmapIndex = struct {
    version: u16,
    subtables_count: u16,
};

const CMAPPlatformID = enum(u16) {
    unicode = 0,
    macintosh,
    reserved,
    microsoft,
};

const CMAPPlatformSpecificID = packed union {
    const Unicode = enum(u16) {
        version1_0,
        version1_1,
        iso_10646,
        unicode2_0_bmp_only,
        unicode2_0,
        unicode_variation_sequences,
        last_resort,
        other, // This value is allowed but shall be ignored
    };

    const Macintosh = enum(u16) {
        roman,
        japanese,
        traditional_chinese,
        // etc: https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6name.html
    };

    const Microsoft = enum(u16) {
        symbol,
        unicode_bmp_only,
        shift_jis,
        prc,
        big_five,
        johab,
        unicode_ucs_4,
    };

    unicode: Unicode,
    microsoft: Microsoft,
    macintosh: Macintosh,
};

const CMAPSubtable = struct {
    pub fn fromBigEndianBytes(bytes: []u8) ?CMAPSubtable {
        var table: CMAPSubtable = undefined;

        const platform_id_u16 = toNative(u16, @ptrCast(*u16, @alignCast(2, bytes.ptr)).*, .Big);

        if (platform_id_u16 > @enumToInt(CMAPPlatformID.microsoft)) {
            log.warn("Invalid platform ID '{d}' parsed from CMAP subtable", .{platform_id_u16});
            return null;
        }

        table.platform_id = @intToEnum(CMAPPlatformID, platform_id_u16);

        table.offset = toNative(u32, @ptrCast(*u32, @alignCast(4, &bytes.ptr[4])).*, .Big);

        const platform_specific_id_u16 = toNative(u16, @ptrCast(*u16, @alignCast(2, &bytes.ptr[2])).*, .Big);

        switch (table.platform_id) {
            .unicode => {
                if (platform_specific_id_u16 < @enumToInt(CMAPPlatformSpecificID.Unicode.last_resort)) {
                    table.platform_specific_id = .{ .unicode = @intToEnum(CMAPPlatformSpecificID.Unicode, platform_specific_id_u16) };
                } else {
                    table.platform_specific_id = .{ .unicode = .other };
                }
                log.info("Platform specific ID for '{s}' => '{s}'", .{ table.platform_id, table.platform_specific_id.unicode });
            },
            .microsoft => {
                // unreachable;
            },
            .macintosh => {
                // unreachable;
            },
            .reserved => {
                // unreachable;
            },
        }

        return table;
    }

    platform_id: CMAPPlatformID,
    platform_specific_id: CMAPPlatformSpecificID,
    offset: u32,
};

const CMAPFormat2 = struct {
    format: u16,
    length: u16,
    language: u16,
};

pub fn initializeFont(allocator: Allocator, data: [*]u8) !FontInfo {
    _ = allocator;

    var cmap: u32 = 0;
    // var t: u32 = 0;

    var font_info: FontInfo = .{
        .data = data[0..10],
        .loca = .{},
        .head = .{},
        .hhea = .{},
        .hmtx = .{},
        .glyf = .{},
        .kern = .{},
        .gpos = .{},
        .svg = .{},
        .maxp = .{},
        .cff = .{
            .data = undefined,
        },
        .char_strings = .{ .data = undefined },
        .gsubrs = .{ .data = undefined },
        .subrs = .{ .data = undefined },
        .userdata = undefined,
        .font_dicts = .{ .data = undefined },
        .fd_select = .{ .data = undefined },
    };

    // TODO: What is the real allocation size?
    // font_info.cff = try allocator.alloc(u8, 0);

    {
        const offset_subtable = OffsetSubtable.fromBigEndianBytes(@intToPtr(*align(4) [@sizeOf(OffsetSubtable)]u8, @ptrToInt(data)));
        assert(offset_subtable.tables_count < 20);

        var i: u32 = 0;
        while (i < offset_subtable.tables_count) : (i += 1) {
            const entry_addr = @intToPtr(*align(4) [@sizeOf(TableDirectory)]u8, @ptrToInt(data + @sizeOf(OffsetSubtable)) + (@sizeOf(TableDirectory) * i));
            if (TableDirectory.fromBigEndianBytes(entry_addr)) |table_directory| {
                var found: bool = false;
                for (TableTypeList) |valid_tag, valid_tag_i| {

                    // This is a little silly as we're doing a string comparision
                    // And then doing a somewhat unnessecary int comparision / jump

                    if (eql(u8, valid_tag, table_directory.tag[0..])) {
                        found = true;
                        switch (@intToEnum(TableType, @intCast(u4, valid_tag_i))) {
                            .cmap => {
                                cmap = table_directory.offset;
                            },
                            .loca => {
                                font_info.loca.offset = table_directory.offset;
                                font_info.loca.length = table_directory.length;
                            },
                            .head => {
                                font_info.head.offset = table_directory.offset;
                                font_info.head.length = table_directory.length;
                            },
                            .glyf => {
                                font_info.glyf.offset = table_directory.offset;
                                font_info.glyf.length = table_directory.length;
                            },
                            .hhea => {
                                font_info.hhea.offset = table_directory.offset;
                                font_info.hhea.length = table_directory.length;
                            },
                            .hmtx => {
                                font_info.hmtx.offset = table_directory.offset;
                                font_info.hmtx.length = table_directory.length;
                            },
                            .kern => {
                                font_info.loca.offset = table_directory.offset;
                                font_info.loca.length = table_directory.length;
                            },
                            .gpos => {
                                font_info.gpos.offset = table_directory.offset;
                                font_info.gpos.length = table_directory.length;
                            },
                            .maxp => {
                                font_info.maxp.offset = table_directory.offset;
                                font_info.maxp.length = table_directory.length;
                            },
                        }
                    }
                }

                found = false;
            } else {
                log.warn("Failed to load table directory", .{});
            }
        }
    }

    font_info.glyph_count = bigToNative(u16, @intToPtr(*u16, @ptrToInt(data) + font_info.maxp.offset + 4).*);
    font_info.index_to_loc_format = bigToNative(u16, @intToPtr(*u16, @ptrToInt(data) + font_info.head.offset + 50).*);

    if (cmap == 0) {
        return error.RequiredFontTableCmapMissing;
    }

    if (font_info.head.offset == 0) {
        return error.RequiredFontTableHeadMissing;
    }

    if (font_info.hhea.offset == 0) {
        return error.RequiredFontTableHheaMissing;
    }

    if (font_info.hmtx.offset == 0) {
        return error.RequiredFontTableHmtxMissing;
    }

    const head = @intToPtr(*Head, @ptrToInt(data) + font_info.head.offset).*;
    assert(toNative(u32, head.magic_number, .Big) == 0x5F0F3CF5);

    // Let's read CMAP tables
    var cmap_index_table = @intToPtr(*CmapIndex, @ptrToInt(data + cmap)).*;

    cmap_index_table.version = toNative(u16, cmap_index_table.version, .Big);
    cmap_index_table.subtables_count = toNative(u16, cmap_index_table.subtables_count, .Big);

    assert(@sizeOf(CMAPPlatformID) == 2);
    assert(@sizeOf(CMAPPlatformSpecificID) == 2);

    font_info.cmap_encoding_table_offset = blk: {
        var cmap_subtable_index: u32 = 0;
        while (cmap_subtable_index < cmap_index_table.subtables_count) : (cmap_subtable_index += 1) {
            assert(@sizeOf(CmapIndex) == 4);
            assert(@sizeOf(CMAPSubtable) == 8);

            const cmap_subtable_addr: [*]u8 = @intToPtr([*]u8, @ptrToInt(data) + cmap + @sizeOf(CmapIndex) + (cmap_subtable_index * @sizeOf(CMAPSubtable)));
            const cmap_subtable = CMAPSubtable.fromBigEndianBytes(cmap_subtable_addr[0..@sizeOf(CMAPSubtable)]).?;

            if (cmap_subtable.platform_id == .microsoft and cmap_subtable.platform_specific_id.unicode != .other) {
                break :blk cmap + cmap_subtable.offset;
            }
        }

        unreachable;
    };

    const encoding_format: u16 = toNative(u16, @intToPtr(*u16, @ptrToInt(data) + font_info.cmap_encoding_table_offset).*, .Big);
    _ = encoding_format;

    // Load CFF

    // if(font_info.glyf != 0) {
    // if(font_info.loca == 0) { return error.RequiredFontTableCmapMissing; }
    // } else {

    // var buffer: Buffer = undefined;
    // var top_dict: Buffer = undefined;
    // var top_dict_idx: Buffer = undefined;

    // var cstype: u32 = 2;
    // var char_strings: u32 = 0;
    // var fdarrayoff: u32 = 0;
    // var fdselectoff: u32 = 0;
    // var cff: u32 = findTable(data, font_start, "CFF ");

    // if(!cff) {
    // return error.RequiredFontTableCffMissing;
    // }

    // font_info.font_dicts = Buffer.create();
    // font_info.fd_select = Buffer.create();

    // }
    //

    return font_info;
}

fn findGlyphIndex(font_info: FontInfo, unicode_codepoint: i32) u32 {
    const data = font_info.data;
    const encoding_offset = font_info.cmap_encoding_table_offset;

    if (unicode_codepoint > 0xffff) {
        log.info("Invalid codepoint", .{});
        return 0;
    }

    const base_index: usize = @ptrToInt(data.ptr) + encoding_offset;
    const format: u16 = bigToNative(u16, @intToPtr(*u16, base_index).*);

    // TODO:
    assert(format == 4);

    const segcount = toNative(u16, @intToPtr(*u16, base_index + 6).*, .Big) >> 1;
    var search_range = toNative(u16, @intToPtr(*u16, base_index + 8).*, .Big) >> 1;
    var entry_selector = toNative(u16, @intToPtr(*u16, base_index + 10).*, .Big);
    const range_shift = toNative(u16, @intToPtr(*u16, base_index + 12).*, .Big) >> 1;

    const end_count: u32 = encoding_offset + 14;
    var search: u32 = end_count;

    if (unicode_codepoint >= toNative(u16, @intToPtr(*u16, @ptrToInt(data.ptr) + search + (range_shift * 2)).*, .Big)) {
        search += range_shift * 2;
    }

    search -= 2;

    while (entry_selector != 0) {
        var end: u16 = undefined;
        search_range = search_range >> 1;

        end = toNative(u16, @intToPtr(*u16, @ptrToInt(data.ptr) + search + (search_range * 2)).*, .Big);

        if (unicode_codepoint > end) {
            search += search_range * 2;
        }
        entry_selector -= 1;
    }

    search += 2;

    {
        var offset: u16 = undefined;
        var start: u16 = undefined;
        const item: u32 = (search - end_count) >> 1;

        assert(unicode_codepoint <= toNative(u16, @intToPtr(*u16, @ptrToInt(data.ptr) + end_count + (item * 2)).*, .Big));
        start = toNative(u16, @intToPtr(*u16, @ptrToInt(data.ptr) + encoding_offset + 14 + (segcount * 2) + 2 + (2 * item)).*, .Big);

        if (unicode_codepoint < start) {
            // TODO: return error
            return 0;
        }

        offset = toNative(u16, @intToPtr(*u16, @ptrToInt(data.ptr) + encoding_offset + 14 + (segcount * 6) + 2 + (item * 2)).*, .Big);
        if (offset == 0) {
            const base = bigToNative(i16, @intToPtr(*i16, base_index + 14 + (segcount * 4) + 2 + (2 * item)).*);
            return @intCast(u32, unicode_codepoint + base);
            // return @intCast(u32, unicode_codepoint + toNative(u16, @intToPtr(*u16, @ptrToInt(data.ptr) + encoding_offset + 14 + (segcount * 4) + 2 + (2 * item)).*, .Big));
        }

        const result_addr_index = @ptrToInt(data.ptr) + offset + @intCast(usize, unicode_codepoint - start) * 2 + encoding_offset + 14 + (segcount * 6) + 2 + (2 * item);

        const result_addr = @intToPtr(*u8, result_addr_index);
        const result_addr_aligned = @ptrCast(*u16, @alignCast(2, result_addr));

        return @intCast(u32, toNative(u16, result_addr_aligned.*, .Big));
    }
}
