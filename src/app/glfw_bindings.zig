// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

//! Minimal GLFW bindings for music_player

const std = @import("std");
const log = std.log;
// TODO:
const geometry = @import("geometry");
const vk = @import("vulkan");

pub const c = @cImport({
    @cDefine("GLFW_INCLUDE_VULKAN", "1");
    @cInclude("GLFW/glfw3.h");
});

const constants = @import("constants.zig");
const ScreenPixelBaseType = constants.ScreenPixelBaseType;

pub const VKProc = fn () callconv(.C) void;

pub const Window = opaque {};

pub const Action = enum(c_int) {
    release = c.GLFW_RELEASE,
    press = c.GLFW_PRESS,
    repeat = c.GLFW_REPEAT,
};

pub const Mods = packed struct {
    shift_bit: bool align(@alignOf(c_int)) = false,
    control_bit: bool = false,
    alt_bit: bool = false,
    super_bit: bool = false,
    caps_lock_bit: bool = false,
    num_lock_bit: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const MouseButton = enum(c_int) {
    left = c.GLFW_MOUSE_BUTTON_1,
    right = c.GLFW_MOUSE_BUTTON_2,
    middle = c.GLFW_MOUSE_BUTTON_3,
    four = c.GLFW_MOUSE_BUTTON_4,
    five = c.GLFW_MOUSE_BUTTON_5,
    six = c.GLFW_MOUSE_BUTTON_6,
    seven = c.GLFW_MOUSE_BUTTON_7,
    eight = c.GLFW_MOUSE_BUTTON_8,
};

pub const Hint = enum(c_int) { client_api = c.GLFW_CLIENT_API };
pub const HintClientApi = enum(c_int) { open_gl = c.GLFW_OPENGL_ES_API, open_gl_es = c.GLFW_OPENGL_API, none = c.GLFW_NO_API };

pub fn HintValueType(comptime hint: Hint) type {
    return switch (hint) {
        .client_api => HintClientApi,
    };
}

var is_mouse_button_callback_set: bool = false;
var is_mouse_cursor_callback_set: bool = false;

var userMouseButtonCallback: fn (window: *Window, button: MouseButton, action: Action, mods: Mods) void = undefined;
var userMouseCursorCallback: fn (window: *Window, xpos: f64, ypos: f64) void = undefined;

fn mouseCursorCallback(window: ?*c.GLFWwindow, xpos: f64, ypos: f64) callconv(.C) void {
    if (is_mouse_cursor_callback_set) {
        userMouseCursorCallback(@ptrCast(*Window, window.?), xpos, ypos);
    } else {
        log.err("mouseCursorCallback called but not set", .{});
    }
}

fn mouseButtonCallback(window: ?*c.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.C) void {
    if (is_mouse_button_callback_set) {
        userMouseButtonCallback(@ptrCast(*Window, window.?), @intToEnum(MouseButton, button), @intToEnum(Action, action), @bitCast(Mods, mods));
    } else {
        log.err("mouseButtonCallback called but not set", .{});
    }
}

pub inline fn setCursorPosCallback(window: *Window, callback: fn (window: *Window, xpos: f64, ypos: f64) void) void {
    userMouseCursorCallback = callback;
    if (!is_mouse_cursor_callback_set) {
        _ = c.glfwSetCursorPosCallback(@ptrCast(*c.GLFWwindow, window), mouseCursorCallback);
        is_mouse_cursor_callback_set = true;
    }
}

pub inline fn setMouseButtonCallback(window: *Window, callback: fn (window: *Window, button: MouseButton, action: Action, mods: Mods) void) void {
    userMouseButtonCallback = callback;
    if (!is_mouse_button_callback_set) {
        _ = c.glfwSetMouseButtonCallback(@ptrCast(*c.GLFWwindow, window), mouseButtonCallback);
        is_mouse_button_callback_set = true;
    }
}

pub inline fn getCursorPos(window: *Window) !geometry.Coordinates2D(f64) {
    var xpos: f64 = undefined;
    var ypos: f64 = undefined;
    c.glfwGetCursorPos(@ptrCast(*c.GLFWwindow, window), &xpos, &ypos);
    return geometry.Coordinates2D(f64){ .x = xpos, .y = ypos };
}

pub fn getInstanceProcAddress(vk_instance: *anyopaque, proc_name: [*:0]const u8) ?VKProc {
    return c.glfwGetInstanceProcAddress(@ptrCast(c.VkInstance, vk_instance), proc_name);
}

pub fn vulkanSupported() bool {
    return if (c.glfwVulkanSupported() == c.GLFW_TRUE) true else false;
}

pub inline fn pollEvents() void {
    c.glfwPollEvents();
}

pub inline fn setHint(comptime hint: Hint, value: HintValueType(hint)) void {
    c.glfwWindowHint(@enumToInt(hint), @enumToInt(value));
}

pub inline fn initialize() !void {
    if (c.glfwInit() == c.GLFW_TRUE) return;

    return error.FailedToInitializeGLFW;
}

pub inline fn shouldClose(window: *Window) bool {
    return (c.glfwWindowShouldClose(@ptrCast(*c.GLFWwindow, window)) == c.GLFW_TRUE);
}

pub inline fn createWindowSurface(vk_instance: anytype, window: *Window, vk_allocation_callbacks: anytype, vk_surface_khr: anytype) !i32 {
    const instance: c.VkInstance = switch (@typeInfo(@TypeOf(vk_instance))) {
        .Enum => @intToPtr(c.VkInstance, @enumToInt(vk_instance)),
        else => @ptrCast(c.VkInstance, vk_instance),
    };

    const v = c.glfwCreateWindowSurface(
        instance,
        @ptrCast(*c.GLFWwindow, window),
        if (vk_allocation_callbacks == null) null else @ptrCast(*const c.VkAllocationCallbacks, @alignCast(@alignOf(c.VkAllocationCallbacks), vk_allocation_callbacks)),
        @ptrCast(*c.VkSurfaceKHR, @alignCast(@alignOf(c.VkSurfaceKHR), vk_surface_khr)),
    );
    if (v == c.VK_SUCCESS) return v;

    return error.FailedToCreateWindowSurface;
}

pub inline fn getRequiredInstanceExtensions() error{APIUnavailable}![][*:0]const u8 {
    var count: u32 = 0;
    if (c.glfwGetRequiredInstanceExtensions(&count)) |extensions| return @ptrCast([*][*:0]const u8, extensions)[0..count];
    unreachable;
}

pub inline fn getFramebufferSize(window: *Window) geometry.Dimensions2D(ScreenPixelBaseType) {
    var width: c_int = 0;
    var height: c_int = 0;
    c.glfwGetFramebufferSize(@ptrCast(*c.GLFWwindow, window), &width, &height);
    return geometry.Dimensions2D(ScreenPixelBaseType){ .width = @intCast(ScreenPixelBaseType, width), .height = @intCast(ScreenPixelBaseType, height) };
}

pub inline fn terminate() void {
    c.glfwTerminate();
}

pub inline fn createWindow(
    dimensions: geometry.Dimensions2D(ScreenPixelBaseType),
    title: [*:0]const u8,
) !*Window {
    const result = c.glfwCreateWindow(@intCast(c_int, dimensions.width), @intCast(c_int, dimensions.height), &title[0], null, null);
    if (result) |window| {
        return @ptrCast(*Window, window);
    }

    return error.FailedToCreateGLFWWindow;
}
