const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_vulkan = b.option(bool, "vulkan", "Compile the optional Vulkan/SDL3 renderer") orelse false;
    const enable_openal = b.option(bool, "openal", "Link the optional OpenAL audio library") orelse false;
    const openal_lib_dir = b.option([]const u8, "openal-lib-dir", "Directory containing OpenAL32.lib");
    const vulkan_lib_dir = b.option([]const u8, "vulkan-lib-dir", "Directory containing vulkan-1.lib");

    const options = b.addOptions();
    options.addOption(bool, "enable_vulkan", enable_vulkan);

    // PNG/image decoding: zig-gamedev/zstbi (Zig wrapper over stb_image).
    // Its "root" module compiles the stb C sources itself (the package only
    // exposes a "zstbi-tests" artifact, no linkable library), and C code
    // needs libc, hence link_libc below.
    const zstbi = b.dependency("zstbi", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig_zine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zstbi", .module = zstbi.module("root") },
            },
        }),
    });
    exe.root_module.addOptions("build_options", options);

    // SDL3 + Vulkan are only pulled in for -Dvulkan=true (window + Vulkan
    // device/swapchain, see src/platform.zig). The default build is headless:
    // no window, GPU, or system-library requirements.
    if (enable_vulkan) {
        const sdl = b.dependency("sdl", .{
            .target = target,
            .optimize = optimize,
        });

        const vulkan_headers = b.dependency("vulkan_headers", .{});
        const vulkan = b.dependency("vulkan", .{
            .registry = vulkan_headers.path("registry/vk.xml"),
        });
        exe.root_module.addImport("vulkan", vulkan.module("vulkan-zig"));
        exe.root_module.linkLibrary(sdl.artifact("SDL3"));

        switch (target.result.os.tag) {
            .windows => {
                if (vulkan_lib_dir) |path| {
                    exe.root_module.addLibraryPath(.{ .cwd_relative = path });
                } else if (b.graph.environ_map.get("VULKAN_SDK")) |sdk| {
                    exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "Lib" }) });
                }
                exe.root_module.linkSystemLibrary("vulkan-1", .{});
                if (enable_openal) {
                    if (openal_lib_dir) |path| {
                        exe.root_module.addLibraryPath(.{ .cwd_relative = path });
                    }
                    exe.root_module.linkSystemLibrary("openal32", .{});
                }
            },
            .linux => {
                exe.root_module.linkSystemLibrary("vulkan", .{});
                if (enable_openal) exe.root_module.linkSystemLibrary("openal", .{});
            },
            .macos => {
                exe.root_module.linkFramework("OpenAL", .{});
                exe.root_module.linkSystemLibrary("vulkan", .{});
            },
            else => {},
        }
    }
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the engine demo");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const ecs = b.dependency("entt", .{}).module("zig-ecs");

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const ecs_stress_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ecs_stress_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ecs", .module = ecs }},
        }),
    });
    const test_step = b.step("test", "Run all engine tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(ecs_stress_tests).step);
}
