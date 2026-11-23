const std = @import("std");
const c_abi = @import("c_abi.zig");
const c_hdr = @cImport({
    @cInclude("ziggui.h");
});

test "Flat C ABI lifecycle: create, build widgets, layout, inject touch, poll UiEvent, destroy" {
    const ctx = c_abi.ziggui_create(400.0, 400.0, 2.0) orelse return error.CreateFailed;
    defer c_abi.ziggui_destroy(ctx);

    const root = c_abi.ziggui_add_vstack(ctx, 0, "root", 16.0, 12.0);
    try std.testing.expect(root != 0);
    const t1 = c_abi.ziggui_add_toggle(ctx, root, "c.toggle", "Enable Cache", 56.0, false);
    try std.testing.expect(t1 != 0);
    const s1 = c_abi.ziggui_add_slider(ctx, root, "c.slider", "Threads", 56.0, 0.25);
    try std.testing.expect(s1 != 0);

    c_abi.ziggui_layout(ctx);

    var r: c_abi.ZigguiRect = undefined;
    try std.testing.expect(c_abi.ziggui_get_rect(ctx, t1, &r));
    try std.testing.expectEqual(@as(f32, 16.0), r.x);
    try std.testing.expectEqual(@as(f32, 56.0), r.h);

    // Tap toggle via C ABI
    c_abi.ziggui_pointer_down(ctx, 0, r.x + r.w * 0.5, r.y + r.h * 0.5, true);
    c_abi.ziggui_pointer_up(ctx, 0, r.x + r.w * 0.5, r.y + r.h * 0.5, true);

    var ev: c_abi.ZigguiEvent = undefined;
    try std.testing.expect(c_abi.ziggui_poll_event(ctx, &ev));
    try std.testing.expectEqual(c_abi.ZigguiEventKind.toggled, ev.kind);
    try std.testing.expectEqual(t1, ev.node_id);
    try std.testing.expect(ev.bool_val);
    try std.testing.expect(!c_abi.ziggui_poll_event(ctx, &ev)); // drained

    // Zero-alloc quad emission via C ABI
    var quads: [64]c_abi.ZigguiQuad = undefined;
    const nq = c_abi.ziggui_emit_quads(ctx, &quads, quads.len);
    try std.testing.expect(nq >= 4);
}

test "C ABI struct sizes and ABI layout invariants" {
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(c_abi.ZigguiQuad));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(c_abi.ZigguiRect));
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(c_abi.ZigguiEvent));
}

test "C ABI null pointer safety on every exported function and invalid create args" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    try std.testing.expectEqual(@as(?*c_abi.ZigguiContext, null), c_abi.ziggui_create(0.0, 400.0, 1.0));
    try std.testing.expectEqual(@as(?*c_abi.ZigguiContext, null), c_abi.ziggui_create(400.0, -10.0, 1.0));
    try std.testing.expectEqual(@as(?*c_abi.ZigguiContext, null), c_abi.ziggui_create(400.0, 400.0, 0.0));
    try std.testing.expectEqual(@as(?*c_abi.ZigguiContext, null), c_abi.ziggui_create(nan, 400.0, 1.0));
    try std.testing.expectEqual(@as(?*c_abi.ZigguiContext, null), c_abi.ziggui_create(400.0, inf, 1.0));

    c_abi.ziggui_destroy(null);
    c_abi.ziggui_reset(null);
    c_abi.ziggui_set_viewport(null, 800.0, 600.0, 2.0);
    try std.testing.expectEqual(@as(u32, 0), c_abi.ziggui_add_vstack(null, 0, "r", 0.0, 0.0));
    try std.testing.expectEqual(@as(u32, 0), c_abi.ziggui_add_hstack(null, 0, "r", 0.0, 0.0));
    try std.testing.expectEqual(@as(u32, 0), c_abi.ziggui_add_card(null, 0, "c", "lbl", 40.0));
    try std.testing.expectEqual(@as(u32, 0), c_abi.ziggui_add_toggle(null, 0, "t", "lbl", 40.0, false));
    try std.testing.expectEqual(@as(u32, 0), c_abi.ziggui_add_slider(null, 0, "s", "lbl", 40.0, 0.5));
    c_abi.ziggui_layout(null);

    var r: c_abi.ZigguiRect = undefined;
    try std.testing.expect(!c_abi.ziggui_get_rect(null, 1, &r));

    c_abi.ziggui_pointer_down(null, 0, 10.0, 10.0, false);
    c_abi.ziggui_pointer_move(null, 0, 10.0, 10.0, false);
    c_abi.ziggui_pointer_up(null, 0, 10.0, 10.0, false);
    c_abi.ziggui_pointer_cancel(null, 0);
    c_abi.ziggui_wheel(null, 10.0, 10.0, 0.0, 1.0);
    c_abi.ziggui_key_down(null, 0, 0, 0, false);

    var ev: c_abi.ZigguiEvent = undefined;
    try std.testing.expect(!c_abi.ziggui_poll_event(null, &ev));
    try std.testing.expect(!c_abi.ziggui_needs_redraw(null));
    c_abi.ziggui_consume_redraw(null);

    var quads: [4]c_abi.ZigguiQuad = undefined;
    try std.testing.expectEqual(@as(usize, 0), c_abi.ziggui_emit_quads(null, &quads, quads.len));

    // Also verify non-null ctx with null output pointers / invalid args
    const ctx = c_abi.ziggui_create(320.0, 240.0, 1.0) orelse return error.CreateFailed;
    defer c_abi.ziggui_destroy(ctx);

    const root = c_abi.ziggui_add_vstack(ctx, 0, null, 8.0, 8.0);
    try std.testing.expect(root != 0);
    const card = c_abi.ziggui_add_card(ctx, root, null, null, 48.0);
    try std.testing.expect(card != 0);
    try std.testing.expectEqual(@as(u32, 0), c_abi.ziggui_add_toggle(ctx, 0xDEAD_BEEF, "bad", "bad", 48.0, false));
    c_abi.ziggui_layout(ctx);

    try std.testing.expect(!c_abi.ziggui_get_rect(ctx, card, null));
    try std.testing.expect(!c_abi.ziggui_get_rect(ctx, 0, &r));
    try std.testing.expectEqual(@as(usize, 0), c_abi.ziggui_emit_quads(ctx, null, 10));
    try std.testing.expectEqual(@as(usize, 0), c_abi.ziggui_emit_quads(ctx, &quads, 0));

    // Polling with null out_ev must not drop queued events
    try std.testing.expect(c_abi.ziggui_get_rect(ctx, card, &r));
    c_abi.ziggui_pointer_down(ctx, 0, r.x + r.w * 0.5, r.y + r.h * 0.5, true);
    c_abi.ziggui_pointer_up(ctx, 0, r.x + r.w * 0.5, r.y + r.h * 0.5, true);
    try std.testing.expect(!c_abi.ziggui_poll_event(ctx, null));
    try std.testing.expect(c_abi.ziggui_poll_event(ctx, &ev));
    try std.testing.expectEqual(c_abi.ZigguiEventKind.clicked, ev.kind);
    try std.testing.expectEqual(card, ev.node_id);
}

test "C ABI stack-string lifetime safety: mutating caller buffer after add_toggle preserves test_id" {
    const ctx = c_abi.ziggui_create(400.0, 400.0, 1.0) orelse return error.CreateFailed;
    defer c_abi.ziggui_destroy(ctx);

    var tid_buf = [_:0]u8{ 's', 't', 'a', 'c', 'k', '.', 't', 'o', 'g', 'g', 'l', 'e' };
    var lbl_buf = [_:0]u8{ 'M', 'y', ' ', 'T', 'o', 'g', 'g', 'l', 'e' };

    const root = c_abi.ziggui_add_vstack(ctx, 0, "root", 10.0, 8.0);
    const tog = c_abi.ziggui_add_toggle(ctx, root, &tid_buf, &lbl_buf, 48.0, false);
    try std.testing.expect(tog != 0);

    // Overwrite caller stack buffers with garbage immediately after add_toggle
    @memset(&tid_buf, 'X');
    @memset(&lbl_buf, 'Y');

    c_abi.ziggui_layout(ctx);
    var r: c_abi.ZigguiRect = undefined;
    try std.testing.expect(c_abi.ziggui_get_rect(ctx, tog, &r));

    c_abi.ziggui_pointer_down(ctx, 0, r.x + r.w * 0.5, r.y + r.h * 0.5, true);
    c_abi.ziggui_pointer_up(ctx, 0, r.x + r.w * 0.5, r.y + r.h * 0.5, true);

    var ev: c_abi.ZigguiEvent = undefined;
    try std.testing.expect(c_abi.ziggui_poll_event(ctx, &ev));
    try std.testing.expectEqual(c_abi.ZigguiEventKind.toggled, ev.kind);
    try std.testing.expectEqualStrings("stack.toggle", ev.test_id[0..ev.test_id_len]);
    try std.testing.expectEqual(@as(u8, 0), ev.test_id[ev.test_id_len]);
}

test "C ABI slider drag emits changed_f32 events and respects redraw lifecycle" {
    const ctx = c_abi.ziggui_create(400.0, 400.0, 2.0) orelse return error.CreateFailed;
    defer c_abi.ziggui_destroy(ctx);

    const root = c_abi.ziggui_add_vstack(ctx, 0, "root", 16.0, 12.0);
    const hrow = c_abi.ziggui_add_hstack(ctx, root, "row", 0.0, 8.0);
    const s1 = c_abi.ziggui_add_slider(ctx, hrow, "vol.slider", "Volume", 56.0, 0.1);
    try std.testing.expect(s1 != 0);

    c_abi.ziggui_layout(ctx);
    try std.testing.expect(c_abi.ziggui_needs_redraw(ctx));
    c_abi.ziggui_consume_redraw(ctx);
    try std.testing.expect(!c_abi.ziggui_needs_redraw(ctx));

    var r: c_abi.ZigguiRect = undefined;
    try std.testing.expect(c_abi.ziggui_get_rect(ctx, s1, &r));
    const cy = r.y + r.h * 0.5;

    // Drag slider from left edge toward right edge
    c_abi.ziggui_pointer_down(ctx, 1, r.x + 20.0, cy, true);
    c_abi.ziggui_pointer_move(ctx, 1, r.x + r.w * 0.75, cy, true);
    c_abi.ziggui_pointer_up(ctx, 1, r.x + r.w * 0.75, cy, true);

    try std.testing.expect(c_abi.ziggui_needs_redraw(ctx));

    var saw_changed = false;
    var last_val: f32 = 0.0;
    var ev: c_abi.ZigguiEvent = undefined;
    while (c_abi.ziggui_poll_event(ctx, &ev)) {
        if (ev.kind == .changed_f32 and ev.node_id == s1) {
            saw_changed = true;
            last_val = ev.f32_val;
            try std.testing.expectEqualStrings("vol.slider", ev.test_id[0..ev.test_id_len]);
        }
    }
    try std.testing.expect(saw_changed);
    try std.testing.expect(last_val > 0.65 and last_val <= 1.0);
}

test "C ABI ziggui_reset invalidates old u32 handles and clears queued events" {
    const ctx = c_abi.ziggui_create(400.0, 400.0, 1.0) orelse return error.CreateFailed;
    defer c_abi.ziggui_destroy(ctx);

    const old_root = c_abi.ziggui_add_vstack(ctx, 0, "old.root", 12.0, 8.0);
    const old_card = c_abi.ziggui_add_card(ctx, old_root, "old.card", "Old", 50.0);
    try std.testing.expect(old_root != 0 and old_card != 0);
    c_abi.ziggui_layout(ctx);

    var r: c_abi.ZigguiRect = undefined;
    try std.testing.expect(c_abi.ziggui_get_rect(ctx, old_card, &r));
    c_abi.ziggui_pointer_down(ctx, 0, r.x + r.w * 0.5, r.y + r.h * 0.5, true);
    c_abi.ziggui_pointer_up(ctx, 0, r.x + r.w * 0.5, r.y + r.h * 0.5, true);

    // Reset before polling queued event
    c_abi.ziggui_reset(ctx);

    // Old queued event must be cleared (no dangling string slice)
    var ev: c_abi.ZigguiEvent = undefined;
    try std.testing.expect(!c_abi.ziggui_poll_event(ctx, &ev));

    // Old handles must be rejected even after new nodes occupy the same indices
    const new_root = c_abi.ziggui_add_vstack(ctx, 0, "new.root", 12.0, 8.0);
    const new_card = c_abi.ziggui_add_card(ctx, new_root, "new.card", "New", 50.0);
    try std.testing.expect(new_root != 0 and new_card != 0);
    try std.testing.expect(new_root != old_root);
    try std.testing.expect(new_card != old_card);

    c_abi.ziggui_layout(ctx);
    try std.testing.expect(!c_abi.ziggui_get_rect(ctx, old_root, &r));
    try std.testing.expect(!c_abi.ziggui_get_rect(ctx, old_card, &r));
    try std.testing.expectEqual(@as(u32, 0), c_abi.ziggui_add_toggle(ctx, old_root, "bad", "Bad", 40.0, false));
    try std.testing.expect(c_abi.ziggui_get_rect(ctx, new_card, &r));

    // Viewport update and shortcut key check
    c_abi.ziggui_set_viewport(ctx, 600.0, 500.0, 1.5);
    c_abi.ziggui_key_down(ctx, 0, 1, 0, false); // escape + ctrl
    try std.testing.expect(c_abi.ziggui_poll_event(ctx, &ev));
    try std.testing.expectEqual(c_abi.ZigguiEventKind.shortcut, ev.kind);
    try std.testing.expectEqual(@as(u32, 0), ev.key);
    try std.testing.expectEqual(@as(u32, 1), ev.mods);
}

test "C header @cImport parity: ZigguiRect, ZigguiQuad, ZigguiEvent size, align, and offsets" {
    try std.testing.expectEqual(@sizeOf(c_abi.ZigguiRect), @sizeOf(c_hdr.ZigguiRect));
    try std.testing.expectEqual(@alignOf(c_abi.ZigguiRect), @alignOf(c_hdr.ZigguiRect));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiRect, "x"), @offsetOf(c_hdr.ZigguiRect, "x"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiRect, "y"), @offsetOf(c_hdr.ZigguiRect, "y"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiRect, "w"), @offsetOf(c_hdr.ZigguiRect, "w"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiRect, "h"), @offsetOf(c_hdr.ZigguiRect, "h"));

    try std.testing.expectEqual(@sizeOf(c_abi.ZigguiQuad), @sizeOf(c_hdr.ZigguiQuad));
    try std.testing.expectEqual(@alignOf(c_abi.ZigguiQuad), @alignOf(c_hdr.ZigguiQuad));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiQuad, "pos_size"), @offsetOf(c_hdr.ZigguiQuad, "pos_size"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiQuad, "uv_rect"), @offsetOf(c_hdr.ZigguiQuad, "uv_rect"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiQuad, "color"), @offsetOf(c_hdr.ZigguiQuad, "color"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiQuad, "border_color"), @offsetOf(c_hdr.ZigguiQuad, "border_color"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiQuad, "params"), @offsetOf(c_hdr.ZigguiQuad, "params"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiQuad, "clip_rect"), @offsetOf(c_hdr.ZigguiQuad, "clip_rect"));

    try std.testing.expectEqual(@sizeOf(c_abi.ZigguiEvent), @sizeOf(c_hdr.ZigguiEvent));
    try std.testing.expectEqual(@alignOf(c_abi.ZigguiEvent), @alignOf(c_hdr.ZigguiEvent));
    try std.testing.expectEqual(@sizeOf(c_abi.ZigguiEventKind), @sizeOf(c_hdr.ZigguiEventKind));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiEvent, "kind"), @offsetOf(c_hdr.ZigguiEvent, "kind"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiEvent, "node_id"), @offsetOf(c_hdr.ZigguiEvent, "node_id"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiEvent, "bool_val"), @offsetOf(c_hdr.ZigguiEvent, "bool_val"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiEvent, "_pad0"), @offsetOf(c_hdr.ZigguiEvent, "_pad0"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiEvent, "f32_val"), @offsetOf(c_hdr.ZigguiEvent, "f32_val"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiEvent, "dx"), @offsetOf(c_hdr.ZigguiEvent, "dx"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiEvent, "dy"), @offsetOf(c_hdr.ZigguiEvent, "dy"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiEvent, "key"), @offsetOf(c_hdr.ZigguiEvent, "key"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiEvent, "mods"), @offsetOf(c_hdr.ZigguiEvent, "mods"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiEvent, "codepoint"), @offsetOf(c_hdr.ZigguiEvent, "codepoint"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiEvent, "test_id"), @offsetOf(c_hdr.ZigguiEvent, "test_id"));
    try std.testing.expectEqual(@offsetOf(c_abi.ZigguiEvent, "test_id_len"), @offsetOf(c_hdr.ZigguiEvent, "test_id_len"));
}

test "C ABI rejects second root when root already exists" {
    const ctx = c_abi.ziggui_create(400.0, 400.0, 1.0) orelse return error.CreateFailed;
    defer c_abi.ziggui_destroy(ctx);

    const root1 = c_abi.ziggui_add_vstack(ctx, 0, "root1", 8.0, 8.0);
    try std.testing.expect(root1 != 0);

    // Second parent_id == 0 must return 0 instead of creating an unreachable orphan node
    try std.testing.expectEqual(@as(u32, 0), c_abi.ziggui_add_vstack(ctx, 0, "root2", 8.0, 8.0));
    try std.testing.expectEqual(@as(u32, 0), c_abi.ziggui_add_hstack(ctx, 0, "root3", 8.0, 8.0));
    try std.testing.expectEqual(@as(u32, 0), c_abi.ziggui_add_card(ctx, 0, "root4", "lbl", 40.0));
    try std.testing.expectEqual(@as(u32, 0), c_abi.ziggui_add_toggle(ctx, 0, "root5", "lbl", 40.0, false));
    try std.testing.expectEqual(@as(u32, 0), c_abi.ziggui_add_slider(ctx, 0, "root6", "lbl", 40.0, 0.5));

    // After reset, creating a new root succeeds again
    c_abi.ziggui_reset(ctx);
    const root_after_reset = c_abi.ziggui_add_hstack(ctx, 0, "new_root", 8.0, 8.0);
    try std.testing.expect(root_after_reset != 0);
}

test "C ABI ziggui_set_viewport ignores NaN, non-positive, and Inf values" {
    const ctx = c_abi.ziggui_create(400.0, 300.0, 2.0) orelse return error.CreateFailed;
    defer c_abi.ziggui_destroy(ctx);

    const root = c_abi.ziggui_add_vstack(ctx, 0, "root", 0.0, 0.0);
    const card = c_abi.ziggui_add_card(ctx, root, "card", "C", 50.0);
    c_abi.ziggui_layout(ctx);

    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    c_abi.ziggui_set_viewport(ctx, nan, 300.0, 2.0);
    c_abi.ziggui_set_viewport(ctx, 0.0, 300.0, 2.0);
    c_abi.ziggui_set_viewport(ctx, 400.0, -10.0, 2.0);
    c_abi.ziggui_set_viewport(ctx, 400.0, 300.0, inf);
    c_abi.ziggui_set_viewport(ctx, 400.0, 300.0, 0.0);

    c_abi.ziggui_layout(ctx);
    var r: c_abi.ZigguiRect = undefined;
    try std.testing.expect(c_abi.ziggui_get_rect(ctx, card, &r));
    try std.testing.expectEqual(@as(f32, 400.0), r.w);
    try std.testing.expectEqual(@as(f32, 50.0), r.h);
}

test "C ABI ziggui_key_down ignores invalid key > 11 and sanitizes surrogate/out-of-range codepoints" {
    const ctx = c_abi.ziggui_create(400.0, 300.0, 1.0) orelse return error.CreateFailed;
    defer c_abi.ziggui_destroy(ctx);

    var ev: c_abi.ZigguiEvent = undefined;

    // Invalid key > 11 must be ignored
    c_abi.ziggui_key_down(ctx, 12, 1, 'a', false);
    c_abi.ziggui_key_down(ctx, 9999, 1, 'a', false);
    try std.testing.expect(!c_abi.ziggui_poll_event(ctx, &ev));

    // UTF-16 surrogates (0xD800..0xDFFF) and > 0x10FFFF must sanitize to 0
    c_abi.ziggui_key_down(ctx, 11, 1, 0xD800, false); // char + ctrl
    try std.testing.expect(c_abi.ziggui_poll_event(ctx, &ev));
    try std.testing.expectEqual(c_abi.ZigguiEventKind.shortcut, ev.kind);
    try std.testing.expectEqual(@as(u32, 0), ev.codepoint);

    c_abi.ziggui_key_down(ctx, 11, 1, 0xDFFF, false);
    try std.testing.expect(c_abi.ziggui_poll_event(ctx, &ev));
    try std.testing.expectEqual(@as(u32, 0), ev.codepoint);

    c_abi.ziggui_key_down(ctx, 11, 1, 0x110000, false);
    try std.testing.expect(c_abi.ziggui_poll_event(ctx, &ev));
    try std.testing.expectEqual(@as(u32, 0), ev.codepoint);

    // Valid non-ASCII scalar value passes through untouched
    c_abi.ziggui_key_down(ctx, 11, 1, 0x1F680, false);
    try std.testing.expect(c_abi.ziggui_poll_event(ctx, &ev));
    try std.testing.expectEqual(@as(u32, 0x1F680), ev.codepoint);
}

test "C ABI copyTestId truncates multi-byte UTF-8 test_id on valid codepoint boundary <= 63 bytes" {
    const ctx = c_abi.ziggui_create(400.0, 400.0, 1.0) orelse return error.CreateFailed;
    defer c_abi.ziggui_destroy(ctx);

    // 61 ASCII 'a' + 4-byte emoji U+1F680 ("🚀") + "tail" = 69 bytes total.
    // Truncating at byte 63 would split the 4-byte emoji; boundary truncation must stop at 61.
    var long_tid: [70:0]u8 = undefined;
    @memset(long_tid[0..61], 'a');
    long_tid[61] = 0xF0;
    long_tid[62] = 0x9F;
    long_tid[63] = 0x9A;
    long_tid[64] = 0x80;
    @memcpy(long_tid[65..69], "tail");
    long_tid[69] = 0;

    const root = c_abi.ziggui_add_vstack(ctx, 0, "root", 8.0, 8.0);
    const card = c_abi.ziggui_add_card(ctx, root, &long_tid, "UTF8", 48.0);
    try std.testing.expect(card != 0);
    c_abi.ziggui_layout(ctx);

    var r: c_abi.ZigguiRect = undefined;
    try std.testing.expect(c_abi.ziggui_get_rect(ctx, card, &r));
    c_abi.ziggui_pointer_down(ctx, 0, r.x + r.w * 0.5, r.y + r.h * 0.5, true);
    c_abi.ziggui_pointer_up(ctx, 0, r.x + r.w * 0.5, r.y + r.h * 0.5, true);

    var ev: c_abi.ZigguiEvent = undefined;
    try std.testing.expect(c_abi.ziggui_poll_event(ctx, &ev));
    try std.testing.expectEqual(c_abi.ZigguiEventKind.clicked, ev.kind);
    try std.testing.expectEqual(@as(u32, 61), ev.test_id_len);
    try std.testing.expectEqual(@as(u8, 0), ev.test_id[ev.test_id_len]);
    try std.testing.expect(std.unicode.utf8ValidateSlice(ev.test_id[0..ev.test_id_len]));
}

test "C ABI ziggui_emit_quads safely clamps cap = maxInt(usize)" {
    const ctx = c_abi.ziggui_create(400.0, 400.0, 2.0) orelse return error.CreateFailed;
    defer c_abi.ziggui_destroy(ctx);

    const root = c_abi.ziggui_add_vstack(ctx, 0, "root", 16.0, 12.0);
    _ = c_abi.ziggui_add_toggle(ctx, root, "t1", "T1", 56.0, false);
    c_abi.ziggui_layout(ctx);

    var quads: [64]c_abi.ZigguiQuad = undefined;
    const nq = c_abi.ziggui_emit_quads(ctx, &quads, std.math.maxInt(usize));
    try std.testing.expect(nq >= 4 and nq < 64);
}
