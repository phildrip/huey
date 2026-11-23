const std = @import("std");
const builtin = @import("builtin");
const overlay = @import("overlay.zig");
const core = @import("core.zig");
const wayland = @import("wayland.zig");

test "placePopup: bottom_start fits cleanly inside viewport without flip" {
    const res = overlay.placePopup(.{
        .anchor = .{ .x = 100, .y = 40, .w = 80, .h = 28 },
        .width = 160,
        .height = 120,
        .placement = .bottom_start,
        .gap = 4,
    }, 1280, 720);

    try std.testing.expectApproxEqAbs(@as(f32, 100), res.rect.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 72), res.rect.y, 0.01);
    try std.testing.expect(!res.flipped_x);
    try std.testing.expect(!res.flipped_y);
}

test "placePopup: flips vertically when overflowing bottom edge" {
    const res = overlay.placePopup(.{
        .anchor = .{ .x = 100, .y = 650, .w = 80, .h = 30 },
        .width = 160,
        .height = 120,
        .placement = .bottom_start,
        .gap = 4,
    }, 1280, 720);

    // Flips above anchor: 650 - 4 - 120 = 526
    try std.testing.expect(res.flipped_y);
    try std.testing.expectApproxEqAbs(@as(f32, 526), res.rect.y, 0.01);
    try std.testing.expect(res.rect.y >= 0 and res.rect.y + res.rect.h <= 720);
}

test "placePopup: flips horizontally when overflowing right edge" {
    const res = overlay.placePopup(.{
        .anchor = .{ .x = 1200, .y = 32, .w = 60, .h = 24 },
        .width = 200,
        .height = 100,
        .placement = .bottom_start,
        .gap = 4,
    }, 1280, 720);

    // Flips to align right edge with anchor right edge (1260 - 200 = 1060)
    try std.testing.expect(res.flipped_x);
    try std.testing.expectApproxEqAbs(@as(f32, 1060), res.rect.x, 0.01);
    try std.testing.expect(res.rect.x >= 0 and res.rect.x + res.rect.w <= 1280);
}

test "placePopup: clamps oversize popup safely and handles NaN" {
    const res = overlay.placePopup(.{
        .anchor = .{ .x = std.math.nan(f32), .y = 50, .w = 20, .h = 20 },
        .width = 5000,
        .height = 3000,
        .placement = .bottom_start,
    }, 800, 600);

    try std.testing.expect(!std.math.isNan(res.rect.x));
    try std.testing.expect(res.rect.x >= 0);
    try std.testing.expect(res.rect.y >= 0);
    try std.testing.expect(res.rect.w <= 800);
    try std.testing.expect(res.rect.h <= 600);
    try std.testing.expect(res.clamped);
}

test "OverlayManager: portal quads escape parent scissor and dismiss on outside click" {
    var mgr = overlay.OverlayManager.init();
    const id = try mgr.open(.{
        .anchor = .{ .x = 20, .y = 28, .w = 60, .h = 24 },
        .width = 180,
        .height = 140,
        .placement = .bottom_start,
        .modal = true,
        .bg_color = .{ 0.23, 0.26, 0.32, 1.0 },
        .backdrop_color = .{ 0.0, 0.0, 0.0, 0.45 },
    }, 1280, 720);

    try std.testing.expectEqual(@as(usize, 1), mgr.activeCount());
    try std.testing.expect(mgr.isOpen(id));

    var quads: [16]core.QuadInstance = undefined;
    const count = mgr.emitOverlayQuads(1280, 720, &quads);
    // Backdrop quad + popup surface quad
    try std.testing.expectEqual(@as(usize, 2), count);
    // Both portal quads must have full-viewport clip_rect escaping any parent scissor!
    try std.testing.expectEqual([4]f32{ 0, 0, 1280, 720 }, quads[0].clip_rect);
    try std.testing.expectEqual([4]f32{ 0, 0, 1280, 720 }, quads[1].clip_rect);

    // Click inside popup keeps it open
    try std.testing.expect(!mgr.handleOutsideClick(50, 80));
    try std.testing.expectEqual(@as(usize, 1), mgr.activeCount());

    // Click outside popup dismisses top modal overlay
    try std.testing.expect(mgr.handleOutsideClick(900, 500));
    try std.testing.expectEqual(@as(usize, 0), mgr.activeCount());
}

test "XdgPositioner: encodes valid Wayland xdg_positioner & layer_surface.get_popup wire frames" {
    var buf: [512]u8 = undefined;
    var enc = wayland.WireEncoder.init(&buf);

    try overlay.encodeXdgPositioner(&enc, 42, .{
        .width = 200,
        .height = 160,
        .anchor_x = 12,
        .anchor_y = 0,
        .anchor_w = 80,
        .anchor_h = 28,
        .anchor = .bottom_left,
        .gravity = .bottom_right,
        .constraint_adjustment = .{ .flip_x = true, .flip_y = true, .slide_x = true },
        .offset_x = 0,
        .offset_y = 4,
    });
    try overlay.encodeLayerGetPopup(&enc, 10, 43);

    const bytes = enc.written();
    try std.testing.expect(bytes.len >= 8 * 7);
    try std.testing.expectEqual(@as(usize, 0), bytes.len % 4);

    // Verify first message is set_size on object_id=42, opcode=1
    var dec = try wayland.WireDecoder.init(bytes);
    try std.testing.expectEqual(@as(u32, 42), dec.object_id);
    try std.testing.expectEqual(@as(u16, 1), dec.opcode);
    try std.testing.expectEqual(@as(i32, 200), try dec.readI32());
    try std.testing.expectEqual(@as(i32, 160), try dec.readI32());
}

test "H1: anchor overhanging edge must not flip when flip worsens overflow" {
    // 1. bottom_start alignment X: anchor overhangs right; flipping to end pushes further right.
    const r1 = overlay.placePopup(.{
        .anchor = .{ .x = 10, .y = 10, .w = 150, .h = 20 },
        .width = 120,
        .height = 40,
        .placement = .bottom_start,
        .slide_x = false,
    }, 100, 200);
    try std.testing.expect(!r1.flipped_x);
    try std.testing.expectApproxEqAbs(@as(f32, 10), r1.rect.x, 0.01);

    // 2. right_start alignment Y: anchor overhangs bottom; flipping to end pushes further down.
    const r2 = overlay.placePopup(.{
        .anchor = .{ .x = 10, .y = 10, .w = 20, .h = 150 },
        .width = 40,
        .height = 120,
        .placement = .right_start,
        .slide_y = false,
    }, 400, 100);
    try std.testing.expect(!r2.flipped_y);
    try std.testing.expectApproxEqAbs(@as(f32, 10), r2.rect.y, 0.01);

    // 3. bottom_start primary Y: anchor overhangs top; flipping above worsens top overflow.
    const r3 = overlay.placePopup(.{
        .anchor = .{ .x = 20, .y = -50, .w = 40, .h = 80 },
        .width = 100,
        .height = 90,
        .placement = .bottom_start,
        .gap = 4,
        .slide_y = false,
    }, 400, 100);
    try std.testing.expect(!r3.flipped_y);
    try std.testing.expectApproxEqAbs(@as(f32, 34), r3.rect.y, 0.01);
}

test "H2: opposite-edge overflow flips cleanly inside viewport" {
    // 1. bottom_start overflowing left edge flips to end alignment inside viewport.
    const r1 = overlay.placePopup(.{
        .anchor = .{ .x = -100, .y = 20, .w = 250, .h = 20 },
        .width = 100,
        .height = 50,
        .placement = .bottom_start,
        .slide_x = false,
    }, 800, 600);
    try std.testing.expect(r1.flipped_x);
    try std.testing.expectApproxEqAbs(@as(f32, 50), r1.rect.x, 0.01);

    // 2. bottom_end overflowing right edge flips to start alignment inside viewport.
    const r2 = overlay.placePopup(.{
        .anchor = .{ .x = 650, .y = 20, .w = 250, .h = 20 },
        .width = 100,
        .height = 50,
        .placement = .bottom_end,
        .slide_x = false,
    }, 800, 600);
    try std.testing.expect(r2.flipped_x);
    try std.testing.expectApproxEqAbs(@as(f32, 650), r2.rect.x, 0.01);

    // 3. right_start overflowing top edge flips alignment inside viewport.
    const r3 = overlay.placePopup(.{
        .anchor = .{ .x = 20, .y = -100, .w = 20, .h = 250 },
        .width = 100,
        .height = 100,
        .placement = .right_start,
        .slide_y = false,
    }, 800, 600);
    try std.testing.expect(r3.flipped_y);
    try std.testing.expectApproxEqAbs(@as(f32, 50), r3.rect.y, 0.01);
}

test "H3: emitOverlayQuads emits modal backdrop and surface atomically" {
    var mgr = overlay.OverlayManager.init();
    const spec: overlay.PopupSpec = .{
        .anchor = .{ .x = 10, .y = 10, .w = 40, .h = 20 },
        .width = 120,
        .height = 80,
        .modal = true,
        .bg_color = .{ 0.2, 0.3, 0.4, 1.0 },
        .backdrop_color = .{ 0.0, 0.0, 0.0, 0.5 },
    };
    _ = try mgr.open(spec, 800, 600);
    _ = try mgr.open(spec, 800, 600);

    var q0: [0]core.QuadInstance = undefined;
    try std.testing.expectEqual(@as(usize, 0), mgr.emitOverlayQuads(800, 600, &q0));

    var q1: [1]core.QuadInstance = undefined;
    try std.testing.expectEqual(@as(usize, 0), mgr.emitOverlayQuads(800, 600, &q1));

    var q3: [3]core.QuadInstance = undefined;
    try std.testing.expectEqual(@as(usize, 2), mgr.emitOverlayQuads(800, 600, &q3));
    try std.testing.expectEqual([4]f32{ 0, 0, 800, 600 }, q3[0].pos_size);
    try std.testing.expectEqual(@as(f32, 120), q3[1].pos_size[2]);
}

test "H4 & L11: handleOutsideClick ignores empty/non-modal stacks and uses f64 bounds" {
    var mgr = overlay.OverlayManager.init();
    try std.testing.expect(!mgr.handleOutsideClick(10, 10));

    _ = try mgr.open(.{
        .anchor = .{ .x = 20, .y = 20, .w = 40, .h = 20 },
        .width = 100,
        .height = 60,
        .modal = false,
    }, 800, 600);
    try std.testing.expect(!mgr.handleOutsideClick(500, 500));
    try std.testing.expectEqual(@as(usize, 1), mgr.activeCount());

    mgr.closeAll();

    // f64 bounds check at large coordinate where f32 addition loses 1.0 precision
    _ = try mgr.open(.{
        .anchor = .{ .x = 16777216.0, .y = 10, .w = 10, .h = 10 },
        .width = 1.0,
        .height = 20.0,
        .modal = true,
        .slide_x = false,
    }, 20000000.0, 600);
    try std.testing.expect(!mgr.handleOutsideClick(16777217.0, 25.0));
    try std.testing.expectEqual(@as(usize, 1), mgr.activeCount());
    try std.testing.expect(mgr.handleOutsideClick(16777218.0, 25.0));
    try std.testing.expectEqual(@as(usize, 0), mgr.activeCount());
}

test "M5: zero, negative, and NaN viewports return zero rect without flipping" {
    const cases = [_][2]f32{
        .{ 0.0, 600.0 },
        .{ 800.0, 0.0 },
        .{ -100.0, 600.0 },
        .{ 800.0, -50.0 },
        .{ std.math.nan(f32), 600.0 },
        .{ 800.0, std.math.nan(f32) },
    };
    for (cases) |vp| {
        const res = overlay.placePopup(.{
            .anchor = .{ .x = 10, .y = 10, .w = 20, .h = 20 },
            .width = 100,
            .height = 80,
            .placement = .bottom_start,
        }, vp[0], vp[1]);
        try std.testing.expectEqual(core.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, res.rect);
        try std.testing.expect(!res.flipped_x);
        try std.testing.expect(!res.flipped_y);
        try std.testing.expect(res.clamped);
    }

    const zero_size = overlay.placePopup(.{
        .width = 0,
        .height = 0,
    }, 0, 0);
    try std.testing.expect(!zero_size.clamped);
    try std.testing.expectEqual(core.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, zero_size.rect);
}

test "M6 & L11: f64->f32 round-to-even clamp keeps slid popup within viewport and canonicalizes -0.0" {
    const r1 = overlay.placePopup(.{
        .anchor = .{ .x = 2000, .y = 2000, .w = 10, .h = 10 },
        .width = 1e-5,
        .height = 1e-5,
        .placement = .bottom_start,
    }, 1000.0, 1000.0);
    try std.testing.expect(@as(f64, r1.rect.x) + @as(f64, r1.rect.w) <= 1000.0);
    try std.testing.expect(@as(f64, r1.rect.y) + @as(f64, r1.rect.h) <= 1000.0);

    const r2 = overlay.placePopup(.{
        .anchor = .{ .x = 20000000.0, .y = 20000000.0, .w = 10, .h = 10 },
        .width = 1.0,
        .height = 1.0,
        .placement = .bottom_start,
    }, 16777220.0, 16777220.0);
    try std.testing.expect(@as(f64, r2.rect.x) + @as(f64, r2.rect.w) <= 16777220.0);
    try std.testing.expect(@as(f64, r2.rect.y) + @as(f64, r2.rect.h) <= 16777220.0);

    // -0.0 input canonicalizes to +0.0
    const neg_zero: f32 = -0.0;
    const rz = overlay.placePopup(.{
        .anchor = .{ .x = neg_zero, .y = neg_zero, .w = neg_zero, .h = neg_zero },
        .width = neg_zero,
        .height = neg_zero,
    }, 800.0, 600.0);
    try std.testing.expect(!std.math.signbit(rz.rect.x));
    try std.testing.expect(!std.math.signbit(rz.rect.y));
    try std.testing.expect(!std.math.signbit(rz.rect.w));
    try std.testing.expect(!std.math.signbit(rz.rect.h));
}

test "M7: emitOverlayQuadsScaled handles invalid viewports, skips zero-area entries, and scales by 2.0" {
    var mgr = overlay.OverlayManager.init();
    _ = try mgr.open(.{
        .anchor = .{ .x = 10, .y = 20, .w = 30, .h = 10 },
        .width = 0,
        .height = 50,
        .modal = true,
        .backdrop_color = .{ 0, 0, 0, 0.5 },
    }, 800, 600);
    _ = try mgr.open(.{
        .anchor = .{ .x = 50, .y = 40, .w = 60, .h = 20 },
        .width = 120,
        .height = 80,
        .gap = 4,
        .modal = true,
        .bg_color = .{ 0.2, 0.3, 0.4, 1.0 },
        .backdrop_color = .{ 0.0, 0.0, 0.0, 0.5 },
        .corner_radius = 6,
        .border_width = 2,
        .shadow_blur = 8,
    }, 800, 600);

    var quads: [8]core.QuadInstance = undefined;
    try std.testing.expectEqual(@as(usize, 0), mgr.emitOverlayQuadsScaled(0, 600, 2.0, &quads));
    try std.testing.expectEqual(@as(usize, 0), mgr.emitOverlayQuadsScaled(800, std.math.nan(f32), 2.0, &quads));
    try std.testing.expectEqual(@as(usize, 0), mgr.emitOverlayQuadsScaled(800, 600, 0.0, &quads));
    try std.testing.expectEqual(@as(usize, 0), mgr.emitOverlayQuadsScaled(800, 600, std.math.nan(f32), &quads));

    // Zero-area first entry is skipped; second entry emits backdrop + scaled surface (2 quads)
    const count = mgr.emitOverlayQuadsScaled(800, 600, 2.0, &quads);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual([4]f32{ 0, 0, 1600, 1200 }, quads[0].pos_size);
    try std.testing.expectEqual([4]f32{ 0, 0, 1600, 1200 }, quads[0].clip_rect);
    // y = 40 + 20 + 4 = 64 -> scaled by 2.0 = 128
    try std.testing.expectEqual([4]f32{ 100, 128, 240, 160 }, quads[1].pos_size);
    try std.testing.expectEqual([4]f32{ 12, 4, 16, 0 }, quads[1].params);
    try std.testing.expectEqual([4]f32{ 0, 0, 1600, 1200 }, quads[1].clip_rect);
}

test "M8 & L9-L12: WireEncoder open-message guard, rollback, object IDs, _pad mask, and next_id wrap" {
    const valid_spec: overlay.XdgPositionerSpec = .{
        .width = 100,
        .height = 80,
        .anchor_x = 10,
        .anchor_y = 20,
        .anchor_w = 40,
        .anchor_h = 20,
        .constraint_adjustment = .{ .slide_x = true, .flip_y = true, ._pad = 0x12345 },
    };

    // M8: unfinished message triggers error.MessageAlreadyOpen without corrupting encoder
    var buf: [256]u8 = undefined;
    @memset(&buf, 0xAA);
    var enc = wayland.WireEncoder.init(&buf);
    try enc.writeU32(0x11223344);
    const saved_pos = enc.pos;
    const saved_start = enc.msg_start;
    const saved_open = enc.msg_open;
    try std.testing.expectError(error.MessageAlreadyOpen, overlay.encodeXdgPositioner(&enc, 42, valid_spec));
    try std.testing.expectError(error.MessageAlreadyOpen, overlay.encodeLayerGetPopup(&enc, 10, 43));
    try std.testing.expectEqual(saved_pos, enc.pos);
    try std.testing.expectEqual(saved_start, enc.msg_start);
    try std.testing.expectEqual(saved_open, enc.msg_open);
    try std.testing.expectEqual(@as(u32, 0x11223344), std.mem.readInt(u32, buf[8..12], builtin.cpu.arch.endian()));

    // L9: BufferTooSmall rollback at lengths 0, 64, 91
    const rollback_lens = [_]usize{ 0, 64, 91 };
    for (rollback_lens) |len| {
        var small_buf: [128]u8 = undefined;
        var small_enc = wayland.WireEncoder.init(small_buf[0..len]);
        try std.testing.expectError(error.BufferTooSmall, overlay.encodeXdgPositioner(&small_enc, 42, valid_spec));
        try std.testing.expectEqual(@as(usize, 0), small_enc.written().len);
        try std.testing.expectEqual(@as(usize, 8), small_enc.pos);
        try std.testing.expectEqual(@as(usize, 0), small_enc.msg_start);
        try std.testing.expect(small_enc.msg_open);
    }

    // InvalidObjectId for 0 and layer_surface_id == popup_id
    var ok_enc = wayland.WireEncoder.init(&buf);
    try std.testing.expectError(error.InvalidObjectId, overlay.encodeXdgPositioner(&ok_enc, 0, valid_spec));
    try std.testing.expectError(error.InvalidObjectId, overlay.encodeLayerGetPopup(&ok_enc, 0, 2));
    try std.testing.expectError(error.InvalidObjectId, overlay.encodeLayerGetPopup(&ok_enc, 2, 0));
    try std.testing.expectError(error.InvalidObjectId, overlay.encodeLayerGetPopup(&ok_enc, 7, 7));

    // L10: _pad bits masked out of set_constraint_adjustment (slide_x=1 | flip_y=8 = 9)
    try overlay.encodeXdgPositioner(&ok_enc, 42, valid_spec);
    const wire = ok_enc.written();
    var off: usize = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const d = try wayland.WireDecoder.init(wire[off..]);
        off += d.size;
    }
    var d_adj = try wayland.WireDecoder.init(wire[off..]);
    try std.testing.expectEqual(@as(u16, 5), d_adj.opcode);
    try std.testing.expectEqual(@as(u32, 9), try d_adj.readU32());

    // L12: next_id wraparound skips 0 and active IDs
    var mgr = overlay.OverlayManager.init();
    mgr.next_id = std.math.maxInt(u32);
    const id_max = try mgr.open(.{ .width = 50, .height = 50 }, 800, 600);
    const id_wrap1 = try mgr.open(.{ .width = 50, .height = 50 }, 800, 600);
    try std.testing.expectEqual(std.math.maxInt(u32), id_max);
    try std.testing.expectEqual(@as(u32, 1), id_wrap1);
    mgr.next_id = 1;
    const id_wrap2 = try mgr.open(.{ .width = 50, .height = 50 }, 800, 600);
    try std.testing.expectEqual(@as(u32, 2), id_wrap2);
}
