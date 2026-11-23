const std = @import("std");
const core = @import("core.zig");
const wearos = @import("wearos.zig");

test "curvedScrollMetrics: center is full scale/alpha, poles shrink and fade smoothly" {
    const center = wearos.curvedScrollMetrics(116.5, 116.5, 116.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), center.scale, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), center.alpha, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 233.0), center.chord_width, 0.1);

    const mid = wearos.curvedScrollMetrics(116.5 + 58.25, 116.5, 116.5);
    try std.testing.expect(mid.scale < 1.0 and mid.scale > 0.85);
    try std.testing.expect(mid.alpha < 1.0 and mid.alpha > 0.85);
    try std.testing.expect(mid.chord_width < 233.0 and mid.chord_width > 180.0);

    const pole = wearos.curvedScrollMetrics(233.0, 116.5, 116.5);
    try std.testing.expect(pole.scale <= 0.80 and pole.scale >= 0.70);
    try std.testing.expect(pole.alpha <= 0.50 and pole.alpha >= 0.35);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pole.chord_width, 0.01);
}

test "curvedScrollMetrics: handles NaN/Inf/zero radius safely" {
    const z = wearos.curvedScrollMetrics(std.math.nan(f32), 116.5, 0.0);
    try std.testing.expectEqual(@as(f32, 1.0), z.scale);
    try std.testing.expectEqual(@as(f32, 1.0), z.alpha);
}

test "applyCurvedEdgeTransform: scales and fades off-center quads around viewport X center" {
    var quads = [_]core.QuadInstance{
        // Centered quad: unchanged
        .{
            .pos_size = .{ 100, 200, 266, 66 }, // cy = 233 == vp_cy
            .color = core.Nord.polar_night_1,
            .border_color = core.Nord.frost_1,
            .params = .{ 16, 2, 0, 0 },
            .clip_rect = .{ 0, 0, 466, 466 },
        },
        // Near-bottom quad: shrunk horizontally & faded
        .{
            .pos_size = .{ 100, 380, 266, 66 }, // cy = 413 (near bottom pole)
            .color = core.Nord.polar_night_1,
            .border_color = core.Nord.frost_1,
            .params = .{ 16, 2, 0, 0 },
            .clip_rect = .{ 0, 0, 466, 466 },
        },
    };
    wearos.applyCurvedEdgeTransform(&quads, 233.0, 233.0, 233.0);

    // Center quad untouched
    try std.testing.expectApproxEqAbs(@as(f32, 266.0), quads[0].pos_size[2], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), quads[0].color[3], 0.01);

    // Near-bottom quad scaled down and still centered around x=233
    try std.testing.expect(quads[1].pos_size[2] < 245.0);
    const new_cx = quads[1].pos_size[0] + quads[1].pos_size[2] * 0.5;
    try std.testing.expectApproxEqAbs(@as(f32, 233.0), new_cx, 0.1);
    try std.testing.expect(quads[1].color[3] < 0.9);
}

test "radialPosition: places items at 12, 3, 6, 9 o'clock around circular bezel" {
    // 0 deg = 12 o'clock (top), clockwise
    const top = wearos.radialPosition(116.5, 116.5, 90.0, 0.0, 20.0, 20.0);
    try std.testing.expectApproxEqAbs(@as(f32, 106.5), top.x, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 16.5), top.y, 0.05);

    const right = wearos.radialPosition(116.5, 116.5, 90.0, 90.0, 20.0, 20.0);
    try std.testing.expectApproxEqAbs(@as(f32, 196.5), right.x, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 106.5), right.y, 0.05);
}

test "roundClipAlpha: 1.0 inside circle, 0.0 outside, smooth AA at boundary" {
    try std.testing.expectEqual(@as(f32, 1.0), wearos.roundClipAlpha(233.0, 233.0, 233.0, 233.0, 233.0));
    try std.testing.expectEqual(@as(f32, 0.0), wearos.roundClipAlpha(0.0, 0.0, 233.0, 233.0, 233.0));
    const edge = wearos.roundClipAlpha(466.0, 233.0, 233.0, 233.0, 233.0);
    try std.testing.expect(edge > 0.4 and edge < 0.6);
}

test "emitCurvedScrollArc: emits circular dot/pill track along right bezel" {
    var quads: [32]core.QuadInstance = undefined;
    const n = wearos.emitCurvedScrollArc(
        &quads,
        233.0,
        233.0,
        220.0,
        0.5, // 50% scrolled
        6.0,
        core.Nord.frost_1,
        .{ 0, 0, 466, 466 },
    );
    try std.testing.expect(n >= 4 and n <= 24);
    for (quads[0..n]) |q| {
        try std.testing.expect(q.pos_size[2] > 0 and q.pos_size[3] > 0);
        // All arc dots lie on the right half of the circular watch
        try std.testing.expect(q.pos_size[0] > 233.0);
    }
}

test "applyCurvedGroupTransform: keeps card frame, child button, and text glyphs rigidly contained with baseline alignment and clip_rect scaling" {
    // Card at bottom pole: y in [300, 440], group_cy = 370 (viewport 466x466, vp_cx=233, vp_cy=233, r=233)
    const group_cy: f32 = 370.0;
    const vp_cx: f32 = 233.0;
    const vp_cy: f32 = 233.0;
    const radius: f32 = 233.0;
    const m = wearos.curvedScrollMetrics(group_cy, vp_cy, radius);

    var quads = [_]core.QuadInstance{
        // [0] Full-screen background quad (should be skipped)
        .{
            .pos_size = .{ 0.0, 0.0, 466.0, 466.0 },
            .color = .{ 0.0, 0.0, 0.0, 1.0 },
            .border_color = core.Nord.transparent,
            .params = .{ 0.0, 0.0, 0.0, 0.0 },
            .clip_rect = .{ 0.0, 0.0, 466.0, 466.0 },
        },
        // [1] Card frame with full-viewport clip_rect (clip_rect preserved)
        .{
            .pos_size = .{ 68.0, 300.0, 330.0, 140.0 },
            .color = core.Nord.polar_night_1,
            .border_color = core.Nord.frost_1,
            .params = .{ 18.0, 2.0, 6.0, 0.0 },
            .clip_rect = .{ 0.0, 0.0, 466.0, 466.0 },
        },
        // [2] Child button inside card with sub-viewport clip_rect (clip_rect scaled)
        .{
            .pos_size = .{ 88.0, 380.0, 140.0, 44.0 },
            .color = core.Nord.polar_night_2,
            .border_color = core.Nord.frost_1,
            .params = .{ 22.0, 1.5, 0.0, 0.0 },
            .clip_rect = .{ 78.0, 310.0, 388.0, 430.0 },
        },
        // [3] Text glyph 'T' (tall) on baseline y_base = 410
        .{
            .pos_size = .{ 120.0, 392.0, 10.0, 18.0 }, // bottom = 410
            .color = core.Nord.snow_storm_2,
            .border_color = core.Nord.transparent,
            .params = .{ 0.0, 0.0, 0.0, 1.0 }, // glyph mode > 0.5
            .clip_rect = .{ 78.0, 310.0, 388.0, 430.0 },
        },
        // [4] Text glyph 'a' (short) on same baseline y_base = 410
        .{
            .pos_size = .{ 132.0, 398.0, 9.0, 12.0 }, // bottom = 410
            .color = core.Nord.snow_storm_2,
            .border_color = core.Nord.transparent,
            .params = .{ 0.0, 0.0, 0.0, 1.0 }, // glyph mode > 0.5
            .clip_rect = .{ 78.0, 310.0, 388.0, 430.0 },
        },
    };

    wearos.applyCurvedGroupTransform(&quads, group_cy, vp_cx, vp_cy, radius);

    // Background untouched
    try std.testing.expectApproxEqAbs(@as(f32, 466.0), quads[0].pos_size[2], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), quads[0].color[3], 0.01);

    // Card frame and child button share identical scale and alpha
    try std.testing.expectApproxEqAbs(330.0 * m.scale, quads[1].pos_size[2], 0.01);
    try std.testing.expectApproxEqAbs(140.0 * m.scale, quads[1].pos_size[3], 0.01);
    try std.testing.expectApproxEqAbs(140.0 * m.scale, quads[2].pos_size[2], 0.01);
    try std.testing.expectApproxEqAbs(44.0 * m.scale, quads[2].pos_size[3], 0.01);
    try std.testing.expectApproxEqAbs(m.alpha, quads[1].color[3], 0.001);
    try std.testing.expectApproxEqAbs(m.alpha, quads[2].color[3], 0.001);
    try std.testing.expectApproxEqAbs(m.alpha, quads[3].color[3], 0.001);
    try std.testing.expectApproxEqAbs(m.alpha, quads[4].color[3], 0.001);

    // Child button remains strictly contained within card frame with exact scaled padding (20 * m.scale)
    const card_x0 = quads[1].pos_size[0];
    const card_y0 = quads[1].pos_size[1];
    const card_x1 = card_x0 + quads[1].pos_size[2];
    const card_y1 = card_y0 + quads[1].pos_size[3];
    const btn_x0 = quads[2].pos_size[0];
    const btn_y0 = quads[2].pos_size[1];
    const btn_x1 = btn_x0 + quads[2].pos_size[2];
    const btn_y1 = btn_y0 + quads[2].pos_size[3];
    try std.testing.expect(btn_x0 >= card_x0 and btn_x1 <= card_x1);
    try std.testing.expect(btn_y0 >= card_y0 and btn_y1 <= card_y1);
    try std.testing.expectApproxEqAbs(20.0 * m.scale, btn_x0 - card_x0, 0.01);
    try std.testing.expectApproxEqAbs(16.0 * m.scale, card_y1 - btn_y1, 0.01);

    // Text glyphs 'T' and 'a' preserve exact baseline alignment (identical bottom y)
    const base_t = quads[3].pos_size[1] + quads[3].pos_size[3];
    const base_a = quads[4].pos_size[1] + quads[4].pos_size[3];
    try std.testing.expectApproxEqAbs(base_t, base_a, 0.001);
    try std.testing.expect(quads[3].pos_size[1] >= btn_y0 and base_t <= btn_y1);

    // H2: Full-viewport clip_rect on card is preserved; sub-viewport clip_rect on child is scaled
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), quads[1].clip_rect[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 466.0), quads[1].clip_rect[2], 0.01);
    const expected_clip_x0 = vp_cx + (78.0 - vp_cx) * m.scale;
    const expected_clip_y0 = group_cy + (310.0 - group_cy) * m.scale;
    const expected_clip_x1 = vp_cx + (388.0 - vp_cx) * m.scale;
    const expected_clip_y1 = group_cy + (430.0 - group_cy) * m.scale;
    try std.testing.expectApproxEqAbs(expected_clip_x0, quads[2].clip_rect[0], 0.01);
    try std.testing.expectApproxEqAbs(expected_clip_y0, quads[2].clip_rect[1], 0.01);
    try std.testing.expectApproxEqAbs(expected_clip_x1, quads[2].clip_rect[2], 0.01);
    try std.testing.expectApproxEqAbs(expected_clip_y1, quads[2].clip_rect[3], 0.01);
}

test "applyCurvedQuadWithMetrics: scales shadow_blur (params[2]) and sanitizes non-finite/out-of-range alpha & params" {
    const m = wearos.curvedScrollMetrics(400.0, 233.0, 233.0);

    var sdf_quad = core.QuadInstance{
        .pos_size = .{ 100.0, 360.0, 200.0, 80.0 },
        .color = .{ 0.2, 0.3, 0.4, 2.5 }, // out-of-range alpha > 1.0
        .border_color = .{ 0.5, 0.6, 0.7, std.math.nan(f32) }, // NaN alpha
        .params = .{ 16.0, 2.0, 8.0, 0.0 }, // corner_radius, border_width, shadow_blur, mode=SDF
        .clip_rect = .{ 0.0, 0.0, 466.0, 466.0 },
    };
    wearos.applyCurvedQuadWithMetrics(&sdf_quad, 400.0, 233.0, m);

    try std.testing.expectApproxEqAbs(16.0 * m.scale, sdf_quad.params[0], 0.001);
    try std.testing.expectApproxEqAbs(2.0 * m.scale, sdf_quad.params[1], 0.001);
    try std.testing.expectApproxEqAbs(8.0 * m.scale, sdf_quad.params[2], 0.001);
    try std.testing.expectApproxEqAbs(1.0 * m.alpha, sdf_quad.color[3], 0.001);
    try std.testing.expectEqual(@as(f32, 0.0), sdf_quad.border_color[3]);

    // Negative/non-finite params[0..2] and negative alpha sanitized to 0; glyph params untouched
    var bad_sdf = core.QuadInstance{
        .pos_size = .{ 100.0, 360.0, 200.0, 80.0 },
        .color = .{ 0.2, 0.3, 0.4, -0.5 },
        .border_color = .{ 0.5, 0.6, 0.7, std.math.inf(f32) },
        .params = .{ -4.0, std.math.nan(f32), -8.0, 0.0 },
        .clip_rect = .{ 0.0, 0.0, 466.0, 466.0 },
    };
    wearos.applyCurvedQuadWithMetrics(&bad_sdf, 400.0, 233.0, m);
    try std.testing.expectEqual(@as(f32, 0.0), bad_sdf.params[0]);
    try std.testing.expectEqual(@as(f32, 0.0), bad_sdf.params[1]);
    try std.testing.expectEqual(@as(f32, 0.0), bad_sdf.params[2]);
    try std.testing.expectEqual(@as(f32, 0.0), bad_sdf.color[3]);
    try std.testing.expectEqual(@as(f32, 0.0), bad_sdf.border_color[3]);

    var glyph = core.QuadInstance{
        .pos_size = .{ 120.0, 390.0, 12.0, 16.0 },
        .color = .{ 1.0, 1.0, 1.0, 0.8 },
        .border_color = core.Nord.transparent,
        .params = .{ 0.0, 0.0, 0.0, 1.0 },
        .clip_rect = .{ 0.0, 0.0, 466.0, 466.0 },
    };
    wearos.applyCurvedQuadWithMetrics(&glyph, 400.0, 233.0, m);
    try std.testing.expectEqual(@as(f32, 1.0), glyph.params[3]);
    try std.testing.expectApproxEqAbs(0.8 * m.alpha, glyph.color[3], 0.001);
}

test "emitCurvedScrollArc: handles thin thickness=0.5, progress=NaN, and short buffers safely" {
    var quads: [32]core.QuadInstance = undefined;
    const n = wearos.emitCurvedScrollArc(
        &quads,
        233.0,
        233.0,
        220.0,
        std.math.nan(f32),
        0.5,
        core.Nord.frost_1,
        .{ 0.0, 0.0, 466.0, 466.0 },
    );
    try std.testing.expectEqual(@as(usize, 12), n); // 9 track + 3 thumb
    // Track dots (0..9) must never exceed thumb dots (9..12) when thickness < 1.0
    for (quads[0..9]) |track_q| {
        try std.testing.expect(track_q.pos_size[2] <= 0.5 + 1e-6);
        try std.testing.expect(track_q.pos_size[3] <= 0.5 + 1e-6);
        try std.testing.expect(std.math.isFinite(track_q.pos_size[0]));
        try std.testing.expect(std.math.isFinite(track_q.pos_size[1]));
    }
    for (quads[9..12]) |thumb_q| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), thumb_q.pos_size[2], 1e-5);
        try std.testing.expect(std.math.isFinite(thumb_q.pos_size[0]));
        try std.testing.expect(std.math.isFinite(thumb_q.pos_size[1]));
    }

    // Short buffers must truncate cleanly without overflow
    var short_buf: [5]core.QuadInstance = undefined;
    const n_short = wearos.emitCurvedScrollArc(
        &short_buf,
        233.0,
        233.0,
        220.0,
        0.5,
        3.0,
        core.Nord.frost_1,
        .{ 0.0, 0.0, 466.0, 466.0 },
    );
    try std.testing.expectEqual(@as(usize, 5), n_short);

    var empty_buf: [0]core.QuadInstance = undefined;
    try std.testing.expectEqual(@as(usize, 0), wearos.emitCurvedScrollArc(
        &empty_buf,
        233.0,
        233.0,
        220.0,
        0.5,
        3.0,
        core.Nord.frost_1,
        .{ 0.0, 0.0, 466.0, 466.0 },
    ));
}
