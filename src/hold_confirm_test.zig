const std = @import("std");
const hc = @import("hold_confirm.zig");
const core = @import("core.zig");

test "HoldToConfirm: does not fire on early release and rewinds cleanly to 0% idle" {
    var ctrl = hc.HoldToConfirm.init(1.5);
    try std.testing.expect(!ctrl.isAnimating());
    try std.testing.expectEqual(@as(u32, 0), ctrl.fired_count);

    ctrl.beginHold(1);
    try std.testing.expect(ctrl.isAnimating());

    // Hold for 1.0s (< 1.5s) -> must NOT fire
    var fired = false;
    for (0..60) |_| {
        if (ctrl.step(1.0 / 60.0)) fired = true;
    }
    try std.testing.expect(!fired);
    try std.testing.expect(ctrl.progress > 0.6 and ctrl.progress < 0.72);
    try std.testing.expectEqual(@as(u32, 0), ctrl.fired_count);

    // Release early -> rewinds back to 0.0 and stops animating
    ctrl.endHold(1);
    for (0..120) |_| {
        try std.testing.expect(!ctrl.step(1.0 / 60.0));
    }
    try std.testing.expectEqual(@as(f32, 0.0), ctrl.progress);
    try std.testing.expect(!ctrl.isAnimating());
    try std.testing.expectEqual(@as(u32, 0), ctrl.fired_count);
}

test "HoldToConfirm: fires exactly once at 360 deg (100%) and settles after firework burst" {
    var ctrl = hc.HoldToConfirm.init(1.5);
    ctrl.beginHold(7);

    var fire_events: u32 = 0;
    // Step 2.0s (120 frames) while still holding -> must fire EXACTLY ONCE at ~1.5s
    for (0..120) |_| {
        if (ctrl.step(1.0 / 60.0)) fire_events += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), fire_events);
    try std.testing.expectEqual(@as(u32, 1), ctrl.fired_count);
    try std.testing.expect(ctrl.burst_timer_s > 0.0 or ctrl.activeSparkCount() > 0);

    // Release and step burst until completely settled -> 0% idle CPU
    ctrl.endHold(7);
    var steps: usize = 0;
    while (ctrl.isAnimating() and steps < 240) : (steps += 1) {
        try std.testing.expect(!ctrl.step(1.0 / 60.0));
    }
    try std.testing.expect(!ctrl.isAnimating());
    try std.testing.expectEqual(@as(f32, 0.0), ctrl.progress);
    try std.testing.expectEqual(@as(usize, 0), ctrl.activeSparkCount());
}

test "HoldToConfirm: pointer slip outside button bounds cancels hold without firing" {
    var ctrl = hc.HoldToConfirm.init(1.0);
    const btn_rect = core.Rect{ .x = 40, .y = 100, .w = 80, .h = 48 };
    ctrl.beginHold(3);
    _ = ctrl.step(0.5);
    try std.testing.expect(ctrl.holding);

    // Move slightly inside slop (6dp outside) -> still holding
    ctrl.updatePointerMove(3, 126, 120, btn_rect);
    try std.testing.expect(ctrl.holding);

    // Slip far outside -> cancels hold
    ctrl.updatePointerMove(3, 200, 200, btn_rect);
    try std.testing.expect(!ctrl.holding);
}

test "emitPerimeterFireworkQuads: emits sweeping arc, comet head, and sparks inside watch bezel" {
    var ctrl = hc.HoldToConfirm.init(1.5);
    ctrl.beginHold(1);
    for (0..45) |_| _ = ctrl.step(1.0 / 60.0); // ~50% (180 deg)

    var quads: [160]core.QuadInstance = undefined;
    const count = ctrl.emitPerimeterFireworkQuads(
        &quads,
        233.0,
        233.0,
        226.0,
        8.0,
        .{ 0, 0, 466, 466 },
    );
    try std.testing.expect(count >= 20 and count <= quads.len);
    for (quads[0..count]) |q| {
        for (q.pos_size) |v| try std.testing.expect(std.math.isFinite(v));
        try std.testing.expect(q.pos_size[2] > 0 and q.pos_size[3] > 0);
        try std.testing.expect(q.color[3] >= 0.0 and q.color[3] <= 1.0);
    }
}

test "HoldToConfirm: NaN/Inf/negative dt and invalid duration handled safely" {
    var ctrl = hc.HoldToConfirm.init(std.math.nan(f32));
    ctrl.beginHold(1);
    try std.testing.expect(!ctrl.step(std.math.nan(f32)));
    try std.testing.expect(!ctrl.step(-1.0));
    try std.testing.expect(!ctrl.step(std.math.inf(f32)));
    try std.testing.expect(std.math.isFinite(ctrl.progress));
}

test "HoldToConfirm: rapid re-press during rewind resets progress and prevents premature trigger" {
    var ctrl = hc.HoldToConfirm.init(1.5);
    ctrl.beginHold(1);
    // Hold 1.4s -> ~93.3%
    for (0..84) |_| _ = ctrl.step(1.0 / 60.0);
    try std.testing.expect(ctrl.progress > 0.9);

    // Release and rewind briefly (still > 0.7)
    ctrl.endHold(1);
    _ = ctrl.step(0.05);
    try std.testing.expect(ctrl.progress > 0.7);

    // Rapid re-press must reset progress to 0.0 and require a fresh full 1.5s hold
    ctrl.beginHold(2);
    try std.testing.expectEqual(@as(f32, 0.0), ctrl.progress);
    for (0..30) |_| {
        try std.testing.expect(!ctrl.step(1.0 / 60.0));
    }
    try std.testing.expectEqual(@as(u32, 0), ctrl.fired_count);
}

test "HoldToConfirm: active hold cannot be hijacked by second pointer and sub-ms tap settles to 0" {
    var ctrl = hc.HoldToConfirm.init(1.5);
    ctrl.beginHold(1);
    // Second pointer cannot steal active_pointer_id mid-hold
    ctrl.beginHold(2);
    try std.testing.expectEqual(@as(?i32, 1), ctrl.active_pointer_id);

    // Sub-1.5ms tap (progress < 0.001) still animates until rewound to exact 0.0
    _ = ctrl.step(0.001);
    try std.testing.expect(ctrl.progress > 0.0 and ctrl.progress < 0.001);
    ctrl.endHold(1);
    try std.testing.expect(ctrl.isAnimating());
    _ = ctrl.step(1.0 / 60.0);
    try std.testing.expectEqual(@as(f32, 0.0), ctrl.progress);
    try std.testing.expect(!ctrl.isAnimating());
}

test "HoldToConfirm: spark pool exhaustion, buffer truncation, and invalid quad params" {
    var ctrl = hc.HoldToConfirm.init(0.5);
    ctrl.spawn_accum_s = 1000.0; // must stay bounded
    ctrl.beginHold(1);
    for (0..60) |_| _ = ctrl.step(1.0 / 60.0);
    try std.testing.expect(ctrl.activeSparkCount() <= hc.MAX_SPARKS);

    var empty: [0]core.QuadInstance = undefined;
    try std.testing.expectEqual(@as(usize, 0), ctrl.emitPerimeterFireworkQuads(&empty, 100, 100, 90, 4, .{ 0, 0, 200, 200 }));

    var tiny: [5]core.QuadInstance = undefined;
    const n_tiny = ctrl.emitPerimeterFireworkQuads(&tiny, 100, 100, 90, 4, .{ 0, 0, 200, 200 });
    try std.testing.expectEqual(@as(usize, 5), n_tiny);

    var buf: [64]core.QuadInstance = undefined;
    try std.testing.expectEqual(@as(usize, 0), ctrl.emitPerimeterFireworkQuads(&buf, 100, 100, -5, 4, .{ 0, 0, 200, 200 }));
    try std.testing.expectEqual(@as(usize, 0), ctrl.emitPerimeterFireworkQuads(&buf, 100, 100, 90, 0, .{ 0, 0, 200, 200 }));
    try std.testing.expectEqual(@as(usize, 0), ctrl.emitPerimeterFireworkQuads(&buf, std.math.nan(f32), 100, 90, 4, .{ 0, 0, 200, 200 }));
    try std.testing.expectEqual(@as(usize, 0), ctrl.emitPerimeterFireworkQuads(&buf, 100, 100, 90, 4, .{ 0, 0, std.math.nan(f32), 200 }));
}
