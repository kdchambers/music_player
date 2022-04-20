pub fn handleScreenDimensionsChanged(
    screen_dimensions: geometry.Dimensions2D(.pixel),
    previous_screen_dimensions: geometry.Dimensions2D(.pixel)
) void {

    // If screen is reduced in size, expect scale factor to be negative to scale down rendered elements
    // const scale_factor = ScaleFactor2D {
    //     .horizontal = @intToFloat(f32, screen_dimensions.width) / @intToFloat(f32, previous_screen_dimensions.width),
    //     .vertical = @intToFloat(f32, screen_dimensions.height) / @intToFloat(f32, previous_screen_dimensions.height),
    // };

    // if(event_mouse_hovered_list.count > 0) {
    //     for(event_mouse_hovered_list.items[0..event_mouse_hovered_list.count - 1]) |*mouse_hovered_event| {
    //         mouse_hovered_event.screen_extent.x *= scale_factor.horizontal;
    //         mouse_hovered_event.screen_extent.y *= scale_factor.vertical;
    //         mouse_hovered_event.screen_extent.width *= scale_factor.horizontal;
    //         mouse_hovered_event.screen_extent.height *= scale_factor.vertical;
    //     }
    //     log.info("Mouse hovered event definitions updated for screen resize", .{});
    // }
}