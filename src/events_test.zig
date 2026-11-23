const std = @import("std");
const core = @import("core.zig");
const events = @import("events.zig");

fn buildTestScene(allocator: std.mem.Allocator) !struct {
    arena: core.LayoutArena,
    toggle: core.NodeId,
    slider: core.NodeId,
} {
    var arena = core.LayoutArena.init(allocator);
    errdefer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .test_id = "root",
        .padding = 16.0,
        .gap = 12.0,
        .fill = core.Nord.polar_night_0,
    });
    const toggle = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "settings.gpu_cache",
        .height = 56.0,
        .fill = core.Nord.polar_night_1,
        .checked = false,
    });
    const slider = try arena.addChild(root, .{
        .kind = .slider,
        .role = .slider,
        .test_id = "settings.threads",
        .height = 56.0,
        .fill = core.Nord.polar_night_1,
        .slider_val = 0.25,
    });
    arena.layout(400.0, 400.0);
    return .{ .arena = arena, .toggle = toggle, .slider = slider };
}

test "EventRouter dispatches toggle tap on UP inside bounds and cancels on drag-slop or cancel" {
    var s = try buildTestScene(std.testing.allocator);
    defer s.arena.deinit();

    var router = events.EventRouter.init();

    // Tap down + up inside toggle -> toggles & emits .toggled
    router.dispatch(&s.arena, .{ .pointer_down = .{ .pointer_id = 0, .x = 100.0, .y = 40.0, .is_touch = true } });
    // Should NOT flip yet on DOWN (allows cancel/scroll disambiguation)
    try std.testing.expect(!s.arena.isChecked(s.toggle).?);
    try std.testing.expectEqual(@as(usize, 0), router.pollEvents().len);

    router.dispatch(&s.arena, .{ .pointer_up = .{ .pointer_id = 0, .x = 102.0, .y = 41.0, .is_touch = true } });
    try std.testing.expect(s.arena.isChecked(s.toggle).?);
    const evs = router.pollEvents();
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqualStrings("settings.gpu_cache", evs[0].toggled.test_id);
    try std.testing.expect(evs[0].toggled.checked);

    router.clearEvents();

    // Press + drag beyond touch slop (8dp) + release -> must NOT toggle!
    router.dispatch(&s.arena, .{ .pointer_down = .{ .pointer_id = 0, .x = 100.0, .y = 40.0, .is_touch = true } });
    router.dispatch(&s.arena, .{ .pointer_move = .{ .pointer_id = 0, .x = 100.0, .y = 65.0, .is_touch = true } });
    router.dispatch(&s.arena, .{ .pointer_up = .{ .pointer_id = 0, .x = 100.0, .y = 65.0, .is_touch = true } });
    try std.testing.expect(s.arena.isChecked(s.toggle).?); // unchanged
    try std.testing.expectEqual(@as(usize, 0), router.pollEvents().len);

    // Press + cancel -> must NOT toggle!
    router.dispatch(&s.arena, .{ .pointer_down = .{ .pointer_id = 0, .x = 100.0, .y = 40.0, .is_touch = true } });
    router.dispatch(&s.arena, .{ .pointer_cancel = .{ .pointer_id = 0 } });
    router.dispatch(&s.arena, .{ .pointer_up = .{ .pointer_id = 0, .x = 100.0, .y = 40.0, .is_touch = true } });
    try std.testing.expect(s.arena.isChecked(s.toggle).?);
    try std.testing.expectEqual(@as(usize, 0), router.pollEvents().len);
}

test "EventRouter pointer capture keeps slider drag alive outside bounds and isolates multi-touch" {
    var s = try buildTestScene(std.testing.allocator);
    defer s.arena.deinit();

    var router = events.EventRouter.init();

    // Pointer 0 grabs slider (y = 84..140)
    router.dispatch(&s.arena, .{ .pointer_down = .{ .pointer_id = 0, .x = 200.0, .y = 110.0, .is_touch = true } });
    try std.testing.expectEqual(@as(?core.NodeId, s.slider), router.captured_node);

    // Pointer 1 (second finger) down + up elsewhere must NOT break pointer 0's capture
    router.dispatch(&s.arena, .{ .pointer_down = .{ .pointer_id = 1, .x = 100.0, .y = 40.0, .is_touch = true } });
    router.dispatch(&s.arena, .{ .pointer_up = .{ .pointer_id = 1, .x = 100.0, .y = 40.0, .is_touch = true } });
    try std.testing.expectEqual(@as(?core.NodeId, s.slider), router.captured_node);
    try std.testing.expect(!s.arena.isChecked(s.toggle).?);

    // Pointer 0 moves far outside slider Y-bounds -> still drags slider smoothly to 1.0!
    router.clearEvents();
    router.dispatch(&s.arena, .{ .pointer_move = .{ .pointer_id = 0, .x = 390.0, .y = 350.0, .is_touch = true } });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.arena.getSliderValue(s.slider).?, 0.001);
    const evs = router.pollEvents();
    try std.testing.expect(evs.len >= 1);
    try std.testing.expectEqualStrings("settings.threads", evs[evs.len - 1].changed_f32.test_id);

    // Pointer 0 releases -> capture cleared
    router.dispatch(&s.arena, .{ .pointer_up = .{ .pointer_id = 0, .x = 390.0, .y = 350.0, .is_touch = true } });
    try std.testing.expectEqual(@as(?core.NodeId, null), router.captured_node);
}

test "EventRouter tracks hover enter/leave, wheel bubbling, and keyboard shortcuts" {
    var s = try buildTestScene(std.testing.allocator);
    defer s.arena.deinit();

    var router = events.EventRouter.init();

    // Mouse hover onto toggle
    router.dispatch(&s.arena, .{ .pointer_move = .{ .pointer_id = 0, .x = 100.0, .y = 40.0, .is_touch = false } });
    try std.testing.expectEqual(@as(?core.NodeId, s.toggle), router.hovered_node);
    try std.testing.expectEqual(@as(usize, 1), router.pollEvents().len);
    try std.testing.expect(router.pollEvents()[0].hover_changed.hovered);

    // Move to slider -> leave toggle, enter slider
    router.clearEvents();
    router.dispatch(&s.arena, .{ .pointer_move = .{ .pointer_id = 0, .x = 100.0, .y = 110.0, .is_touch = false } });
    try std.testing.expectEqual(@as(?core.NodeId, s.slider), router.hovered_node);
    try std.testing.expectEqual(@as(usize, 2), router.pollEvents().len);
    try std.testing.expect(!router.pollEvents()[0].hover_changed.hovered);
    try std.testing.expect(router.pollEvents()[1].hover_changed.hovered);

    // Wheel over slider emits .scrolled
    router.clearEvents();
    router.dispatch(&s.arena, .{ .wheel = .{ .x = 100.0, .y = 110.0, .dx = 0.0, .dy = -12.5 } });
    try std.testing.expectEqual(@as(usize, 1), router.pollEvents().len);
    try std.testing.expectEqual(@as(f32, -12.5), router.pollEvents()[0].scrolled.dy);

    // Keyboard shortcut (Ctrl+K) & Enter submit
    router.clearEvents();
    router.dispatch(&s.arena, .{ .key_down = .{ .key = .escape, .mods = .{}, .repeat = false } });
    router.dispatch(&s.arena, .{ .key_down = .{ .key = .enter, .mods = .{}, .repeat = false } });
    try std.testing.expectEqual(@as(usize, 2), router.pollEvents().len);
    try std.testing.expectEqual(events.Key.escape, router.pollEvents()[0].shortcut.key);
    try std.testing.expect(router.pollEvents()[1] == .submitted);
}

test "EventRouter sanitizes non-finite inputs, validates stale handles after reset, and handles focus_lost" {
    var s = try buildTestScene(std.testing.allocator);
    defer s.arena.deinit();

    var router = events.EventRouter.init();
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);

    // Pure hitTest does not mutate toggle or slider
    const h_toggle = s.arena.hitTest(100.0, 40.0).?;
    try std.testing.expectEqual(s.toggle, h_toggle);
    try std.testing.expect(!s.arena.isChecked(s.toggle).?);
    try std.testing.expectEqual(@as(?core.NodeKind, .toggle), s.arena.getKind(s.toggle));
    try std.testing.expectEqualStrings("settings.gpu_cache", s.arena.getTestId(s.toggle).?);
    try std.testing.expect(s.arena.getParent(s.toggle) != null);

    // Non-finite inputs are ignored cleanly
    router.dispatch(&s.arena, .{ .pointer_down = .{ .pointer_id = 0, .x = nan, .y = 40.0 } });
    router.dispatch(&s.arena, .{ .pointer_move = .{ .pointer_id = 0, .x = 100.0, .y = inf, .is_touch = false } });
    router.dispatch(&s.arena, .{ .wheel = .{ .x = 100.0, .y = 40.0, .dx = nan, .dy = 1.0 } });
    try std.testing.expectEqual(@as(usize, 0), router.pollEvents().len);
    try std.testing.expectEqual(@as(?core.NodeId, null), router.captured_node);

    // Hover + grab slider, then focus_lost clears capture, press, and emits hover leave
    router.dispatch(&s.arena, .{ .pointer_move = .{ .pointer_id = 0, .x = 100.0, .y = 40.0, .is_touch = false } });
    router.dispatch(&s.arena, .{ .pointer_down = .{ .pointer_id = 0, .x = 200.0, .y = 110.0, .is_touch = false } });
    try std.testing.expectEqual(@as(?core.NodeId, s.slider), router.captured_node);
    try std.testing.expectEqual(@as(?core.NodeId, s.toggle), router.hovered_node);
    try std.testing.expectEqual(@as(?core.NodeId, s.slider), router.focused_node);

    router.clearEvents();
    router.dispatch(&s.arena, .focus_lost);
    try std.testing.expectEqual(@as(?core.NodeId, null), router.captured_node);
    try std.testing.expectEqual(@as(?core.NodeId, null), router.pressed_node);
    try std.testing.expectEqual(@as(?core.NodeId, null), router.hovered_node);
    try std.testing.expectEqual(@as(?core.NodeId, null), router.focused_node);
    const leave_evs = router.pollEvents();
    try std.testing.expectEqual(@as(usize, 1), leave_evs.len);
    try std.testing.expect(!leave_evs[0].hover_changed.hovered);
    try std.testing.expectEqualStrings("settings.gpu_cache", leave_evs[0].hover_changed.test_id);

    // Stale handles after arena.reset() are cleared without panics or false events
    router.clearEvents();
    router.dispatch(&s.arena, .{ .pointer_move = .{ .pointer_id = 0, .x = 100.0, .y = 40.0, .is_touch = false } });
    router.dispatch(&s.arena, .{ .pointer_down = .{ .pointer_id = 0, .x = 200.0, .y = 110.0, .is_touch = true } });
    s.arena.reset();
    _ = try s.arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "new_root", .fill = core.Nord.polar_night_0 });
    s.arena.layout(400.0, 400.0);

    router.clearEvents();
    router.dispatch(&s.arena, .{ .key_down = .{ .key = .enter } });
    try std.testing.expectEqual(@as(?core.NodeId, null), router.captured_node);
    try std.testing.expectEqual(@as(?core.NodeId, null), router.hovered_node);
    try std.testing.expectEqual(@as(usize, 1), router.pollEvents().len);
    try std.testing.expectEqual(@as(?core.NodeId, null), router.pollEvents()[0].submitted.id);
}

test "EventRouter nextEvent pops FIFO, tracks dropped_events, and handles card click & modifiers" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .padding = 10.0, .fill = core.Nord.polar_night_0 });
    const card = try arena.addChild(root, .{ .kind = .card, .role = .panel, .test_id = "card.btn", .height = 60.0, .fill = core.Nord.polar_night_1 });
    arena.layout(200.0, 200.0);

    var router = events.EventRouter.init();

    // Card tap emits .clicked and focuses card for .submitted
    router.dispatch(&arena, .{ .pointer_down = .{ .pointer_id = 0, .x = 50.0, .y = 30.0, .is_touch = false } });
    router.dispatch(&arena, .{ .pointer_up = .{ .pointer_id = 0, .x = 52.0, .y = 31.0, .is_touch = false } });
    router.dispatch(&arena, .{ .key_down = .{ .key = .enter } });
    router.dispatch(&arena, .{ .key_down = .{ .key = .char, .mods = .{ .ctrl = true }, .codepoint = 'k' } });

    const ev1 = router.nextEvent().?;
    try std.testing.expectEqual(card, ev1.clicked.id);
    try std.testing.expectEqualStrings("card.btn", ev1.clicked.test_id);

    const ev2 = router.nextEvent().?;
    try std.testing.expectEqual(@as(?core.NodeId, card), ev2.submitted.id);
    try std.testing.expectEqualStrings("card.btn", ev2.submitted.test_id);

    const ev3 = router.nextEvent().?;
    try std.testing.expectEqual(events.Key.char, ev3.shortcut.key);
    try std.testing.expect(ev3.shortcut.mods.ctrl);
    try std.testing.expect(router.nextEvent() == null);

    // Overflowing 128-event queue increments dropped_events without crashing or allocating
    var i: usize = 0;
    while (i < 135) : (i += 1) {
        router.dispatch(&arena, .{ .key_down = .{ .key = .escape } });
    }
    try std.testing.expectEqual(@as(usize, 128), router.pollEvents().len);
    try std.testing.expectEqual(@as(usize, 7), router.dropped_events);
}

test "regression: duplicate pointer_down clears stale capture, non-primary buttons ignored, and repeat keys skipped" {
    var s = try buildTestScene(std.testing.allocator);
    defer s.arena.deinit();

    var router = events.EventRouter.init();
    const nan = std.math.nan(f32);

    // 1. Secondary/middle clicks do not activate toggle or capture slider
    router.dispatch(&s.arena, .{ .pointer_down = .{ .pointer_id = 0, .x = 100.0, .y = 40.0, .button = .secondary, .is_touch = false } });
    router.dispatch(&s.arena, .{ .pointer_up = .{ .pointer_id = 0, .x = 100.0, .y = 40.0, .button = .secondary, .is_touch = false } });
    try std.testing.expect(!s.arena.isChecked(s.toggle).?);
    try std.testing.expectEqual(@as(usize, 0), router.pollEvents().len);

    // Non-primary pointer_up (even with NaN coords) must NOT release active primary capture
    router.dispatch(&s.arena, .{ .pointer_down = .{ .pointer_id = 0, .x = 200.0, .y = 110.0, .button = .primary, .is_touch = false } });
    try std.testing.expectEqual(@as(?core.NodeId, s.slider), router.captured_node);
    router.dispatch(&s.arena, .{ .pointer_up = .{ .pointer_id = 0, .x = nan, .y = nan, .button = .secondary, .is_touch = false } });
    try std.testing.expectEqual(@as(?core.NodeId, s.slider), router.captured_node);

    // 2. Duplicate pointer_down on same active pointer_id clears stale slider capture cleanly
    router.dispatch(&s.arena, .{ .pointer_down = .{ .pointer_id = 0, .x = 100.0, .y = 40.0, .button = .primary, .is_touch = false } });
    try std.testing.expectEqual(@as(?core.NodeId, null), router.captured_node);
    try std.testing.expectEqual(@as(?core.NodeId, s.toggle), router.pressed_node);
    router.dispatch(&s.arena, .{ .pointer_up = .{ .pointer_id = 0, .x = 100.0, .y = 40.0, .button = .primary, .is_touch = false } });
    try std.testing.expect(s.arena.isChecked(s.toggle).?);

    // 3. key_down with repeat = true is ignored; shortcut carries codepoint
    router.clearEvents();
    router.dispatch(&s.arena, .{ .key_down = .{ .key = .char, .mods = .{ .ctrl = true }, .repeat = true, .codepoint = 'k' } });
    router.dispatch(&s.arena, .{ .key_down = .{ .key = .enter, .mods = .{}, .repeat = true } });
    try std.testing.expectEqual(@as(usize, 0), router.pollEvents().len);

    router.dispatch(&s.arena, .{ .key_down = .{ .key = .char, .mods = .{ .ctrl = true }, .repeat = false, .codepoint = 'k' } });
    router.dispatch(&s.arena, .{ .key_down = .{ .key = .char, .mods = .{ .ctrl = true }, .repeat = false, .codepoint = 'c' } });
    const evs = router.pollEvents();
    try std.testing.expectEqual(@as(usize, 2), evs.len);
    try std.testing.expectEqual(@as(u21, 'k'), evs[0].shortcut.codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), evs[1].shortcut.codepoint);
}

test "regression: slider endpoint snap, mouse drag-release hover refresh, and release outside bounds" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .padding = 16.0, .gap = 12.0, .fill = core.Nord.polar_night_0 });
    const toggle = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "t", .height = 56.0, .fill = core.Nord.polar_night_1 });
    const slider = try arena.addChild(root, .{ .kind = .slider, .role = .slider, .test_id = "s", .height = 56.0, .fill = core.Nord.polar_night_1, .slider_val = 0.0004 });
    arena.layout(400.0, 400.0);

    var router = events.EventRouter.init();

    // Hover slider first, then exact 0.0 endpoint snap from 0.0004
    router.dispatch(&arena, .{ .pointer_move = .{ .pointer_id = 0, .x = 200.0, .y = 110.0, .is_touch = false } });
    try std.testing.expectEqual(@as(?core.NodeId, slider), router.hovered_node);
    router.clearEvents();

    router.dispatch(&arena, .{ .pointer_down = .{ .pointer_id = 0, .x = 20.0, .y = 110.0, .is_touch = false } });
    try std.testing.expectEqual(@as(f32, 0.0), arena.getSliderValue(slider).?);
    try std.testing.expectEqual(@as(usize, 1), router.pollEvents().len);
    try std.testing.expectEqual(@as(f32, 0.0), router.pollEvents()[0].changed_f32.value);

    // Move near 0.9996 then snap exact 1.0
    router.clearEvents();
    // track_x = 32, track_w = 336 -> 32 + 336 * 0.9996 = 367.8656
    router.dispatch(&arena, .{ .pointer_move = .{ .pointer_id = 0, .x = 367.8656, .y = 110.0, .is_touch = false } });
    router.dispatch(&arena, .{ .pointer_move = .{ .pointer_id = 0, .x = 390.0, .y = 110.0, .is_touch = false } });
    const s_evs = router.pollEvents();
    try std.testing.expectEqual(@as(f32, 1.0), arena.getSliderValue(slider).?);
    try std.testing.expectEqual(@as(f32, 1.0), s_evs[s_evs.len - 1].changed_f32.value);

    // Release captured mouse drag outside scene -> clears stale hovered_node on slider
    router.clearEvents();
    router.dispatch(&arena, .{ .pointer_up = .{ .pointer_id = 0, .x = 500.0, .y = 40.0, .is_touch = false } });
    try std.testing.expectEqual(@as(?core.NodeId, null), router.captured_node);
    try std.testing.expectEqual(@as(?core.NodeId, null), router.hovered_node);
    try std.testing.expectEqual(@as(usize, 1), router.pollEvents().len);
    try std.testing.expect(!router.pollEvents()[0].hover_changed.hovered);
    try std.testing.expectEqual(slider, router.pollEvents()[0].hover_changed.id);

    // Release outside toggle bounds within 8dp drag slop must NOT toggle!
    // toggle rect is y=16..72; press at y=18, release at y=14 (4dp away, inside 8dp touch slop, outside rect!)
    router.clearEvents();
    router.dispatch(&arena, .{ .pointer_down = .{ .pointer_id = 0, .x = 100.0, .y = 18.0, .is_touch = true } });
    router.dispatch(&arena, .{ .pointer_up = .{ .pointer_id = 0, .x = 100.0, .y = 14.0, .is_touch = true } });
    try std.testing.expect(!arena.isChecked(toggle).?);
    try std.testing.expectEqual(@as(usize, 0), router.pollEvents().len);
}

test "regression: bordered transparent card occlusion, bar-inside-card click bubbling, and reset before UP" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .zstack, .role = .container, .fill = core.Nord.polar_night_0 });
    const under_toggle = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "under", .fill = core.Nord.polar_night_1 });
    const card = try arena.addChild(root, .{
        .kind = .card,
        .role = .panel,
        .test_id = "outer.card",
        .border_width = 2.0,
        .fill = core.Nord.transparent,
        .border = core.Nord.frost_1,
        .padding = 20.0,
    });
    const bar = try arena.addChild(card, .{
        .kind = .bar,
        .role = .progress_bar,
        .test_id = "inner.bar",
        .fill = core.Nord.polar_night_2,
        .slider_val = 0.5,
    });
    arena.layout(200.0, 200.0);

    // Transparent bordered card hits card at padding edge (5, 5), occluding under_toggle
    try std.testing.expectEqual(@as(?core.NodeId, card), arena.hitTest(5.0, 5.0));
    try std.testing.expectEqual(@as(?core.NodeId, bar), arena.hitTest(100.0, 100.0));

    // Clicking bar inside card bubbles click to card!
    var router = events.EventRouter.init();
    router.dispatch(&arena, .{ .pointer_down = .{ .pointer_id = 0, .x = 100.0, .y = 100.0, .is_touch = true } });
    router.dispatch(&arena, .{ .pointer_up = .{ .pointer_id = 0, .x = 100.0, .y = 100.0, .is_touch = true } });
    try std.testing.expect(!arena.isChecked(under_toggle).?);
    const evs = router.pollEvents();
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(card, evs[0].clicked.id);
    try std.testing.expectEqualStrings("outer.card", evs[0].clicked.test_id);

    // arena.reset() followed directly by pointer_up and focus_lost must not panic or emit stale events
    router.clearEvents();
    router.dispatch(&arena, .{ .pointer_move = .{ .pointer_id = 0, .x = 5.0, .y = 5.0, .is_touch = false } });
    router.dispatch(&arena, .{ .pointer_down = .{ .pointer_id = 0, .x = 5.0, .y = 5.0, .is_touch = false } });
    arena.reset();
    _ = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "r2", .fill = core.Nord.polar_night_0 });
    arena.layout(200.0, 200.0);
    router.clearEvents();
    router.dispatch(&arena, .{ .pointer_up = .{ .pointer_id = 0, .x = 5.0, .y = 5.0, .is_touch = false } });
    router.dispatch(&arena, .focus_lost);
    try std.testing.expectEqual(@as(usize, 0), router.pollEvents().len);
}
