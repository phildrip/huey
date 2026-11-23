const std = @import("std");
const core = @import("core.zig");
const te = @import("touch_ergonomics.zig");

test "hitTestWithTouchSlop expands small visual toggles to 44dp touch target and picks nearest center" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .padding = 40.0,
        .gap = 30.0,
        .fill = core.Nord.polar_night_0,
    });
    // Small 24x24 visual toggle at (40, 40)..(64, 64), center (52, 52)
    // Expanded 44dp hit-slop covers (30, 30)..(74, 74)!
    const t_small = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "small.toggle",
        .width = 24.0,
        .height = 24.0,
        .fill = core.Nord.polar_night_1,
    });
    arena.layout(300.0, 300.0);

    // Exact hitTest at (34, 52) misses (outside 40..64)
    try std.testing.expect(arena.hitTest(34.0, 52.0) != t_small);
    // Touch hit-slop at (34, 52) hits t_small cleanly!
    try std.testing.expectEqual(@as(?core.NodeId, t_small), te.hitTestWithTouchSlop(&arena, 34.0, 52.0, null));
    // Far away (10, 10) still misses
    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, 10.0, 10.0, null));
}

test "TouchArbiter disambiguates tap, vertical scroll, and horizontal slider drag cleanly" {
    var arb = te.TouchArbiter.init();

    // Small movement < 8dp -> resolves as .tap on up
    arb.onDown(0, 100.0, 100.0, .toggle);
    try std.testing.expectEqual(te.GestureDecision.pending, arb.onMove(0, 102.0, 103.0));
    try std.testing.expectEqual(te.GestureDecision.tap, arb.onUp(0));

    // Vertical swipe over a slider -> locks .vertical_scroll (never misfires slider!)
    arb.onDown(0, 100.0, 100.0, .slider);
    try std.testing.expectEqual(te.GestureDecision.vertical_scroll, arb.onMove(0, 102.0, 115.0));
    try std.testing.expectEqual(te.GestureDecision.vertical_scroll, arb.onMove(0, 140.0, 118.0)); // stays locked!
    try std.testing.expectEqual(te.GestureDecision.scroll_end, arb.onUp(0));

    // Horizontal drag on a slider -> locks .horizontal_drag!
    arb.onDown(0, 100.0, 100.0, .slider);
    try std.testing.expectEqual(te.GestureDecision.horizontal_drag, arb.onMove(0, 114.0, 102.0));
    try std.testing.expectEqual(te.GestureDecision.drag_end, arb.onUp(0));
}

test "hitTestWithTouchSlop picks the closer of two adjacent small toggles" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .hstack,
        .role = .container,
        .padding = 20.0,
        .gap = 8.0,
        .fill = core.Nord.polar_night_0,
    });
    // t_left: (20, 20)..(40, 40), center (30, 30), slop x in [8, 52]
    const t_left = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .width = 20.0,
        .height = 20.0,
    });
    // t_right: (48, 20)..(68, 40), center (58, 30), slop x in [36, 80]
    const t_right = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .width = 20.0,
        .height = 20.0,
    });
    arena.layout(200.0, 100.0);

    // Point (43, 30) is in the 8px gap between toggles, overlapping both 44dp slop rects.
    // Distance to t_left center (30, 30) = 13, distance to t_right center (58, 30) = 15 -> picks t_left.
    try std.testing.expectEqual(@as(?core.NodeId, t_left), te.hitTestWithTouchSlop(&arena, 43.0, 30.0, null));

    // Point (45, 30): distance to t_left = 15, distance to t_right = 13 -> picks t_right.
    try std.testing.expectEqual(@as(?core.NodeId, t_right), te.hitTestWithTouchSlop(&arena, 45.0, 30.0, null));
}

test "hitTestWithTouchSlop respects trapped_container and clip_children boundaries" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .padding = 10.0,
        .gap = 10.0,
        .fill = core.Nord.polar_night_0,
    });

    // Outside toggle at (10, 10)..(30, 30), center (20, 20)
    const outside_toggle = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .width = 20.0,
        .height = 20.0,
    });

    // Modal / trapped container with clip_children viewport starting at y=40, height=60 -> y in [40, 100]
    const modal = try arena.addChild(root, .{
        .kind = .vstack,
        .role = .panel,
        .width = 160.0,
        .height = 60.0,
        .gap = 40.0,
        .clip_children = true,
        .fill = core.Nord.polar_night_1,
    });

    // Inside modal and visible: y in [40, 60], center (20, 50), slop y in [28, 72]
    const inside_visible = try arena.addChild(modal, .{
        .kind = .toggle,
        .role = .switch_control,
        .width = 20.0,
        .height = 20.0,
    });

    // Inside modal but scrolled/laid out past clip bottom: y in [100, 120], center (20, 110), slop y in [88, 132]
    const inside_clipped = try arena.addChild(modal, .{
        .kind = .toggle,
        .role = .switch_control,
        .width = 20.0,
        .height = 20.0,
    });
    _ = inside_clipped;

    arena.layout(300.0, 300.0);

    // Trapped container blocks exact hits and slop hits on outside_toggle
    try std.testing.expectEqual(@as(?core.NodeId, outside_toggle), te.hitTestWithTouchSlop(&arena, 20.0, 20.0, null));
    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, 20.0, 20.0, modal));

    // Hit-slop for inside_visible does NOT reach outside modal's top clip boundary (y=35 < 40)
    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, 20.0, 35.0, modal));
    // Inside modal's clip boundary and within 44dp slop of inside_visible (y=68) -> hits inside_visible!
    try std.testing.expectEqual(@as(?core.NodeId, inside_visible), te.hitTestWithTouchSlop(&arena, 20.0, 68.0, modal));

    // Tap at (20, 95) is inside modal's clip rect [40, 100] and within slop [88, 132] of inside_clipped,
    // but inside_clipped's center (20, 110) is outside clip_children -> must return null!
    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, 20.0, 95.0, modal));
}

test "hitTestWithTouchSlop ignores disabled small toggles and non-finite coordinates" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .padding = 40.0,
        .fill = core.Nord.polar_night_0,
    });
    _ = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .width = 20.0,
        .height = 20.0,
        .disabled = true,
    });
    arena.layout(200.0, 200.0);

    // Exact hit and slop hit both ignore disabled toggle
    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, 50.0, 50.0, null));
    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, 35.0, 50.0, null));
    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, std.math.nan(f32), 50.0, null));
    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, 50.0, std.math.inf(f32), null));
}

test "TouchArbiter cancels tap on horizontal swipe over non-slider" {
    var arb = te.TouchArbiter.init();

    arb.onDown(0, 100.0, 100.0, .toggle);
    try std.testing.expectEqual(te.GestureDecision.pending, arb.state);

    // Horizontal swipe >= 8dp on a toggle -> cancels tap without misfiring scroll or slider drag
    try std.testing.expectEqual(te.GestureDecision.cancelled, arb.onMove(0, 115.0, 102.0));
    // Subsequent vertical movement does not resurrect a cancelled gesture
    try std.testing.expectEqual(te.GestureDecision.cancelled, arb.onMove(0, 115.0, 160.0));
    try std.testing.expectEqual(te.GestureDecision.cancelled, arb.onUp(0));
    try std.testing.expectEqual(te.GestureDecision.idle, arb.state);
    try std.testing.expectEqual(@as(?i32, null), arb.active_pointer);
}

test "TouchArbiter isolates secondary pointers in multi-touch and supports onCancel" {
    var arb = te.TouchArbiter.init();

    // Non-finite down is ignored
    arb.onDown(0, std.math.nan(f32), 100.0, .toggle);
    try std.testing.expectEqual(@as(?i32, null), arb.active_pointer);
    try std.testing.expectEqual(te.GestureDecision.idle, arb.state);

    // Primary pointer 1 goes down
    arb.onDown(1, 50.0, 50.0, .slider);
    try std.testing.expectEqual(@as(?i32, 1), arb.active_pointer);
    try std.testing.expectEqual(te.GestureDecision.pending, arb.state);

    // Secondary pointer 2 down/move/up/cancel must all be ignored
    arb.onDown(2, 200.0, 200.0, .toggle);
    try std.testing.expectEqual(@as(?i32, 1), arb.active_pointer);
    try std.testing.expectEqual(te.GestureDecision.idle, arb.onMove(2, 250.0, 200.0));
    try std.testing.expectEqual(te.GestureDecision.idle, arb.onUp(2));
    try std.testing.expectEqual(te.GestureDecision.idle, arb.onCancel(2));
    try std.testing.expectEqual(te.GestureDecision.pending, arb.state);

    // Non-finite move on active pointer is ignored without corrupting state
    try std.testing.expectEqual(te.GestureDecision.pending, arb.onMove(1, std.math.inf(f32), 50.0));
    try std.testing.expectEqual(te.GestureDecision.pending, arb.state);

    // Primary pointer 1 can lock horizontal_drag and be cancelled cleanly
    try std.testing.expectEqual(te.GestureDecision.horizontal_drag, arb.onMove(1, 65.0, 51.0));
    try std.testing.expectEqual(te.GestureDecision.cancelled, arb.onCancel(1));
    try std.testing.expectEqual(@as(?i32, null), arb.active_pointer);
    try std.testing.expectEqual(te.GestureDecision.idle, arb.state);
}

test "hitTestWithTouchSlop blocks hit-slop behind an occluding card above a small toggle" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .zstack,
        .role = .container,
        .fill = core.Nord.polar_night_0,
    });

    // Small 20x20 toggle placed at (60, 60)..(80, 80), center (70, 70), slop [48..92, 48..92]
    const toggle_layer = try arena.addChild(root, .{
        .kind = .vstack,
        .role = .container,
        .padding = 60.0,
    });
    _ = try arena.addChild(toggle_layer, .{
        .kind = .toggle,
        .role = .switch_control,
        .width = 20.0,
        .height = 20.0,
    });

    // Floating opaque card later in z-order (above toggle_layer) at (55, 55)..(85, 85),
    // completely covering the toggle (60..80, 60..80).
    const card_layer = try arena.addChild(root, .{
        .kind = .vstack,
        .role = .container,
        .padding = 55.0,
    });
    _ = try arena.addChild(card_layer, .{
        .kind = .card,
        .role = .panel,
        .width = 30.0,
        .height = 30.0,
        .fill = core.Nord.polar_night_2,
    });

    arena.layout(200.0, 200.0);

    // Touch directly on the opaque card above the toggle -> blocked
    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, 70.0, 70.0, null));
    // Touch beside the floating card (at 50, 70), still within toggle's 44dp slop,
    // must ALSO be blocked because the toggle's center (70, 70) is covered by the card above it!
    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, 50.0, 70.0, null));
}

test "hitTestWithTouchSlop keeps touch slop for partially clipped toggle whose unclipped center is past clip edge" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .fill = core.Nord.polar_night_0,
    });
    const scroller = try arena.addChild(root, .{
        .kind = .vstack,
        .role = .container,
        .width = 200.0,
        .height = 60.0,
        .padding = 0.0,
        .gap = 52.0,
        .clip_children = true,
        .fill = core.Nord.polar_night_1,
    });
    // Spacer pushes toggle to y = 52..72 (unclipped center = 62 > clip bottom 60),
    // while [52, 60] (8dp) is still visibly inside scroller!
    _ = try arena.addChild(scroller, .{
        .kind = .vstack,
        .role = .container,
        .width = 20.0,
        .height = 0.0,
    });
    const partial_toggle = try arena.addChild(scroller, .{
        .kind = .toggle,
        .role = .switch_control,
        .width = 20.0,
        .height = 20.0,
    });

    arena.layout(200.0, 200.0);

    // Touch inside scroller at (10, 45) is within partial_toggle's 44dp slop (y in [40, 84])
    // and inside scroller's clip rect [0, 60] -> must hit partial_toggle!
    try std.testing.expectEqual(@as(?core.NodeId, partial_toggle), te.hitTestWithTouchSlop(&arena, 10.0, 45.0, null));
    // Touch outside scroller's clip rect at (10, 65) -> must NOT hit!
    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, 10.0, 65.0, null));
}

test "hitTestWithTouchSlop returns null for out-of-viewport coordinates" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .padding = 0.0,
        .fill = core.Nord.polar_night_0,
    });
    // Toggle right at the top-left corner (0, 0)..(20, 20) so 44dp slop extends to (-12, -12)
    _ = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .width = 20.0,
        .height = 20.0,
    });

    arena.layout(100.0, 100.0);

    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, -5.0, 10.0, null));
    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, 10.0, -5.0, null));
    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, 105.0, 10.0, null));
    try std.testing.expectEqual(@as(?core.NodeId, null), te.hitTestWithTouchSlop(&arena, 10.0, 105.0, null));
}

test "hitTestWithTouchSlop normalizes stale or disabled trapped_container" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .padding = 20.0,
        .gap = 20.0,
        .fill = core.Nord.polar_night_0,
    });
    const active_toggle = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .width = 20.0,
        .height = 20.0,
    });
    const disabled_modal = try arena.addChild(root, .{
        .kind = .vstack,
        .role = .panel,
        .width = 100.0,
        .height = 50.0,
        .disabled = true,
    });
    arena.layout(200.0, 200.0);

    // Disabled trapped_container normalizes to null -> does not lock out active_toggle
    try std.testing.expectEqual(@as(?core.NodeId, active_toggle), te.hitTestWithTouchSlop(&arena, 15.0, 30.0, disabled_modal));

    // Stale trapped_container normalizes to null -> does not lock out active_toggle
    const stale_trap: core.NodeId = .{ .index = disabled_modal.index, .gen = disabled_modal.gen +% 1 };
    try std.testing.expectEqual(@as(?core.NodeId, active_toggle), te.hitTestWithTouchSlop(&arena, 15.0, 30.0, stale_trap));
}

test "hitTestWithTouchSlop picks top-most toggle on equidistant tie in zstack" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .zstack,
        .role = .container,
        .padding = 40.0,
        .fill = core.Nord.polar_night_0,
    });
    _ = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "bottom",
        .width = 20.0,
        .height = 20.0,
    });
    const top_toggle = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "top",
        .width = 20.0,
        .height = 20.0,
    });

    arena.layout(200.0, 200.0);

    // At (35, 50), both toggles are equidistant at (40, 40)..(60, 60); top_toggle must win!
    try std.testing.expectEqual(@as(?core.NodeId, top_toggle), te.hitTestWithTouchSlop(&arena, 35.0, 50.0, null));
}

test "TouchArbiter resets when onDown repeats with the same pointer_id" {
    var arb = te.TouchArbiter.init();

    arb.onDown(0, 100.0, 100.0, .slider);
    try std.testing.expectEqual(te.GestureDecision.horizontal_drag, arb.onMove(0, 120.0, 100.0));

    // Missed up followed by duplicate onDown on same pointer_id=0 resets to fresh pending gesture
    arb.onDown(0, 200.0, 200.0, .toggle);
    try std.testing.expectEqual(@as(?i32, 0), arb.active_pointer);
    try std.testing.expectEqual(te.GestureDecision.pending, arb.state);
    try std.testing.expectEqual(@as(?core.NodeKind, .toggle), arb.target_kind);
    try std.testing.expectEqual(@as(f32, 200.0), arb.down_x);
    try std.testing.expectEqual(@as(f32, 200.0), arb.down_y);
    try std.testing.expectEqual(te.GestureDecision.tap, arb.onUp(0));
}
