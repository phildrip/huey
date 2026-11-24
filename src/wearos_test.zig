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

test "BubbleGrid.hexOffset places slot 0 at origin and rings 1 & 2 symmetrically" {
    const s: f32 = 64.0;
    const p0 = wearos.BubbleGrid.hexOffset(0, s);
    try std.testing.expectEqual(@as(f32, 0.0), p0.x);
    try std.testing.expectEqual(@as(f32, 0.0), p0.y);

    // Ring 1 (slots 1..6): exact distance s from origin and opposite pairs sum to (0, 0)
    var ring1: [6]wearos.RingPoint = undefined;
    for (0..6) |i| {
        const pt = wearos.BubbleGrid.hexOffset(@intCast(i + 1), s);
        ring1[i] = pt;
        const dist = std.math.hypot(pt.x, pt.y);
        try std.testing.expectApproxEqAbs(s, dist, 0.01);
    }
    for (0..3) |i| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), ring1[i].x + ring1[i + 3].x, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), ring1[i].y + ring1[i + 3].y, 0.01);
    }

    // Ring 2 (slots 7..12): exact distance s * sqrt(3) and opposite pairs sum to (0, 0)
    const r2_expected = s * @sqrt(@as(f32, 3.0));
    var ring2: [6]wearos.RingPoint = undefined;
    for (0..6) |i| {
        const pt = wearos.BubbleGrid.hexOffset(@intCast(i + 7), s);
        ring2[i] = pt;
        const dist = std.math.hypot(pt.x, pt.y);
        try std.testing.expectApproxEqAbs(r2_expected, dist, 0.02);
    }
    for (0..3) |i| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), ring2[i].x + ring2[i + 3].x, 0.02);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), ring2[i].y + ring2[i + 3].y, 0.02);
    }

    // Outer ring (slots 13..18): exact distance 2*s and opposite pairs sum to (0, 0)
    var outer: [6]wearos.RingPoint = undefined;
    for (0..6) |i| {
        const pt = wearos.BubbleGrid.hexOffset(@intCast(i + 13), s);
        outer[i] = pt;
        try std.testing.expectApproxEqAbs(2.0 * s, std.math.hypot(pt.x, pt.y), 0.02);
    }
    for (0..3) |i| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), outer[i].x + outer[i + 3].x, 0.02);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), outer[i].y + outer[i + 3].y, 0.02);
    }

    // Slot >= 19 and invalid spacing fall back to (0, 0)
    try std.testing.expectEqual(@as(f32, 0.0), wearos.BubbleGrid.hexOffset(19, s).x);
    try std.testing.expectEqual(@as(f32, 0.0), wearos.BubbleGrid.hexOffset(19, s).y);
    try std.testing.expectEqual(@as(f32, 0.0), wearos.BubbleGrid.hexOffset(1, -10.0).x);
    try std.testing.expectEqual(@as(f32, 0.0), wearos.BubbleGrid.hexOffset(1, std.math.nan(f32)).y);
    try std.testing.expectEqual(@as(usize, 19), wearos.BubbleGrid.MAX_ORBS);
}

test "BubbleGrid spherical lens shrinks/fades peripheral orbs, couples neighbor press ripple, and hit-tests highest scale" {
    var grid = wearos.BubbleGrid.init(84.0, 116.5, 64.0);
    const orbs = [_]wearos.BubbleOrb{
        .{ .home_x = 0.0, .home_y = 0.0, .base_radius = 28.0 },
        .{ .home_x = 64.0, .home_y = 0.0, .base_radius = 24.0 },
        .{ .home_x = -64.0, .home_y = 0.0, .base_radius = 24.0 },
    };
    const cx: f32 = 116.5;
    const cy: f32 = 116.5;

    const p_center = grid.project(0, &orbs, cx, cy);
    const p_right = grid.project(1, &orbs, cx, cy);
    try std.testing.expect(p_center.visible and p_right.visible);
    try std.testing.expectApproxEqAbs(cx, p_center.x, 0.01);
    try std.testing.expectApproxEqAbs(cy, p_center.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), p_center.scale, 0.01);
    try std.testing.expect(p_right.scale < p_center.scale);
    try std.testing.expect(p_right.alpha <= p_center.alpha);
    // Fisheye compression pulls projected x closer to center than linear (cx + 64)
    try std.testing.expect(p_right.x > cx and p_right.x < cx + 64.0);

    // Hit test center & peripheral orb
    try std.testing.expectEqual(@as(?usize, 0), grid.hitTest(&orbs, cx, cy, p_center.x, p_center.y));
    try std.testing.expectEqual(@as(?usize, 1), grid.hitTest(&orbs, cx, cy, p_right.x, p_right.y));
    try std.testing.expectEqual(@as(?usize, null), grid.hitTest(&orbs, cx, cy, 0.0, 0.0));

    // Overlapping orbs: hitTest picks highest scale
    const overlap_orbs = [_]wearos.BubbleOrb{
        .{ .home_x = 40.0, .home_y = 0.0, .base_radius = 36.0 },
        .{ .home_x = 0.0, .home_y = 0.0, .base_radius = 28.0 },
    };
    try std.testing.expectEqual(@as(?usize, 1), grid.hitTest(&overlap_orbs, cx, cy, cx + 10.0, cy));

    // Press ripple shrinks pressed orb slightly and nudges adjacent neighbors radially outward
    grid.setPressedOrb(0);
    for (0..25) |_| {
        _ = grid.step(0.016, &orbs);
    }
    const p_center_pressed = grid.project(0, &orbs, cx, cy);
    const p_right_rippled = grid.project(1, &orbs, cx, cy);
    try std.testing.expect(p_center_pressed.scale < p_center.scale);
    try std.testing.expect(p_right_rippled.x > p_right.x);
}

test "BubbleGrid drag rubber-band, fling detent snap, recenter, and NaN/Inf sanitization" {
    var grid = wearos.BubbleGrid.init(84.0, 116.5, 64.0);
    const orbs = [_]wearos.BubbleOrb{
        .{ .home_x = 0.0, .home_y = 0.0, .base_radius = 28.0 },
        .{ .home_x = 64.0, .home_y = 0.0, .base_radius = 24.0 },
    };

    try std.testing.expect(!grid.isAnimating());

    // Drag beyond max_pan_radius applies 0.35 rubber-band attenuation
    grid.beginDrag(100.0, 100.0);
    try std.testing.expect(grid.isAnimating());
    grid.updateDrag(200.0, 100.0, 0.016); // pan_x = 100 (> 84)
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), grid.pan_x, 0.01);
    grid.updateDrag(220.0, 100.0, 0.016); // beyond 84 -> attenuated by 0.35 -> +7.0
    try std.testing.expectApproxEqAbs(@as(f32, 107.0), grid.pan_x, 0.01);
    grid.endDrag();

    // Drag to pan near (-64, 0) and settle onto orb 1 detent
    grid.recenter();
    try std.testing.expect(!grid.isAnimating());
    grid.beginDrag(100.0, 100.0);
    grid.updateDrag(50.0, 100.0, 0.016); // pan_x = -50 (nearest orb is orb 1 at home_x = 64 -> target_pan = -64)
    grid.endDrag();
    var frames: usize = 0;
    while (grid.step(0.016, &orbs) and frames < 240) : (frames += 1) {}
    try std.testing.expect(!grid.isAnimating());
    try std.testing.expectApproxEqAbs(@as(f32, -64.0), grid.pan_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), grid.pan_y, 0.01);

    // Recenter resets immediately to idle origin
    grid.recenter();
    try std.testing.expectEqual(@as(f32, 0.0), grid.pan_x);
    try std.testing.expect(!grid.isAnimating());

    // NaN/Inf resilience across all inputs
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const bad_grid = wearos.BubbleGrid.init(nan, -10.0, inf);
    try std.testing.expect(bad_grid.max_pan_radius > 0.0 and bad_grid.lens_radius > 0.0 and bad_grid.spacing_dp > 0.0);

    grid.beginDrag(nan, inf);
    try std.testing.expect(!grid.dragging);
    grid.beginDrag(10.0, 10.0);
    grid.updateDrag(nan, 20.0, 0.016);
    grid.updateDrag(20.0, 20.0, nan);
    grid.updateDrag(20.0, 20.0, 0.0);
    try std.testing.expect(std.math.isFinite(grid.pan_x) and std.math.isFinite(grid.vel_x));
    _ = grid.step(nan, &orbs);
    _ = grid.step(-1.0, &orbs);
    try std.testing.expectEqual(@as(?usize, null), grid.hitTest(&orbs, 116.5, 116.5, nan, inf));
    const oob = grid.project(99, &orbs, 116.5, 116.5);
    try std.testing.expect(!oob.visible);
}

test "BubbleGrid: monotonic fisheye past sqrt(5), smooth release ripple_orb, held press & OOB settle, inward drag, and detent skip" {
    const cx: f32 = 116.5;
    const cy: f32 = 116.5;
    const lens: f32 = 116.5;

    // 1. Strictly monotonic fisheye projection at u > sqrt(5) (2.236) and off-screen fade at u >= 2.2
    var mono_grid = wearos.BubbleGrid.init(84.0, lens, 64.0);
    const far_orbs = [_]wearos.BubbleOrb{
        .{ .home_x = 2.5 * lens, .home_y = 0.0, .base_radius = 24.0 },
        .{ .home_x = 4.0 * lens, .home_y = 0.0, .base_radius = 24.0 },
    };
    const p_25 = mono_grid.project(0, &far_orbs, cx, cy);
    const p_40 = mono_grid.project(1, &far_orbs, cx, cy);
    try std.testing.expect(p_40.x > p_25.x);
    try std.testing.expect(!p_25.visible);
    try std.testing.expectEqual(@as(f32, 0.0), p_25.alpha);
    try std.testing.expect(!p_40.visible);
    try std.testing.expectEqual(@as(f32, 0.0), p_40.alpha);

    // Corrupted lens_radius falls back cleanly; NaN pan_x yields invisible projection
    mono_grid.lens_radius = -10.0;
    const ok_orbs = [_]wearos.BubbleOrb{
        .{ .home_x = 0.0, .home_y = 0.0, .base_radius = 24.0 },
        .{ .home_x = 64.0, .home_y = 0.0, .base_radius = 24.0 },
    };
    try std.testing.expect(mono_grid.project(0, &ok_orbs, cx, cy).visible);
    mono_grid.lens_radius = lens;
    mono_grid.pan_x = std.math.nan(f32);
    try std.testing.expect(!mono_grid.project(0, &ok_orbs, cx, cy).visible);

    // 2. ripple_orb smoothly animates release spring instead of snapping; stationary held press settles
    var press_grid = wearos.BubbleGrid.init(84.0, lens, 64.0);
    press_grid.setPressedOrb(0);
    try std.testing.expectEqual(@as(?usize, 0), press_grid.ripple_orb);
    var hold_frames: usize = 0;
    while (press_grid.step(0.016, &ok_orbs) and hold_frames < 120) : (hold_frames += 1) {}
    // Stationary held press must settle and stop animating!
    try std.testing.expect(!press_grid.isAnimating());
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), press_grid.press_t, 0.002);

    // Releasing press keeps ripple_orb during spring return so project() decays smoothly
    press_grid.setPressedOrb(null);
    try std.testing.expect(press_grid.isAnimating());
    try std.testing.expectEqual(@as(?usize, 0), press_grid.ripple_orb);
    const p_unpressed = (wearos.BubbleGrid.init(84.0, lens, 64.0)).project(1, &ok_orbs, cx, cy);
    _ = press_grid.step(0.016, &ok_orbs);
    try std.testing.expect(press_grid.press_t > 0.1 and press_grid.press_t < 0.99);
    const p_releasing = press_grid.project(1, &ok_orbs, cx, cy);
    try std.testing.expect(p_releasing.x > p_unpressed.x); // neighbor still smoothly returning
    var rel_frames: usize = 0;
    while (press_grid.step(0.016, &ok_orbs) and rel_frames < 120) : (rel_frames += 1) {}
    try std.testing.expect(!press_grid.isAnimating());
    try std.testing.expectEqual(@as(?usize, null), press_grid.ripple_orb);

    // 3. OOB pressed_orb resets cleanly on step()
    press_grid.setPressedOrb(99);
    _ = press_grid.step(0.016, &ok_orbs);
    try std.testing.expectEqual(@as(?usize, null), press_grid.pressed_orb);
    try std.testing.expectEqual(@as(?usize, null), press_grid.ripple_orb);
    try std.testing.expect(!press_grid.isAnimating());

    // 4. Inward drag recovery from beyond max_pan_radius moves 1:1 without attenuation, and large f64 delta is safe
    var drag_grid = wearos.BubbleGrid.init(84.0, lens, 64.0);
    drag_grid.beginDrag(100.0, 100.0);
    drag_grid.updateDrag(200.0, 100.0, 0.016); // pan_x = 100 (> 84)
    drag_grid.updateDrag(190.0, 100.0, 0.016); // inward dx = -10 -> 1:1 -> pan_x = 90
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), drag_grid.pan_x, 0.01);
    drag_grid.endDrag();

    // 5. High-velocity fling stays bounded and settles cleanly
    drag_grid.recenter();
    drag_grid.vel_x = -2000.0;
    drag_grid.settled = false;
    var fling_frames: usize = 0;
    while (drag_grid.step(0.016, &ok_orbs) and fling_frames < 300) : (fling_frames += 1) {}
    try std.testing.expect(!drag_grid.isAnimating());
    try std.testing.expect(std.math.isFinite(drag_grid.pan_x));

    // 6. nearestDetent skips invisible/invalid orbs (base_radius <= 0 or NaN)
    const mixed_orbs = [_]wearos.BubbleOrb{
        .{ .home_x = 0.0, .home_y = 0.0, .base_radius = 0.0 },
        .{ .home_x = 40.0, .home_y = 0.0, .base_radius = 24.0 },
    };
    var det_grid = wearos.BubbleGrid.init(84.0, lens, 64.0);
    det_grid.pan_x = -5.0; // closer to orb 0 (0,0), but orb 0 has base_radius = 0 -> must snap to orb 1 (-40, 0)
    det_grid.settled = false;
    var det_frames: usize = 0;
    while (det_grid.step(0.016, &mixed_orbs) and det_frames < 240) : (det_frames += 1) {}
    try std.testing.expect(!det_grid.isAnimating());
    try std.testing.expectApproxEqAbs(@as(f32, -40.0), det_grid.pan_x, 0.02);
}

test "BubbleGrid atan-integral honeycomb lens: exact values, d(r_proj)/dr == scale, monotonicity, far_fade, and focusedOrb" {
    const cx: f32 = 116.5;
    const cy: f32 = 116.5;
    const lens: f32 = 100.0;
    var grid = wearos.BubbleGrid.init(84.0, lens, 76.0);

    // 1. Exact lens scale values & monotonic decrease (scale >= 0.24)
    const sample_u = [_]f32{ 0.0, 0.25, 0.50, 0.76, 1.00, 1.25, 1.55, 2.05, 2.50, 4.00 };
    var sample_orbs: [sample_u.len]wearos.BubbleOrb = undefined;
    for (sample_u, 0..) |u, idx| {
        sample_orbs[idx] = .{ .home_x = u * lens, .home_y = 0.0, .base_radius = 33.5 };
    }

    var prev_x: f32 = cx - 1.0;
    var prev_scale: f32 = 2.0;
    for (sample_u, 0..) |u, idx| {
        const p = grid.project(idx, &sample_orbs, cx, cy);
        try std.testing.expect(p.x > prev_x);
        try std.testing.expect(p.scale >= 0.24);
        try std.testing.expect(p.scale < prev_scale);
        if (u >= 2.05) {
            try std.testing.expect(!p.visible);
            try std.testing.expectEqual(@as(f32, 0.0), p.alpha);
        } else {
            try std.testing.expect(p.visible);
            try std.testing.expect(p.alpha > 0.02);
        }
        prev_x = p.x;
        prev_scale = p.scale;
    }

    const p_center = grid.project(0, &sample_orbs, cx, cy); // u = 0.0
    const p_076 = grid.project(3, &sample_orbs, cx, cy); // u = 0.76
    const p_125 = grid.project(5, &sample_orbs, cx, cy); // u = 1.25
    const p_155 = grid.project(6, &sample_orbs, cx, cy); // u = 1.55
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), p_center.scale, 0.0005);
    try std.testing.expectApproxEqAbs(@as(f32, 0.629), p_076.scale, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.452), p_125.scale, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.50), p_155.alpha, 0.001);

    // Closed-form atan-integral radial position check at u = 0.76
    const k: f64 = 1.65;
    const sqrt_k: f64 = @sqrt(k);
    const u_076: f64 = 0.76;
    const expected_r_076: f32 = @floatCast(@as(f64, lens) * (0.24 * u_076 + (1.0 - 0.24) * std.math.atan(sqrt_k * u_076) / sqrt_k));
    try std.testing.expectApproxEqAbs(cx + expected_r_076, p_076.x, 0.01);

    // 2. Numerical derivative d(r_proj)/dr == scale(u) around u = 0.76 and u = 1.25
    const eps: f32 = 0.05;
    const deriv_orbs = [_]wearos.BubbleOrb{
        .{ .home_x = 0.76 * lens - eps, .home_y = 0.0, .base_radius = 28.0 },
        .{ .home_x = 0.76 * lens + eps, .home_y = 0.0, .base_radius = 28.0 },
        .{ .home_x = 1.25 * lens - eps, .home_y = 0.0, .base_radius = 28.0 },
        .{ .home_x = 1.25 * lens + eps, .home_y = 0.0, .base_radius = 28.0 },
    };
    const d_076 = (grid.project(1, &deriv_orbs, cx, cy).x - grid.project(0, &deriv_orbs, cx, cy).x) / (2.0 * eps);
    const d_125 = (grid.project(3, &deriv_orbs, cx, cy).x - grid.project(2, &deriv_orbs, cx, cy).x) / (2.0 * eps);
    try std.testing.expectApproxEqAbs(p_076.scale, d_076, 0.002);
    try std.testing.expectApproxEqAbs(p_125.scale, d_125, 0.002);

    // 3. Dense honeycomb zero-overlap check (orb_r = 33.5, spacing = 76.0, lens = 100.0) across rest (0,0) and all 7 hex slots
    const spacing: f32 = 76.0;
    const orb_r: f32 = 33.5;
    var hex_orbs: [7]wearos.BubbleOrb = undefined;
    for (0..7) |slot| {
        const off = wearos.BubbleGrid.hexOffset(@intCast(slot), spacing);
        hex_orbs[slot] = .{ .home_x = off.x, .home_y = off.y, .base_radius = orb_r };
    }
    for (0..7) |focus_slot| {
        grid.pan_x = -hex_orbs[focus_slot].home_x;
        grid.pan_y = -hex_orbs[focus_slot].home_y;
        for (0..7) |i| {
            const pi = grid.project(i, &hex_orbs, cx, cy);
            try std.testing.expect(pi.visible);
            for ((i + 1)..7) |j| {
                const pj = grid.project(j, &hex_orbs, cx, cy);
                const dist = std.math.hypot(pi.x - pj.x, pi.y - pj.y);
                try std.testing.expect(dist >= pi.radius + pj.radius);
            }
        }
    }
    grid.recenter();

    // 4. focusedOrb() tracking, invalid/empty/NaN guards, and base_radius <= 0 skipping
    const empty_orbs = [_]wearos.BubbleOrb{};
    try std.testing.expectEqual(@as(?usize, null), grid.focusedOrb(&empty_orbs));

    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const invalid_orbs = [_]wearos.BubbleOrb{
        .{ .home_x = 0.0, .home_y = 0.0, .base_radius = 0.0 },
        .{ .home_x = 10.0, .home_y = 0.0, .base_radius = -5.0 },
        .{ .home_x = nan, .home_y = 0.0, .base_radius = 24.0 },
        .{ .home_x = 0.0, .home_y = inf, .base_radius = 24.0 },
    };
    try std.testing.expectEqual(@as(?usize, null), grid.focusedOrb(&invalid_orbs));

    const focus_orbs = [_]wearos.BubbleOrb{
        .{ .home_x = 0.0, .home_y = 0.0, .base_radius = 0.0 }, // invalid, skipped even at pan = (0, 0)
        .{ .home_x = 20.0, .home_y = 0.0, .base_radius = 24.0 },
        .{ .home_x = -50.0, .home_y = 0.0, .base_radius = 24.0 },
        .{ .home_x = 0.0, .home_y = 60.0, .base_radius = 24.0 },
    };
    try std.testing.expectEqual(@as(?usize, 1), grid.focusedOrb(&focus_orbs));

    grid.pan_x = 45.0; // orb 2 is at (-50 + 45, 0) -> dist 5 (closest)
    grid.pan_y = 0.0;
    try std.testing.expectEqual(@as(?usize, 2), grid.focusedOrb(&focus_orbs));

    grid.pan_x = 0.0;
    grid.pan_y = -58.0; // orb 3 is at (0, 60 - 58) -> dist 2 (closest)
    try std.testing.expectEqual(@as(?usize, 3), grid.focusedOrb(&focus_orbs));

    grid.pan_x = nan;
    try std.testing.expectEqual(@as(?usize, null), grid.focusedOrb(&focus_orbs));
    grid.pan_x = 0.0;
    grid.pan_y = inf;
    try std.testing.expectEqual(@as(?usize, null), grid.focusedOrb(&focus_orbs));
}
