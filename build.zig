const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public umbrella module: @import("huey")
    _ = b.addModule("huey", .{
        .root_source_file = b.path("src/huey.zig"),
    });

    // Main desktop shell prototype executable: huey-stratifi
    const stratifi_mod = b.createModule(.{
        .root_source_file = b.path("src/stratifi_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stratifi_exe = b.addExecutable(.{
        .name = "huey-stratifi",
        .root_module = stratifi_mod,
    });
    const stratifi_install = b.addInstallArtifact(stratifi_exe, .{});
    b.getInstallStep().dependOn(&stratifi_install.step);

    const stratifi_step = b.step("stratifi-demo", "Build the huey-stratifi desktop shell prototype");
    stratifi_step.dependOn(&stratifi_install.step);

    const run_cmd = b.addRunArtifact(stratifi_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run huey-stratifi");
    run_step.dependOn(&run_cmd.step);

    // Unified test step covering all unit test suites in src/
    const test_step = b.step("test", "Run all Huey unit test suites");

    const pure_test_suites = [_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "core_test", .path = "src/core_test.zig" },
        .{ .name = "events_test", .path = "src/events_test.zig" },
        .{ .name = "headless_test", .path = "src/headless_test.zig" },
        .{ .name = "focus_test", .path = "src/focus_test.zig" },
        .{ .name = "layout_test", .path = "src/layout_test.zig" },
        .{ .name = "clip_ime_test", .path = "src/clip_ime_test.zig" },
        .{ .name = "virtual_scroll_test", .path = "src/virtual_scroll_test.zig" },
        .{ .name = "reconcile_test", .path = "src/reconcile_test.zig" },
        .{ .name = "async_queue_test", .path = "src/async_queue_test.zig" },
        .{ .name = "tokens_test", .path = "src/tokens_test.zig" },
        .{ .name = "theme_test", .path = "src/theme_test.zig" },
        .{ .name = "declarative_test", .path = "src/declarative_test.zig" },
        .{ .name = "text_edit_test", .path = "src/text_edit_test.zig" },
        .{ .name = "a11y_test", .path = "src/a11y_test.zig" },
        .{ .name = "image_atlas_test", .path = "src/image_atlas_test.zig" },
        .{ .name = "ipc_bridge_test", .path = "src/ipc_bridge_test.zig" },
        .{ .name = "touch_ergonomics_test", .path = "src/touch_ergonomics_test.zig" },
        .{ .name = "color_pipeline_test", .path = "src/color_pipeline_test.zig" },
        .{ .name = "wearos_test", .path = "src/wearos_test.zig" },
        .{ .name = "wear_circular_test", .path = "src/wear_circular_test.zig" },
        .{ .name = "hold_confirm_test", .path = "src/hold_confirm_test.zig" },
        .{ .name = "text_input_test", .path = "src/text_input_test.zig" },
        .{ .name = "controls_test", .path = "src/controls_test.zig" },
        .{ .name = "primitives_test", .path = "src/primitives_test.zig" },
        .{ .name = "android_platform_test", .path = "src/android_platform_test.zig" },
        .{ .name = "overlay_test", .path = "src/overlay_test.zig" },
        .{ .name = "multi_window_test", .path = "src/multi_window_test.zig" },
        .{ .name = "wayland_test", .path = "src/wayland_test.zig" },
        .{ .name = "animation_test", .path = "src/animation_test.zig" },
        .{ .name = "workbench_test", .path = "src/workbench_test.zig" },
        .{ .name = "stratifi_demo_test", .path = "src/stratifi_demo_test.zig" },
    };

    for (pure_test_suites) |suite| {
        const mod = b.createModule(.{
            .root_source_file = b.path(suite.path),
            .target = target,
            .optimize = optimize,
        });
        const t = b.addTest(.{
            .name = suite.name,
            .root_module = mod,
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    // c_abi_test.zig (-I include + libc)
    const c_abi_mod = b.createModule(.{
        .root_source_file = b.path("src/c_abi_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_abi_mod.addIncludePath(b.path("include"));
    const c_abi_test = b.addTest(.{
        .name = "c_abi_test",
        .root_module = c_abi_mod,
    });
    test_step.dependOn(&b.addRunArtifact(c_abi_test).step);

    // stb_truetype-backed test suites (-I vendor + src/stb_truetype_impl.c + libc + libm)
    const stb_test_suites = [_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "glyph_atlas_test", .path = "src/glyph_atlas_test.zig" },
        .{ .name = "showcase_scene_test", .path = "src/showcase_scene_test.zig" },
        .{ .name = "wear_showcase_scene_test", .path = "src/wear_showcase_scene_test.zig" },
    };

    for (stb_test_suites) |suite| {
        const stb_mod = b.createModule(.{
            .root_source_file = b.path(suite.path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        stb_mod.addIncludePath(b.path("vendor"));
        stb_mod.addCSourceFile(.{
            .file = b.path("src/stb_truetype_impl.c"),
        });
        stb_mod.linkSystemLibrary("m", .{});
        const stb_test = b.addTest(.{
            .name = suite.name,
            .root_module = stb_mod,
        });
        test_step.dependOn(&b.addRunArtifact(stb_test).step);
    }
}
