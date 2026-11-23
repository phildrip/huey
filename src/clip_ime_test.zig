const std = @import("std");
const core = @import("core.zig");
const ime = @import("ime.zig");
const headless = @import("headless.zig");

test "QuadInstance is 96-byte ABI aligned with per-instance clip_rect" {
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(core.QuadInstance));
}

test "Hierarchical clip_children intersects nested clip_rects, culls offscreen quads, and clips hit-testing" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .test_id = "root",
        .padding = 20.0,
        .fill = core.Nord.polar_night_0,
    });
    const scroller = try arena.addChild(root, .{
        .kind = .vstack,
        .role = .container,
        .test_id = "scroller",
        .height = 100.0,
        .clip_children = true,
        .scroll_y = 60.0,
        .fill = core.Nord.polar_night_1,
    });
    // Item 0: y = 20 - 60 = -40..10 (completely above scroller y=20..120 -> CULLED!)
    const item0 = try arena.addChild(scroller, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "item0",
        .height = 50.0,
        .fill = core.Nord.polar_night_2,
    });
    // Item 1: y = 70 - 60 = 10..60 (partially visible inside y=20..120 -> CLIPPED to y>=20!)
    const item1 = try arena.addChild(scroller, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "item1",
        .height = 50.0,
        .fill = core.Nord.polar_night_2,
    });
    // Item 2: y = 120 - 60 = 60..110 (fully visible inside y=20..120)
    const item2 = try arena.addChild(scroller, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "item2",
        .height = 50.0,
        .fill = core.Nord.polar_night_2,
    });
    // Item 3: y = 170 - 60 = 110..160 (partially clipped at bottom y=120)
    _ = try arena.addChild(scroller, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "item3",
        .height = 50.0,
        .fill = core.Nord.polar_night_2,
    });
    // Item 4: y = 220 - 60 = 160..210 (completely below scroller -> CULLED!)
    const item4 = try arena.addChild(scroller, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "item4",
        .height = 50.0,
        .fill = core.Nord.polar_night_2,
    });

    arena.layout(300.0, 300.0);

    // Hit-testing clipped-out item0 (at y=5, outside scroller y=20..120) must NOT hit item0 or item1!
    try std.testing.expect(arena.hitTest(100.0, 15.0) != item0);
    try std.testing.expect(arena.hitTest(100.0, 15.0) != item1);
    // Hit-testing item4 below scroller (at y=170) must NOT hit item4!
    try std.testing.expect(arena.hitTest(100.0, 170.0) != item4);
    // Hit-testing visible portion of item1 (y=35) hits item1, and item2 (y=80) hits item2!
    try std.testing.expectEqual(@as(?core.NodeId, item1), arena.hitTest(100.0, 35.0));
    try std.testing.expectEqual(@as(?core.NodeId, item2), arena.hitTest(100.0, 80.0));

    // Emitted quads for scroller children carry physical clip_rect = (40, 40, 560, 240) at scale=2.0
    var buf: [64]core.QuadInstance = undefined;
    const n = arena.emitQuads(&buf, 2.0);
    try std.testing.expect(n >= 4);
    var saw_clipped_child = false;
    for (buf[0..n]) |q| {
        if (q.clip_rect[1] == 40.0 and q.clip_rect[3] == 240.0) {
            saw_clipped_child = true;
            // No completely offscreen quad should be emitted!
            try std.testing.expect(q.pos_size[1] + q.pos_size[3] >= 40.0 - 20.0);
            try std.testing.expect(q.pos_size[1] <= 240.0 + 20.0);
        }
    }
    try std.testing.expect(saw_clipped_child);
}

test "ImeState manages preedit composition, cursor range, commit, and cancel cleanly" {
    var state = ime.ImeState.init();
    try std.testing.expect(!state.composing);

    state.setPreedit("nihao", 2, 5);
    try std.testing.expect(state.composing);
    try std.testing.expectEqualStrings("nihao", state.preeditText());
    try std.testing.expectEqual(@as(usize, 2), state.cursor_start);
    try std.testing.expectEqual(@as(usize, 5), state.cursor_end);

    state.commit("你好");
    try std.testing.expect(!state.composing);
    try std.testing.expectEqualStrings("", state.preeditText());
    try std.testing.expectEqualStrings("你好", state.takeCommitted().?);
    try std.testing.expectEqual(@as(?[]const u8, null), state.takeCommitted());

    state.setPreedit("temp", 0, 4);
    state.cancel();
    try std.testing.expect(!state.composing);
    try std.testing.expectEqualStrings("", state.preeditText());
}

test "setScroll, getScroll, grandchild scroll inheritance, and nested clip intersection" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .padding = 10.0,
    });
    const outer = try arena.addChild(root, .{
        .kind = .vstack,
        .role = .container,
        .height = 100.0,
        .clip_children = true,
        .fill = core.Nord.polar_night_0,
    });
    const inner = try arena.addChild(outer, .{
        .kind = .vstack,
        .role = .container,
        .height = 120.0,
        .padding = 10.0,
        .clip_children = true,
        .fill = core.Nord.polar_night_1,
    });
    const leaf = try arena.addChild(inner, .{
        .kind = .toggle,
        .role = .switch_control,
        .height = 40.0,
        .fill = core.Nord.aurora_red,
    });

    arena.layout(200.0, 200.0);
    arena.consumeRedraw();
    try std.testing.expectEqual(@as(?[2]f32, .{ 0.0, 0.0 }), arena.getScroll(outer));

    // Unchanged scroll does not dirty layout or redraw
    arena.setScroll(outer, 0.0, 0.0);
    try std.testing.expect(!arena.layout_dirty);
    try std.testing.expect(!arena.needsRedraw());

    // Scroll updates layout_dirty and redraw_needed and shifts grandchildren
    arena.setScroll(outer, 5.0, 20.0);
    try std.testing.expect(arena.layout_dirty);
    try std.testing.expect(arena.needsRedraw());
    try std.testing.expectEqual(@as(?[2]f32, .{ 5.0, 20.0 }), arena.getScroll(outer));

    arena.layout(200.0, 200.0);
    const leaf_rect = arena.getRect(leaf).?;
    // root pad(10) - outer scroll(5, 20) + inner pad(10) => x=15, y=0
    try std.testing.expectEqual(@as(f32, 15.0), leaf_rect.x);
    try std.testing.expectEqual(@as(f32, 0.0), leaf_rect.y);

    // Nested clip intersection at scale 1.0:
    // outer: [10, 10, 190, 110]
    // inner: [5, -10, 185, 110] -> intersected: [10, 10, 185, 110]
    var buf: [32]core.QuadInstance = undefined;
    const n = arena.emitQuads(&buf, 1.0);
    var saw_leaf = false;
    for (buf[0..n]) |q| {
        if (q.color[0] == core.Nord.aurora_red[0] and q.color[1] == core.Nord.aurora_red[1]) {
            saw_leaf = true;
            try std.testing.expectEqual([4]f32{ 10.0, 10.0, 185.0, 110.0 }, q.clip_rect);
        }
    }
    try std.testing.expect(saw_leaf);

    // Clipped-out toggle cannot be toggled via handlePointerDown
    // Scroll outer so leaf is completely above outer (y < 10)
    arena.setScroll(outer, 0.0, 70.0);
    arena.layout(200.0, 200.0);
    try std.testing.expect(arena.handlePointerDown(50.0, 5.0) == null);
    try std.testing.expectEqual(@as(?bool, false), arena.isChecked(leaf));

    // Non-finite scroll values sanitize to 0
    arena.setScroll(outer, std.math.nan(f32), std.math.inf(f32));
    try std.testing.expectEqual(@as(?[2]f32, .{ 0.0, 0.0 }), arena.getScroll(outer));
}

test "Empty child_clip skips subtree and headless rasterizer enforces clip_rect pixel-for-pixel" {
    var session = try headless.HeadlessSession.init(std.testing.allocator, 100.0, 100.0, 1.0);
    defer session.deinit();

    const root = try session.arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .fill = core.Nord.polar_night_0,
    });
    const clipper = try session.arena.addChild(root, .{
        .kind = .vstack,
        .role = .container,
        .height = 40.0,
        .clip_children = true,
        .fill = core.Nord.polar_night_0,
    });
    // Child taller than clipper (80 > 40) with bright red fill
    _ = try session.arena.addChild(clipper, .{
        .kind = .card,
        .role = .panel,
        .height = 80.0,
        .fill = core.Nord.aurora_red,
    });
    // Zero-size clipper whose child would otherwise extend outside if not skipped
    const zero_clip = try session.arena.addChild(root, .{
        .kind = .vstack,
        .role = .container,
        .height = 0.0,
        .flex = 0.0,
        .clip_children = true,
    });
    _ = try session.arena.addChild(zero_clip, .{
        .kind = .card,
        .role = .panel,
        .height = 30.0,
        .fill = core.Nord.aurora_green,
    });

    _ = session.step(16.67);
    const img = try session.renderSnapshotRgba(std.testing.allocator, false);
    defer std.testing.allocator.free(img);

    // Pixel (50, 20) inside clipper [0..40] must be red
    const off_in = (20 * 100 + 50) * 4;
    try std.testing.expect(img[off_in + 0] > 150 and img[off_in + 1] < 130);
    // Pixel (50, 50) outside clipper [0..40] must remain polar_night_0 (blueish dark, not red or green)
    const off_out = (50 * 100 + 50) * 4;
    try std.testing.expect(img[off_out + 0] < 60 and img[off_out + 1] < 70 and img[off_out + 2] < 80);
}

test "ImeState handles UTF-8 clamping, empty preedit, and caretRect" {
    var state = ime.ImeState.init();
    // Empty text sets composing = false
    state.setPreedit("abc", 1, 2);
    try std.testing.expect(state.composing);
    state.setPreedit("", 0, 0);
    try std.testing.expect(!state.composing);

    // 255 ASCII bytes + 3-byte UTF-8 char ("你") = 258 bytes -> clamped cleanly to 255 bytes
    var long_buf: [258]u8 = undefined;
    @memset(long_buf[0..255], 'a');
    @memcpy(long_buf[255..258], "你");
    state.setPreedit(&long_buf, 1000, 1000);
    try std.testing.expectEqual(@as(usize, 255), state.preeditText().len);
    try std.testing.expectEqual(@as(usize, 255), state.cursor_start);
    try std.testing.expectEqual(@as(usize, 255), state.cursor_end);
    try std.testing.expect(std.unicode.utf8ValidateSlice(state.preeditText()));

    // Mid-codepoint cursor index clamps to UTF-8 boundary
    state.setPreedit("你好", 1, 4);
    try std.testing.expectEqual(@as(usize, 0), state.cursor_start);
    try std.testing.expectEqual(@as(usize, 3), state.cursor_end);

    // caretRect resolves target node layout rect and ignores stale NodeId
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    const root = try arena.addNode(.{ .kind = .vstack, .padding = 10.0 });
    const input = try arena.addChild(root, .{ .kind = .card, .height = 40.0 });
    arena.layout(200.0, 200.0);

    try std.testing.expect(state.caretRect(&arena) == null);
    state.target_node = input;
    const caret = state.caretRect(&arena).?;
    try std.testing.expect(caret.x >= 10.0 and caret.y >= 10.0);
    try std.testing.expect(caret.w > 0.0 and caret.h > 0.0);

    arena.reset();
    try std.testing.expect(state.caretRect(&arena) == null);
}

test "ImeState regression: strict UTF-8 prefix, reversed cursor range, commit empty preserves pending, and caretRect guards" {
    var state = ime.ImeState.init();

    // Invalid UTF-8 bytes (0xFF) and truncated 4-byte emoji at byte 255 always produce valid UTF-8
    const invalid_bytes = [_]u8{ 'h', 'i', 0xFF, 'x' };
    state.setPreedit(&invalid_bytes, 0, 4);
    try std.testing.expect(std.unicode.utf8ValidateSlice(state.preeditText()));
    try std.testing.expectEqualStrings("hi", state.preeditText());

    var emoji_edge: [258]u8 = undefined;
    @memset(emoji_edge[0..254], 'a');
    @memcpy(emoji_edge[254..258], "\xF0\x9F\x98\x80"); // 4-byte emoji spanning 254..258
    state.setPreedit(&emoji_edge, 300, 100);
    try std.testing.expect(std.unicode.utf8ValidateSlice(state.preeditText()));
    try std.testing.expectEqual(@as(usize, 254), state.preeditText().len);
    try std.testing.expectEqual(@as(usize, 100), state.cursor_start);
    try std.testing.expectEqual(@as(usize, 254), state.cursor_end);

    // Reversed cursor range normalizes to [min, max]
    state.setPreedit("nihao", 5, 2);
    try std.testing.expectEqual(@as(usize, 2), state.cursor_start);
    try std.testing.expectEqual(@as(usize, 5), state.cursor_end);

    // commit("") clears preedit but preserves unconsumed pending commit
    state.commit("你好");
    state.setPreedit("abc", 0, 3);
    state.commit("");
    try std.testing.expect(!state.composing);
    try std.testing.expectEqualStrings("你好", state.takeCommitted().?);
    try std.testing.expectEqual(@as(?[]const u8, null), state.takeCommitted());

    // caretRect returns null when disabled or scrolled out of ancestor clip_children container
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    const root = try arena.addNode(.{ .kind = .vstack, .padding = 10.0 });
    const scroller = try arena.addChild(root, .{
        .kind = .vstack,
        .height = 60.0,
        .clip_children = true,
        .scroll_y = 0.0,
    });
    const input = try arena.addChild(scroller, .{ .kind = .card, .height = 40.0 });
    arena.layout(200.0, 200.0);

    state.target_node = input;
    try std.testing.expect(state.caretRect(&arena) != null);

    // Scrolled completely above scroller (y = 10 - 100 = -90..-50) -> null
    arena.setScroll(scroller, 0.0, 100.0);
    arena.layout(200.0, 200.0);
    try std.testing.expect(state.caretRect(&arena) == null);

    // Disabled node -> null even when visible
    var arena2 = core.LayoutArena.init(std.testing.allocator);
    defer arena2.deinit();
    const r2 = try arena2.addNode(.{ .kind = .vstack });
    const disabled_input = try arena2.addChild(r2, .{ .kind = .card, .height = 40.0, .disabled = true });
    arena2.layout(200.0, 200.0);
    state.target_node = disabled_input;
    try std.testing.expect(state.caretRect(&arena2) == null);
}

test "layoutChildren clamps extreme scroll offsets without Inf or NaN" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    const root = try arena.addNode(.{
        .kind = .zstack,
        .scroll_x = std.math.floatMax(f32),
        .scroll_y = -std.math.floatMax(f32),
    });
    const child = try arena.addChild(root, .{ .kind = .card, .width = 50.0, .height = 50.0 });
    arena.layout(200.0, 200.0);
    const cr = arena.getRect(child).?;
    try std.testing.expect(std.math.isFinite(cr.x) and std.math.isFinite(cr.y));
}
