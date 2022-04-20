const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const toNative = std.mem.toNative;
const eql = std.mem.eql;
const assert = std.debug.assert;

pub const FontInfo = struct { // zigfmt: off
// zig fmt: off
    userdata: *void,
    data: []u8,
    font_start: i32,
    glyph_count: i32,
    loca: u32,
    head: u32,
    glyf: u32,
    hhea: u32,
    hmtx: u32,
    kern: u32,
    gpos: u32,
    svg: u32,
    index_map: i32, 
    indexToLocFormat: i32,
    cff: Buffer,
    char_strings: Buffer,
    gsubrs: Buffer,
    subrs: Buffer,
    font_dicts: Buffer,
    fd_select: Buffer
// zig fmt: on
};

const Buffer = struct {
    data: []u8,
    cursor: u32,
    size: u32,
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

    log.info("Font type: {s}", .{font_type});

    if (font_type == .none) {
        return if (index == 0) 0 else -1;
    }

    // if (tag(font_collection, "ttcf")) {
    // // version 1
    // if (ttULONG(font_collection + 4) == 0x00010000 or ttULONG(font_collection + 4) == 0x00020000) {
    // var n: i32 = ttULONG(font_collection + 8);
    // if (index >= n) {
    // return -1;
    // }
    // return ttULONG(font_collection + 12 + (index * 4));
    // }
    // }

    return -1;
}

fn ttUShort(data: [*]u8) u16 {
    return @intCast(u16, data[0]) * 256 + data[1];
}

pub fn printFontTags(data: []u8, font_start: i32) void {
    const tables_count_addr: *u16 = @intToPtr(*u16, @ptrToInt(data.ptr) + @intCast(usize, font_start) + 4);
    const tables_count = toNative(u16, tables_count_addr.*, .Big);
    log.info("Tables: {d}", .{tables_count});

    const table_dir: u32 = @intCast(u32, font_start) + 12;

    var i: u32 = 0;
    while (i < tables_count) : (i += 1) {
        const loc: u32 = table_dir + (16 * i);
        const tag: *[4]u8 = @intToPtr(*[4]u8, @ptrToInt(data.ptr) + loc);
        log.info("Tag: '{s}'", .{tag.*[0..]});
    }
}

fn findTable(data: []u8, font_start: u32, tag: []const u8) u32 {
    const tables_count_addr: *i32 = data + font_start + 4;
    const tables_count: i32 = toNative(i32, tables_count_addr.*, .LittleEndian);
    const table_dir = font_start + 12;

    var i: u32 = 0;
    while (i < tables_count) : (i += 1) {
        const loc: u32 = table_dir + (16 * i);
        if (Tag(data + loc + 0, ag)) {
            return toNative(u64, data + loc + 8, .BigEndian);
        }
    }

    return 0;
}

const TableType = enum { cmap, loca, head, glyf, hhea, hmtx, kern, gpos };

const TableTypeList: [8]*const [4:0]u8 = .{
    "cmap",
    "loca",
    "head",
    "glyf",
    "hhea",
    "hmtx",
    "kern",
    "GPOS",
};

pub fn initializeFont(allocator: *Allocator, data: [*]u8, font_start: usize) !FontInfo {
    var cmap: u32 = 0;
    var t: u32 = 0;

    var font_info: FontInfo = undefined;

    font_info.data = data[0..10];
    font_info.font_start = @intCast(i32, font_start);
    // TODO: What is the real allocation size?
    // font_info.cff = try allocator.alloc(u8, 0);

    {

        // Load tables into our font structure
        const tables_count_addr: *i32 = @intToPtr(*i32, @ptrToInt(data) + font_start + 4);
        const tables_count: i32 = toNative(i32, tables_count_addr.*, .Big);

        log.info("Table count: {d}", .{tables_count});

        const table_directory_addr: *u32 = @intToPtr(*u32, @ptrToInt(data) + font_start + 12);
        const table_directory_size: u32 = 16;

        assert(tables_count < 20);

        var i: u32 = 0;
        while (i < tables_count) : (i += 1) {
            const table_directory_entry_addr: *u32 = @intToPtr(*u32, @ptrToInt(table_directory_addr) + (table_directory_size * i));
            const table_tag: *[4]u8 = @ptrCast(*[4]u8, table_directory_entry_addr);
            const table_tag_value: u32 = @ptrCast(*u32, @intToPtr(*u32, @ptrToInt(table_directory_entry_addr) + 8)).*;

            log.info("Tag name: {d} {s}", .{ i, table_tag.* });

            for (TableTypeList) |valid_tag, valid_tag_i| {

                // This is a little silly as we're doing a string comparision
                // And then doing a somewhat unnessecary int comparision / jump

                // log.info("Tag name: {d} {s} {s}", .{ i, valid_tag, table_tag.* });

                if (eql(u8, valid_tag, table_tag)) {
                    switch (@intToEnum(TableType, @intCast(u3, valid_tag_i))) {
                        .cmap => {
                            cmap = toNative(u32, table_tag_value, .Big);
                            log.info("cmap: {d}", .{cmap});
                        },
                        .loca => {
                            font_info.loca = toNative(u32, table_tag_value, .Big);
                            log.info("loca: {d}", .{font_info.loca});
                        },
                        .head => {
                            font_info.head = toNative(u32, table_tag_value, .Big);
                            log.info("head: {d}", .{font_info.head});
                        },
                        .glyf => {
                            font_info.glyf = toNative(u32, table_tag_value, .Big);
                            log.info("glyf: {d}", .{font_info.glyf});
                        },
                        .hhea => {
                            font_info.hhea = toNative(u32, table_tag_value, .Big);
                            log.info("hhea: {d}", .{font_info.hhea});
                        },
                        .hmtx => {
                            font_info.hmtx = toNative(u32, table_tag_value, .Big);
                            log.info("hmtx: {d}", .{font_info.hmtx});
                        },
                        .kern => {
                            font_info.loca = toNative(u32, table_tag_value, .Big);
                            log.info("kern: {d}", .{font_info.kern});
                        },
                        .gpos => {
                            font_info.gpos = toNative(u32, table_tag_value, .Big);
                            log.info("gpos: {d}", .{font_info.gpos});
                        },
                    }
                }
            }
        }
    }

    // cmap = findTable(data, font_start, "cmap"); // required

    // font_info.loca = findTable(data, font_start, "loca");
    // font_info.head = findTable(data, font_start, "head");
    // font_info.glyf = findTable(data, font_start, "glyf");
    // font_info.hhea = findTable(data, font_start, "hhea");
    // font_info.hmtx = findTable(data, font_start, "hmtx");
    // font_info.kern = findTable(data, font_start, "kern");
    // font_info.gpos = findTable(data, font_start, "GPOS");

    // log.info("loca {d}", .{font_info.loca});
    // log.info("head {d}", .{font_info.head});
    // log.info("glyf {d}", .{font_info.glyf});
    // log.info("hhea {d}", .{font_info.hhea});
    // log.info("hmtx {d}", .{font_info.hmtx});
    // log.info("kern {d}", .{font_info.kern});
    // log.info("gpos {d}", .{font_info.gpos});

    if (cmap == 0) {
        return error.RequiredFontTableCmapMissing;
    }
    if (font_info.head == 0) {
        return error.RequiredFontTableHeadMissing;
    }
    if (font_info.hhea == 0) {
        return error.RequiredFontTableHheaMissing;
    }
    if (font_info.hmtx == 0) {
        return error.RequiredFontTableHmtxMissing;
    }

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
