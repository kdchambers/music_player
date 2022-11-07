const std = @import("std");
const assert = std.debug.assert;

pub fn handleTrigger() void {
    std.log.info("Handling trigger in memory", .{});
}

fn sliceFromNullTerminatedString(null_terminated_string: [*:0]const u8) []const u8 {
    var count: u32 = 0;
    const max: u32 = 1024;
    while (count < max) : (count += 1) {
        if (null_terminated_string[count] == 0) {
            return null_terminated_string[0..count];
        }
    }
    std.log.err("Failed to find null terminator in string after {d} charactors", .{max});
    unreachable;
}

pub const LinearArena = struct {
    const Self = @This();

    used: u16 = 0,
    memory: []u8 = undefined,

    pub inline fn indexFor(self: @This(), value: *u8) u16 {
        return @intCast(u16, @ptrToInt(value) - @ptrToInt(self.memory.ptr));
    }

    pub inline fn reset(self: *Self) void {
        self.used = 0;
    }

    pub fn init(self: *Self, backing_memory: []u8) void {
        std.debug.assert(backing_memory.len > 0);
        self.memory = backing_memory;
        self.used = 0;
    }

    pub fn allocateAligned(self: *Self, comptime T: type, comptime alignment: u23, amount: u16) []T {
        std.log.info("Allocating {d} bytes from remaining pool of {d}", .{ amount * @sizeOf(T), self.memory.len - self.used });

        std.debug.assert(self.used < self.memory.len);
        const misaligned_by = (@ptrToInt(&self.memory[self.used]) % alignment);
        const alignment_padding = blk: {
            if (misaligned_by > 0) {
                break :blk alignment - misaligned_by;
            }
            break :blk 0;
        };

        if (alignment_padding > 0) {
            std.log.warn("Adding {d} bytes of padding for alignment", .{alignment_padding});
        }

        const bytes_required = alignment_padding + (amount * @sizeOf(T));
        std.debug.assert((self.memory.len - self.used) >= bytes_required);
        defer self.used += @intCast(u16, bytes_required);
        var aligned_ptr = @ptrCast([*]T, @alignCast(alignment, &self.memory[self.used + alignment_padding]));
        std.debug.assert(@ptrToInt(aligned_ptr) % alignment == 0);

        // std.log.info("Allocated {d} bytes: {d} remaining", .{ bytes_required, self.memory.len - self.used });

        return aligned_ptr[0..amount];
    }

    // Access + claim
    pub fn allocate(self: *Self, comptime T: type, amount: u16) []T {
        return self.allocateAligned(T, @alignOf(T), amount);
    }

    pub fn createAligned(self: *@This(), comptime T: type, comptime alignment: u8) *T {
        std.debug.assert(self.memory.len > 0);
        std.debug.assert(self.used < self.memory.len);
        std.debug.assert(self.memory.len > (self.used + @sizeOf(T)));

        const misaligned_by = (@ptrToInt(&self.memory[self.used]) % alignment);
        std.debug.assert(misaligned_by < alignment);

        const alignment_padding = blk: {
            if (misaligned_by > 0) {
                break :blk alignment - misaligned_by;
            }
            break :blk 0;
        };
        std.debug.assert(alignment_padding < alignment);

        if (alignment_padding > 0) {
            std.log.warn("Adding {d} bytes of alignment", .{alignment_padding});
        }

        const bytes_required = alignment_padding + @sizeOf(T);
        std.debug.assert((self.memory.len - self.used) >= bytes_required);

        defer self.used += @intCast(u16, bytes_required);
        var aligned_ptr = @ptrCast(*T, @alignCast(alignment, &self.memory[self.used + alignment_padding]));
        std.debug.assert(@ptrToInt(aligned_ptr) % alignment == 0);

        std.log.info("Allocated {d} bytes: {d} remaining", .{ bytes_required, (self.memory.len - self.used) - bytes_required });

        return aligned_ptr;
    }

    pub fn create(self: *Self, comptime T: type) *T {
        return self.createAligned(T, @alignOf(T));
    }

    pub fn access(self: *Self) []u8 {
        return self.memory[self.used..];
    }

    pub fn peek(self: *Self) *u8 {
        return &self.memory[self.used];
    }

    pub fn checkpoint(self: *Self) u16 {
        return self.used;
    }

    pub fn remainingCount(self: Self) u16 {
        std.debug.assert(self.memory.len >= self.used);
        return @intCast(u16, self.memory.len - self.used);
    }

    pub fn claim(self: *Self, amount_bytes: u16) void {
        std.debug.assert((self.memory.len - self.used) >= amount_bytes);
        self.used += amount_bytes;
    }

    pub fn rewindBy(self: *Self, amount_bytes: u16) void {
        std.debug.assert(self.used >= amount_bytes);
        self.used -= amount_bytes;
    }

    pub fn rewindTo(self: *Self, point: u16) void {
        std.debug.assert(point <= self.used);
        self.used = point;
    }
};

// To be used for storing tag strings
pub fn LinearPackedStringList(comptime Capacity: usize) type {
    return struct {
        const Self = @This();

        count: u16,
        memory_used: u16,
        sizes: [Capacity]u8,
        memory: [*]u8,

        pub fn init(self: *Self, arena: LinearArena) !void {
            self.memory = arena.peek();
            self.count = 0;
            self.memory_used = 0;
        }

        pub fn clear(self: *Self) void {
            self.count = 0;
            self.memory_used = 0;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.memory);
        }

        pub fn append(self: *Self, arena: LinearArena, value: []const u8) !void {
            std.debug.assert(value.len > 0);
            if (self.count >= Capacity) {
                return error.CapacityReached;
            }
            const remaining = self.memory.len - self.memory_used;
            if (value.len > (remaining + 1)) {
                // TODO: Handle with realloc
                return error.InsufficientSpace;
            }

            var memory = arena.allocate(value.len + 1);
            for (value) |char, i| {
                memory[self.memory_used + i] = char;
            }

            // Null terminate
            memory[self.memory_used + value.len] = 0;
            self.count += 1;
            self.memory_used = value.len + 1;
        }

        pub fn at(self: Self, index: u16) []const u8 {
            std.debug.assert(self.count > index);
            const string_start_index = blk: {
                var i: u16 = 0;
                var count: u16 = 0;
                while (i < index) : (i += 1) {
                    count += self.sizes[i] + 1;
                }
                break :blk count;
            };

            const string_length = self.sizes[index];
            return self.memory[string_start_index .. string_start_index + string_length];
        }

        pub fn atZ(self: Self, index: u16) [:0]const u8 {
            std.debug.assert(self.count > index);
            const string_start_index = blk: {
                var i: u16 = 0;
                var count: u16 = 0;
                while (i < index) : (i += 1) {
                    count += self.sizes[i] + 1;
                }
                break :blk count;
            };

            const string_length = self.sizes[index] + 1;
            return self.memory[string_start_index .. string_start_index + string_length];
        }
    };
}

pub fn FixedBuffer(comptime BaseType: type, comptime capacity: u32) type {
    return struct {
        items: [capacity]BaseType = undefined,
        count: u32 = 0,

        const Self = @This();

        pub inline fn remainingCount(self: *@This()) u32 {
            return capacity - self.count;
        }

        pub inline fn append(self: *Self, item: BaseType) u32 {
            if (self.count >= capacity) {
                std.log.err("Overflow of {} with capacity: {d}", .{ BaseType, self.count });
                assert(self.count < capacity);
            }

            self.items[self.count] = item;
            self.count += 1;
            return self.count - 1;
        }

        pub fn toSlice(self: Self) []const BaseType {
            return self.items[0..self.count];
        }

        pub fn toSliceMutable(self: *Self) []BaseType {
            return self.items[0..self.count];
        }

        pub fn clear(self: *Self) void {
            self.count = 0;
        }
    };
}
