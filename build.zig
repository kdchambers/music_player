// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2023 Keith Chambers
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

    const exe = b.addExecutable("music_player", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    exe.addIncludePath("deps/glfw/include/");
    exe.addIncludePath("deps/libmad");

    exe.addPackage(.{
        .name = "shaders",
        .source = .{ .path = "shaders/shaders.zig" },
    });

    const gen = vkgen.VkGenerateStep.create(b, "deps/vk.xml", "vk.zig");
    const vulkan_pkg = gen.getPackage("vulkan");

    exe.addPackage(vulkan_pkg);

    exe.linkLibC();

    exe.linkSystemLibrary("ao");
    exe.linkSystemLibrary("glfw");

    // TODO: Staticially link or port
    exe.linkSystemLibrary("mad");

    exe.install();

    const run_cmd = exe.run();
    if (b.args) |args| run_cmd.addArgs(args);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run music_player");
    run_step.dependOn(&run_cmd.step);
}
