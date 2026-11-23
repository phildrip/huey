const std = @import("std");
const core = @import("core.zig");
const events = @import("events.zig");
const wearos = @import("wearos.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const wear_showcase = @import("wear_showcase_scene.zig");

const HOST_FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";

fn loadHostFont(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, HOST_FONT_PATH, allocator, .limited(4 * 1024 * 1024));
}

fn tapNode(
    app: *wear_showcase.WearShowcaseApp,
    arena: *core.LayoutArena,
    router: *events.EventRouter,
    test_id: []const u8,
    w: f32,
    h: f32,
) !bool {
    const id = arena.findByTestId(test_id) orelse return error.TestNodeNotFound;
    const r = arena.getRect(id) orelse return error.TestNodeNotFound;
    const cx = r.x + r.w * 0.5;
    const cy = r.y + r.h * 0.5;

    if (app.handlePointerDown(cx, cy)) {
        return false;
    }

    router.dispatch(arena, .{ .pointer_down = .{
        .pointer_id = 1,
        .x = cx,
        .y = cy,
        .is_touch = true,
    } });
    router.dispatch(arena, .{ .pointer_up = .{
        .pointer_id = 1,
        .x = cx,
        .y = cy,
        .is_touch = true,
    } });

    var rebuilt = false;
    while (router.nextEvent()) |ev| {
        if (app.handleUiEvent(ev, w, h)) {
            rebuilt = true;
        }
    }
    if (rebuilt) {
        try app.buildScene(arena, w, h);
        arena.layout(w, h);
    }
    return rebuilt;
}

test "WearShowcaseApp 233x233 round OLED layout fits inscribed safe square and scrolls" {
    var app = wear_showcase.WearShowcaseApp.init();
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const w: f32 = 233.0;
    const h: f32 = 233.0;
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);

    // True-black #000000 root background for OLED power savings
    const root_id = arena.findByTestId("wear.root").?;
    const root_fill = arena.nodes.items(.fill)[root_id.index];
    try std.testing.expectEqual(@as(f32, 0.0), root_fill[0]);
    try std.testing.expectEqual(@as(f32, 0.0), root_fill[1]);
    try std.testing.expectEqual(@as(f32, 0.0), root_fill[2]);
    try std.testing.expectEqual(@as(f32, 1.0), root_fill[3]);

    // Scrollable container exists and clips children
    const sc = app.scroll_container orelse return error.MissingScrollContainer;
    try std.testing.expect(arena.nodes.items(.scroll_props)[sc.index].clip_children);
    const body_r = arena.getRect(sc).?;
    const content_h = arena.contentHeight(sc);
    try std.testing.expect(content_h > body_r.h);

    // Inscribed safe square for 233x233 round watch (~34.12dp margin, ~164.75dp width)
    const safe = wearos.WearConfig.init(w, h, true, 0.0).safeRect();
    const card_ids = [_][]const u8{ "wear_tesla_card", "wear_theme_card", "wear_stats_card" };
    for (card_ids) |cid| {
        const nid = arena.findByTestId(cid) orelse return error.MissingCard;
        const r = arena.getRect(nid).?;
        try std.testing.expect(r.x >= safe.x - 0.1);
        try std.testing.expect(r.x + r.w <= safe.x + safe.w + 0.1);
    }

    // Ergonomic touch targets
    const lock_r = arena.getRect(arena.findByTestId("wear_lock").?).?;
    try std.testing.expect(lock_r.h >= 48.0);
    const trunk_r = arena.getRect(arena.findByTestId("wear_trunk").?).?;
    try std.testing.expect(trunk_r.h >= 44.0);
    try std.testing.expect(trunk_r.w >= 44.0);
    const flash_r = arena.getRect(arena.findByTestId("wear_flash").?).?;
    try std.testing.expect(flash_r.h >= 44.0);
    try std.testing.expect(flash_r.w >= 44.0);
    const ambient_r = arena.getRect(arena.findByTestId("wear_ambient").?).?;
    try std.testing.expect(ambient_r.h >= 46.0);
    try std.testing.expect(ambient_r.w >= 120.0);

    // Scrolling shifts cards upward into the center
    const card3_before = arena.getRect(arena.findByTestId("wear_stats_card").?).?;
    arena.setScroll(sc, 0.0, 140.0);
    arena.layout(w, h);
    const card3_after = arena.getRect(arena.findByTestId("wear_stats_card").?).?;
    try std.testing.expectApproxEqAbs(card3_before.y - 140.0, card3_after.y, 0.01);
}

test "WearShowcaseApp Tesla Key interactions: lock, trunk, flash" {
    var app = wear_showcase.WearShowcaseApp.init();
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var router = events.EventRouter.init();

    const w: f32 = 233.0;
    const h: f32 = 233.0;
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);

    // Initial locked state -> Nord Frost
    try std.testing.expect(app.locked);
    const lock_id_0 = arena.findByTestId("wear_lock").?;
    try std.testing.expectEqualStrings("LOCKED", arena.nodes.items(.label)[lock_id_0.index]);
    try std.testing.expectApproxEqAbs(core.Nord.frost_1[0], arena.nodes.items(.fill)[lock_id_0.index][0], 1e-5);
    const hdr_0 = arena.findByTestId("wear_tesla_header").?;
    try std.testing.expectEqualStrings("MODEL Y", arena.nodes.items(.label)[hdr_0.index]);
    try std.testing.expectEqualStrings("LOCKED", arena.nodes.items(.sublabel)[hdr_0.index]);

    // Tap wear_lock -> UNLOCKED + Oklab morph to Aurora Green + Bezel pulse (5.0 -> 2.0)
    try std.testing.expect(!app.isAnimating());
    try std.testing.expect(try tapNode(&app, &arena, &router, "wear_lock", w, h));
    try std.testing.expect(!app.locked);
    try std.testing.expect(app.isAnimating());
    const lock_id_1 = arena.findByTestId("wear_lock").?;
    try std.testing.expectEqualStrings("UNLOCKED", arena.nodes.items(.label)[lock_id_1.index]);
    const hdr_1 = arena.findByTestId("wear_tesla_header").?;
    try std.testing.expectEqualStrings("UNLOCKED", arena.nodes.items(.sublabel)[hdr_1.index]);

    // Frame 0 bezel width starts pulsed at 5.0dp
    var pulse_quads: [2048]core.QuadInstance = undefined;
    const base_p0 = arena.emitQuads(&pulse_quads, 1.0);
    const total_p0 = app.emitPostQuads(&arena, &pulse_quads, base_p0, w, h, 1.0, null, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), pulse_quads[total_p0 - 1].params[1], 0.1);

    // Mid-flight step: color morphs in Oklab and bezel_w shrinks toward 2.0
    _ = app.stepAnimations(1.0 / 60.0);
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);
    const lock_mid = arena.nodes.items(.fill)[arena.findByTestId("wear_lock").?.index];
    try std.testing.expect(lock_mid[0] != core.Nord.aurora_green[0] or lock_mid[1] != core.Nord.aurora_green[1]);

    var steps: usize = 0;
    while (app.isAnimating() and steps < 240) : (steps += 1) {
        _ = app.stepAnimations(1.0 / 60.0);
    }
    try std.testing.expect(!app.isAnimating());
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);
    const lock_settled = arena.findByTestId("wear_lock").?;
    try std.testing.expectApproxEqAbs(core.Nord.aurora_green[0], arena.nodes.items(.fill)[lock_settled.index][0], 1e-4);
    const base_p1 = arena.emitQuads(&pulse_quads, 1.0);
    const total_p1 = app.emitPostQuads(&arena, &pulse_quads, base_p1, w, h, 1.0, null, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), pulse_quads[total_p1 - 1].params[1], 0.01);

    // Tap wear_lock again -> LOCKED + bezel pulse
    try std.testing.expect(try tapNode(&app, &arena, &router, "wear_lock", w, h));
    try std.testing.expect(app.locked);
    try std.testing.expect(app.isAnimating());
    while (app.isAnimating()) _ = app.stepAnimations(1.0 / 60.0);

    // Tap wear_trunk -> OPEN -> TRUNK (each triggers bezel pulse)
    const trunk_0 = arena.findByTestId("wear_trunk").?;
    try std.testing.expectEqualStrings("TRUNK", arena.nodes.items(.label)[trunk_0.index]);
    try std.testing.expect(try tapNode(&app, &arena, &router, "wear_trunk", w, h));
    try std.testing.expect(app.trunk_open);
    try std.testing.expect(app.isAnimating());
    try std.testing.expectEqualStrings("OPEN", arena.nodes.items(.label)[arena.findByTestId("wear_trunk").?.index]);
    while (app.isAnimating()) _ = app.stepAnimations(1.0 / 60.0);
    try std.testing.expect(try tapNode(&app, &arena, &router, "wear_trunk", w, h));
    try std.testing.expect(!app.trunk_open);
    try std.testing.expectEqualStrings("TRUNK", arena.nodes.items(.label)[arena.findByTestId("wear_trunk").?.index]);
    while (app.isAnimating()) _ = app.stepAnimations(1.0 / 60.0);

    // Tap wear_flash -> FLASH 1 -> FLASH 2 (triggers bezel pulse)
    const flash_0 = arena.findByTestId("wear_flash").?;
    try std.testing.expectEqualStrings("FLASH", arena.nodes.items(.label)[flash_0.index]);
    try std.testing.expect(try tapNode(&app, &arena, &router, "wear_flash", w, h));
    try std.testing.expectEqual(@as(u32, 1), app.flash_count);
    try std.testing.expect(app.isAnimating());
    try std.testing.expectEqualStrings("FLASH 1", arena.nodes.items(.label)[arena.findByTestId("wear_flash").?.index]);
    while (app.isAnimating()) _ = app.stepAnimations(1.0 / 60.0);
    try std.testing.expect(try tapNode(&app, &arena, &router, "wear_flash", w, h));
    try std.testing.expectEqual(@as(u32, 2), app.flash_count);
    try std.testing.expectEqualStrings("FLASH 2", arena.nodes.items(.label)[arena.findByTestId("wear_flash").?.index]);
    while (app.isAnimating()) _ = app.stepAnimations(1.0 / 60.0);
}

test "WearShowcaseApp Nord accent swatches, bezel ring, and OLED ambient transform" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 512, 512);
    defer atlas.deinit();

    var app = wear_showcase.WearShowcaseApp.init();
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var router = events.EventRouter.init();

    const w: f32 = 233.0;
    const h: f32 = 233.0;
    const scale: f32 = 2.0;
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);

    // Scroll Card 2 into view so its swatches and ambient switch are well inside viewport
    const sc = app.scroll_container.?;
    arena.setScroll(sc, 0.0, 140.0);
    arena.layout(w, h);

    for (0..wear_showcase.ACCENTS.len) |i| {
        var id_buf: [20]u8 = undefined;
        const aid = try std.fmt.bufPrint(&id_buf, "wear_accent_{d}", .{i});
        try std.testing.expect(try tapNode(&app, &arena, &router, aid, w, h));
        try std.testing.expectEqual(@as(u8, @intCast(i)), app.accent_idx);

        if (i > 0) {
            try std.testing.expect(app.isAnimating());
            var steps: usize = 0;
            while (app.isAnimating() and steps < 240) : (steps += 1) {
                _ = app.stepAnimations(1.0 / 60.0);
                // Finding #2: rebuilding scene every VSync frame while locked must converge cleanly without re-waking lock_color
                try app.buildScene(&arena, w, h);
            }
            try std.testing.expect(!app.isAnimating());
            try app.buildScene(&arena, w, h);
            try std.testing.expect(!app.isAnimating());
            const lock_idx = arena.findByTestId("wear_lock").?.index;
            try std.testing.expectApproxEqAbs(wear_showcase.ACCENTS[i][0], arena.nodes.items(.fill)[lock_idx][0], 1e-4);
            try std.testing.expectApproxEqAbs(wear_showcase.ACCENTS[i][1], arena.nodes.items(.fill)[lock_idx][1], 1e-4);
        }

        // Keep Card 2 scrolled in view after rebuild
        arena.setScroll(app.scroll_container.?, 0.0, 140.0);
        arena.layout(w, h);

        var quads: [2048]core.QuadInstance = undefined;
        const base_count = arena.emitQuadsWithAtlas(&quads, scale, &atlas, @intCast(i + 1));
        const total = app.emitPostQuads(&arena, &quads, base_count, w, h, scale, &atlas, @intCast(i + 1));
        try std.testing.expectEqual(base_count + 1, total);

        const bezel = quads[total - 1];
        try std.testing.expectApproxEqAbs(2.0 * scale, bezel.pos_size[0], 0.01);
        try std.testing.expectApproxEqAbs(2.0 * scale, bezel.pos_size[1], 0.01);
        try std.testing.expectApproxEqAbs((w - 4.0) * scale, bezel.pos_size[2], 0.01);
        try std.testing.expectApproxEqAbs((h - 4.0) * scale, bezel.pos_size[3], 0.01);
        try std.testing.expectApproxEqAbs((w * 0.5 - 2.0) * scale, bezel.params[0], 0.01);
        try std.testing.expectApproxEqAbs(2.0 * scale, bezel.params[1], 0.01);
        try std.testing.expectEqual(@as(f32, 0.0), bezel.color[3]);
        try std.testing.expectApproxEqAbs(wear_showcase.ACCENTS[i][0], bezel.border_color[0], 1e-4);
        try std.testing.expectApproxEqAbs(wear_showcase.ACCENTS[i][1], bezel.border_color[1], 1e-4);
        try std.testing.expectApproxEqAbs(wear_showcase.ACCENTS[i][2], bezel.border_color[2], 1e-4);
    }

    // Toggle wear_ambient ON and verify full-frame ambient OLED transform + reduced motion (no 60Hz animations)
    try std.testing.expect(try tapNode(&app, &arena, &router, "wear_ambient", w, h));
    try std.testing.expect(app.wear_ambient);
    try std.testing.expect(!app.isAnimating());
    // Tapping lock while in OLED ambient mode must not wake 60Hz animations
    try std.testing.expect(app.handleUiEvent(.{ .clicked = .{ .id = .{ .index = 0, .gen = 1 }, .test_id = "wear_lock" } }, w, h));
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);
    try std.testing.expect(!app.isAnimating());

    var quads: [2048]core.QuadInstance = undefined;
    const base_count = arena.emitQuadsWithAtlas(&quads, scale, &atlas, 10);
    const total = app.emitPostQuads(&arena, &quads, base_count, w, h, scale, &atlas, 10);
    try std.testing.expect(total > base_count);

    var saw_glyph = false;
    for (quads[0..total]) |q| {
        try std.testing.expectEqual(@as(f32, 0.0), q.params[2]); // shadow blur stripped
        if (q.params[3] > 0.5) {
            saw_glyph = true;
            // Oklab grayscale glyph (R == G == B)
            try std.testing.expectApproxEqAbs(q.color[0], q.color[1], 1e-5);
            try std.testing.expectApproxEqAbs(q.color[1], q.color[2], 1e-5);
        } else if (q.color[3] > 0.0 and q.params[3] <= 0.1) {
            // Non-indicator filled rect becomes pure black with 1px grayscale border
            try std.testing.expectEqual(@as(f32, 0.0), q.color[0]);
            try std.testing.expectEqual(@as(f32, 0.0), q.color[1]);
            try std.testing.expectEqual(@as(f32, 0.0), q.color[2]);
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), q.params[1], 1e-5);
        }
    }
    try std.testing.expect(saw_glyph);
    // Bezel ring border clamped to 1px and grayscale in ambient mode
    const amb_bezel = quads[total - 1];
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), amb_bezel.params[1], 1e-5);
    try std.testing.expectApproxEqAbs(amb_bezel.border_color[0], amb_bezel.border_color[2], 1e-5);
}

test "WearShowcaseApp telemetry stats, counter stepper, slider, and edge-case sanitization" {
    var app = wear_showcase.WearShowcaseApp.init();
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var router = events.EventRouter.init();

    const w: f32 = 233.0;
    const h: f32 = 233.0;
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);

    // Scroll Card 3 into view
    arena.setScroll(app.scroll_container.?, 0.0, 280.0);
    arena.layout(w, h);

    const stats_0 = arena.findByTestId("wear_stats").?;
    try std.testing.expectEqualStrings("60 FPS | 1.8 ms", arena.nodes.items(.label)[stats_0.index]);

    app.last_frame_ms = 33.3;
    try app.buildScene(&arena, w, h);
    arena.setScroll(app.scroll_container.?, 0.0, 280.0);
    arena.layout(w, h);
    const stats_1 = arena.findByTestId("wear_stats").?;
    try std.testing.expectEqualStrings("30 FPS | 33.3 ms", arena.nodes.items(.label)[stats_1.index]);

    // Counter stepper
    try std.testing.expect(try tapNode(&app, &arena, &router, "wear_inc", w, h));
    try std.testing.expectEqual(@as(i32, 43), app.counter);
    arena.setScroll(app.scroll_container.?, 0.0, 280.0);
    arena.layout(w, h);
    try std.testing.expectEqualStrings("43", arena.nodes.items(.label)[arena.findByTestId("wear_counter").?.index]);

    try std.testing.expect(try tapNode(&app, &arena, &router, "wear_dec", w, h));
    arena.setScroll(app.scroll_container.?, 0.0, 280.0);
    arena.layout(w, h);
    try std.testing.expect(try tapNode(&app, &arena, &router, "wear_dec", w, h));
    try std.testing.expectEqual(@as(i32, 41), app.counter);
    arena.setScroll(app.scroll_container.?, 0.0, 280.0);
    arena.layout(w, h);

    // Interactive slider drag
    const slider_r = arena.getRect(arena.findByTestId("wear_slider").?).?;
    router.dispatch(&arena, .{ .pointer_down = .{
        .pointer_id = 3,
        .x = slider_r.x + slider_r.w * 0.25,
        .y = slider_r.y + slider_r.h * 0.5,
        .is_touch = true,
    } });
    router.dispatch(&arena, .{ .pointer_move = .{
        .pointer_id = 3,
        .x = slider_r.x + slider_r.w * 0.85,
        .y = slider_r.y + slider_r.h * 0.5,
        .is_touch = true,
    } });
    router.dispatch(&arena, .{ .pointer_up = .{
        .pointer_id = 3,
        .x = slider_r.x + slider_r.w * 0.85,
        .y = slider_r.y + slider_r.h * 0.5,
        .is_touch = true,
    } });
    var slider_events: usize = 0;
    while (router.nextEvent()) |ev| {
        if (app.handleUiEvent(ev, w, h)) slider_events += 1;
    }
    try std.testing.expect(slider_events >= 1);
    try std.testing.expect(app.slider_value > 0.80);

    // NaN / overflow / tight buffer sanitization
    app.counter = std.math.maxInt(i32);
    try std.testing.expect(app.handleUiEvent(.{ .clicked = .{ .id = .{ .index = 0, .gen = 1 }, .test_id = "wear_inc" } }, w, h));
    try std.testing.expectEqual(std.math.maxInt(i32), app.counter);

    app.slider_value = std.math.nan(f32);
    app.last_frame_ms = std.math.nan(f32);
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);

    var quads: [16]core.QuadInstance = undefined;
    try std.testing.expectEqual(@as(usize, 16), app.emitPostQuads(&arena, &quads, 999, w, h, 2.0, null, 1));
    try std.testing.expectEqual(@as(usize, 0), app.emitPostQuads(&arena, &quads, 0, std.math.nan(f32), h, 2.0, null, 1));
}
