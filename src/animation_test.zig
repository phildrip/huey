const std = @import("std");
const anim = @import("animation.zig");
const core = @import("core.zig");
const tokens = @import("tokens.zig");

test "SpringState: converges smoothly to target, preserves momentum on retarget, and settles to 0% idle" {
    var s = anim.SpringState.init(0.0);
    try std.testing.expect(!s.isAnimating());

    s.setTarget(1.0);
    try std.testing.expect(s.isAnimating());

    // Step 3 frames at 60Hz: should move monotonically toward 1.0 with positive velocity
    for (0..3) |_| {
        _ = s.step(1.0 / 60.0, anim.SpringConfig.snappy);
    }
    try std.testing.expect(s.value > 0.05 and s.value < 1.0);
    const vel_before = s.velocity;
    try std.testing.expect(vel_before > 0.0);

    // Mid-flight retarget preserves momentum
    s.setTarget(0.0);
    try std.testing.expectApproxEqAbs(vel_before, s.velocity, 0.0001);

    // Run up to 3 seconds at 60Hz -> must settle exactly to 0.0 and stop animating
    var steps: usize = 0;
    while (s.isAnimating() and steps < 180) : (steps += 1) {
        _ = s.step(1.0 / 60.0, anim.SpringConfig.snappy);
    }
    try std.testing.expect(!s.isAnimating());
    try std.testing.expectEqual(@as(f32, 0.0), s.value);
    try std.testing.expectEqual(@as(f32, 0.0), s.velocity);
}

test "SpringState: large dt spike or NaN never explodes" {
    var s = anim.SpringState.init(0.0);
    s.setTarget(100.0);
    _ = s.step(5.0, anim.SpringConfig.snappy); // huge 5s stall clamped safely
    try std.testing.expect(std.math.isFinite(s.value));
    try std.testing.expect(std.math.isFinite(s.velocity));
    _ = s.step(std.math.nan(f32), anim.SpringConfig.snappy);
    try std.testing.expect(std.math.isFinite(s.value));
}

test "TweenState: easing curves reach exact endpoints and settle" {
    var tw = anim.TweenState.init(10.0, 110.0, 0.25, .ease_out_cubic);
    try std.testing.expect(tw.isAnimating());
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), tw.value(), 0.001);

    // Halfway through ease_out_cubic should be > 50% (fast start, soft landing)
    _ = tw.step(0.125);
    try std.testing.expect(tw.value() > 65.0 and tw.value() < 110.0);

    // Complete
    _ = tw.step(0.2);
    try std.testing.expect(!tw.isAnimating());
    try std.testing.expectApproxEqAbs(@as(f32, 110.0), tw.value(), 0.001);
}

test "lerpColorOklab: preserves perceptual lightness across Nord Frost -> Aurora Orange" {
    const frost = core.Nord.frost_1;
    const orange = core.Nord.aurora_orange;
    const start = anim.lerpColorOklab(frost, orange, 0.0);
    const mid = anim.lerpColorOklab(frost, orange, 0.5);
    const end = anim.lerpColorOklab(frost, orange, 1.0);

    try std.testing.expectApproxEqAbs(frost[0], start[0], 0.01);
    try std.testing.expectApproxEqAbs(orange[0], end[0], 0.01);
    // Midpoint should remain bright and finite, not collapsed to dark mud
    try std.testing.expect(mid[0] > 0.5 and mid[1] > 0.5 and mid[2] > 0.4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mid[3], 0.01);
}

test "AnimationPool: first call snaps with no cold-start flash, target change animates and settles" {
    var pool = anim.AnimationPool.init();
    const key = anim.hashKey("card_toggle_0", "thumb");

    // Cold start initializes at target without animating
    const v0 = pool.animateSpring(key, 1.0, anim.SpringConfig.snappy);
    try std.testing.expectEqual(@as(f32, 1.0), v0);
    try std.testing.expect(!pool.isAnimating());

    // Target changes -> animates smoothly toward 0.0
    const v1 = pool.animateSpring(key, 0.0, anim.SpringConfig.snappy);
    try std.testing.expectEqual(@as(f32, 1.0), v1);
    try std.testing.expect(pool.isAnimating());

    _ = pool.step(1.0 / 60.0);
    const v2 = pool.animateSpring(key, 0.0, anim.SpringConfig.snappy);
    try std.testing.expect(v2 < 1.0 and v2 > 0.0);

    // Color animation in Oklab
    const ckey = anim.hashKey("theme", "accent");
    const c0 = pool.animateColor(ckey, core.Nord.frost_1, anim.SpringConfig.gentle);
    try std.testing.expectApproxEqAbs(core.Nord.frost_1[0], c0[0], 0.01);
    _ = pool.animateColor(ckey, core.Nord.aurora_green, anim.SpringConfig.gentle);
    _ = pool.step(1.0 / 30.0);
    const c_mid = pool.animateColor(ckey, core.Nord.aurora_green, anim.SpringConfig.gentle);
    try std.testing.expect(c_mid[0] != core.Nord.frost_1[0] or c_mid[1] != core.Nord.frost_1[1]);

    // Step until all settled -> 0% idle CPU
    var i: usize = 0;
    while (pool.isAnimating() and i < 240) : (i += 1) {
        _ = pool.step(1.0 / 60.0);
    }
    try std.testing.expect(!pool.isAnimating());
}

test "AnimationPool: reduced_motion snaps immediately to target" {
    var pool = anim.AnimationPool.init();
    pool.reduced_motion = true;
    const key = anim.hashKey("toggle_1", "thumb");
    _ = pool.animateSpring(key, 0.0, anim.SpringConfig.snappy);
    const snapped = pool.animateSpring(key, 1.0, anim.SpringConfig.snappy);
    try std.testing.expectEqual(@as(f32, 1.0), snapped);
    try std.testing.expect(!pool.isAnimating());
}

test "C1: analytical damped harmonic oscillator handles extreme stiffness and all damping regimes without divergence" {
    // 1. Extreme stiffness + tiny mass + minimal damping + max dt spike -> zero divergence
    const extreme_cfg = anim.SpringConfig{
        .stiffness = 1.0e7,
        .damping = 0.1,
        .mass = 0.01,
    };
    var s_ext = anim.SpringState.init(0.0);
    s_ext.setTargetWithConfig(100.0, extreme_cfg);
    for (0..20) |_| {
        _ = s_ext.step(0.1, extreme_cfg);
        try std.testing.expect(std.math.isFinite(s_ext.value));
        try std.testing.expect(std.math.isFinite(s_ext.velocity));
        try std.testing.expect(@abs(s_ext.value - 100.0) <= 105.0);
    }

    // 2. Underdamped (zeta < 1): overshoots target before settling
    const under_cfg = anim.SpringConfig{ .stiffness = 400.0, .damping = 8.0, .mass = 1.0 };
    var s_under = anim.SpringState.init(0.0);
    s_under.setTargetWithConfig(1.0, under_cfg);
    var saw_overshoot = false;
    var steps: usize = 0;
    while (s_under.isAnimating() and steps < 600) : (steps += 1) {
        _ = s_under.step(1.0 / 60.0, under_cfg);
        if (s_under.value > 1.01) saw_overshoot = true;
    }
    try std.testing.expect(saw_overshoot);
    try std.testing.expect(!s_under.isAnimating());
    try std.testing.expectEqual(@as(f32, 1.0), s_under.value);

    // 3. Critically damped (zeta == 1): c = 2 * sqrt(k * m) = 2 * 20 = 40.0 -> monotonic, no overshoot
    const crit_cfg = anim.SpringConfig{ .stiffness = 400.0, .damping = 40.0, .mass = 1.0 };
    var s_crit = anim.SpringState.init(0.0);
    s_crit.setTargetWithConfig(1.0, crit_cfg);
    steps = 0;
    while (s_crit.isAnimating() and steps < 600) : (steps += 1) {
        _ = s_crit.step(1.0 / 60.0, crit_cfg);
        try std.testing.expect(s_crit.value <= 1.0001);
    }
    try std.testing.expect(!s_crit.isAnimating());
    try std.testing.expectEqual(@as(f32, 1.0), s_crit.value);

    // 4. Overdamped (zeta > 1) including huge zeta (cancellation-free): monotonic, settles cleanly
    const over_cfg = anim.SpringConfig{ .stiffness = 400.0, .damping = 120.0, .mass = 1.0 };
    var s_over = anim.SpringState.init(0.0);
    s_over.setTargetWithConfig(1.0, over_cfg);
    steps = 0;
    while (s_over.isAnimating() and steps < 600) : (steps += 1) {
        _ = s_over.step(1.0 / 60.0, over_cfg);
        try std.testing.expect(s_over.value <= 1.0001);
    }
    try std.testing.expect(!s_over.isAnimating());
    try std.testing.expectEqual(@as(f32, 1.0), s_over.value);

    const huge_zeta_cfg = anim.SpringConfig{ .stiffness = 1.0, .damping = 1.0e7, .mass = 0.01 };
    var s_hz = anim.SpringState.init(0.0);
    s_hz.setTargetWithConfig(10.0, huge_zeta_cfg);
    _ = s_hz.step(0.1, huge_zeta_cfg);
    try std.testing.expect(std.math.isFinite(s_hz.value));
    try std.testing.expect(std.math.isFinite(s_hz.velocity));

    // 5. Time-step invariance: 1 step of 0.05s equals 2 steps of 0.025s
    var s_one = anim.SpringState.init(0.0);
    s_one.setTargetWithConfig(10.0, under_cfg);
    _ = s_one.step(0.05, under_cfg);

    var s_two = anim.SpringState.init(0.0);
    s_two.setTargetWithConfig(10.0, under_cfg);
    _ = s_two.step(0.025, under_cfg);
    _ = s_two.step(0.025, under_cfg);
    try std.testing.expectApproxEqAbs(s_one.value, s_two.value, 1.0e-5);
    try std.testing.expectApproxEqAbs(s_one.velocity, s_two.velocity, 1.0e-4);
}

test "C2: f32 ULP quantization trap at large target with tight pos_epsilon always settles" {
    const tight_cfg = anim.SpringConfig{
        .stiffness = 420.0,
        .damping = 34.0,
        .pos_epsilon = 1.0e-6,
        .vel_epsilon = 1.0e-6,
    };
    var s = anim.SpringState.init(0.0);
    s.setTargetWithConfig(10000.0, tight_cfg);
    try std.testing.expect(s.isAnimating());

    var steps: usize = 0;
    while (s.isAnimating() and steps < 600) : (steps += 1) {
        _ = s.step(1.0 / 60.0, tight_cfg);
    }
    try std.testing.expect(!s.isAnimating());
    try std.testing.expectEqual(@as(f32, 10000.0), s.value);
    try std.testing.expectEqual(@as(f32, 0.0), s.velocity);
}

test "H3: LRU eviction prefers settled slots over older active slots" {
    var pool = anim.AnimationPool.init();

    // Fill slot 0 with an active spring (oldest touch)
    const k0: u64 = 1000;
    _ = pool.animateSpring(k0, 0.0, anim.SpringConfig.snappy);
    _ = pool.animateSpring(k0, 100.0, anim.SpringConfig.snappy);
    try std.testing.expect(pool.springs[0].spring.active);

    // Fill slots 1..MAX_SPRINGS-1 with settled springs (newer touches)
    var i: usize = 1;
    while (i < anim.MAX_SPRINGS) : (i += 1) {
        const ki: u64 = 1000 + @as(u64, i);
        _ = pool.animateSpring(ki, 1.0, anim.SpringConfig.snappy);
        try std.testing.expect(!pool.springs[i].spring.active);
    }
    try std.testing.expectEqual(anim.MAX_SPRINGS, pool.spring_count);

    // Insert a new spring -> must evict slot 1 (oldest settled), NOT slot 0 (oldest overall, but active)
    const k_new: u64 = 9999;
    _ = pool.animateSpring(k_new, 5.0, anim.SpringConfig.snappy);
    try std.testing.expectEqual(k0, pool.springs[0].key);
    try std.testing.expect(pool.springs[0].spring.active);
    try std.testing.expectEqual(k_new, pool.springs[1].key);

    // Now make ALL slots active -> evicting must fall back to the oldest active slot (slot 0)
    for (1..anim.MAX_SPRINGS) |idx| {
        _ = pool.animateSpring(pool.springs[idx].key, 50.0, anim.SpringConfig.snappy);
        try std.testing.expect(pool.springs[idx].spring.active);
    }
    const k_overflow: u64 = 10000;
    _ = pool.animateSpring(k_overflow, 3.0, anim.SpringConfig.snappy);
    try std.testing.expectEqual(k_overflow, pool.springs[0].key);
}

test "H4: LRU eviction uses u64 wraparound-safe age" {
    var pool = anim.AnimationPool.init();
    pool.touch_counter = std.math.maxInt(u64) - 2;

    // Insert MAX_SPRINGS settled entries across the maxInt(u64) -> 1 wrap boundary.
    // Entry 0 gets last_touch = maxInt - 1
    // Entry 1 gets last_touch = maxInt
    // Entry 2 gets last_touch = 1 (wrapped!)
    // ...
    // Entry 0 has the largest wrapping age and MUST be evicted.
    var i: usize = 0;
    while (i < anim.MAX_SPRINGS) : (i += 1) {
        const ki: u64 = 2000 + @as(u64, i);
        _ = pool.animateSpring(ki, 1.0, anim.SpringConfig.snappy);
    }
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64) - 1), pool.springs[0].last_touch);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), pool.springs[1].last_touch);
    try std.testing.expectEqual(@as(u64, 1), pool.springs[2].last_touch);

    const k_evict_trigger: u64 = 8888;
    _ = pool.animateSpring(k_evict_trigger, 2.0, anim.SpringConfig.snappy);
    try std.testing.expectEqual(k_evict_trigger, pool.springs[0].key);
    try std.testing.expectEqual(@as(u64, 2002), pool.springs[2].key);
}

test "H5: TweenState.value() computes in f64 and never produces NaN or Inf for huge ranges" {
    var tw = anim.TweenState.init(-3.0e38, 3.0e38, 1.0, .linear);
    const v0 = tw.value();
    try std.testing.expect(std.math.isFinite(v0));
    try std.testing.expectApproxEqAbs(@as(f32, -3.0e38), v0, 1.0e32);

    _ = tw.step(0.5);
    const v_mid = tw.value();
    try std.testing.expect(std.math.isFinite(v_mid));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), v_mid, 1.0e32);

    _ = tw.step(0.5);
    const v_end = tw.value();
    try std.testing.expect(std.math.isFinite(v_end));
    try std.testing.expectEqual(@as(f32, 3.0e38), v_end);
}

test "H6: SpringState.setTargetWithConfig and AnimationPool honor cfg.pos_epsilon consistently" {
    // Tight epsilon (1e-5) animates a 2e-4 delta that default 5e-4 would snap
    const tight_cfg = anim.SpringConfig{
        .stiffness = 420.0,
        .damping = 34.0,
        .pos_epsilon = 1.0e-5,
        .vel_epsilon = 1.0e-5,
    };
    var s_tight = anim.SpringState.init(0.0);
    s_tight.setTargetWithConfig(2.0e-4, tight_cfg);
    try std.testing.expect(s_tight.isAnimating());

    // Coarse epsilon (0.1) snaps a 0.05 delta immediately without waking
    const coarse_cfg = anim.SpringConfig{
        .stiffness = 420.0,
        .damping = 34.0,
        .pos_epsilon = 0.1,
        .vel_epsilon = 0.1,
    };
    var s_coarse = anim.SpringState.init(0.0);
    s_coarse.setTargetWithConfig(0.05, coarse_cfg);
    try std.testing.expect(!s_coarse.isAnimating());
    try std.testing.expectEqual(@as(f32, 0.05), s_coarse.value);

    // AnimationPool uses setTargetWithConfig consistently
    var pool = anim.AnimationPool.init();
    const key = anim.hashKey("eps", "test");
    _ = pool.animateSpring(key, 0.0, coarse_cfg);
    const out = pool.animateSpring(key, 0.05, coarse_cfg);
    try std.testing.expectEqual(@as(f32, 0.05), out);
    try std.testing.expect(!pool.isAnimating());
}

test "M8: reduced_motion mid-flight disables isAnimating and setReducedMotion snaps active entries" {
    var pool = anim.AnimationPool.init();
    const skey = anim.hashKey("m8", "spring");
    const ckey = anim.hashKey("m8", "color");

    _ = pool.animateSpring(skey, 0.0, anim.SpringConfig.snappy);
    _ = pool.animateSpring(skey, 10.0, anim.SpringConfig.snappy);
    _ = pool.animateColor(ckey, core.Nord.polar_night_0, anim.SpringConfig.gentle);
    _ = pool.animateColor(ckey, core.Nord.aurora_red, anim.SpringConfig.gentle);
    try std.testing.expect(pool.isAnimating());

    // Direct flag toggle mid-flight immediately hides active state in isAnimating() and snaps on step()
    pool.reduced_motion = true;
    try std.testing.expect(!pool.isAnimating());
    try std.testing.expect(!pool.step(1.0 / 60.0));
    try std.testing.expectEqual(@as(f32, 10.0), pool.animateSpring(skey, 10.0, anim.SpringConfig.snappy));

    // Re-enable animations, start new ones, then call setReducedMotion(true)
    pool.setReducedMotion(false);
    _ = pool.animateSpring(skey, 20.0, anim.SpringConfig.snappy);
    _ = pool.animateColor(ckey, core.Nord.frost_1, anim.SpringConfig.gentle);
    try std.testing.expect(pool.isAnimating());

    pool.setReducedMotion(true);
    try std.testing.expect(!pool.isAnimating());
    // Even if reduced_motion is turned back off, previously snapped entries remain settled
    pool.setReducedMotion(false);
    try std.testing.expect(!pool.isAnimating());
    try std.testing.expectEqual(@as(f32, 20.0), pool.animateSpring(skey, 20.0, anim.SpringConfig.snappy));
    const settled_col = pool.animateColor(ckey, core.Nord.frost_1, anim.SpringConfig.gentle);
    try std.testing.expectApproxEqAbs(core.Nord.frost_1[0], settled_col[0], 1.0e-5);
}

test "M9: animateColor A -> B -> A before step snaps without waking isAnimating" {
    var pool = anim.AnimationPool.init();
    const ckey = anim.hashKey("m9", "bg");

    _ = pool.animateColor(ckey, core.Nord.frost_1, anim.SpringConfig.gentle);
    try std.testing.expect(!pool.isAnimating());

    // Retarget to B (current is still A because step hasn't run)
    _ = pool.animateColor(ckey, core.Nord.aurora_orange, anim.SpringConfig.gentle);
    try std.testing.expect(pool.isAnimating());

    // Immediately retarget back to A -> current == target, must snap without animating
    const res = pool.animateColor(ckey, core.Nord.frost_1, anim.SpringConfig.gentle);
    try std.testing.expect(!pool.isAnimating());
    try std.testing.expectApproxEqAbs(core.Nord.frost_1[0], res[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(core.Nord.frost_1[1], res[1], 1.0e-5);
    try std.testing.expectApproxEqAbs(core.Nord.frost_1[2], res[2], 1.0e-5);
}

test "M10: lerpColorOklab avoids transparent-black fringes and returns exact endpoints" {
    const fg = core.Nord.snow_storm_2;

    // Exact endpoints
    const e0 = anim.lerpColorOklab(core.Nord.transparent, fg, 0.0);
    const e1 = anim.lerpColorOklab(core.Nord.transparent, fg, 1.0);
    try std.testing.expectEqual(core.Nord.transparent, e0);
    try std.testing.expectEqual(fg, e1);

    // Fade in from transparent: RGB must match target fg (no dark gray fringe)
    const fade_in = anim.lerpColorOklab(core.Nord.transparent, fg, 0.5);
    try std.testing.expectApproxEqAbs(fg[0], fade_in[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(fg[1], fade_in[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(fg[2], fade_in[2], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), fade_in[3], 1.0e-6);

    // Fade out to transparent: RGB must match source fg
    const fade_out = anim.lerpColorOklab(fg, core.Nord.transparent, 0.25);
    try std.testing.expectApproxEqAbs(fg[0], fade_out[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(fg[1], fade_out[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(fg[2], fade_out[2], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), fade_out[3], 1.0e-6);
}

test "M11: TweenState setTarget is idempotent and uses f64 elapsed_s precision" {
    var tw = anim.TweenState.init(0.0, 100.0, 1.0, .linear);
    _ = tw.step(0.4);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), tw.value(), 0.01);

    // Repeated setTarget with the same target must not restart elapsed_s
    tw.setTarget(100.0, 1.0, .linear);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), tw.value(), 0.01);

    _ = tw.step(0.6);
    try std.testing.expect(!tw.isAnimating());
    try std.testing.expectEqual(@as(f32, 100.0), tw.value());

    // f64 elapsed_s accumulates tiny dt after large duration without stalling
    var long_tw = anim.TweenState.init(0.0, 1.0, 100000.0, .linear);
    _ = long_tw.step(99999.0);
    const before = long_tw.elapsed_s;
    _ = long_tw.step(1.0e-5);
    try std.testing.expect(long_tw.elapsed_s > before);
}

test "M12: hashKey is length-prefixed and key==0 is remapped safely" {
    // Delimiter collision from old 0xFF separator is prevented
    const k1 = anim.hashKey("a\xFFb", "c");
    const k2 = anim.hashKey("a", "b\xFFc");
    try std.testing.expect(k1 != k2);
    try std.testing.expect(k1 != 0);
    try std.testing.expect(k2 != 0);

    // Passing key == 0 remaps to 1 cleanly for both springs and colors
    var pool = anim.AnimationPool.init();
    _ = pool.animateSpring(0, 1.0, anim.SpringConfig.snappy);
    _ = pool.animateSpring(0, 2.0, anim.SpringConfig.snappy);
    try std.testing.expectEqual(@as(usize, 1), pool.spring_count);
    try std.testing.expectEqual(@as(u64, 1), pool.springs[0].key);

    _ = pool.animateColor(0, core.Nord.frost_0, anim.SpringConfig.gentle);
    try std.testing.expectEqual(@as(usize, 1), pool.color_count);
    try std.testing.expectEqual(@as(u64, 1), pool.colors[0].key);
}

test "L13: sanitizeUnit normalizes negative zero to positive zero" {
    const e_neg0 = anim.evalEasing(.linear, -0.0);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(e_neg0)));

    const e_nan = anim.evalEasing(.linear, std.math.nan(f32));
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(e_nan)));

    const e_ninf = anim.evalEasing(.linear, -std.math.inf(f32));
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(e_ninf)));

    const e_pinf = anim.evalEasing(.linear, std.math.inf(f32));
    try std.testing.expectEqual(@as(f32, 0.0), e_pinf);

    const e_gt1 = anim.evalEasing(.linear, 2.0);
    try std.testing.expectEqual(@as(f32, 1.0), e_gt1);

    const c_neg0 = anim.lerpColorOklab(core.Nord.polar_night_0, core.Nord.snow_storm_2, -0.0);
    try std.testing.expectEqual(@as(u32, @bitCast(core.Nord.polar_night_0[0])), @as(u32, @bitCast(c_neg0[0])));
}

test "OklabColor.fromSrgb: round-trip accuracy, lightness ordering, and sanitization" {
    const black = tokens.OklabColor.fromSrgb(.{ 0.0, 0.0, 0.0, 1.0 });
    const white = tokens.OklabColor.fromSrgb(.{ 1.0, 1.0, 1.0, 1.0 });
    const dark_nord = tokens.OklabColor.fromSrgb(core.Nord.polar_night_0);
    const light_nord = tokens.OklabColor.fromSrgb(core.Nord.snow_storm_2);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), black.l, 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), white.l, 1.0e-4);
    try std.testing.expect(black.l < dark_nord.l and dark_nord.l < light_nord.l and light_nord.l < white.l);

    // Round-trip Nord aurora_orange through Oklab -> sRGB
    const orange_ok = tokens.OklabColor.fromSrgb(core.Nord.aurora_orange);
    const orange_rt = orange_ok.toSrgb();
    try std.testing.expectApproxEqAbs(core.Nord.aurora_orange[0], orange_rt[0], 0.002);
    try std.testing.expectApproxEqAbs(core.Nord.aurora_orange[1], orange_rt[1], 0.002);
    try std.testing.expectApproxEqAbs(core.Nord.aurora_orange[2], orange_rt[2], 0.002);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), orange_rt[3], 1.0e-6);

    // Non-finite / out-of-range inputs are sanitized safely
    const weird = tokens.OklabColor.fromSrgb(.{ std.math.nan(f32), -5.0, 2.5, std.math.inf(f32) });
    try std.testing.expect(std.math.isFinite(weird.l));
    try std.testing.expect(std.math.isFinite(weird.a));
    try std.testing.expect(std.math.isFinite(weird.b));
    try std.testing.expect(std.math.isFinite(weird.alpha));
}

test "AnimationPool: snapSpring and restartSpring reset value and animate cleanly to target" {
    var pool = anim.AnimationPool.init();
    const pop_key = anim.hashKey("popup", "scale");

    // Cold-start restartSpring(0.88 -> 1.0, bouncy) starts at 0.88 and animates to 1.0
    pool.restartSpring(pop_key, 0.88, 1.0, anim.SpringConfig.bouncy);
    try std.testing.expect(pool.isAnimating());
    const s0 = pool.animateSpring(pop_key, 1.0, anim.SpringConfig.bouncy);
    try std.testing.expectApproxEqAbs(@as(f32, 0.88), s0, 1.0e-5);

    var steps: usize = 0;
    while (pool.isAnimating() and steps < 240) : (steps += 1) {
        _ = pool.step(1.0 / 60.0);
    }
    try std.testing.expect(!pool.isAnimating());
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pool.animateSpring(pop_key, 1.0, anim.SpringConfig.bouncy), 1.0e-5);

    // Re-triggering after settling must restart from 0.88 again
    pool.restartSpring(pop_key, 0.88, 1.0, anim.SpringConfig.bouncy);
    try std.testing.expect(pool.isAnimating());
    try std.testing.expectApproxEqAbs(@as(f32, 0.88), pool.animateSpring(pop_key, 1.0, anim.SpringConfig.bouncy), 1.0e-5);

    // snapSpring stops animation immediately and sanitizes NaN
    pool.snapSpring(pop_key, 1.0);
    try std.testing.expect(!pool.isAnimating());
    pool.snapSpring(pop_key, std.math.nan(f32));
    try std.testing.expect(!pool.isAnimating());
    try std.testing.expectEqual(@as(f32, 0.0), pool.animateSpring(pop_key, 0.0, anim.SpringConfig.snappy));

    // reduced_motion skips straight to target on restartSpring
    pool.setReducedMotion(true);
    pool.restartSpring(pop_key, 5.0, 2.0, anim.SpringConfig.snappy);
    try std.testing.expect(!pool.isAnimating());
    try std.testing.expectEqual(@as(f32, 2.0), pool.animateSpring(pop_key, 2.0, anim.SpringConfig.snappy));
}

test "TweenState: zero-delta init settles immediately, duration=0 setTarget snaps mid-flight, and value sanitizes NaN" {
    // 1. init with from == to does not stay active
    const noop_tw = anim.TweenState.init(5.0, 5.0, 0.5, .linear);
    try std.testing.expect(!noop_tw.isAnimating());
    try std.testing.expectEqual(@as(f32, 5.0), noop_tw.value());

    // 2. setTarget(same_to, 0.0, ...) while mid-flight snaps immediately
    var tw = anim.TweenState.init(0.0, 100.0, 1.0, .linear);
    _ = tw.step(0.25);
    try std.testing.expect(tw.isAnimating());
    tw.setTarget(100.0, 0.0, .linear);
    try std.testing.expect(!tw.isAnimating());
    try std.testing.expectEqual(@as(f32, 100.0), tw.value());

    // 3. Corrupted non-finite `to` returns 0.0 safely from value()
    tw.to = std.math.nan(f32);
    try std.testing.expectEqual(@as(f32, 0.0), tw.value());
}
