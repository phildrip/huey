const std = @import("std");
const core = @import("core.zig");
const wearos = @import("wearos.zig");

test "WearConfig computes exact inscribed-square safe insets for round watches (OPWWE251 454x454 @ 2x)" {
    // 454x454 physical px @ 2.0x scale -> 227x227 logical dp round screen
    // Inscribed square side = 227 / sqrt(2) ~= 160.51 dp -> inset ~= 33.24 dp on each side
    const cfg = wearos.WearConfig.init(227.0, 227.0, true, 0.0);
    const safe = cfg.safeRect();
    try std.testing.expectApproxEqAbs(@as(f32, 33.24), safe.x, 0.2);
    try std.testing.expectApproxEqAbs(@as(f32, 33.24), safe.y, 0.2);
    try std.testing.expectApproxEqAbs(@as(f32, 160.51), safe.w, 0.4);
    try std.testing.expectApproxEqAbs(@as(f32, 160.51), safe.h, 0.4);

    // Rectangular watch has zero round inset (except optional chin)
    const rect_cfg = wearos.WearConfig.init(200.0, 240.0, false, 10.0);
    const rect_safe = rect_cfg.safeRect();
    try std.testing.expectEqual(@as(f32, 0.0), rect_safe.x);
    try std.testing.expectEqual(@as(f32, 0.0), rect_safe.y);
    try std.testing.expectEqual(@as(f32, 200.0), rect_safe.w);
    try std.testing.expectEqual(@as(f32, 230.0), rect_safe.h);
}

test "WearRotaryAdapter maps crown AXIS_SCROLL detents into scroll deltas & discrete ticks" {
    var rot = wearos.WearRotaryAdapter.init(36.0); // 36dp per detent
    const d1 = rot.onRotaryDelta(-1.0); // clockwise scroll down
    try std.testing.expectApproxEqAbs(@as(f32, 36.0), d1.scroll_dy, 0.01);
    try std.testing.expectEqual(@as(i32, 1), d1.detent_steps);

    // Sub-detent micro-rotations accumulate until 1 full detent
    const d2 = rot.onRotaryDelta(-0.4);
    try std.testing.expectEqual(@as(i32, 0), d2.detent_steps);
    const d3 = rot.onRotaryDelta(-0.7);
    try std.testing.expectEqual(@as(i32, 1), d3.detent_steps);
}

test "WearAmbientPolicy enforces OLED burn-in protection (pure black bg, <= 15% OPR, high-contrast outlines)" {
    const col = wearos.ambientTransformColor(core.Nord.polar_night_1, true, true);
    try std.testing.expectEqual(@as(f32, 0.0), col[0]); // background -> pure black in ambient mode!
    try std.testing.expectEqual(@as(f32, 0.0), col[1]);
    try std.testing.expectEqual(@as(f32, 0.0), col[2]);

    const fg = wearos.ambientTransformColor(core.Nord.frost_1, false, true);
    try std.testing.expect(fg[0] == fg[1] and fg[1] == fg[2]); // monochrome grayscale for low-bit ambient
    try std.testing.expect(fg[0] > 0.5);
}

test "transformQuadsForAmbient strips shadows, blacks backgrounds with 1px outlines, and converts glyphs" {
    var quads = [_]core.QuadInstance{
        // Filled card with shadow and no border
        .{
            .pos_size = .{ 10.0, 10.0, 200.0, 80.0 },
            .color = core.Nord.polar_night_1,
            .border_color = core.Nord.transparent,
            .params = .{ 12.0, 0.0, 10.0, 0.0 },
        },
        // Filled button with thick border and shadow
        .{
            .pos_size = .{ 20.0, 100.0, 120.0, 44.0 },
            .color = core.Nord.frost_2,
            .border_color = core.Nord.snow_storm_2,
            .params = .{ 8.0, 3.0, 6.0, 0.0 },
        },
        // Glyph quad
        .{
            .pos_size = .{ 30.0, 110.0, 16.0, 16.0 },
            .uv_rect = .{ 0.0, 0.0, 0.1, 0.1 },
            .color = core.Nord.aurora_green,
            .border_color = core.Nord.transparent,
            .params = .{ 0.0, 0.0, 2.0, 1.0 },
        },
    };

    wearos.transformQuadsForAmbient(&quads, true);

    // Card: shadow stripped, pure black fill, crisp 1px monochrome outline
    try std.testing.expectEqual(@as(f32, 0.0), quads[0].params[2]);
    try std.testing.expectEqual(@as(f32, 1.0), quads[0].params[1]);
    try std.testing.expectEqual(@as(f32, 0.0), quads[0].color[0]);
    try std.testing.expectEqual(@as(f32, 0.0), quads[0].color[1]);
    try std.testing.expectEqual(@as(f32, 0.0), quads[0].color[2]);
    try std.testing.expectEqual(@as(f32, 1.0), quads[0].color[3]);
    try std.testing.expect(quads[0].border_color[0] == quads[0].border_color[1] and quads[0].border_color[1] == quads[0].border_color[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), quads[0].border_color[0], 0.001);

    // Button: shadow stripped, pure black fill, 1px outline from border_color
    try std.testing.expectEqual(@as(f32, 0.0), quads[1].params[2]);
    try std.testing.expectEqual(@as(f32, 1.0), quads[1].params[1]);
    try std.testing.expectEqual(@as(f32, 0.0), quads[1].color[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), quads[1].border_color[0], 0.001);

    // Glyph: shadow stripped, monochrome foreground
    try std.testing.expectEqual(@as(f32, 0.0), quads[2].params[2]);
    try std.testing.expectEqual(@as(f32, 1.0), quads[2].params[3]);
    try std.testing.expect(quads[2].color[0] == quads[2].color[1] and quads[2].color[1] == quads[2].color[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), quads[2].color[0], 0.001);

    // Smooth non-low-bit mode preserves Oklab lightness grayscale
    var smooth_quad = [_]core.QuadInstance{.{
        .pos_size = .{ 0.0, 0.0, 10.0, 10.0 },
        .color = core.Nord.frost_1,
        .border_color = core.Nord.transparent,
        .params = .{ 0.0, 0.0, 4.0, 1.0 },
    }};
    wearos.transformQuadsForAmbient(&smooth_quad, false);
    const expected_l = core.srgbToOklabL(core.Nord.frost_1);
    try std.testing.expectApproxEqAbs(expected_l, smooth_quad[0].color[0], 0.0001);
    try std.testing.expectEqual(smooth_quad[0].color[0], smooth_quad[0].color[1]);
    try std.testing.expectEqual(smooth_quad[0].color[1], smooth_quad[0].color[2]);
}

test "SurfaceHost manages attached -> ambient -> exit ambient -> paused -> detached lifecycle" {
    var host = wearos.SurfaceHost.init();
    try std.testing.expectEqual(wearos.SurfaceHostState.detached, host.state);
    try std.testing.expect(!host.canDraw());

    // Ignoring surface changes / ambient updates while detached
    host.onSurfaceChanged(454, 454);
    host.onAmbientUpdate();
    try std.testing.expectEqual(wearos.SurfaceHostState.detached, host.state);
    try std.testing.expectEqual(@as(u32, 0), host.width_px);
    try std.testing.expectEqual(@as(u64, 0), host.ambient_updates);

    // Null ANativeWindow cannot attach
    host.onSurfaceCreated(null);
    try std.testing.expectEqual(wearos.SurfaceHostState.detached, host.state);

    // Attach valid window & resize
    var dummy_window: u8 = 1;
    host.onSurfaceCreated(@ptrCast(&dummy_window));
    try std.testing.expectEqual(wearos.SurfaceHostState.attached, host.state);
    try std.testing.expectEqual(@as(u64, 1), host.generation);
    try std.testing.expect(!host.canDraw()); // size not set yet

    host.onSurfaceChanged(454, 454);
    try std.testing.expect(host.canDraw());
    try std.testing.expect(host.consumeRedraw());
    try std.testing.expect(!host.consumeRedraw());

    // Enter ambient mode
    host.onEnterAmbient(true, true);
    try std.testing.expectEqual(wearos.SurfaceHostState.ambient, host.state);
    try std.testing.expect(host.low_bit_ambient);
    try std.testing.expect(host.burn_in_protection);
    try std.testing.expect(host.consumeRedraw());

    var cfg = wearos.WearConfig.init(227.0, 227.0, true, 0.0);
    host.applyToConfig(&cfg);
    try std.testing.expect(cfg.ambient);
    try std.testing.expect(cfg.low_bit_ambient);
    try std.testing.expect(cfg.burn_in_protection);

    host.onAmbientUpdate();
    try std.testing.expectEqual(@as(u64, 1), host.ambient_updates);
    try std.testing.expect(host.consumeRedraw());

    // Exit ambient back to interactive attached
    host.onExitAmbient();
    try std.testing.expectEqual(wearos.SurfaceHostState.attached, host.state);
    try std.testing.expect(host.consumeRedraw());
    host.applyToConfig(&cfg);
    try std.testing.expect(!cfg.ambient);

    // Pause / resume
    host.onPause();
    try std.testing.expectEqual(wearos.SurfaceHostState.paused, host.state);
    try std.testing.expect(!host.canDraw());
    host.onResume();
    try std.testing.expectEqual(wearos.SurfaceHostState.attached, host.state);
    try std.testing.expect(host.canDraw());

    // Destroy surface
    host.onSurfaceDestroyed();
    try std.testing.expectEqual(wearos.SurfaceHostState.detached, host.state);
    try std.testing.expect(host.native_window == null);
    try std.testing.expectEqual(@as(u32, 0), host.width_px);
    try std.testing.expect(!host.canDraw());
}

test "WearConfig and WearRotaryAdapter sanitize negative, NaN, and Inf inputs safely" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);

    const bad_cfg = wearos.WearConfig.init(-100.0, nan, true, -20.0);
    try std.testing.expectEqual(@as(f32, 0.0), bad_cfg.width_dp);
    try std.testing.expectEqual(@as(f32, 0.0), bad_cfg.height_dp);
    try std.testing.expectEqual(@as(f32, 0.0), bad_cfg.chin_dp);
    const bad_safe = bad_cfg.safeRect();
    try std.testing.expectEqual(@as(f32, 0.0), bad_safe.w);
    try std.testing.expectEqual(@as(f32, 0.0), bad_safe.h);
    try std.testing.expectEqual(@as(f32, 0.0), bad_cfg.ringRadius(-10.0));
    try std.testing.expectEqual(@as(f32, 0.0), bad_cfg.ringRadius(nan));

    // Round display with flat-tire chin clamps bottom of safeRect
    const chin_cfg = wearos.WearConfig.init(227.0, 227.0, true, 40.0);
    const chin_safe = chin_cfg.safeRect();
    try std.testing.expectApproxEqAbs(@as(f32, 187.0), chin_safe.y + chin_safe.h, 0.2);

    // Rotary adapter sanitizes dp_per_detent and ignores non-finite AXIS_SCROLL
    var rot = wearos.WearRotaryAdapter.init(-5.0);
    try std.testing.expectEqual(@as(f32, 36.0), rot.dp_per_detent);
    const rot_nan = wearos.WearRotaryAdapter.init(nan);
    try std.testing.expectEqual(@as(f32, 36.0), rot_nan.dp_per_detent);

    // Extreme values clamp cleanly without @intFromFloat UB
    const d_huge = rot.onRotaryDelta(-1e12);
    try std.testing.expectEqual(std.math.maxInt(i32), d_huge.detent_steps);
    const d_huge_neg = rot.onRotaryDelta(1e12);
    try std.testing.expectEqual(std.math.minInt(i32), d_huge_neg.detent_steps);

    const d_nan = rot.onRotaryDelta(nan);
    try std.testing.expectEqual(@as(f32, 0.0), d_nan.scroll_dy);
    try std.testing.expectEqual(@as(i32, 0), d_nan.detent_steps);

    const d_inf = rot.onRotaryDelta(inf);
    try std.testing.expectEqual(@as(f32, 0.0), d_inf.scroll_dy);
    try std.testing.expectEqual(@as(i32, 0), d_inf.detent_steps);

    // Reset clears fractional accumulator
    _ = rot.onRotaryDelta(-0.4);
    rot.reset();
    try std.testing.expectEqual(@as(f32, 0.0), rot.accum);
    const d_after_reset = rot.onRotaryDelta(-0.7);
    try std.testing.expectEqual(@as(i32, 0), d_after_reset.detent_steps);
}

test "WearConfig ringRadius and arc geometry emit circular bezel gauges" {
    const cfg = wearos.WearConfig.init(227.0, 227.0, true, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 105.5), cfg.ringRadius(8.0), 0.01);

    const c = cfg.center();
    const r = cfg.ringRadius(8.0);
    const top_pt = wearos.ringPoint(c.x, c.y, r, -std.math.pi * 0.5);
    try std.testing.expectApproxEqAbs(c.x, top_pt.x, 0.01);
    try std.testing.expectApproxEqAbs(c.y - r, top_pt.y, 0.01);

    var buf: [256]core.QuadInstance = undefined;
    const count = wearos.emitArcDots(
        c.x,
        c.y,
        r,
        -std.math.pi * 0.5,
        std.math.pi * 2.0,
        0.5,
        6.0,
        2.0,
        core.Nord.frost_1,
        &buf,
    );
    try std.testing.expect(count > 10 and count <= buf.len);
    try std.testing.expectEqual(@as(f32, 12.0), buf[0].pos_size[2]);
    try std.testing.expectEqual(@as(f32, 6.0), buf[0].params[0]);
}

test "transformQuadsForAmbient preserves foreground dots/knobs and dark glyph/border visibility" {
    const cfg = wearos.WearConfig.init(227.0, 227.0, true, 0.0);
    const c = cfg.center();
    const r = cfg.ringRadius(8.0);
    var arc_buf: [256]core.QuadInstance = undefined;
    const arc_count = wearos.emitArcDots(
        c.x,
        c.y,
        r,
        -std.math.pi * 0.5,
        std.math.pi * 2.0,
        1.0,
        6.0,
        2.0,
        core.Nord.frost_1,
        &arc_buf,
    );
    try std.testing.expect(arc_count > 10);
    // Closed 2*pi ring should not double-draw start == end seam dot
    const first_pos = arc_buf[0].pos_size;
    const last_pos = arc_buf[arc_count - 1].pos_size;
    const seam_dist = @abs(first_pos[0] - last_pos[0]) + @abs(first_pos[1] - last_pos[1]);
    try std.testing.expect(seam_dist > 1.0);

    wearos.transformQuadsForAmbient(arc_buf[0..arc_count], true);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), arc_buf[0].color[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), arc_buf[0].color[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), arc_buf[0].color[2], 0.001);

    // Small circular knob/dot, dark glyph, and dark transparent-fill border stay visible in low_bit mode
    const dark_fg: core.Color = .{ 0.05, 0.05, 0.05, 1.0 };
    var quads = [_]core.QuadInstance{
        // Small circular knob (untagged, <= 32px, radius >= 0.45*min_dim, no border)
        .{
            .pos_size = .{ 40.0, 40.0, 24.0, 24.0 },
            .color = core.Nord.aurora_orange,
            .border_color = core.Nord.transparent,
            .params = .{ 12.0, 0.0, 4.0, 0.0 },
        },
        // Dark glyph in low_bit mode
        .{
            .pos_size = .{ 10.0, 10.0, 14.0, 14.0 },
            .color = dark_fg,
            .border_color = core.Nord.transparent,
            .params = .{ 0.0, 0.0, 0.0, 1.0 },
        },
        // Dark border on transparent-fill quad in low_bit mode
        .{
            .pos_size = .{ 0.0, 0.0, 100.0, 60.0 },
            .color = core.Nord.transparent,
            .border_color = dark_fg,
            .params = .{ 6.0, 2.0, 3.0, 0.0 },
        },
    };

    wearos.transformQuadsForAmbient(&quads, true);

    // Small knob stays bright monochrome, shadow stripped
    try std.testing.expectEqual(@as(f32, 0.0), quads[0].params[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), quads[0].color[0], 0.001);
    // Dark glyph falls back to visible 0.85
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), quads[1].color[0], 0.001);
    // Dark border on transparent-fill quad falls back to visible 0.85 and 1px width
    try std.testing.expectEqual(@as(f32, 0.0), quads[2].params[2]);
    try std.testing.expectEqual(@as(f32, 1.0), quads[2].params[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), quads[2].border_color[0], 0.001);
}

test "WearRotaryAdapter clamps +/-1e38 without dropping to zero" {
    var rot = wearos.WearRotaryAdapter.init(36.0);
    const d_neg = rot.onRotaryDelta(-1e38);
    try std.testing.expectEqual(std.math.maxInt(i32), d_neg.detent_steps);
    try std.testing.expectEqual(std.math.floatMax(f32), d_neg.scroll_dy);

    const d_pos = rot.onRotaryDelta(1e38);
    try std.testing.expectEqual(std.math.minInt(i32), d_pos.detent_steps);
    try std.testing.expectEqual(-std.math.floatMax(f32), d_pos.scroll_dy);
}

test "SurfaceHost handles paused/ambient interactions and window swap resets" {
    var host = wearos.SurfaceHost.init();
    var win_a: u8 = 1;
    var win_b: u8 = 2;

    host.onSurfaceCreated(@ptrCast(&win_a));
    host.onSurfaceChanged(454, 454);
    try std.testing.expect(host.canDraw());

    // paused -> onEnterAmbient keeps state .paused, then onResume transitions to .ambient
    host.onPause();
    try std.testing.expectEqual(wearos.SurfaceHostState.paused, host.state);
    host.onEnterAmbient(true, true);
    try std.testing.expectEqual(wearos.SurfaceHostState.paused, host.state);
    try std.testing.expect(host.pending_ambient);
    host.onResume();
    try std.testing.expectEqual(wearos.SurfaceHostState.ambient, host.state);
    try std.testing.expect(host.canDraw());

    // ambient -> onPause -> onResume returns to .ambient
    host.onPause();
    try std.testing.expectEqual(wearos.SurfaceHostState.paused, host.state);
    try std.testing.expect(!host.canDraw());
    host.onResume();
    try std.testing.expectEqual(wearos.SurfaceHostState.ambient, host.state);

    // Swapping to win_b resets width_px/height_px until onSurfaceChanged
    host.onSurfaceCreated(@ptrCast(&win_b));
    try std.testing.expectEqual(@as(u32, 0), host.width_px);
    try std.testing.expectEqual(@as(u32, 0), host.height_px);
    try std.testing.expect(!host.canDraw());

    // Swapping window while paused must not override .paused
    host.onSurfaceChanged(454, 454);
    host.onExitAmbient();
    host.onPause();
    host.onSurfaceCreated(@ptrCast(&win_a));
    try std.testing.expectEqual(wearos.SurfaceHostState.paused, host.state);
}

test "safeRect with extreme chin_dp and ringRadius(inf) clamp to zero" {
    const inf = std.math.inf(f32);
    const cfg = wearos.WearConfig.init(227.0, 227.0, true, 200.0);
    const safe = cfg.safeRect();
    try std.testing.expectEqual(@as(f32, 0.0), safe.x);
    try std.testing.expectEqual(@as(f32, 0.0), safe.y);
    try std.testing.expectEqual(@as(f32, 0.0), safe.w);
    try std.testing.expectEqual(@as(f32, 0.0), safe.h);

    try std.testing.expectEqual(@as(f32, 0.0), cfg.ringRadius(inf));

    // Huge radius or thickness overflowing f32 at scale=2.0 fails finiteness guard cleanly
    var buf: [4]core.QuadInstance = undefined;
    try std.testing.expectEqual(@as(usize, 0), wearos.emitArcDots(100.0, 100.0, 2e38, 0.0, std.math.pi, 1.0, 4.0, 2.0, core.Nord.frost_1, &buf));
    try std.testing.expectEqual(@as(usize, 0), wearos.emitArcDots(100.0, 100.0, 50.0, 0.0, std.math.pi, 1.0, 2e38, 2.0, core.Nord.frost_1, &buf));
}

test "wearos.emitArcQuad emits 1-quad QUAD_MODE_ARC, enforces bounds, and handles NaN/zero safely" {
    var quads: [4]core.QuadInstance = undefined;
    var count: usize = 0;
    const clip = [4]f32{ 0.0, 0.0, 466.0, 466.0 };

    wearos.emitArcQuad(
        116.5,
        116.5,
        100.0,
        -std.math.pi * 0.5,
        std.math.pi,
        4.0,
        6.0,
        2.0,
        core.Nord.frost_1,
        clip,
        &quads,
        &count,
    );
    try std.testing.expectEqual(@as(usize, 1), count);
    const q = quads[0];
    try std.testing.expectEqual(core.QUAD_MODE_ARC, q.params[3]);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), q.params[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), q.params[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), q.params[2], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -std.math.pi * 0.5), q.uv_rect[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi), q.uv_rect[1], 0.0001);
    // Bounding box centered at (233, 233) with half-extent = 200 + 4 = 204
    try std.testing.expectApproxEqAbs(@as(f32, 233.0), q.pos_size[0] + q.pos_size[2] * 0.5, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 233.0), q.pos_size[1] + q.pos_size[3] * 0.5, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 408.0), q.pos_size[2], 0.01);

    // Zero thickness, zero sweep, NaN radius, and full buffer do not emit
    wearos.emitArcQuad(116.5, 116.5, 100.0, 0.0, std.math.pi, 0.0, 0.0, 2.0, core.Nord.frost_1, clip, &quads, &count);
    wearos.emitArcQuad(116.5, 116.5, 100.0, 0.0, 0.0, 4.0, 0.0, 2.0, core.Nord.frost_1, clip, &quads, &count);
    wearos.emitArcQuad(116.5, 116.5, std.math.nan(f32), 0.0, std.math.pi, 4.0, 0.0, 2.0, core.Nord.frost_1, clip, &quads, &count);
    try std.testing.expectEqual(@as(usize, 1), count);

    var zero_buf: [0]core.QuadInstance = undefined;
    var zero_count: usize = 0;
    wearos.emitArcQuad(116.5, 116.5, 100.0, 0.0, std.math.pi, 4.0, 0.0, 2.0, core.Nord.frost_1, clip, &zero_buf, &zero_count);
    try std.testing.expectEqual(@as(usize, 0), zero_count);
}

test "transformQuadsForAmbient handles QUAD_MODE_SURFACE, QUAD_MODE_ARC, QUAD_MODE_CAPSULE, and negative rotated GLYPH" {
    var quads = [_]core.QuadInstance{
        // [0] QUAD_MODE_SURFACE with gradient, specular rim, and glow
        .{
            .pos_size = .{ 20.0, 20.0, 120.0, 60.0 },
            .uv_rect = .{ 0.05, 0.08, 0.12, 0.35 },
            .color = .{ 0.12, 0.18, 0.23, 1.0 },
            .border_color = core.Nord.frost_1,
            .params = .{ 16.0, 2.5, 14.0, core.QUAD_MODE_SURFACE },
        },
        // [1] QUAD_MODE_ARC with colored glow
        .{
            .pos_size = .{ 10.0, 10.0, 200.0, 200.0 },
            .uv_rect = .{ -std.math.pi * 0.5, std.math.pi, 0.0, 0.0 },
            .color = core.Nord.frost_1,
            .border_color = core.Nord.transparent,
            .params = .{ 96.0, 6.0, 10.0, core.QUAD_MODE_ARC },
        },
        // [2] QUAD_MODE_CAPSULE rotated with glow
        .{
            .pos_size = .{ 50.0, 50.0, 40.0, 8.0 },
            .uv_rect = .{ 0.785, 0.0, 0.0, 0.0 },
            .color = core.Nord.aurora_green,
            .border_color = core.Nord.transparent,
            .params = .{ 4.0, 0.0, 8.0, core.QUAD_MODE_CAPSULE },
        },
        // [3] Rotated QUAD_MODE_GLYPH with negative angle_rad
        .{
            .pos_size = .{ 80.0, 30.0, 12.0, 16.0 },
            .uv_rect = .{ 0.1, 0.1, 0.2, 0.2 },
            .color = core.Nord.snow_storm_2,
            .border_color = core.Nord.transparent,
            .params = .{ -0.35, 0.0, 0.0, core.QUAD_MODE_GLYPH },
        },
    };

    wearos.transformQuadsForAmbient(&quads, true);

    // Surface -> OLED black fill, 1px monochrome outline, zero glow, zero specular/gradient
    try std.testing.expectEqual(@as(f32, 0.0), quads[0].color[0]);
    try std.testing.expectEqual(@as(f32, 0.0), quads[0].color[1]);
    try std.testing.expectEqual(@as(f32, 0.0), quads[0].color[2]);
    try std.testing.expectEqual(@as(f32, 1.0), quads[0].params[1]);
    try std.testing.expectEqual(@as(f32, 0.0), quads[0].params[2]);
    try std.testing.expectEqual(@as(f32, 0.0), quads[0].uv_rect[3]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), quads[0].border_color[0], 0.001);

    // Arc -> glow stripped, stroke thickness preserved, color converted to visible monochrome
    try std.testing.expectEqual(@as(f32, 0.0), quads[1].params[2]);
    try std.testing.expectEqual(@as(f32, 6.0), quads[1].params[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), quads[1].color[0], 0.001);

    // Capsule -> glow stripped, angle preserved, foreground color converted to visible monochrome
    try std.testing.expectEqual(@as(f32, 0.0), quads[2].params[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.785), quads[2].uv_rect[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), quads[2].color[0], 0.001);

    // Rotated glyph -> negative angle preserved!
    try std.testing.expectApproxEqAbs(@as(f32, -0.35), quads[3].params[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), quads[3].color[0], 0.001);

    // Non-low-bit ambient (low_bit=false) + NaN border/angle hygiene
    const nan = std.math.nan(f32);
    var smooth_quads = [_]core.QuadInstance{
        .{
            .pos_size = .{ 10.0, 10.0, 100.0, 100.0 },
            .uv_rect = .{ 0.0, std.math.pi, 0.0, 0.0 },
            .color = core.Nord.frost_1,
            .border_color = .{ 1.0, 0.0, 0.0, nan },
            .params = .{ 45.0, 4.0, 8.0, core.QUAD_MODE_ARC },
        },
        .{
            .pos_size = .{ 20.0, 20.0, 80.0, 40.0 },
            .uv_rect = .{ 0.1, 0.2, 0.3, 0.5 },
            .color = core.Nord.polar_night_2,
            .border_color = .{ 0.5, 0.5, 0.5, nan },
            .params = .{ 10.0, 2.0, 6.0, core.QUAD_MODE_SURFACE },
        },
        .{
            .pos_size = .{ 30.0, 30.0, 40.0, 8.0 },
            .uv_rect = .{ nan, 0.0, 0.0, 0.0 },
            .color = core.Nord.aurora_green,
            .border_color = .{ 1.0, 1.0, 1.0, nan },
            .params = .{ 4.0, 0.0, 6.0, core.QUAD_MODE_CAPSULE },
        },
    };
    wearos.transformQuadsForAmbient(&smooth_quads, false);

    // ARC: Oklab lightness grayscale, border_color cleaned to transparent
    try std.testing.expectApproxEqAbs(core.srgbToOklabL(core.Nord.frost_1), smooth_quads[0].color[0], 0.001);
    try std.testing.expectEqual(core.Nord.transparent, smooth_quads[0].border_color);
    // SURFACE: pure black fill, 1px outline from orig_fill, zero specular
    try std.testing.expectEqual(@as(f32, 0.0), smooth_quads[1].color[0]);
    try std.testing.expectEqual(@as(f32, 1.0), smooth_quads[1].params[1]);
    try std.testing.expectApproxEqAbs(core.srgbToOklabL(core.Nord.polar_night_2), smooth_quads[1].border_color[0], 0.001);
    // CAPSULE: NaN angle sanitized to 0, NaN border cleaned to transparent, Oklab lightness color
    try std.testing.expectEqual(@as(f32, 0.0), smooth_quads[2].uv_rect[0]);
    try std.testing.expectEqual(core.Nord.transparent, smooth_quads[2].border_color);
    try std.testing.expectApproxEqAbs(core.srgbToOklabL(core.Nord.aurora_green), smooth_quads[2].color[0], 0.001);
}

test "applyCurvedEdgeTransform scales ARC/SURFACE/CAPSULE params and preserves GLYPH rotation angle" {
    var quads = [_]core.QuadInstance{
        .{
            .pos_size = .{ 100.0, 380.0, 60.0, 60.0 }, // cy = 410 (off-center near bottom pole)
            .uv_rect = .{ -std.math.pi * 0.5, std.math.pi, 0.0, 0.0 },
            .color = core.Nord.frost_1,
            .border_color = core.Nord.transparent,
            .params = .{ 25.0, 6.0, 10.0, core.QUAD_MODE_ARC },
            .clip_rect = .{ 0.0, 0.0, 466.0, 466.0 },
        },
        .{
            .pos_size = .{ 100.0, 380.0, 80.0, 40.0 },
            .uv_rect = .{ 0.1, 0.1, 0.1, 0.3 },
            .color = core.Nord.polar_night_1,
            .border_color = core.Nord.frost_1,
            .params = .{ 12.0, 2.0, 8.0, core.QUAD_MODE_SURFACE },
            .clip_rect = .{ 0.0, 0.0, 466.0, 466.0 },
        },
        .{
            .pos_size = .{ 100.0, 396.0, 40.0, 8.0 },
            .uv_rect = .{ 0.5, 0.0, 0.0, 0.0 },
            .color = core.Nord.aurora_green,
            .border_color = core.Nord.transparent,
            .params = .{ 4.0, 0.0, 6.0, core.QUAD_MODE_CAPSULE },
            .clip_rect = .{ 0.0, 0.0, 466.0, 466.0 },
        },
        .{
            .pos_size = .{ 100.0, 390.0, 12.0, 16.0 },
            .uv_rect = .{ 0.1, 0.1, 0.2, 0.2 },
            .color = core.Nord.snow_storm_2,
            .border_color = core.Nord.transparent,
            .params = .{ -0.45, 0.0, 0.0, core.QUAD_MODE_GLYPH },
            .clip_rect = .{ 0.0, 0.0, 466.0, 466.0 },
        },
    };
    const m_arc = wearos.curvedScrollMetrics(410.0, 233.0, 233.0);
    const m_cap = wearos.curvedScrollMetrics(400.0, 233.0, 233.0);
    wearos.applyCurvedEdgeTransform(&quads, 233.0, 233.0, 233.0);

    try std.testing.expectApproxEqAbs(25.0 * m_arc.scale, quads[0].params[0], 0.01);
    try std.testing.expectApproxEqAbs(6.0 * m_arc.scale, quads[0].params[1], 0.01);
    try std.testing.expectApproxEqAbs(12.0 * m_cap.scale, quads[1].params[0], 0.01);
    try std.testing.expectApproxEqAbs(4.0 * m_cap.scale, quads[2].params[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -0.45), quads[3].params[0], 0.0001);
}
