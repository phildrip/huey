const std = @import("std");
const huey = @import("huey");
const stratifi = @import("stratifi_demo.zig");
const core = huey.core;

test "StratifiShell: bar rendering produces workspace pills, active window, status chips, and atlas icons" {
    var shell = try stratifi.StratifiShell.init(std.testing.allocator);
    defer shell.deinit();

    const quad_count = try shell.buildBarScene(1920.0, 32.0, 1, false);
    try std.testing.expect(quad_count >= 15);
    try std.testing.expectEqual(@as(usize, 0), shell.last_launcher_quads);
    try std.testing.expectEqual(@as(usize, 0), shell.last_overlay_quads);
    try std.testing.expectEqual(quad_count, shell.quads.items.len);

    // Status bar & workspace pills 1..5 exist in LayoutArena
    const bar_id = shell.arena.findByTestId("status-bar").?;
    const bar_rect = shell.arena.getRect(bar_id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1920.0), bar_rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 32.0), bar_rect.h, 0.01);

    try std.testing.expect(shell.arena.findByTestId("ws-1") != null);
    try std.testing.expect(shell.arena.findByTestId("ws-2") != null);
    try std.testing.expect(shell.arena.findByTestId("ws-3") != null);
    try std.testing.expect(shell.arena.findByTestId("ws-4") != null);
    try std.testing.expect(shell.arena.findByTestId("ws-5") != null);
    try std.testing.expect(shell.arena.findByTestId("active-window") != null);
    try std.testing.expect(shell.arena.findByTestId("chip-net") != null);
    try std.testing.expect(shell.arena.findByTestId("chip-vol") != null);
    try std.testing.expect(shell.arena.findByTestId("chip-bat") != null);
    try std.testing.expect(shell.arena.findByTestId("chip-menu") != null);

    // Procedural icons rasterized into ImageAtlas and emitted with non-zero UVs
    try std.testing.expect(shell.atlas.cachedCount() >= 4);
    var textured_quads: usize = 0;
    for (shell.quads.items) |q| {
        if (q.uv_rect[2] > q.uv_rect[0] and q.uv_rect[3] > q.uv_rect[1]) {
            textured_quads += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), textured_quads);
}

test "StratifiShell: workspace switching updates active workspace checked state" {
    var shell = try stratifi.StratifiShell.init(std.testing.allocator);
    defer shell.deinit();

    _ = try shell.buildBarScene(1280.0, 32.0, 1, false);
    const ws1_initial = shell.arena.findByTestId("ws-1").?;
    const ws4_initial = shell.arena.findByTestId("ws-4").?;
    try std.testing.expectEqual(@as(?bool, true), shell.arena.isChecked(ws1_initial));
    try std.testing.expectEqual(@as(?bool, false), shell.arena.isChecked(ws4_initial));

    _ = try shell.buildBarScene(1280.0, 32.0, 4, false);
    const ws1_after = shell.arena.findByTestId("ws-1").?;
    const ws4_after = shell.arena.findByTestId("ws-4").?;
    try std.testing.expectEqual(@as(?bool, false), shell.arena.isChecked(ws1_after));
    try std.testing.expectEqual(@as(?bool, true), shell.arena.isChecked(ws4_after));
}

test "StratifiShell: launcher toggle, modal focus trap, search filtering, and backspace" {
    var shell = try stratifi.StratifiShell.init(std.testing.allocator);
    defer shell.deinit();

    const bar_only = try shell.buildBarScene(1920.0, 32.0, 1, false);
    try std.testing.expect(!shell.launcher_open);
    try std.testing.expect(shell.focus_mgr.topTrappedContainer(&shell.arena) == null);

    // Open launcher via toggleLauncher
    shell.toggleLauncher();
    try std.testing.expect(shell.launcher_open);
    const unfiltered_total = try shell.buildBarScene(1920.0, 32.0, 1, shell.launcher_open);
    try std.testing.expect(unfiltered_total > bar_only);
    try std.testing.expect(shell.last_launcher_quads > 0);
    try std.testing.expectEqual(stratifi.DEFAULT_LAUNCHER_ITEMS.len, shell.matched_count);

    // Centered modal & trapped focus scope
    const modal_id = shell.arena.findByTestId("launcher-modal").?;
    const modal_rect = shell.arena.getRect(modal_id).?;
    try std.testing.expectApproxEqAbs(@as(f32, (1920.0 - modal_rect.w) * 0.5), modal_rect.x, 1.0);
    try std.testing.expect(modal_rect.y > 32.0);
    const trap_id = shell.focus_mgr.topTrappedContainer(&shell.arena).?;
    try std.testing.expectEqual(modal_id.index, trap_id.index);
    try std.testing.expect(shell.focus_mgr.focused() != null);

    // Type query "term" -> matches only Terminal (foot)
    try shell.typeLauncherChar("t");
    try shell.typeLauncherChar("e");
    try shell.typeLauncherChar("r");
    try shell.typeLauncherChar("m");
    try std.testing.expectEqualStrings("term", shell.query());

    const filtered_total = try shell.buildBarScene(1920.0, 32.0, 1, shell.launcher_open);
    try std.testing.expectEqual(@as(usize, 1), shell.matched_count);
    try std.testing.expect(filtered_total < unfiltered_total);
    try std.testing.expect(shell.arena.findByTestId("foot") != null);
    try std.testing.expect(shell.arena.findByTestId("firefox") == null);

    // Query with no matches drops items to 0
    try shell.typeLauncherChar("zzz");
    _ = try shell.buildBarScene(1920.0, 32.0, 1, shell.launcher_open);
    try std.testing.expectEqual(@as(usize, 0), shell.matched_count);

    // Backspace restores matches
    try shell.backspaceLauncher();
    try shell.backspaceLauncher();
    try shell.backspaceLauncher();
    try std.testing.expectEqualStrings("term", shell.query());
    _ = try shell.buildBarScene(1920.0, 32.0, 1, shell.launcher_open);
    try std.testing.expectEqual(@as(usize, 1), shell.matched_count);

    try shell.backspaceLauncher();
    try shell.backspaceLauncher();
    try shell.backspaceLauncher();
    try shell.backspaceLauncher();
    try std.testing.expectEqualStrings("", shell.query());
    const restored_total = try shell.buildBarScene(1920.0, 32.0, 1, shell.launcher_open);
    try std.testing.expectEqual(stratifi.DEFAULT_LAUNCHER_ITEMS.len, shell.matched_count);
    try std.testing.expectEqual(unfiltered_total, restored_total);

    // Closing launcher pops modal focus trap
    shell.toggleLauncher();
    try std.testing.expect(!shell.launcher_open);
    try std.testing.expect(shell.focus_mgr.topTrappedContainer(&shell.arena) == null);
}

test "StratifiShell: anchored bar dropdown menu flips near right edge, encodes xdg_positioner, and dismisses" {
    var shell = try stratifi.StratifiShell.init(std.testing.allocator);
    defer shell.deinit();

    // Anchor near right edge of 1920x1080 so bottom_start flips horizontally inside viewport
    const overlay_id = try shell.openBarMenu(1830.0, 1920.0, 1080.0);
    try std.testing.expect(overlay_id != 0);
    try std.testing.expect(shell.overlays.isOpen(overlay_id));
    try std.testing.expect(shell.last_positioner_wire_len >= 8 * 7);
    try std.testing.expectEqual(@as(usize, 0), shell.last_positioner_wire_len % 4);

    const top_entry = shell.overlays.top().?;
    try std.testing.expect(top_entry.placed.flipped_x);
    try std.testing.expect(top_entry.rect.x + top_entry.rect.w <= 1920.0);
    try std.testing.expectApproxEqAbs(@as(f32, 36.0), top_entry.rect.y, 0.01);

    const scale = shell.primaryScale();
    const total = try shell.buildBarScene(1920.0, 32.0, 1, false);
    try std.testing.expectEqual(@as(usize, 2), shell.last_overlay_quads);
    const n = shell.quads.items.len;
    try std.testing.expectEqual(total, n);
    // Last two quads are backdrop + popup surface with physical-pixel scaled clip_rect
    try std.testing.expectEqual([4]f32{ 0.0, 0.0, 1920.0 * scale, 1080.0 * scale }, shell.quads.items[n - 2].clip_rect);
    try std.testing.expectEqual([4]f32{ 0.0, 0.0, 1920.0 * scale, 1080.0 * scale }, shell.quads.items[n - 1].clip_rect);

    // Outside click dismisses popup
    try std.testing.expect(shell.overlays.handleOutsideClick(100.0, 500.0));
    try std.testing.expectEqual(@as(usize, 0), shell.overlays.activeCount());
}

test "StratifiShell: multi-monitor mixed-DPI bars compute physical sizes and frame pacing" {
    var shell = try stratifi.StratifiShell.init(std.testing.allocator);
    defer shell.deinit();

    try std.testing.expectEqual(@as(usize, 2), shell.windows.output_count);
    const p1 = shell.windows.physicalSize(shell.primary_bar_win_id).?;
    const p2 = shell.windows.physicalSize(shell.secondary_bar_win_id).?;
    try std.testing.expectEqual(@as(u32, 3840), p1.w);
    try std.testing.expectEqual(@as(u32, 48), p1.h);
    try std.testing.expectEqual(@as(u32, 1920), p2.w);
    try std.testing.expectEqual(@as(u32, 32), p2.h);
    // 144Hz fastest output -> ~6944us min frame interval
    try std.testing.expectEqual(@as(u32, 6944), shell.windows.minFrameIntervalUs());
}

test "StratifiShell: deinit is idempotent" {
    var shell = try stratifi.StratifiShell.init(std.testing.allocator);
    _ = try shell.buildBarScene(1920.0, 32.0, 1, false);
    shell.deinit();
    shell.deinit();
}

test "StratifiShell: openBarMenu validates bounds before closing existing menu and rolls back on ID overflow" {
    var shell = try stratifi.StratifiShell.init(std.testing.allocator);
    defer shell.deinit();

    const existing_id = try shell.openBarMenu(1700.0, 1920.0, 1080.0);
    try std.testing.expect(shell.overlays.isOpen(existing_id));

    // Invalid viewport/anchor must reject with error.InvalidMenuBounds without closing existing menu
    try std.testing.expectError(error.InvalidMenuBounds, shell.openBarMenu(100.0, 0.0, 1080.0));
    try std.testing.expectError(error.InvalidMenuBounds, shell.openBarMenu(100.0, -1920.0, 1080.0));
    try std.testing.expectError(error.InvalidMenuBounds, shell.openBarMenu(100.0, 1920.0, 0.0));
    try std.testing.expectError(error.InvalidMenuBounds, shell.openBarMenu(100.0, std.math.nan(f32), 1080.0));
    try std.testing.expectError(error.InvalidMenuBounds, shell.openBarMenu(100.0, 1920.0, std.math.inf(f32)));
    try std.testing.expectError(error.InvalidMenuBounds, shell.openBarMenu(std.math.nan(f32), 1920.0, 1080.0));
    try std.testing.expectError(error.InvalidMenuBounds, shell.openBarMenu(std.math.inf(f32), 1920.0, 1080.0));
    try std.testing.expect(shell.overlays.isOpen(existing_id));
    try std.testing.expectEqual(existing_id, shell.bar_menu_id);

    // Dismissing externally leaves stale bar_menu_id; next openBarMenu clears stale id cleanly
    try std.testing.expect(shell.overlays.handleOutsideClick(10.0, 500.0));
    try std.testing.expect(!shell.overlays.isOpen(existing_id));

    // Overflow guard on 200 + id must roll back the opened overlay
    shell.overlays.next_id = std.math.maxInt(u32) - 50;
    try std.testing.expectError(error.OverlayIdOverflow, shell.openBarMenu(1700.0, 1920.0, 1080.0));
    try std.testing.expectEqual(@as(usize, 0), shell.overlays.activeCount());
    try std.testing.expectEqual(@as(u32, 0), shell.bar_menu_id);
}

test "StratifiShell: buildBarScene rejects invalid viewport and workspace inputs" {
    var shell = try stratifi.StratifiShell.init(std.testing.allocator);
    defer shell.deinit();

    try std.testing.expectError(error.InvalidViewport, shell.buildBarScene(0.0, 32.0, 1, false));
    try std.testing.expectError(error.InvalidViewport, shell.buildBarScene(-100.0, 32.0, 1, false));
    try std.testing.expectError(error.InvalidViewport, shell.buildBarScene(1e6 + 1.0, 32.0, 1, false));
    try std.testing.expectError(error.InvalidViewport, shell.buildBarScene(std.math.nan(f32), 32.0, 1, false));
    try std.testing.expectError(error.InvalidViewport, shell.buildBarScene(std.math.inf(f32), 32.0, 1, false));
    try std.testing.expectError(error.InvalidViewport, shell.buildBarScene(1920.0, 0.0, 1, false));
    try std.testing.expectError(error.InvalidViewport, shell.buildBarScene(1920.0, 1e6 + 1.0, 1, false));
    try std.testing.expectError(error.InvalidViewport, shell.buildBarScene(1920.0, std.math.nan(f32), 1, false));

    try std.testing.expectError(error.InvalidWorkspace, shell.buildBarScene(1920.0, 32.0, 0, false));
    try std.testing.expectError(error.InvalidWorkspace, shell.buildBarScene(1920.0, 32.0, 6, false));
}

test "StratifiShell: launcher rejects invalid UTF-8 and preserves query buffer across reallocations" {
    var shell = try stratifi.StratifiShell.init(std.testing.allocator);
    defer shell.deinit();

    try shell.typeLauncherChar("ter");
    try std.testing.expectError(error.InvalidUtf8, shell.typeLauncherChar(&[_]u8{ 0xFF, 0xFE }));
    try std.testing.expectEqualStrings("ter", shell.query());

    shell.toggleLauncher();
    _ = try shell.buildBarScene(1920.0, 32.0, 1, shell.launcher_open);

    // Force TextEditor buffer growth well past initial capacity and verify Arena label stays valid
    for (0..300) |_| {
        try shell.typeLauncherChar("a");
    }
    _ = try shell.buildBarScene(1920.0, 32.0, 1, shell.launcher_open);
    const input_node = shell.arena.findByTestId("launcher-input").?;
    const slice = shell.arena.nodes.slice();
    const label = slice.items(.label)[input_node.index];
    try std.testing.expectEqual(@as(usize, 256), label.len);
    try std.testing.expectEqualStrings("ter", label[0..3]);
}

test "StratifiShell: launcher focus scope preserves and restores prior bar focus across rebuilds" {
    var shell = try stratifi.StratifiShell.init(std.testing.allocator);
    defer shell.deinit();

    _ = try shell.buildBarScene(1920.0, 32.0, 1, false);
    const chip_menu_initial = shell.arena.findByTestId("chip-menu").?;
    shell.focus_mgr.setFocusedByKeyboard(&shell.arena, chip_menu_initial);

    // Rebuilding bar without launcher preserves bar focus
    _ = try shell.buildBarScene(1920.0, 32.0, 2, false);
    try std.testing.expectEqualStrings("chip-menu", shell.arena.getTestId(shell.focus_mgr.focused().?).?);

    // Opening launcher pushes trapped modal scope and focuses launcher-input
    shell.toggleLauncher();
    _ = try shell.buildBarScene(1920.0, 32.0, 2, shell.launcher_open);
    try std.testing.expect(shell.focus_mgr.topTrappedContainer(&shell.arena) != null);
    try std.testing.expectEqualStrings("launcher-input", shell.arena.getTestId(shell.focus_mgr.focused().?).?);

    // Tabbing inside launcher and rebuilding keeps focus on the launcher result instead of resetting
    const next_focus = shell.focus_mgr.focusNext(&shell.arena).?;
    try std.testing.expectEqualStrings("foot", shell.arena.getTestId(next_focus).?);
    try shell.typeLauncherChar("t");
    _ = try shell.buildBarScene(1920.0, 32.0, 2, shell.launcher_open);
    try std.testing.expectEqualStrings("foot", shell.arena.getTestId(shell.focus_mgr.focused().?).?);

    // Closing launcher restores prior bar focus (chip-menu)
    shell.toggleLauncher();
    _ = try shell.buildBarScene(1920.0, 32.0, 2, shell.launcher_open);
    try std.testing.expect(shell.focus_mgr.topTrappedContainer(&shell.arena) == null);
    try std.testing.expectEqualStrings("chip-menu", shell.arena.getTestId(shell.focus_mgr.focused().?).?);

    // Direct buildBarScene(..., false) from open launcher also pops scope and restores bar focus
    _ = try shell.buildBarScene(1920.0, 32.0, 2, true);
    try std.testing.expect(shell.focus_mgr.topTrappedContainer(&shell.arena) != null);
    _ = try shell.buildBarScene(1920.0, 32.0, 2, false);
    try std.testing.expect(shell.focus_mgr.topTrappedContainer(&shell.arena) == null);
    try std.testing.expectEqualStrings("chip-menu", shell.arena.getTestId(shell.focus_mgr.focused().?).?);
}
