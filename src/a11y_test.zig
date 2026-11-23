const std = @import("std");
const core = @import("core.zig");
const focus = @import("focus.zig");
const a11y = @import("a11y.zig");

test "A11yTree builds dirty-tracked accessibility snapshot coupled to LayoutArena + FocusManager" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "root", .padding = 12.0 });
    const t1 = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "t1", .label = "GPU Cache", .height = 48.0, .checked = true });
    const s1 = try arena.addChild(root, .{ .kind = .slider, .role = .slider, .test_id = "s1", .label = "Threads", .height = 48.0, .slider_val = 0.6 });
    const d1 = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "d1", .label = "Locked", .height = 48.0, .disabled = true });
    arena.layout(400.0, 300.0);

    var fm = focus.FocusManager.init();
    fm.setFocusedByKeyboard(&arena, t1);

    var tree = a11y.A11yTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.syncFromArena(&arena, &fm);

    try std.testing.expectEqual(@as(usize, 4), tree.nodes.items.len);
    const n_t1 = tree.findByNodeId(t1).?;
    try std.testing.expectEqual(a11y.A11yRole.switch_control, n_t1.role);
    try std.testing.expectEqualStrings("GPU Cache", n_t1.name);
    try std.testing.expect(n_t1.states.focused);
    try std.testing.expect(n_t1.states.checked);
    try std.testing.expect(n_t1.actions.toggle);

    const n_s1 = tree.findByNodeId(s1).?;
    try std.testing.expect(n_s1.actions.set_value);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), n_s1.numeric_value.?, 0.001);

    const n_d1 = tree.findByNodeId(d1).?;
    try std.testing.expect(n_d1.states.disabled);
    try std.testing.expect(!n_d1.actions.toggle); // disabled nodes expose no invokable actions!

    // Live region announcements queue
    try tree.announce("GPU Cache enabled", .polite);
    const ann = tree.popAnnouncement().?;
    try std.testing.expectEqualStrings("GPU Cache enabled", ann.message);
    try std.testing.expectEqual(a11y.LivePoliteness.polite, ann.politeness);
}

test "A11yTree.invokeAction executes toggle, click, set_value, focus, scroll and rejects disabled, non-interactive, or stale nodes" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "root", .padding = 8.0 });
    const t1 = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "t1", .height = 40.0, .checked = false });
    const s1 = try arena.addChild(root, .{ .kind = .slider, .role = .slider, .test_id = "s1", .height = 40.0, .slider_val = 0.25 });
    const c1 = try arena.addChild(root, .{ .kind = .card, .role = .panel, .test_id = "c1", .height = 40.0, .fill = core.Nord.polar_night_1 });
    const c_label = try arena.addChild(root, .{ .kind = .card, .role = .panel, .test_id = "c_label", .label = "Static Title", .height = 24.0 });
    const d1 = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "d1", .height = 40.0, .disabled = true });
    const disabled_group = try arena.addChild(root, .{ .kind = .vstack, .role = .container, .test_id = "dg", .disabled = true });
    const d_child_toggle = try arena.addChild(disabled_group, .{ .kind = .toggle, .role = .switch_control, .test_id = "d_child_toggle", .height = 40.0, .checked = false });
    const d_child_slider = try arena.addChild(disabled_group, .{ .kind = .slider, .role = .slider, .test_id = "d_child_slider", .height = 40.0, .slider_val = 0.5 });
    arena.layout(400.0, 500.0);

    var fm = focus.FocusManager.init();
    var tree = a11y.A11yTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.syncFromArena(&arena, &fm);

    // Ancestor-disabled nodes also expose zero actions
    const n_dct = tree.findByTestId("d_child_toggle").?;
    try std.testing.expect(n_dct.states.disabled);
    try std.testing.expect(!n_dct.actions.toggle);
    try std.testing.expect(!n_dct.actions.click);
    try std.testing.expect(!n_dct.actions.focus);

    // Transparent non-bordered card is not clickable; filled/bordered card is clickable
    try std.testing.expect(tree.findByNodeId(c1).?.actions.click);
    try std.testing.expect(!tree.findByNodeId(c_label).?.actions.click);
    try std.testing.expect(tree.invokeAction(&arena, &fm, .{ .click = c1 }));
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .click = c_label }));
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .click = root }));

    // Toggle and click on enabled toggle
    try std.testing.expect(tree.invokeAction(&arena, &fm, .{ .toggle = t1 }));
    try std.testing.expectEqual(@as(?bool, true), arena.isChecked(t1));
    try std.testing.expect(tree.invokeAction(&arena, &fm, .{ .click = t1 }));
    try std.testing.expectEqual(@as(?bool, false), arena.isChecked(t1));

    // Slider set_value clamps finite values and rejects NaN / wrong kind
    try std.testing.expect(tree.invokeAction(&arena, &fm, .{ .set_value = .{ .id = s1, .value = 0.85 } }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), arena.getSliderValue(s1).?, 0.001);
    try std.testing.expect(tree.invokeAction(&arena, &fm, .{ .set_value = .{ .id = s1, .value = 2.5 } }));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), arena.getSliderValue(s1).?, 0.001);
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .set_value = .{ .id = s1, .value = std.math.nan(f32) } }));
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .set_value = .{ .id = t1, .value = 0.5 } }));

    // Focus action focuses enabled focusable node and rejects non-focusable / disabled
    try std.testing.expect(tree.invokeAction(&arena, &fm, .{ .focus = s1 }));
    try std.testing.expectEqual(s1, fm.focused().?);
    try std.testing.expect(fm.isFocusVisible());
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .focus = root }));
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .focus = d1 }));
    try std.testing.expect(!tree.invokeAction(&arena, null, .{ .focus = t1 }));

    // Reject direct disabled and ancestor-disabled actions
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .toggle = d1 }));
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .click = d1 }));
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .toggle = d_child_toggle }));
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .set_value = .{ .id = d_child_slider, .value = 0.1 } }));
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .focus = d_child_slider }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), arena.getSliderValue(d_child_slider).?, 0.001);

    // Stale NodeIds after arena.reset() are cleanly rejected
    arena.reset();
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .toggle = t1 }));
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .click = c1 }));
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .set_value = .{ .id = s1, .value = 0.3 } }));
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .focus = s1 }));
}

test "A11yTree clip_children propagation marks scrolled-out nodes hidden and blocks invokeAction" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "root", .padding = 0.0 });
    const scroller = try arena.addChild(root, .{
        .kind = .vstack,
        .role = .container,
        .test_id = "scroller",
        .height = 60.0,
        .clip_children = true,
        .gap = 0.0,
    });
    const visible_btn = try arena.addChild(scroller, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "visible_btn",
        .height = 50.0,
        .checked = false,
    });
    const offscreen_btn = try arena.addChild(scroller, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "offscreen_btn",
        .height = 50.0,
        .checked = false,
    });
    const offscreen_slider = try arena.addChild(scroller, .{
        .kind = .slider,
        .role = .slider,
        .test_id = "offscreen_slider",
        .height = 50.0,
        .slider_val = 0.4,
    });
    arena.layout(300.0, 200.0);

    var fm = focus.FocusManager.init();
    var tree = a11y.A11yTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.syncFromArena(&arena, &fm);

    // First child (y=0..50) is visible inside scroller (y=0..60)
    const n_vis = tree.findByNodeId(visible_btn).?;
    try std.testing.expect(!n_vis.states.hidden);
    try std.testing.expect(n_vis.actions.toggle);

    // Third child (y=100..150) is scrolled out of clip_children (y=0..60)
    const n_off = tree.findByNodeId(offscreen_slider).?;
    try std.testing.expect(n_off.states.hidden);
    try std.testing.expect(!n_off.actions.set_value);
    try std.testing.expect(!n_off.actions.focus);

    // Second child (y=50..100) still intersects (0..60); scroll down so visible_btn scrolls out and offscreen_slider scrolls in
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .set_value = .{ .id = offscreen_slider, .value = 0.9 } }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), arena.getSliderValue(offscreen_slider).?, 0.001);

    // invokeAction(.scroll) updates scroll offset on clip_children container (and rejects non-clipping node)
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .scroll = .{ .id = visible_btn, .x = 0.0, .y = 100.0 } }));
    try std.testing.expect(tree.invokeAction(&arena, &fm, .{ .scroll = .{ .id = scroller, .x = 0.0, .y = 100.0 } }));
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), arena.getScroll(scroller).?[1], 0.001);
    arena.layout(300.0, 200.0);
    try tree.syncFromArena(&arena, &fm);

    // Now visible_btn (y=-100..-50) is hidden and blocked; offscreen_slider (y=0..50) is visible and operable
    try std.testing.expect(tree.findByNodeId(visible_btn).?.states.hidden);
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .toggle = visible_btn }));
    try std.testing.expect(!tree.findByNodeId(offscreen_slider).?.states.hidden);
    try std.testing.expect(tree.invokeAction(&arena, &fm, .{ .set_value = .{ .id = offscreen_slider, .value = 0.9 } }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), arena.getSliderValue(offscreen_slider).?, 0.001);
    _ = offscreen_btn;
}

test "A11yTree enforces modal focus trap in both syncFromArena and invokeAction" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "root", .padding = 8.0 });
    const bg_toggle = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "bg_toggle", .height = 40.0, .checked = false });
    const bg_slider = try arena.addChild(root, .{ .kind = .slider, .role = .slider, .test_id = "bg_slider", .height = 40.0, .slider_val = 0.2 });
    const bg_card = try arena.addChild(root, .{ .kind = .card, .role = .panel, .test_id = "bg_card", .height = 40.0, .fill = core.Nord.polar_night_1 });
    const modal = try arena.addChild(root, .{ .kind = .card, .role = .panel, .test_id = "modal", .height = 80.0, .fill = core.Nord.polar_night_2 });
    const modal_toggle = try arena.addChild(modal, .{ .kind = .toggle, .role = .switch_control, .test_id = "modal_toggle", .height = 40.0, .checked = false });
    arena.layout(400.0, 400.0);

    var fm = focus.FocusManager.init();
    fm.setFocusedByKeyboard(&arena, bg_toggle);
    try fm.pushScope(&arena, modal, true);

    var tree = a11y.A11yTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.syncFromArena(&arena, &fm);

    // Background nodes outside active trap suppress focusable/focused and interactive actions
    const n_bg_t = tree.findByNodeId(bg_toggle).?;
    try std.testing.expect(!n_bg_t.states.focusable);
    try std.testing.expect(!n_bg_t.states.focused);
    try std.testing.expect(!n_bg_t.actions.toggle);
    try std.testing.expect(!n_bg_t.actions.click);
    try std.testing.expect(!n_bg_t.actions.focus);

    // Modal node inside trap remains focusable and interactive
    const n_mod_t = tree.findByNodeId(modal_toggle).?;
    try std.testing.expect(n_mod_t.states.focusable);
    try std.testing.expect(n_mod_t.states.focused);
    try std.testing.expect(n_mod_t.actions.toggle);

    // Active modal trap blocks toggle, set_value, click, and focus on background nodes
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .toggle = bg_toggle }));
    try std.testing.expectEqual(@as(?bool, false), arena.isChecked(bg_toggle));
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .set_value = .{ .id = bg_slider, .value = 0.8 } }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), arena.getSliderValue(bg_slider).?, 0.001);
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .click = bg_card }));
    try std.testing.expect(!tree.invokeAction(&arena, &fm, .{ .focus = bg_toggle }));

    // Modal control remains operable
    try std.testing.expect(tree.invokeAction(&arena, &fm, .{ .toggle = modal_toggle }));
    try std.testing.expectEqual(@as(?bool, true), arena.isChecked(modal_toggle));
}

test "A11yTree.writeAtSpiJson sanitizes invalid UTF-8, normalizes -0.0, and parses via std.json.parseFromSlice" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const neg_zero: f32 = -0.0;
    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .test_id = "root\"quote\\slash\nctrl\x01\x7f",
        .label = "Bad\xffUTF8\xe2\x82Title",
        .padding = 10.0,
        .clip_children = true,
        .scroll_x = neg_zero,
    });
    const t1 = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "toggle.ok",
        .label = "Enable \"VSync\"",
        .height = 48.0,
        .checked = true,
    });
    _ = try arena.addChild(root, .{
        .kind = .bar,
        .role = .progress_bar,
        .test_id = "bar.progress",
        .height = 16.0,
        .slider_val = 0.75,
    });
    _ = try arena.addChild(root, .{
        .kind = .slider,
        .role = .slider,
        .test_id = "slider.disabled",
        .label = "Gain",
        .height = 40.0,
        .slider_val = neg_zero,
        .disabled = true,
    });
    arena.layout(320.0, 240.0);

    var fm = focus.FocusManager.init();
    fm.setFocusedByKeyboard(&arena, t1);

    var tree = a11y.A11yTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.syncFromArena(&arena, &fm);
    try tree.announce("Ready", .assertive);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try tree.writeAtSpiJson(&aw.writer);

    // Ensure no "-0.0" appears in serialized JSON
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "-0.0") == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("at-spi-accesskit-v1", obj.get("schema").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("generation").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("pending_announcements").?.integer);
    try std.testing.expect(obj.get("root_id").? != .null);

    const nodes = obj.get("nodes").?.array;
    try std.testing.expectEqual(@as(usize, 4), nodes.items.len);

    // Root node: escaped control chars + 0x7f, sanitized invalid UTF-8 in label
    const j_root = nodes.items[0].object;
    try std.testing.expectEqualStrings("root\"quote\\slash\nctrl\x01\x7f", j_root.get("test_id").?.string);
    try std.testing.expectEqualStrings("Bad\u{FFFD}UTF8\u{FFFD}\u{FFFD}Title", j_root.get("name").?.string);
    try std.testing.expect(j_root.get("parent").? == .null);
    try std.testing.expect(j_root.get("actions").?.object.get("scroll").?.bool);
    try std.testing.expect(j_root.get("numeric_value").? == .null);

    // Toggle node: focused, checked, toggle/click/focus actions
    const j_t1 = nodes.items[1].object;
    try std.testing.expectEqualStrings("switch_control", j_t1.get("role").?.string);
    try std.testing.expectEqualStrings("Enable \"VSync\"", j_t1.get("name").?.string);
    try std.testing.expect(j_t1.get("states").?.object.get("focused").?.bool);
    try std.testing.expect(j_t1.get("states").?.object.get("focus_visible").?.bool);
    try std.testing.expect(j_t1.get("states").?.object.get("checked").?.bool);
    try std.testing.expect(j_t1.get("actions").?.object.get("toggle").?.bool);

    // Progress bar node: numeric_value present, set_value false
    const j_bar = nodes.items[2].object;
    try std.testing.expectEqualStrings("progress_bar", j_bar.get("role").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), j_bar.get("numeric_value").?.float, 0.001);
    try std.testing.expect(!j_bar.get("actions").?.object.get("set_value").?.bool);

    // Disabled slider: disabled true, all actions false
    const j_dis = nodes.items[3].object;
    try std.testing.expect(j_dis.get("states").?.object.get("disabled").?.bool);
    try std.testing.expect(!j_dis.get("actions").?.object.get("set_value").?.bool);
    try std.testing.expect(!j_dis.get("actions").?.object.get("focus").?.bool);

    // Empty tree serializes cleanly with root_id == null
    arena.reset();
    try tree.syncFromArena(&arena, &fm);
    var aw_empty: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw_empty.deinit();
    try tree.writeAtSpiJson(&aw_empty.writer);
    var parsed_empty = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw_empty.written(), .{});
    defer parsed_empty.deinit();
    try std.testing.expect(parsed_empty.value.object.get("root_id").? == .null);
    try std.testing.expectEqual(@as(usize, 0), parsed_empty.value.object.get("nodes").?.array.items.len);
}

test "A11yTree announcement ring handles alias safety, invalid UTF-8, overflow, and OOM-atomic steady-state sync" {
    var tree = a11y.A11yTree.init(std.testing.allocator);
    defer tree.deinit();

    // Empty, .off, and short invalid UTF-8 announcements are ignored
    try tree.announce("", .polite);
    try tree.announce("ignored", .off);
    try tree.announce("\xff\xfe", .polite);
    try std.testing.expect(tree.popAnnouncement() == null);

    // Temporary heap-allocated strings can be freed immediately after announce()
    {
        const tmp = try std.testing.allocator.print("Saved #{d}", .{42});
        defer std.testing.allocator.free(tmp);
        try tree.announce(tmp, .assertive);
    }
    const popped_tmp = tree.popAnnouncement().?;
    try std.testing.expectEqualStrings("Saved #42", popped_tmp.message);
    try std.testing.expectEqual(a11y.LivePoliteness.assertive, popped_tmp.politeness);
    try std.testing.expect(tree.popAnnouncement() == null);

    // Overflowing the 32-slot ring retains the newest 32 in FIFO order without leaking
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var buf: [32]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "msg-{d}", .{i});
        try tree.announce(msg, if (i % 2 == 0) .polite else .assertive);
    }

    // Popping from a full ring and immediately re-announcing ann.message writes into the same slot safely (no @memcpy alias panic)
    const first_full_pop = tree.popAnnouncement().?;
    try std.testing.expectEqualStrings("msg-8", first_full_pop.message);
    try tree.announce(first_full_pop.message, first_full_pop.politeness);

    var popped_count: usize = 0;
    while (tree.popAnnouncement()) |ann| : (popped_count += 1) {
        if (popped_count < 31) {
            var exp_buf: [32]u8 = undefined;
            const expected = try std.fmt.bufPrint(&exp_buf, "msg-{d}", .{popped_count + 9});
            try std.testing.expectEqualStrings(expected, ann.message);
        } else {
            try std.testing.expectEqualStrings("msg-8", ann.message);
        }
    }
    try std.testing.expectEqual(a11y.MAX_ANNOUNCEMENTS, popped_count);
    try std.testing.expect(tree.popAnnouncement() == null);

    // Long UTF-8 message truncates cleanly on a codepoint boundary <= 128 bytes
    var long_buf: [140]u8 = undefined;
    @memset(long_buf[0..126], 'a');
    @memcpy(long_buf[126..130], "\xf0\x9f\x98\x80");
    @memset(long_buf[130..140], 'b');
    try tree.announce(&long_buf, .polite);
    const trunc_ann = tree.popAnnouncement().?;
    try std.testing.expectEqual(@as(usize, 126), trunc_ann.message.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(trunc_ann.message));

    // OOM-atomic syncFromArena: OOM on growth preserves prior snapshot & generation, and steady-state performs zero allocs
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "r" });
    const t = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "t", .height = 40.0 });
    arena.layout(200.0, 200.0);

    try tree.syncFromArena(&arena, null);
    try std.testing.expectEqual(@as(u64, 1), tree.generation);
    try std.testing.expectEqual(@as(usize, 2), tree.nodes.items.len);

    // Steady-state sync with FailingAllocator succeeds with zero allocations
    const orig_alloc = tree.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    tree.allocator = failing.allocator();
    _ = arena.toggleNode(t);
    try tree.syncFromArena(&arena, null);
    try std.testing.expectEqual(@as(u64, 2), tree.generation);
    try std.testing.expect(tree.findByTestId("t").?.states.checked);

    // Trigger capacity growth under FailingAllocator: OOM must preserve prior 2-node snapshot & generation == 2
    tree.allocator = orig_alloc;
    var extra: usize = 0;
    while (extra < 64) : (extra += 1) {
        _ = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "extra", .height = 20.0 });
    }
    arena.layout(200.0, 2000.0);

    var oom_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    tree.allocator = oom_failing.allocator();
    try std.testing.expectError(error.OutOfMemory, tree.syncFromArena(&arena, null));
    tree.allocator = orig_alloc;
    try std.testing.expectEqual(@as(u64, 2), tree.generation);
    try std.testing.expectEqual(@as(usize, 2), tree.nodes.items.len);
}
