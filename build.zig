// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");

const Builder = std.build.Builder;
const Build = std.build;
const Pkg = Build.Pkg;

const vkgen = @import("deps/vulkan-zig/generator/index.zig");

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const lib_src_path = "src/lib/";
    const app_src_path = "src/app/";

    const exe = b.addExecutable("music_player", app_src_path ++ "core.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    exe.addIncludeDir("/usr/include/");
    exe.addIncludeDir("/usr/local/include");

    // TODO: Library layer should not depend on application layer
    //       Add a comptime and remove dependency
    const constants_pkg = std.build.Pkg{
        .name = "constants",
        .path = .{ .path = app_src_path ++ "constants.zig" },
    };

    const geometry_pkg = std.build.Pkg{
        .name = "geometry",
        .path = .{ .path = lib_src_path ++ "geometry.zig" },
    };

    const message_queue_pkg = std.build.Pkg{
        .name = "message_queue",
        .path = .{ .path = lib_src_path ++ "message_queue.zig" },
    };

    const memory_pkg = std.build.Pkg{
        .name = "memory",
        .path = .{ .path = lib_src_path ++ "memory.zig" },
    };

    const audio_pkg = std.build.Pkg{
        .name = "audio",
        .path = .{
            .path = lib_src_path ++ "audio.zig",
        },
        .dependencies = &[_]Pkg{ message_queue_pkg, memory_pkg },
    };

    const font_pkg = std.build.Pkg{
        .name = "font",
        .path = .{
            .path = lib_src_path ++ "font.zig",
        },
        .dependencies = &[_]Pkg{geometry_pkg},
    };

    const graphics_pkg = std.build.Pkg{
        .name = "graphics",
        .path = .{
            .path = lib_src_path ++ "graphics.zig",
        },
        .dependencies = &[_]Pkg{ geometry_pkg, constants_pkg },
    };

    const utility_pkg = std.build.Pkg{
        .name = "utility",
        .path = .{ .path = app_src_path ++ "utility.zig" },
    };

    const text_pkg = std.build.Pkg{
        .name = "text",
        .path = .{
            .path = lib_src_path ++ "text.zig",
        },
        .dependencies = &[_]Pkg{
            font_pkg,
            geometry_pkg,
            graphics_pkg,
            utility_pkg,
            constants_pkg,
        },
    };

    const event_system_pkg = std.build.Pkg{
        .name = "event_system",
        .path = .{
            .path = lib_src_path ++ "event_system.zig",
        },
        .dependencies = &[_]Pkg{ constants_pkg, geometry_pkg, text_pkg, graphics_pkg, memory_pkg },
    };

    const gen = vkgen.VkGenerateStep.init(b, "deps/vk.xml", "vk.zig");
    const vulkan_pkg = gen.package;

    exe.addPackage(std.build.Pkg{
        .name = "zigimg",
        .path = .{ .path = "deps/zigimg/zigimg.zig" },
    });

    const gui_pkg = std.build.Pkg{
        .name = "gui",
        .path = .{
            .path = lib_src_path ++ "gui.zig",
        },
        .dependencies = &[_]Pkg{
            geometry_pkg,
            graphics_pkg,
            constants_pkg,
            text_pkg,
            utility_pkg,
        },
    };

    const glfw_pkg = std.build.Pkg{
        .name = "glfw",
        .path = .{
            .path = app_src_path ++ "glfw_bindings.zig",
        },
        .dependencies = &[_]Pkg{ geometry_pkg, vulkan_pkg },
    };

    const vulkan_config_pkg = std.build.Pkg{
        .name = "vulkan_config",
        .path = .{
            .path = app_src_path ++ "vulkan_config.zig",
        },
        .dependencies = &[_]Pkg{vulkan_pkg},
    };

    const user_config_pkg = std.build.Pkg{
        .name = "user_config",
        .path = .{
            .path = app_src_path ++ "user_config.zig",
        },
        .dependencies = &[_]Pkg{graphics_pkg},
    };

    const vulkan_wrapper_pkg = std.build.Pkg{
        .name = "vulkan_wrapper",
        .path = .{
            .path = lib_src_path ++ "vulkan_wrapper.zig",
        },
        .dependencies = &[_]Pkg{
            glfw_pkg,
            vulkan_config_pkg,
            vulkan_pkg,
        },
    };

    exe.addPackage(vulkan_pkg);
    exe.addPackage(text_pkg);
    exe.addPackage(constants_pkg);
    exe.addPackage(font_pkg);
    exe.addPackage(audio_pkg);
    exe.addPackage(vulkan_wrapper_pkg);
    exe.addPackage(user_config_pkg);
    exe.addPackage(glfw_pkg);
    exe.addPackage(memory_pkg);
    exe.addPackage(message_queue_pkg);
    exe.addPackage(utility_pkg);
    exe.addPackage(graphics_pkg);
    exe.addPackage(geometry_pkg);
    exe.addPackage(gui_pkg);
    exe.addPackage(event_system_pkg);

    // exe.addLibPath("/usr/local/lib");
    exe.linkSystemLibrary("ao");
    exe.linkSystemLibrary("glfw");
    exe.linkSystemLibrary("c");

    // TODO: Staticially link or port
    exe.linkSystemLibrary("FLAC");
    exe.linkSystemLibrary("mad");
    exe.linkSystemLibrary("id3v2");

    exe.install();

    const run_cmd = exe.run();
    if (b.args) |args| run_cmd.addArgs(args);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run music_player");
    run_step.dependOn(&run_cmd.step);
}
