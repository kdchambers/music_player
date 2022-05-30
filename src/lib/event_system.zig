// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const graphics = @import("graphics");
const GenericVertex = graphics.GenericVertex;
const geometry = @import("geometry");
const ScaleFactor2D = geometry.ScaleFactor2D;
const memory = @import("memory");
const constants = @import("constants");
const ScreenNormalizedBaseType = constants.ScreenNormalizedBaseType;
const ScreenPixelBaseType = constants.ScreenPixelBaseType;

pub const ActionIndex = u12;
pub const EventIndex = u12;
pub const SubsystemIndex = u4;

pub const InternalEventBinding = struct {
    /// Event that occurs within the system
    origin: SubsystemEventIndex,

    /// Action that is to be invoked in response
    target: SubsystemActionIndex,
};

pub fn resetActiveTimeIntervalEvents() void {
    for (registered_time_interval_events.toSliceMutable()) |*event| {
        event.start_timestamp_ms = 0;
    }
}

pub fn resetBindings() void {
    registered_time_interval_events.clear();
    internal_event_bindings.clear();
}

var internal_event_bindings: memory.FixedBuffer(InternalEventBinding, 20) = .{};

pub fn internalEventsBind(binding: InternalEventBinding) u16 {
    return @intCast(u16, internal_event_bindings.append(binding));
}

pub fn internalEventHandle(origin: SubsystemActionIndex) void {
    if (internal_event_bindings.count == 0) {
        std.log.warn("No internal events loaded to invoke", .{});
        return;
    }
    for (internal_event_bindings.toSlice()) |event| {
        const current_origin = event.origin;
        if (current_origin.index == origin.index and current_origin.subsystem == origin.subsystem) {
            registered_action_handlers[event.target.subsystem].*(event.target.index);
        }
    }
}

pub const ActionHandlerFunction = fn (ActionIndex) void;

pub const null_action_index: ActionIndex = std.math.maxInt(ActionIndex);
pub const null_subsystem_index: SubsystemIndex = std.math.maxInt(SubsystemIndex);

const TimeIntervalEventBinding = struct {
    callback: *const fn () void,
    start_timestamp_ms: i64,
    last_called_timestamp_ms: i64,
    interval_milliseconds: u32,
    invocation_count: u32 = 0,
};

pub const TimeIntervalEventEntry = struct {
    callback: *const fn () void,
    interval_milliseconds: u32,
};

var registered_time_interval_events: memory.FixedBuffer(TimeIntervalEventBinding, 20) = .{};

pub fn timeIntervalEventRegister(entry: TimeIntervalEventEntry) u16 {
    return @intCast(u16, registered_time_interval_events.append(.{
        .callback = entry.callback,
        .start_timestamp_ms = 0,
        .last_called_timestamp_ms = 0,
        .interval_milliseconds = entry.interval_milliseconds,
    }));
}

pub fn timeIntervalEventBegin(entry_id: u16) void {
    var entry = &registered_time_interval_events.items[entry_id];
    const current_timestamp_ms = std.time.milliTimestamp();
    std.debug.assert(current_timestamp_ms >= 0);
    entry.start_timestamp_ms = current_timestamp_ms;
    entry.last_called_timestamp_ms = entry.start_timestamp_ms;

    std.log.info("timeIntervalEvent started", .{});
}

pub fn handleTimeEvents(timestamp_ms: i64) void {
    const active_handlers_count = registered_time_interval_events.count;
    std.debug.assert(active_handlers_count == 0 or active_handlers_count == 1);

    for (registered_time_interval_events.toSliceMutable()) |*event_entry| {
        if (event_entry.start_timestamp_ms == 0) {
            continue;
        }

        if (timestamp_ms < event_entry.last_called_timestamp_ms) {
            // This is possible as last_called_timestamp can be initialized
            // from another thread between this point and when
            // timestamp_ms is created in the app loop
            continue;
        }

        var since_last_call = timestamp_ms - event_entry.last_called_timestamp_ms;
        var i: u32 = 0;
        while (since_last_call >= event_entry.interval_milliseconds) : (i += 1) {
            // Recalculate last_called_timestamp_ms to be a multiple of interval_milliseconds
            // to avoid time drift
            event_entry.invocation_count += 1;
            event_entry.last_called_timestamp_ms = event_entry.start_timestamp_ms + (event_entry.interval_milliseconds * event_entry.invocation_count);
            since_last_call = timestamp_ms - event_entry.last_called_timestamp_ms;

            event_entry.callback.*();
        }
    }
}

pub const SubsystemEventIndex = packed struct {
    subsystem: SubsystemIndex,
    index: EventIndex,
};

pub const SubsystemActionRange = packed struct {
    subsystem: SubsystemIndex,
    base_index: ActionIndex,
    index_count: u16,
};

pub const SubsystemActionIndex = packed struct {
    pub const null_subsystem: SubsystemIndex = std.math.maxInt(SubsystemIndex);
    pub const null_value = SubsystemActionIndex{
        .subsystem = null_subsystem,
        .index = std.math.maxInt(ActionIndex),
    };

    subsystem: SubsystemIndex,
    index: ActionIndex,

    pub inline fn isNull(self: @This()) bool {
        return (self.subsystem == null_subsystem);
    }
};

test "SubsystemActionIndex size" {
    try std.testing.expect(@sizeOf(SubsystemActionIndex) == 2);
}

const registered_action_handlers_max: u32 = std.math.maxInt(SubsystemIndex) - 1;
var registered_action_handlers: [registered_action_handlers_max]*const ActionHandlerFunction = undefined;
var registered_action_handlers_count: u8 = 0;

pub var mouse_event_writer: MouseEventWriter = undefined;

pub const MouseButtonState = struct {
    is_left_pressed: bool,
    is_right_pressed: bool,
};

pub const InputEventType = enum(u4) {
    none,
    mouse_button_left_press,
    mouse_button_left_release,
    mouse_button_right_press,
    mouse_button_right_release,
    mouse_hover_enter,
    mouse_hover_exit,
    mouse_hover_reflexive_enter,
    mouse_hover_reflexive_exit,
};

const MouseEventEntryType = enum(u8) {
    none,
    extent,
    pattern_vertical,
    pattern_horizontal,
    pattern_grid,
};

const EventEntry = packed struct {
    const Flags = packed struct {
        disabled: bool = false,
        reflexive: bool = false,
        reserved_bit_2: bool = undefined,
        reserved_bit_3: bool = undefined,
    };

    kind: InputEventType,
    flags: Flags,
    action_count: u8,
    // action_list: SubsystemActionIndex,
};

test "EventEntry size" {
    try std.testing.expect(@sizeOf(EventEntry) == 4);
    try std.testing.expect(@alignOf(EventEntry) == 1);
}

const MouseEventEntryBase = packed struct {
    extent: geometry.Extent2D(f32), // u16 * 4
    kind: MouseEventEntryType,
    action_count: u8 = 0, // These can be used together to calculate size
    event_count: u8 = 0,
    padding: u8 = 0,
    // event_entry_list: EventEntry,

    pub fn log(self: *@This()) void {
        const print = std.debug.print;

        print("\nKind: {s}\n", .{self.kind});
        print("Events: {d}\n", .{self.event_count});
        print("Actions: {d}\n", .{self.action_count});
        var event_index: u32 = 0;
        var event_offset: u32 = 0;
        var event_base = @intToPtr([*]EventEntry, @ptrToInt(self) + @sizeOf(MouseEventEntryBase));
        var event = &event_base[0];

        while (event_index < self.event_count) : (event_index += 1) {
            print("  Event #{d} {s} with {d} actions\n", .{ event_index, event.kind, event.action_count });

            var action_index: u32 = 0;
            var actions_base = @intToPtr([*]SubsystemActionIndex, @ptrToInt(event) + @sizeOf(EventEntry));
            while (action_index < event.action_count) : (action_index += 1) {
                event_offset += 1 + event.action_count;
                const action = actions_base[action_index];
                print("    Action: {d} {d}\n", .{ action.subsystem, action.index });
                std.debug.assert(event.action_count == 1);
            }
            event = &event_base[event_offset];
        }
        print("\n", .{});
    }
};

const MouseEventEntryExtent = packed struct {
    base: MouseEventEntryBase,
};

const PatternVerticalEntry = packed struct {
    base: MouseEventEntryBase,
    gap: f32,
    count: u8,
    reserved: u24,
    // events: [event_count]EventEntry

    pub fn size(self: @This()) u16 {
        std.debug.assert(@sizeOf(SubsystemActionIndex) == @sizeOf(EventEntry));
        const EventEntrySize = @sizeOf(EventEntry);
        return @sizeOf(@This()) + (EventEntrySize * (self.action_count + self.event_count));
    }
};

const PatternGridEntry = packed struct {
    base: MouseEventEntryBase,
    horizonal_gap: f32,
    vertical_gap: f32,
    row_size: u8,
    count: u8,
    // events: [event_count]EventEntry

    pub fn size(self: @This()) u16 {
        std.debug.assert(@sizeOf(SubsystemActionIndex) == @sizeOf(EventEntry));
        const EventEntrySize = @sizeOf(EventEntry);
        return @sizeOf(@This()) + (EventEntrySize * (self.action_count + self.event_count));
    }
};

pub const MouseEventWriter = struct {
    backing_arena: memory.LinearArena,
    count: u16 = 0,

    pub fn log(self: *@This()) void {
        var index: u32 = 0;
        const base = @ptrCast([*]MouseEventEntryBase, self.backing_arena.memory.ptr);
        while (index < self.count) : (index += 1) {
            base[index].log();
        }
    }

    pub fn print(self: @This()) void {
        const base = @ptrCast(*MouseEventEntryBase, self.backing_arena.memory.ptr);
        std.debug.print("Type: {s}\n", .{base.kind});
        std.debug.print("Extent: {d} {d} -> {d}x{d}\n", .{ base.extent.x, base.extent.y, base.extent.width, base.extent.height });
    }

    pub fn reset(self: *@This()) void {
        self.*.backing_arena.reset();
        self.*.count = 0;
    }

    pub fn init(self: *@This(), arena: *memory.LinearArena, size: u16) void {
        self.*.backing_arena = memory.LinearArena{
            .memory = arena.allocateAligned(u8, 2, size),
            .used = 0,
        };
        self.*.count = 0;
    }

    pub fn create(arena: memory.LinearArena, size: u16) @This() {
        return .{
            .backing_arena = memory.LinearArena.create(arena.allocateAligned(u8, 2, size)),
            .count = 0,
        };
    }

    pub inline fn addPatternVertical(self: *@This(), pattern: Pattern) ResourceEventWriter {
        @compileLog("TODO: Implement patterns");
        self.backing_arena.create(Pattern).* = pattern;
        self.count += 1;
        return .{
            .arena = &self.backing_arena,
            .base = undefined,
        };
    }

    pub inline fn addExtent(self: *@This(), extent: geometry.Extent2D(ScreenNormalizedBaseType)) ResourceEventWriter {
        var base = self.backing_arena.create(MouseEventEntryBase);
        base.* = .{
            .kind = .extent,
            .extent = extent,
        };
        self.count += 1;

        return .{
            .arena = &self.backing_arena,
            .base = base,
        };
    }
};

const PatternVertical = struct {
    extent: geometry.Extent2D(ScreenNormalizedBaseType),
    vertical_gap: f32,
    count: u16,
};

const Pattern = packed struct {
    extent: geometry.Extent2D(ScreenNormalizedBaseType),
    horizonal_gap: f32,
    vertical_gap: f32,
    row_size: u16,
    count: u16,

    pub inline fn extentFor(self: @This(), index: u32) geometry.Extent2D(ScreenNormalizedBaseType) {
        // For now just implement vertical
        if (self.row_size == 1) {
            return .{
                .x = self.extent.x,
                .y = self.extent.y + ((self.vertical_gap + self.extent.height) * @intToFloat(f64, index)),
                .width = self.width,
                .height = self.height,
            };
        } else unreachable;
    }
};

pub inline fn registerActionHandler(action_handler_function: *const ActionHandlerFunction) SubsystemIndex {
    std.debug.assert(registered_action_handlers_count < (std.math.maxInt(SubsystemIndex) + 1));
    registered_action_handlers[registered_action_handlers_count] = action_handler_function;
    registered_action_handlers_count += 1;
    return @intCast(SubsystemIndex, registered_action_handlers_count - 1);
}

/// Lets you write a list of actions to be triggered for an event type E.g mouse_button_left_press
/// EventWriters are bound to the resource they were created with
/// E.g An extent, or pattern
///
/// The workflow is as follows:
/// 1. Write a mouse region either as an extent or pattern
/// 2. For each event type you want to test for:
///     2a. Write with list of actions to trigger
pub const ResourceEventWriter = struct {
    arena: *memory.LinearArena,
    base: *MouseEventEntryBase,

    pub fn log(self: @This()) void {
        self.base.log();
    }

    inline fn prepareForEvents(self: *@This(), action_count: usize) void {
        std.debug.assert(self.base.kind == .extent);
        self.base.*.action_count += @intCast(u6, action_count);
        self.base.*.event_count += 1;
    }

    pub inline fn onClickLeft(self: *@This(), action_list: []const SubsystemActionIndex) void {
        var base = self.base;
        var event = self.arena.create(EventEntry);
        event.* = .{
            .kind = .mouse_button_left_press,
            .flags = .{},
            .action_count = @intCast(u8, action_list.len),
        };

        base.*.action_count += @intCast(u6, action_list.len);
        base.*.event_count += 1;

        var allocated_actions = self.arena.allocate(SubsystemActionIndex, @intCast(u16, action_list.len));

        std.mem.copy(SubsystemActionIndex, allocated_actions, action_list);
    }

    pub inline fn onHover(self: *@This(), action_list: []const SubsystemActionIndex, hover_event_type: InputEventType) void {
        std.debug.assert(self.base.kind == .extent);
        var base = self.base;

        var event = self.arena.create(EventEntry);

        const disabled = if (hover_event_type == .mouse_hover_exit or hover_event_type == .mouse_hover_reflexive_exit) true else false;
        event.* = .{
            .kind = hover_event_type,
            .flags = .{ .disabled = disabled },
            .action_count = @intCast(u8, action_list.len),
        };

        base.*.action_count += @intCast(u6, action_list.len);
        base.*.event_count += 1;

        var allocated_actions = self.arena.allocate(SubsystemActionIndex, @intCast(u16, action_list.len));
        std.mem.copy(SubsystemActionIndex, allocated_actions, action_list[0..]);
    }

    pub inline fn onHoverReflexive(
        self: *@This(),
        action_list: []const SubsystemActionIndex,
        reset_action_list: []const SubsystemActionIndex,
    ) void {
        std.debug.assert(action_list.len == reset_action_list.len);
        std.debug.assert(self.base.kind == .extent);

        for (action_list) |action| {
            std.debug.assert(action.subsystem < 3);
        }

        for (reset_action_list) |action| {
            std.debug.assert(action.subsystem < 3);
        }

        var base = self.base;

        var event = self.arena.create(EventEntry);
        event.* = .{
            .kind = .mouse_hover_reflexive_enter,
            .flags = .{},
            .action_count = @intCast(u8, action_list.len * 2),
        };

        base.*.action_count += @intCast(u6, action_list.len * 2);
        base.*.event_count += 1;

        var allocated_actions = self.arena.allocate(SubsystemActionIndex, @intCast(u16, action_list.len * 2));

        std.mem.copy(SubsystemActionIndex, allocated_actions[0..action_list.len], action_list[0..]);
        std.mem.copy(SubsystemActionIndex, allocated_actions[action_list.len..], reset_action_list[0..]);
    }

    pub inline fn onHoverEnter(self: *@This(), action_list: []const SubsystemActionIndex) void {
        self.onHover(action_list, .mouse_hover_enter);
    }

    pub inline fn onHoverExit(self: *@This(), action_list: []const SubsystemActionIndex) void {
        self.onHover(action_list, .mouse_hover_exit);
    }
};

// IDEA: After looping return the distance of the nearest point that would trigger an action
//       Then that can be used to reduce looping through this every mouse move
pub fn handleMouseEvents(
    position: geometry.Coordinates2D(ScreenNormalizedBaseType),
    is_pressed_left: bool,
    is_pressed_right: bool,
) void {
    // std.log.info("Handling mouse events: {d}", .{mouse_event_writer.count});

    _ = is_pressed_right;
    if (mouse_event_writer.count == 0) return;

    // TODO: Bounds check
    var triggered_actions: [20]SubsystemActionIndex = undefined;
    var triggered_actions_count: u16 = 0;

    var i: u16 = 0;
    var offset: u32 = 0;

    // Loop through all the attachments
    while (i < mouse_event_writer.count) : (i += 1) {
        var current_attachment = @ptrCast(*MouseEventEntryBase, &mouse_event_writer.backing_arena.memory[offset]);
        offset += @sizeOf(MouseEventEntryBase);

        std.debug.assert(current_attachment.kind == .extent);

        const extent = current_attachment.extent;
        const is_within_extent = (position.x >= extent.x and position.x <= (extent.x + extent.width) and
            position.y <= extent.y and position.y >= (extent.y - extent.height));

        var event_i: u32 = 0;
        var event_offset: u32 = 0;

        // current_attachment.log();

        const events_base = @intToPtr([*]EventEntry, @ptrToInt(current_attachment) + @sizeOf(MouseEventEntryBase));

        // Loop through all the events tied to an attachment
        while (event_i < current_attachment.event_count) : (event_i += 1) {
            var current_event = &events_base[event_offset];
            const action_count = current_event.action_count;
            std.debug.assert(@sizeOf(SubsystemActionIndex) == @sizeOf(EventEntry));
            offset += (action_count + 1) * @sizeOf(EventEntry);
            std.debug.assert(action_count <= 2);
            event_offset += action_count + 1;
            var dest_slice = triggered_actions[triggered_actions_count .. triggered_actions_count + action_count];

            if (current_event.flags.disabled) {
                continue;
            }

            switch (current_event.kind) {
                .mouse_button_left_press => {
                    if (is_within_extent and is_pressed_left) {
                        std.log.info("Left clicked invoked", .{});
                        var action_list = @intToPtr([*]SubsystemActionIndex, @ptrToInt(current_event) + @sizeOf(EventEntry))[0..action_count];
                        std.mem.copy(SubsystemActionIndex, dest_slice, action_list);
                        triggered_actions_count += action_count;
                    }
                },
                .mouse_hover_enter => {
                    if (is_within_extent) {
                        var action_list = @intToPtr([*]SubsystemActionIndex, @ptrToInt(current_event) + @sizeOf(EventEntry))[0..action_count];
                        std.log.info("Enter event triggered", .{});
                        std.mem.copy(SubsystemActionIndex, dest_slice, action_list);
                        triggered_actions_count += action_count;
                    }
                },
                .mouse_hover_exit => {
                    if (!is_within_extent) {
                        var action_list = @intToPtr([*]SubsystemActionIndex, @ptrToInt(current_event) + @sizeOf(EventEntry))[0..action_count];
                        std.log.info("Exit event triggered", .{});
                        std.mem.copy(SubsystemActionIndex, dest_slice, action_list);
                        triggered_actions_count += action_count;
                    }
                },
                .mouse_hover_reflexive_enter => {
                    if (is_within_extent) {
                        std.debug.assert(action_count == 2);
                        var action_list = @intToPtr([*]SubsystemActionIndex, @ptrToInt(current_event) + @sizeOf(EventEntry))[0 .. action_count / 2];
                        std.debug.assert(action_list.len == 1);
                        std.mem.copy(SubsystemActionIndex, dest_slice, action_list);
                        triggered_actions_count += action_count / 2;
                        current_event.*.kind = .mouse_hover_reflexive_exit;
                    }
                },
                .mouse_hover_reflexive_exit => {
                    if (!is_within_extent) {
                        std.debug.assert(action_count == 2);
                        var action_list = @intToPtr([*]SubsystemActionIndex, @ptrToInt(current_event) + @sizeOf(EventEntry))[action_count / 2 .. action_count];
                        std.debug.assert(action_list.len == 1);
                        std.mem.copy(SubsystemActionIndex, dest_slice, action_list);
                        triggered_actions_count += action_count / 2;
                        current_event.*.kind = .mouse_hover_reflexive_enter;
                    }
                },
                else => unreachable,
            }
        }
    }

    // TODO: Order and send in batches to subsystems
    for (triggered_actions[0..triggered_actions_count]) |action| {
        if (action.subsystem > registered_action_handlers_count) {
            std.log.err("Invalid subsystem: {d}", .{action.subsystem});
            std.debug.assert(registered_action_handlers_count > action.subsystem);
        }
        registered_action_handlers[action.subsystem].*(action.index);
    }
}
