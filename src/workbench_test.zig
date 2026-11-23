const std = @import("std");
const workbench = @import("workbench.zig");
const tokens = @import("tokens.zig");
const core = @import("core.zig");

test "Workbench: instant DPI scale presets (1x, 1.25x, 1.5x, 2x) and scene reload" {
    const alloc = std.testing.allocator;
    var wb = try workbench.Workbench.init(alloc, 800, 600);
    defer wb.deinit();

    // Load a declarative JSON widget gallery scene
    const scene_json =
        \\{
        \\  "type": "vstack",
        \\  "id": "gallery_root",
        \\  "padding": 12,
        \\  "gap": 8,
        \\  "fill": "polar_night_0",
        \\  "children": [
        \\    { "type": "toggle", "id": "btn_primary", "width": 160, "height": 48, "fill": "frost_1", "corner_radius": 8 },
        \\    { "type": "card", "id": "card_info", "width": 240, "height": 80, "fill": "polar_night_1", "corner_radius": 10 }
        \\  ]
        \\}
    ;
    try wb.loadSceneJson(scene_json);
    try wb.stepFrame(1_800); // 1.8 ms simulated frame

    try std.testing.expectEqual(@as(f32, 1.0), wb.scale_factor);
    try std.testing.expect(wb.last_quad_count >= 3);

    // Cycle DPI preset: 1.0 -> 1.25 -> 1.5 -> 2.0 -> 1.0
    wb.cycleDpiPreset();
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), wb.scale_factor, 0.001);
    wb.cycleDpiPreset();
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), wb.scale_factor, 0.001);
    wb.cycleDpiPreset();
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), wb.scale_factor, 0.001);
    wb.cycleDpiPreset();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), wb.scale_factor, 0.001);
}

test "Workbench: debug HUD emits layout-bounds & hit-target overlay quads when toggled on" {
    const alloc = std.testing.allocator;
    var wb = try workbench.Workbench.init(alloc, 800, 600);
    defer wb.deinit();

    try wb.loadBuiltinGallery();
    wb.hud_flags = .{};
    try wb.stepFrame(2_000);
    const base_quads = wb.last_quad_count;
    try std.testing.expect(base_quads > 0);

    // Enable layout bounds + hit-target + frame-budget HUD overlays
    wb.hud_flags = .{
        .show_layout_bounds = true,
        .show_hit_targets = true,
        .show_frame_budget = true,
    };
    try wb.stepFrame(2_000);
    try std.testing.expect(wb.last_quad_count > base_quads);
    try std.testing.expect(wb.hud_quad_count > 0);
}

test "Workbench: mmap token file hot-reload updates generation and re-renders" {
    const alloc = std.testing.allocator;

    var path_buf: [256]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/ziggui_wb_test_{d}.tok", .{std.os.linux.getpid()}, 0);
    defer _ = std.os.linux.unlink(tmp_path.ptr);

    var tbl = tokens.TokenTable.nordDefault();
    tbl.version = 1;
    try tokens.writeTokenFile(tmp_path.ptr, &tbl);

    var wb = try workbench.Workbench.init(alloc, 640, 480);
    defer wb.deinit();
    try wb.attachTokenFile(tmp_path);
    try wb.loadBuiltinGallery();
    try wb.stepFrame(1_500);
    try std.testing.expectEqual(@as(u32, 1), wb.token_generation);

    // Hot-update token file on disk
    tbl.version = 2;
    tbl.accent_primary = tokens.OklabColor.fromSrgbHex(0xA3BE8C);
    try tokens.writeTokenFile(tmp_path.ptr, &tbl);

    const reloaded = try wb.pollTokenReload();
    try std.testing.expect(reloaded);
    try std.testing.expectEqual(@as(u32, 2), wb.token_generation);
}

test "Workbench: frame budget tracker computes rolling average and warns above 16.6ms" {
    const alloc = std.testing.allocator;
    var wb = try workbench.Workbench.init(alloc, 640, 480);
    defer wb.deinit();
    try wb.loadBuiltinGallery();

    try wb.stepFrame(2_000);
    try wb.stepFrame(4_000);
    try std.testing.expectEqual(@as(u32, 3_000), wb.avgFrameUs());
    try std.testing.expect(!wb.isOverBudget());

    // Push a 20ms spike
    try wb.stepFrame(20_000);
    try std.testing.expect(wb.last_frame_us == 20_000);
    try std.testing.expect(wb.isOverBudget());
}

test "Workbench: DPI scaling re-emits scaled quads, dirty transitions, and ignores out-of-range presets" {
    const alloc = std.testing.allocator;
    var wb = try workbench.Workbench.init(alloc, 800, 600);
    defer wb.deinit();

    try std.testing.expectEqual(@as(u32, 0), wb.avgFrameUs());
    try std.testing.expect(wb.dirty);

    const scene_json =
        \\{
        \\  "type": "vstack",
        \\  "id": "root",
        \\  "children": [
        \\    { "type": "card", "id": "box", "width": 100, "height": 50, "fill": "frost_1", "corner_radius": 8 }
        \\  ]
        \\}
    ;
    try wb.loadSceneJson(scene_json);
    try std.testing.expect(wb.dirty);

    try wb.stepFrame(1_000);
    try std.testing.expect(!wb.dirty);
    try std.testing.expectEqual(@as(usize, 1), wb.last_quad_count);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), wb.quads.items[0].pos_size[2], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), wb.quads.items[0].params[0], 0.01);

    wb.setDpiPreset(3); // 2.0x
    try std.testing.expect(wb.dirty);
    try wb.stepFrame(1_000);
    try std.testing.expect(!wb.dirty);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), wb.quads.items[0].pos_size[2], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), wb.quads.items[0].params[0], 0.01);

    // Out-of-range preset index is a safe no-op
    wb.setDpiPreset(99);
    try std.testing.expectEqual(@as(usize, 3), wb.dpi_index);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), wb.scale_factor, 0.001);
}

test "Workbench: HUD semantics, clipping, tiny viewports, and toggle off" {
    const alloc = std.testing.allocator;
    var wb = try workbench.Workbench.init(alloc, 800, 600);
    defer wb.deinit();

    // Empty scene with frame budget HUD works safely
    wb.hud_flags = .{ .show_frame_budget = true };
    try wb.stepFrame(16_666);
    try std.testing.expect(!wb.isOverBudget());
    try std.testing.expectEqual(@as(usize, 2), wb.hud_quad_count);
    try std.testing.expectEqual(wb.token_table.accent_success.toSrgb(), wb.quads.items[1].color);

    try wb.stepFrame(16_667);
    try std.testing.expect(wb.isOverBudget());
    try std.testing.expectEqual(wb.token_table.accent_danger.toSrgb(), wb.quads.items[1].color);

    // Toggling HUD back off clears hud_quad_count
    try wb.loadBuiltinGallery();
    wb.hud_flags = .{};
    try wb.stepFrame(1_000);
    const base_quads = wb.last_quad_count;
    try std.testing.expectEqual(@as(usize, 0), wb.hud_quad_count);

    // Hit targets HUD: gallery.btn_compact (32x32 < 44dp) gets danger border; gallery.btn_primary (148x48) gets success border
    wb.hud_flags = .{ .show_hit_targets = true };
    try wb.stepFrame(1_000);
    var saw_danger = false;
    var saw_success = false;
    const danger_col = core.sanitizeColor(wb.token_table.accent_danger.toSrgb());
    const success_col = core.sanitizeColor(wb.token_table.accent_success.toSrgb());
    for (wb.quads.items[base_quads..]) |q| {
        if (std.mem.eql(f32, &q.border_color, &danger_col)) saw_danger = true;
        if (std.mem.eql(f32, &q.border_color, &success_col)) saw_success = true;
    }
    try std.testing.expect(saw_danger);
    try std.testing.expect(saw_success);

    // Clipped offscreen child is culled from layout_bounds & hit_targets HUDs
    const clipped_json =
        \\{
        \\  "type": "vstack",
        \\  "id": "clip_root",
        \\  "clip_children": true,
        \\  "children": [
        \\    { "type": "toggle", "id": "vis_toggle", "height": 50 },
        \\    { "type": "toggle", "id": "offscreen_toggle", "height": 50 }
        \\  ]
        \\}
    ;
    try wb.setViewport(200, 50);
    try wb.loadSceneJson(clipped_json);
    wb.hud_flags = .{ .show_layout_bounds = true, .show_hit_targets = true };
    try wb.stepFrame(1_000);
    // Only clip_root + vis_toggle are visible (2 layout bounds + 1 hit target = 3 HUD quads; offscreen_toggle culled)
    try std.testing.expectEqual(@as(usize, 3), wb.hud_quad_count);

    // Tiny viewport keeps frame budget HUD pos_size and all clip_rects strictly within [0, width] x [0, height]
    try wb.setViewport(20, 20);
    wb.hud_flags = .{ .show_frame_budget = true };
    try wb.stepFrame(5_000);
    try std.testing.expectEqual(@as(usize, 2), wb.hud_quad_count);
    for (wb.quads.items[wb.quads.items.len - 2 ..]) |q| {
        try std.testing.expect(q.pos_size[0] >= 0.0);
        try std.testing.expect(q.pos_size[1] >= 0.0);
        try std.testing.expect(q.pos_size[0] + q.pos_size[2] <= 20.0 + 0.01);
        try std.testing.expect(q.pos_size[1] + q.pos_size[3] <= 20.0 + 0.01);
    }
}

test "Workbench: frame history ring wraparound and maxInt(u32) overflow safety" {
    const alloc = std.testing.allocator;
    var wb = try workbench.Workbench.init(alloc, 320, 240);
    defer wb.deinit();

    for (0..32) |_| {
        try wb.stepFrame(1_000);
    }
    try std.testing.expectEqual(@as(u32, 1_000), wb.avgFrameUs());

    for (0..32) |_| {
        try wb.stepFrame(5_000);
    }
    try std.testing.expectEqual(@as(u32, 5_000), wb.avgFrameUs());

    var wb_max = try workbench.Workbench.init(alloc, 320, 240);
    defer wb_max.deinit();
    try wb_max.stepFrame(std.math.maxInt(u32));
    try wb_max.stepFrame(std.math.maxInt(u32));
    try std.testing.expectEqual(std.math.maxInt(u32), wb_max.avgFrameUs());
}

test "Workbench: double pollTokenReload, error atomicity, embedded NUL path, and idempotent deinit" {
    const alloc = std.testing.allocator;

    // Invalid viewport rejected
    try std.testing.expectError(error.InvalidViewport, workbench.Workbench.init(alloc, 0, 100));
    try std.testing.expectError(error.InvalidViewport, workbench.Workbench.init(alloc, std.math.nan(f32), 100));

    var path_buf: [256]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/ziggui_wb_adv_{d}.tok", .{std.os.linux.getpid()}, 0);
    defer _ = std.os.linux.unlink(tmp_path.ptr);

    var tbl = tokens.TokenTable.nordDefault();
    tbl.version = 1;
    try tokens.writeTokenFile(tmp_path.ptr, &tbl);

    var wb = try workbench.Workbench.init(alloc, 640, 480);
    defer wb.deinit();

    // Unattached poll returns false
    try std.testing.expect(!try wb.pollTokenReload());

    // Embedded NUL byte in path rejected
    try std.testing.expectError(error.InvalidPath, wb.attachTokenFile("/tmp/foo\x00bar.tok"));

    // Load JSON scene referencing token colors, attach token file, and hot-reload
    const json_scene =
        \\{
        \\  "type": "card",
        \\  "id": "tok_card",
        \\  "width": 120,
        \\  "height": 60,
        \\  "fill": "accent_primary"
        \\}
    ;
    try wb.loadSceneJson(json_scene);
    try wb.attachTokenFile(tmp_path);
    try wb.stepFrame(1_000);
    const color_v1 = wb.quads.items[0].color;

    // Invalid JSON preserves prior valid scene
    try std.testing.expectError(error.InvalidJson, wb.loadSceneJson("{bad"));
    try std.testing.expectEqual(@as(usize, 1), wb.arena.nodes.len);

    // Update token file on disk and verify pollTokenReload returns true once, then false, and updates quads
    tbl.version = 2;
    tbl.accent_primary = tokens.OklabColor.fromSrgbHex(0xBF616A);
    try tokens.writeTokenFile(tmp_path.ptr, &tbl);

    try std.testing.expect(try wb.pollTokenReload());
    try std.testing.expect(!try wb.pollTokenReload());
    try wb.stepFrame(1_000);
    const color_v2 = wb.quads.items[0].color;
    try std.testing.expect(!std.mem.eql(f32, &color_v1, &color_v2));

    // Idempotent double deinit
    wb.deinit();
    wb.deinit();
}

test "Workbench: OOM atomicity on loadSceneJson, attachTokenFile, pollTokenReload, and stepFrame" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    const alloc = failing.allocator();

    var path_buf: [256]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/ziggui_wb_oom_{d}.tok", .{std.os.linux.getpid()}, 0);
    defer _ = std.os.linux.unlink(tmp_path.ptr);

    var tbl = tokens.TokenTable.nordDefault();
    tbl.version = 1;
    try tokens.writeTokenFile(tmp_path.ptr, &tbl);

    var wb = try workbench.Workbench.init(alloc, 640, 480);
    defer wb.deinit();

    try wb.loadSceneJson(
        \\{ "type": "card", "id": "orig", "width": 100, "height": 50, "fill": "accent_primary" }
    );
    try wb.attachTokenFile(tmp_path);
    wb.hud_flags = .{ .show_layout_bounds = true, .show_frame_budget = true };
    try wb.stepFrame(1_500);
    const orig_quad_count = wb.last_quad_count;

    // Trigger OOM during loadSceneJson: prior arena and scene must survive intact
    failing.fail_index = failing.alloc_index + 2;
    try std.testing.expectError(error.OutOfMemory, wb.loadSceneJson(
        \\{ "type": "vstack", "id": "new_root", "children": [ { "type": "card", "id": "c1" }, { "type": "card", "id": "c2" } ] }
    ));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(wb.arena.findByTestId("orig") != null);

    // Trigger OOM during attachTokenFile rebuildActiveScene: prior mmap_tokens & version must survive
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, wb.attachTokenFile(tmp_path));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(u32, 1), wb.token_generation);

    // Trigger OOM during pollTokenReload rebuild: retry on next poll succeeds and updates scene
    tbl.version = 2;
    tbl.accent_primary = tokens.OklabColor.fromSrgbHex(0xA3BE8C);
    try tokens.writeTokenFile(tmp_path.ptr, &tbl);

    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, wb.pollTokenReload());
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(u32, 1), wb.token_generation);
    try std.testing.expect(try wb.pollTokenReload());
    try std.testing.expectEqual(@as(u32, 2), wb.token_generation);

    // Trigger OOM during stepFrame with new large gallery: frame_history & last_quad_count remain consistent
    try wb.loadBuiltinGallery();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, wb.stepFrame(9_999));
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(u32, 1_500), wb.last_frame_us);
    try std.testing.expectEqual(orig_quad_count, wb.last_quad_count);
}
