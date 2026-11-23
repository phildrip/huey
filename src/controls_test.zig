const std = @import("std");
const controls = @import("widgets/controls.zig");
const core = @import("core.zig");
const tokens = @import("tokens.zig");
const anim = @import("animation.zig");

test "Button: variants resolve contrasting colors and spring shape-morphs on press" {
    const tbl = tokens.TokenTable.nordDefault();
    var pool = anim.AnimationPool.init();

    const btn = controls.ButtonSpec{
        .id = "btn_lock",
        .label = "LOCK",
        .variant = .primary,
        .shape = .pill,
        .pressed = false,
    };
    var quads: [16]core.QuadInstance = undefined;
    const n0 = controls.emitButton(btn, .{ .x = 20, .y = 20, .w = 64, .h = 64 }, 2.0, &tbl, &pool, &quads, .{ 0, 0, 466, 466 });
    try std.testing.expectEqual(@as(usize, 1), n0);
    const idle_radius = quads[0].params[0];

    // Press -> morphs corner radius smoothly toward rounded square (animatedShapes!)
    var pressed_btn = btn;
    pressed_btn.pressed = true;
    _ = controls.emitButton(pressed_btn, .{ .x = 20, .y = 20, .w = 64, .h = 64 }, 2.0, &tbl, &pool, &quads, .{ 0, 0, 466, 466 });
    try std.testing.expect(pool.isAnimating());
    _ = pool.step(1.0 / 30.0);
    _ = controls.emitButton(pressed_btn, .{ .x = 20, .y = 20, .w = 64, .h = 64 }, 2.0, &tbl, &pool, &quads, .{ 0, 0, 466, 466 });
    try std.testing.expect(quads[0].params[0] < idle_radius);
}

test "Checkbox, Switch & RadioGroup: state transitions and quad emission" {
    const tbl = tokens.TokenTable.nordDefault();
    var pool = anim.AnimationPool.init();
    var quads: [32]core.QuadInstance = undefined;

    // Checkbox (unchecked -> checked -> indeterminate)
    const n_cb = controls.emitCheckbox(.{ .id = "cb1", .state = .checked }, .{ .x = 10, .y = 10, .w = 24, .h = 24 }, 2.0, &tbl, &pool, &quads, .{ 0, 0, 400, 400 });
    try std.testing.expect(n_cb >= 2);

    // Switch with spring-sliding thumb
    const n_sw0 = controls.emitSwitch(.{ .id = "sw1", .checked = false }, .{ .x = 10, .y = 50, .w = 52, .h = 30 }, 2.0, &tbl, &pool, &quads, .{ 0, 0, 400, 400 });
    try std.testing.expectEqual(@as(usize, 2), n_sw0);
    const thumb_off_x = quads[1].pos_size[0];
    _ = controls.emitSwitch(.{ .id = "sw1", .checked = true }, .{ .x = 10, .y = 50, .w = 52, .h = 30 }, 2.0, &tbl, &pool, &quads, .{ 0, 0, 400, 400 });
    for (0..30) |_| _ = pool.step(1.0 / 60.0);
    _ = controls.emitSwitch(.{ .id = "sw1", .checked = true }, .{ .x = 10, .y = 50, .w = 52, .h = 30 }, 2.0, &tbl, &pool, &quads, .{ 0, 0, 400, 400 });
    try std.testing.expect(quads[1].pos_size[0] > thumb_off_x + 10.0);

    // RadioGroup selection
    var rg = controls.RadioGroup.init(3, 0);
    try std.testing.expectEqual(@as(usize, 0), rg.selected);
    rg.selectNext();
    try std.testing.expectEqual(@as(usize, 1), rg.selected);
    rg.selectPrev();
    try std.testing.expectEqual(@as(usize, 0), rg.selected);
    rg.selectPrev(); // wraps cleanly
    try std.testing.expectEqual(@as(usize, 2), rg.selected);
}

test "Regression: Checkbox indeterminate small-side clamp stays inside box" {
    const tbl = tokens.TokenTable.nordDefault();
    var pool = anim.AnimationPool.init();
    var quads: [8]core.QuadInstance = undefined;
    const clip = [4]f32{ 0, 0, 200, 200 };

    const n = controls.emitCheckbox(
        .{ .id = "cb_tiny", .state = .indeterminate },
        .{ .x = 10, .y = 10, .w = 1.2, .h = 1.2 },
        2.0,
        &tbl,
        &pool,
        &quads,
        clip,
    );
    try std.testing.expectEqual(@as(usize, 2), n);

    const box = quads[0].pos_size;
    const ind = quads[1].pos_size;
    try std.testing.expect(ind[3] > 0.0);
    try std.testing.expect(ind[3] < box[3]);
    try std.testing.expect(ind[0] >= box[0]);
    try std.testing.expect(ind[1] >= box[1]);
    try std.testing.expect(ind[0] + ind[2] <= box[0] + box[2]);
    try std.testing.expect(ind[1] + ind[3] <= box[1] + box[3]);
}

test "Regression: ±inf clip_rect and NaN/Inf rect or scale emit 0 quads" {
    const tbl = tokens.TokenTable.nordDefault();
    var pool = anim.AnimationPool.init();
    var quads: [16]core.QuadInstance = undefined;
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);

    const valid_rect = core.Rect{ .x = 10, .y = 10, .w = 40, .h = 24 };
    const valid_clip = [4]f32{ 0, 0, 400, 400 };
    var tg = controls.ToggleGroup.init(2, false);
    tg.select(0);
    const items = [_]controls.ButtonSpec{.{ .id = "b0", .label = "B" }};

    // ±inf clip_rect variants
    const bad_clips = [_][4]f32{
        .{ -inf, 0, 100, 100 },
        .{ 0, -inf, 100, 100 },
        .{ 0, 0, inf, 100 },
        .{ 0, 0, 100, inf },
        .{ nan, 0, 100, 100 },
    };
    for (bad_clips) |bad_clip| {
        try std.testing.expectEqual(@as(usize, 0), controls.emitButton(.{ .id = "b" }, valid_rect, 2.0, &tbl, &pool, &quads, bad_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitButtonGroup(.{ .id = "bg", .items = &items }, valid_rect, 2.0, &tbl, &pool, &quads, bad_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitCheckbox(.{ .id = "cb", .state = .checked }, valid_rect, 2.0, &tbl, &pool, &quads, bad_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitSwitch(.{ .id = "sw", .checked = true }, valid_rect, 2.0, &tbl, &pool, &quads, bad_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitRadio(.{ .id = "rd", .selected = true }, valid_rect, 2.0, &tbl, &pool, &quads, bad_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitToggleGroup(.{ .id = "tg", .labels = &.{ "A", "B" }, .group = &tg }, valid_rect, 2.0, &tbl, &pool, &quads, bad_clip));
    }

    // NaN / Inf in rect or scale
    const bad_rects = [_]core.Rect{
        .{ .x = nan, .y = 10, .w = 40, .h = 24 },
        .{ .x = 10, .y = inf, .w = 40, .h = 24 },
        .{ .x = 10, .y = 10, .w = inf, .h = 24 },
        .{ .x = 10, .y = 10, .w = 40, .h = -inf },
        .{ .x = 10, .y = 10, .w = nan, .h = 24 },
    };
    for (bad_rects) |bad_rect| {
        try std.testing.expectEqual(@as(usize, 0), controls.emitButton(.{ .id = "b" }, bad_rect, 2.0, &tbl, &pool, &quads, valid_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitButtonGroup(.{ .id = "bg", .items = &items }, bad_rect, 2.0, &tbl, &pool, &quads, valid_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitCheckbox(.{ .id = "cb", .state = .checked }, bad_rect, 2.0, &tbl, &pool, &quads, valid_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitSwitch(.{ .id = "sw", .checked = true }, bad_rect, 2.0, &tbl, &pool, &quads, valid_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitRadio(.{ .id = "rd", .selected = true }, bad_rect, 2.0, &tbl, &pool, &quads, valid_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitToggleGroup(.{ .id = "tg", .labels = &.{ "A", "B" }, .group = &tg }, bad_rect, 2.0, &tbl, &pool, &quads, valid_clip));
    }

    const bad_scales = [_]f32{ nan, inf, -inf, 0.0, -1.0 };
    for (bad_scales) |bad_scale| {
        try std.testing.expectEqual(@as(usize, 0), controls.emitButton(.{ .id = "b" }, valid_rect, bad_scale, &tbl, &pool, &quads, valid_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitButtonGroup(.{ .id = "bg", .items = &items }, valid_rect, bad_scale, &tbl, &pool, &quads, valid_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitCheckbox(.{ .id = "cb", .state = .checked }, valid_rect, bad_scale, &tbl, &pool, &quads, valid_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitSwitch(.{ .id = "sw", .checked = true }, valid_rect, bad_scale, &tbl, &pool, &quads, valid_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitRadio(.{ .id = "rd", .selected = true }, valid_rect, bad_scale, &tbl, &pool, &quads, valid_clip));
        try std.testing.expectEqual(@as(usize, 0), controls.emitToggleGroup(.{ .id = "tg", .labels = &.{ "A", "B" }, .group = &tg }, valid_rect, bad_scale, &tbl, &pool, &quads, valid_clip));
    }
}

test "Regression: ToggleGroup disabled+focused unselected skips segment quad" {
    const tbl = tokens.TokenTable.nordDefault();
    var pool = anim.AnimationPool.init();
    var quads: [16]core.QuadInstance = undefined;
    const clip = [4]f32{ 0, 0, 400, 400 };
    const rect = core.Rect{ .x = 10, .y = 10, .w = 180, .h = 36 };

    const tg = controls.ToggleGroup.init(3, false);

    // Disabled + focused on unselected segment -> only track quad emitted
    const n_disabled = controls.emitToggleGroup(.{
        .id = "tg_disabled_focus",
        .labels = &.{ "A", "B", "C" },
        .group = &tg,
        .disabled = true,
        .focused_idx = 1,
    }, rect, 2.0, &tbl, &pool, &quads, clip);
    try std.testing.expectEqual(@as(usize, 1), n_disabled);

    // Enabled + focused on unselected segment -> track + focus ring quad emitted
    const n_enabled = controls.emitToggleGroup(.{
        .id = "tg_enabled_focus",
        .labels = &.{ "A", "B", "C" },
        .group = &tg,
        .disabled = false,
        .focused_idx = 1,
    }, rect, 2.0, &tbl, &pool, &quads, clip);
    try std.testing.expectEqual(@as(usize, 2), n_enabled);
}

test "Regression: RadioGroup count==0, initial>=count, and maxInt(usize) overflow guard" {
    var rg0 = controls.RadioGroup.init(0, 5);
    try std.testing.expectEqual(@as(usize, 0), rg0.count);
    try std.testing.expectEqual(@as(usize, 0), rg0.selected);
    rg0.select(0);
    rg0.selectNext();
    rg0.selectPrev();
    try std.testing.expectEqual(@as(usize, 0), rg0.selected);

    const rg_oob = controls.RadioGroup.init(3, 10);
    try std.testing.expectEqual(@as(usize, 2), rg_oob.selected);

    var rg_max = controls.RadioGroup{ .count = 3, .selected = std.math.maxInt(usize) };
    rg_max.selectNext();
    try std.testing.expectEqual(@as(usize, 1), rg_max.selected);

    rg_max.selected = std.math.maxInt(usize);
    rg_max.selectPrev();
    try std.testing.expectEqual(@as(usize, 2), rg_max.selected);
}

test "Regression: emitSwitch with w < h and emitButtonGroup with empty items" {
    const tbl = tokens.TokenTable.nordDefault();
    var pool = anim.AnimationPool.init();
    var quads: [16]core.QuadInstance = undefined;
    const clip = [4]f32{ 0, 0, 400, 400 };

    // emitSwitch with narrow/tall rect (w < h)
    const n_sw = controls.emitSwitch(
        .{ .id = "sw_narrow", .checked = true },
        .{ .x = 10, .y = 10, .w = 20, .h = 40 },
        2.0,
        &tbl,
        &pool,
        &quads,
        clip,
    );
    try std.testing.expectEqual(@as(usize, 2), n_sw);
    const track = quads[0].pos_size;
    const thumb = quads[1].pos_size;
    try std.testing.expect(thumb[0] >= track[0]);
    try std.testing.expect(thumb[0] + thumb[2] <= track[0] + track[2]);
    try std.testing.expect(thumb[1] >= track[1]);
    try std.testing.expect(thumb[1] + thumb[3] <= track[1] + track[3]);

    // emitButtonGroup with items.len == 0
    const n_bg = controls.emitButtonGroup(
        .{ .id = "bg_empty", .items = &.{} },
        .{ .x = 10, .y = 60, .w = 200, .h = 40 },
        2.0,
        &tbl,
        &pool,
        &quads,
        clip,
    );
    try std.testing.expectEqual(@as(usize, 0), n_bg);
}
