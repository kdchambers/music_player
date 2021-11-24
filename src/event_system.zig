const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const graphics = @import("graphics.zig");
const RGBA = graphics.RGBA;
const QuadFace = graphics.QuadFace;
const text = @import("text.zig");
const GenericVertex = text.GenericVertex;
const geometry = @import("geometry.zig");
const ScaleFactor2D = geometry.ScaleFactor2D;

const memory = @import("memory.zig");
const FixedBuffer = memory.FixedBuffer;

pub const InputEventType = enum(u8) { none, mouse_button_left_press, mouse_button_left_release, mouse_button_right_press, mouse_button_right_release, mouse_hover_enter, mouse_hover_exit, mouse_hover_reflexive_enter, mouse_hover_reflexive_exit };

pub const EventFlagsOnMouseBounds = packed struct {
    is_disabled: bool = false,

    is_hovered_enabled: bool = false,
    is_hovered_ongoing: bool = false,
    is_hovered_triggered: bool = false,

    is_clicked_enabled: bool = false,

    // We expect client to store current click states
    // The triggered flag will be set if any change occurs,
    // but will not be able to specify what changed between
    // left and right button
    is_clicked_right: bool = false,
    is_clicked_left: bool = false,
    is_clicked_triggered: bool = false,
};

test "EventFlagsOnMouseHover" {
    expect(@sizeOf(EventFlagsOnMouseHover) == 8);
}

pub const EventFlags = packed union {
    mouse_bounds: EventFlagsOnMouseBounds,
};

pub const Event = packed struct {
    event_type: InputEventType,
    attachment_id: u8,
};

var registered_events: FixedBuffer(Event, 50) = .{};

const EventAttachmentExtent2D = geometry.Extent2D(.ndc_right);

var extent_attachments: FixedBuffer(EventAttachmentExtent2D, 40) = .{};

pub fn clearEvents() void {
    extent_attachments.count = 0;
    registered_events.count = 0;
    current_event_id = 0;
}

// Source Attachment // Based on property, dimensions, position, color, etc
// Meta (id, flags)
// Action
// Dest Attachment

var current_event_id: u16 = 0;

pub fn registerMouseHoverReflexiveEnterAction(
    screen_extent: geometry.Extent2D(.ndc_right),
) [2]u16 {

    // Seeing as the reflexive event changes between enter and exit,
    // we return two action slots so both events can be handled independently
    const attachment_id = @intCast(u16, extent_attachments.append(screen_extent));
    const event_id = @intCast(u16, registered_events.append(.{
        .event_type = .mouse_hover_reflexive_enter,
        .attachment_id = @intCast(u8, attachment_id),
    }));
    _ = @intCast(u16, registered_events.append(.{
        .event_type = .none,
        .attachment_id = @intCast(u8, attachment_id),
    }));

    current_event_id += 2;

    return .{ current_event_id - 2, current_event_id - 1 };
}

pub fn registerMouseHoverEnterAction(
    screen_extent: geometry.Extent2D(.ndc_right),
) u16 {
    // TODO: Check to see if already added
    const attachment_id = @intCast(u16, extent_attachments.append(screen_extent));
    _ = @intCast(u16, registered_events.append(.{
        .event_type = .mouse_hover_enter,
        .attachment_id = @intCast(u8, attachment_id),
    }));

    current_event_id += 1;
    return current_event_id - 1;
}

pub fn registerMouseHoverExitAction(
    screen_extent: geometry.Extent2D(.ndc_right),
) u16 {
    // TODO: Check to see if already added
    const attachment_id = @intCast(u16, extent_attachments.append(screen_extent));
    _ = @intCast(u16, registered_events.append(.{
        .event_type = .mouse_hover_exit,
        .attachment_id = @intCast(u8, attachment_id),
    }));
    current_event_id += 1;
    return current_event_id - 1;
}

pub fn registerMouseLeftPressAction(
    screen_extent: geometry.Extent2D(.ndc_right),
) u16 {
    // TODO: Check to see if already added
    const attachment_id = @intCast(u16, extent_attachments.append(screen_extent));
    _ = @intCast(u16, registered_events.append(.{
        .event_type = .mouse_button_left_press,
        .attachment_id = @intCast(u8, attachment_id),
    }));
    current_event_id += 1;
    return current_event_id - 1;
}
// Division criteria
// Big / Small
// Static / Dynamic
// [small_static, big_static, small_dynamic, big_dynamic]

pub const EventID = u16;

pub const MouseButtonState = struct {
    is_left_pressed: bool,
    is_right_pressed: bool,
};

// TODO: This should just take a pre-allocated buffer
// TODO: Fix double event trigger from left click
pub fn eventsFromMouseUpdate(comptime max_events: u32, position: geometry.Coordinates2D(.ndc_right), button_state: MouseButtonState) FixedBuffer(u16, max_events) {

    // TODO: Check this before calling function to save a wasted jump
    // You can keep track of this value client side probably
    if (registered_events.count == 0) return .{ .items = undefined, .count = 0 };

    var triggered_events: FixedBuffer(u16, max_events) = .{};
    for (registered_events.toSliceMutable()) |*registered_event, event_id| {

        // NOTE: You could probably make this branchless by writing to the next
        // element and incrementing the count by is_within_extent (Zero if false)
        const trigger_extent = extent_attachments.items[registered_event.attachment_id];
        const is_within_extent = position.x >= trigger_extent.x and position.x <= (trigger_extent.x + trigger_extent.width) and
            position.y <= trigger_extent.y and position.y >= (trigger_extent.y - trigger_extent.height);

        switch (registered_event.event_type) {
            .mouse_button_left_press => {
                if (is_within_extent and button_state.is_left_pressed) {
                    _ = triggered_events.append(@intCast(u16, event_id));
                    log.info("Mouse left press triggered: {d}", .{event_id});
                }
            },
            .mouse_hover_enter => {
                if (is_within_extent) {
                    _ = triggered_events.append(@intCast(u16, event_id));
                    // log.info("Mouse hover enter triggered", .{});
                }
            },
            .mouse_hover_exit => {
                if (!is_within_extent) {
                    _ = triggered_events.append(@intCast(u16, event_id));
                    // log.info("Mouse hover exit triggered", .{});
                }
            },
            .mouse_hover_reflexive_enter => {
                if (is_within_extent) {
                    _ = triggered_events.append(@intCast(u16, event_id));
                    registered_event.event_type = .mouse_hover_reflexive_exit;
                    // log.info("Reflexive enter triggered", .{});
                }
            },
            .mouse_hover_reflexive_exit => {
                if (!is_within_extent) {
                    _ = triggered_events.append(@intCast(u16, event_id + 1));
                    registered_event.event_type = .mouse_hover_reflexive_enter;
                    // log.info("Reflexive exit triggered", .{});
                }
            },
            else => {},
        }
    }
    return triggered_events;
}
