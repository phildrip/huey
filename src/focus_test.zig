const std = @import("std");
const core = @import("core.zig");
const focus = @import("focus.zig");

test "FocusManager Tab/Shift+Tab wraps cleanly, skips disabled nodes, and sets focus_visible" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "root" });
    const t1 = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "t1", .height = 48.0 });
    _ = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "t_disabled", .height = 48.0, .disabled = true });
    const s1 = try arena.addChild(root, .{ .kind = .slider, .role = .slider, .test_id = "s1", .height = 48.0 });
    arena.layout(400.0, 400.0);

    var fm = focus.FocusManager.init();
    try std.testing.expectEqual(@as(?core.NodeId, null), fm.focused());
    try std.testing.expect(!fm.isFocusVisible());

    // Tab -> t1 (keyboard -> focus_visible = true)
    try std.testing.expectEqual(@as(?core.NodeId, t1), fm.focusNext(&arena));
    try std.testing.expect(fm.isFocusVisible());

    // Tab -> skips t_disabled -> s1
    try std.testing.expectEqual(@as(?core.NodeId, s1), fm.focusNext(&arena));

    // Tab wraps -> t1
    try std.testing.expectEqual(@as(?core.NodeId, t1), fm.focusNext(&arena));

    // Shift+Tab wraps backward -> s1
    try std.testing.expectEqual(@as(?core.NodeId, s1), fm.focusPrev(&arena));

    // Pointer focus clears focus_visible
    fm.setFocusedByPointer(&arena, t1);
    try std.testing.expectEqual(@as(?core.NodeId, t1), fm.focused());
    try std.testing.expect(!fm.isFocusVisible());
}

test "FocusManager traps focus inside modal/launcher scope and restores previous focus on pop" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "root" });
    const outer_btn = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "outer", .height = 48.0 });
    const modal = try arena.addChild(root, .{ .kind = .vstack, .role = .container, .test_id = "modal", .height = 200.0 });
    const m1 = try arena.addChild(modal, .{ .kind = .toggle, .role = .switch_control, .test_id = "m1", .height = 48.0 });
    const m2 = try arena.addChild(modal, .{ .kind = .slider, .role = .slider, .test_id = "m2", .height = 48.0 });
    arena.layout(400.0, 400.0);

    var fm = focus.FocusManager.init();
    fm.setFocusedByKeyboard(&arena, outer_btn);
    try std.testing.expectEqual(@as(?core.NodeId, outer_btn), fm.focused());

    // Push trapped modal scope -> moves focus to m1
    try fm.pushScope(&arena, modal, true);
    try std.testing.expectEqual(@as(?core.NodeId, m1), fm.focused());

    // Tab inside trapped scope cycles strictly m1 -> m2 -> m1 (never escapes to outer_btn!)
    try std.testing.expectEqual(@as(?core.NodeId, m2), fm.focusNext(&arena));
    try std.testing.expectEqual(@as(?core.NodeId, m1), fm.focusNext(&arena));
    try std.testing.expectEqual(@as(?core.NodeId, m2), fm.focusPrev(&arena));

    // Pop scope -> automatically restores outer_btn!
    fm.popScope(&arena);
    try std.testing.expectEqual(@as(?core.NodeId, outer_btn), fm.focused());
}

test "FocusManager roving tabindex lets Tab jump over group while arrows navigate within it" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "root" });
    const before = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "before", .height = 48.0 });
    const toolbar = try arena.addChild(root, .{ .kind = .hstack, .role = .container, .test_id = "toolbar", .height = 48.0, .roving_group = true });
    const b0 = try arena.addChild(toolbar, .{ .kind = .toggle, .role = .switch_control, .test_id = "b0", .width = 60.0 });
    const b1 = try arena.addChild(toolbar, .{ .kind = .toggle, .role = .switch_control, .test_id = "b1", .width = 60.0 });
    const b2 = try arena.addChild(toolbar, .{ .kind = .toggle, .role = .switch_control, .test_id = "b2", .width = 60.0 });
    const after = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "after", .height = 48.0 });
    arena.layout(400.0, 400.0);

    var fm = focus.FocusManager.init();
    try std.testing.expectEqual(@as(?core.NodeId, before), fm.focusNext(&arena));
    // Tab enters toolbar at b0
    try std.testing.expectEqual(@as(?core.NodeId, b0), fm.focusNext(&arena));
    // Arrow right moves inside toolbar: b0 -> b1 -> b2
    try std.testing.expectEqual(@as(?core.NodeId, b1), fm.moveInRovingGroup(&arena, 1));
    try std.testing.expectEqual(@as(?core.NodeId, b2), fm.moveInRovingGroup(&arena, 1));
    // Tab exits toolbar straight to `after`!
    try std.testing.expectEqual(@as(?core.NodeId, after), fm.focusNext(&arena));
    // Shift+Tab re-enters toolbar at remembered active child `b2`!
    try std.testing.expectEqual(@as(?core.NodeId, b2), fm.focusPrev(&arena));
}

test "FocusManager validate clears stale state after reset, pushScope bounds/errors, and popScope restores focus_visible" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container });
    const btn = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .height = 48.0 });
    const modal = try arena.addChild(root, .{ .kind = .vstack, .role = .container, .height = 100.0 });
    const m1 = try arena.addChild(modal, .{ .kind = .toggle, .role = .switch_control, .height = 48.0 });
    arena.layout(400.0, 400.0);

    var fm = focus.FocusManager.init();
    // Pointer focus -> focus_visible = false
    fm.setFocusedByPointer(&arena, btn);
    try std.testing.expectEqual(@as(?core.NodeId, btn), fm.focused());
    try std.testing.expect(!fm.isFocusVisible());

    // Push scope -> moves to m1 (keyboard visible = true), then pop restores btn AND focus_visible = false
    try fm.pushScope(&arena, modal, true);
    try std.testing.expectEqual(@as(?core.NodeId, m1), fm.focused());
    try std.testing.expect(fm.isFocusVisible());
    fm.popScope(&arena);
    try std.testing.expectEqual(@as(?core.NodeId, btn), fm.focused());
    try std.testing.expect(!fm.isFocusVisible());

    // MAX_SCOPES overflow check
    var i: usize = 0;
    while (i < focus.MAX_SCOPES) : (i += 1) {
        try fm.pushScope(&arena, modal, false);
    }
    try std.testing.expectError(error.ScopeStackOverflow, fm.pushScope(&arena, modal, false));

    // arena.reset() -> validate clears stale focused_node and pops all stale scopes
    arena.reset();
    _ = try arena.addNode(.{ .kind = .vstack, .role = .container });
    arena.layout(400.0, 400.0);
    fm.validate(&arena);
    try std.testing.expectEqual(@as(?core.NodeId, null), fm.focused());
    try std.testing.expect(!fm.isFocusVisible());
    try std.testing.expectEqual(@as(usize, 0), fm.scope_len);
    try std.testing.expectError(error.InvalidNodeId, fm.pushScope(&arena, modal, true));
}

test "FocusManager roving group wraps backward/forward and skips disabled items" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container });
    const rg = try arena.addChild(root, .{ .kind = .hstack, .role = .container, .roving_group = true, .height = 48.0 });
    const b0 = try arena.addChild(rg, .{ .kind = .toggle, .role = .switch_control, .width = 60.0 });
    _ = try arena.addChild(rg, .{ .kind = .toggle, .role = .switch_control, .width = 60.0, .disabled = true });
    const b2 = try arena.addChild(rg, .{ .kind = .toggle, .role = .switch_control, .width = 60.0 });
    arena.layout(400.0, 400.0);

    var fm = focus.FocusManager.init();
    try std.testing.expectEqual(@as(?core.NodeId, b0), fm.focusNext(&arena));
    // Forward skips disabled b1 -> b2
    try std.testing.expectEqual(@as(?core.NodeId, b2), fm.moveInRovingGroup(&arena, 1));
    // Forward wraps -> b0
    try std.testing.expectEqual(@as(?core.NodeId, b0), fm.moveInRovingGroup(&arena, 1));
    // Backward wraps -> b2
    try std.testing.expectEqual(@as(?core.NodeId, b2), fm.moveInRovingGroup(&arena, -1));
}

test "adversarial: trapped modal blocks outside setFocusedByPointer, disabled ancestors block focus, nested roving & trap boundary, popScope after reset" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container });
    const outer_rg = try arena.addChild(root, .{ .kind = .hstack, .role = .container, .roving_group = true, .height = 120.0 });
    const outer_btn = try arena.addChild(outer_rg, .{ .kind = .toggle, .role = .switch_control, .width = 60.0 });
    const modal = try arena.addChild(outer_rg, .{ .kind = .vstack, .role = .container, .width = 160.0 });
    const m1 = try arena.addChild(modal, .{ .kind = .toggle, .role = .switch_control, .height = 48.0 });
    const disabled_wrap = try arena.addChild(root, .{ .kind = .vstack, .role = .container, .disabled = true, .height = 60.0 });
    const child_in_disabled = try arena.addChild(disabled_wrap, .{ .kind = .toggle, .role = .switch_control, .height = 48.0 });
    const nested_outer = try arena.addChild(root, .{ .kind = .hstack, .role = .container, .roving_group = true, .height = 60.0 });
    const n_b0 = try arena.addChild(nested_outer, .{ .kind = .toggle, .role = .switch_control, .width = 40.0 });
    const nested_inner = try arena.addChild(nested_outer, .{ .kind = .hstack, .role = .container, .roving_group = true, .width = 80.0 });
    const n_i0 = try arena.addChild(nested_inner, .{ .kind = .toggle, .role = .switch_control, .width = 40.0 });
    const n_i1 = try arena.addChild(nested_inner, .{ .kind = .toggle, .role = .switch_control, .width = 40.0 });
    const n_b1 = try arena.addChild(nested_outer, .{ .kind = .toggle, .role = .switch_control, .width = 40.0 });
    arena.layout(400.0, 400.0);

    // Disabled ancestor makes descendant unfocusable
    try std.testing.expect(!arena.isEnabledTree(child_in_disabled));
    try std.testing.expect(!arena.isFocusable(child_in_disabled));

    var fm = focus.FocusManager.init();
    fm.setFocusedByKeyboard(&arena, child_in_disabled);
    try std.testing.expectEqual(@as(?core.NodeId, null), fm.focused());

    // Trapped modal rejects setFocusedByPointer outside trap and enclosingRovingGroup does not cross trap
    fm.setFocusedByKeyboard(&arena, outer_btn);
    try fm.pushScope(&arena, modal, true);
    try std.testing.expectEqual(@as(?core.NodeId, m1), fm.focused());
    fm.setFocusedByPointer(&arena, outer_btn);
    try std.testing.expectEqual(@as(?core.NodeId, m1), fm.focused());
    try std.testing.expectEqual(@as(?core.NodeId, null), fm.enclosingRovingGroup(&arena));
    try std.testing.expectEqual(@as(?core.NodeId, null), fm.moveInRovingGroup(&arena, 1));
    try std.testing.expectEqual(@as(?core.NodeId, m1), fm.focused());

    // popScope after arena.reset() clears all stale scopes safely
    fm.popScope(&arena);
    try std.testing.expectEqual(@as(?core.NodeId, outer_btn), fm.focused());

    // Nested roving_group flattens into outermost enclosing roving_group so no sibling is stranded
    fm.setFocusedByKeyboard(&arena, n_b0);
    try std.testing.expectEqual(@as(?core.NodeId, n_i0), fm.moveInRovingGroup(&arena, 1));
    try std.testing.expectEqual(@as(?core.NodeId, n_i1), fm.moveInRovingGroup(&arena, 1));
    try std.testing.expectEqual(@as(?core.NodeId, n_b1), fm.moveInRovingGroup(&arena, 1));
    try std.testing.expectEqual(@as(?core.NodeId, n_b0), fm.moveInRovingGroup(&arena, 1));

    // popScope after arena.reset()
    try fm.pushScope(&arena, modal, true);
    arena.reset();
    _ = try arena.addNode(.{ .kind = .vstack, .role = .container });
    arena.layout(400.0, 400.0);
    fm.popScope(&arena);
    try std.testing.expectEqual(@as(usize, 0), fm.scope_len);
    try std.testing.expectEqual(@as(?core.NodeId, null), fm.focused());
}
