const std = @import("std");
const assert = std.debug.assert;

pub fn FixedBuffer(comptime BaseType: type, comptime capacity: u32) type {
    return struct {
        items: [capacity]BaseType = undefined,
        count: u32 = 0,

        const Self = @This();

        pub inline fn append(self: *Self, item: BaseType) u32 {
            if (self.count >= capacity) {
                std.log.err("Overflow of {s} with capacity: {d}", .{ BaseType, self.count });
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
