const std = @import("std");
const huey = @import("huey");
const core = huey.core;
const events = huey.events;
const overlay = huey.overlay;
const wearos = huey.wearos;
const glyph_atlas = huey.glyph_atlas;
const showcase = @import("showcase_scene.zig");
const theme = huey.theme;
const controls = huey.widgets.controls;
const android_platform = huey.android_platform;

const HOST_FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";

fn loadHostFont(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, HOST_FONT_PATH, allocator, .limited(4 * 1024 * 1024));
}

fn tapNode(
    app: *showcase.ShowcaseApp,
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

test "ShowcaseApp init defaults and pinned header + 48dp tabs across all 5 tabs" {
    var app = showcase.ShowcaseApp.init();
    try std.testing.expectEqual(showcase.Tab.scroll, app.active_tab);
    try std.testing.expectEqual(@as(u8, 0), app.accent_idx);
    try std.testing.expectEqual(@as(i32, 42), app.counter);
    try std.testing.expectApproxEqAbs(@as(f32, 0.68), app.slider_value, 1e-5);
    try std.testing.expect(!app.wear_ambient);
    try std.testing.expect(!app.hud_bounds);
    try std.testing.expect(!app.hud_targets);
    try std.testing.expect(app.hud_budget);
    try std.testing.expectEqual(@as(usize, 0), app.overlays.activeCount());

    for (app.card_toggles, 0..) |t, i| {
        try std.testing.expectEqual(i % 2 == 0, t);
    }

    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var router = events.EventRouter.init();

    const w: f32 = 412.0;
    const h: f32 = 892.0;
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);

    const tab_ids = [_][]const u8{ "tab_scroll", "tab_widgets", "tab_kit", "tab_popups", "tab_hud" };
    for (tab_ids) |tid| {
        const nid = arena.findByTestId(tid) orelse return error.MissingTab;
        const rect = arena.getRect(nid).?;
        try std.testing.expect(rect.h >= 48.0);
        try std.testing.expect(rect.w >= 44.0);
    }

    // Switch through all 5 tabs via pointer events
    try std.testing.expect(try tapNode(&app, &arena, &router, "tab_widgets", w, h));
    try std.testing.expectEqual(showcase.Tab.widgets, app.active_tab);

    try std.testing.expect(try tapNode(&app, &arena, &router, "tab_kit", w, h));
    try std.testing.expectEqual(showcase.Tab.kit, app.active_tab);

    try std.testing.expect(try tapNode(&app, &arena, &router, "tab_popups", w, h));
    try std.testing.expectEqual(showcase.Tab.popups, app.active_tab);

    try std.testing.expect(try tapNode(&app, &arena, &router, "tab_hud", w, h));
    try std.testing.expectEqual(showcase.Tab.hud, app.active_tab);

    try std.testing.expect(try tapNode(&app, &arena, &router, "tab_scroll", w, h));
    try std.testing.expectEqual(showcase.Tab.scroll, app.active_tab);
}

test "ShowcaseApp scroll tab has 16 cards, toggles, and scrollable content" {
    var app = showcase.ShowcaseApp.init();
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var router = events.EventRouter.init();

    const w: f32 = 400.0;
    const h: f32 = 720.0;
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);

    const sc = app.scroll_container orelse return error.MissingScrollContainer;
    const body_rect = arena.getRect(sc).?;
    const content_h = arena.contentHeight(sc);
    try std.testing.expect(content_h > body_rect.h);

    for (0..16) |i| {
        var cbuf: [16]u8 = undefined;
        var tbuf: [24]u8 = undefined;
        const cid = try std.fmt.bufPrint(&cbuf, "card_{d}", .{i});
        const tid = try std.fmt.bufPrint(&tbuf, "card_toggle_{d}", .{i});
        try std.testing.expect(arena.findByTestId(cid) != null);
        const toggle_id = arena.findByTestId(tid) orelse return error.MissingCardToggle;
        try std.testing.expectEqual(i % 2 == 0, arena.isChecked(toggle_id).?);
    }

    // Toggle card_toggle_1 from false -> true
    try std.testing.expect(try tapNode(&app, &arena, &router, "card_toggle_1", w, h));
    try std.testing.expect(app.card_toggles[1]);
    const t1 = arena.findByTestId("card_toggle_1").?;
    try std.testing.expect(arena.isChecked(t1).?);

    // Scroll container moves cards upward
    const sc2 = app.scroll_container orelse return error.MissingScrollContainer;
    const c0_before = arena.getRect(arena.findByTestId("card_0").?).?;
    arena.setScroll(sc2, 0.0, 120.0);
    arena.layout(w, h);
    const c0_after = arena.getRect(arena.findByTestId("card_0").?).?;
    try std.testing.expectApproxEqAbs(c0_before.y - 120.0, c0_after.y, 0.01);
}

test "ShowcaseApp widgets tab: theme accents, counter, live slider drag, and Wear OS ambient mode" {
    var app = showcase.ShowcaseApp.init();
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var router = events.EventRouter.init();

    const w: f32 = 412.0;
    const h: f32 = 892.0;
    app.active_tab = .widgets;
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);

    // Theme switching through all 4 Nord accents (Oklab color morph)
    for (0..showcase.ACCENTS.len) |i| {
        var abuf: [16]u8 = undefined;
        const aid = try std.fmt.bufPrint(&abuf, "accent_{d}", .{i});
        try std.testing.expect(try tapNode(&app, &arena, &router, aid, w, h));
        try std.testing.expectEqual(@as(u8, @intCast(i)), app.accent_idx);
        if (i > 0) {
            try std.testing.expect(app.isAnimating());
            _ = app.stepAnimations(1.0 / 60.0);
            try app.buildScene(&arena, w, h);
            arena.layout(w, h);
            const mid_border = arena.nodes.items(.border)[arena.findByTestId("tab_widgets").?.index];
            try std.testing.expect(mid_border[0] != showcase.ACCENTS[i][0] or mid_border[1] != showcase.ACCENTS[i][1]);
            var steps: usize = 0;
            while (app.isAnimating() and steps < 240) : (steps += 1) {
                _ = app.stepAnimations(1.0 / 60.0);
            }
            try std.testing.expect(!app.isAnimating());
            try app.buildScene(&arena, w, h);
            arena.layout(w, h);
        }
        const tab_id = arena.findByTestId("tab_widgets").?;
        const idx = tab_id.index;
        try std.testing.expectApproxEqAbs(showcase.ACCENTS[i][0], arena.nodes.items(.border)[idx][0], 1e-4);
        try std.testing.expectApproxEqAbs(showcase.ACCENTS[i][1], arena.nodes.items(.border)[idx][1], 1e-4);
        try std.testing.expectApproxEqAbs(showcase.ACCENTS[i][2], arena.nodes.items(.border)[idx][2], 1e-4);
    }

    // Counter inc & dec
    try std.testing.expect(try tapNode(&app, &arena, &router, "btn_inc", w, h));
    try std.testing.expectEqual(@as(i32, 43), app.counter);
    try std.testing.expect(try tapNode(&app, &arena, &router, "btn_dec", w, h));
    try std.testing.expect(try tapNode(&app, &arena, &router, "btn_dec", w, h));
    try std.testing.expectEqual(@as(i32, 41), app.counter);

    // Continuous slider drag (pointer_down -> pointer_move -> pointer_move -> pointer_up)
    const slider_id = arena.findByTestId("demo_slider").?;
    const sr = arena.getRect(slider_id).?;
    router.dispatch(&arena, .{ .pointer_down = .{
        .pointer_id = 2,
        .x = sr.x + sr.w * 0.25,
        .y = sr.y + sr.h * 0.5,
    } });
    router.dispatch(&arena, .{ .pointer_move = .{
        .pointer_id = 2,
        .x = sr.x + sr.w * 0.50,
        .y = sr.y + sr.h * 0.5,
    } });
    router.dispatch(&arena, .{ .pointer_move = .{
        .pointer_id = 2,
        .x = sr.x + sr.w * 0.85,
        .y = sr.y + sr.h * 0.5,
    } });
    router.dispatch(&arena, .{ .pointer_up = .{
        .pointer_id = 2,
        .x = sr.x + sr.w * 0.85,
        .y = sr.y + sr.h * 0.5,
    } });
    var saw_slider_events: usize = 0;
    while (router.nextEvent()) |ev| {
        if (app.handleUiEvent(ev, w, h)) saw_slider_events += 1;
    }
    try std.testing.expect(saw_slider_events >= 2);
    try std.testing.expect(app.slider_value > 0.80);

    // Wear OS bezel geometry & ambient quad transform
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);
    const bezel_id = arena.findByTestId("wear_bezel").?;
    const bezel_rect = arena.getRect(bezel_id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 180.0), bezel_rect.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 180.0), bezel_rect.h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), arena.nodes.items(.corner_radius)[bezel_id.index], 0.1);

    // Enable ambient mode and verify watch bezel quads become black OLED ambient while header remains colored
    try std.testing.expect(try tapNode(&app, &arena, &router, "wear_ambient", w, h));
    try std.testing.expect(app.wear_ambient);

    var quads: [2048]core.QuadInstance = undefined;
    const base_count = arena.emitQuads(&quads, 1.0);
    const total = app.emitPostQuads(&arena, &quads, base_count, w, h, 1.0, null, 1);
    try std.testing.expect(total >= base_count);

    const b_rect = arena.getRect(arena.findByTestId("wear_bezel").?).?;
    var found_ambient_bezel = false;
    var found_colored_outside = false;
    for (quads[0..base_count]) |q| {
        const cx = q.pos_size[0] + q.pos_size[2] * 0.5;
        const cy = q.pos_size[1] + q.pos_size[3] * 0.5;
        const inside_bezel = cx >= b_rect.x and cx <= b_rect.x + b_rect.w and
            cy >= b_rect.y and cy <= b_rect.y + b_rect.h and
            q.pos_size[2] <= b_rect.w + 2.0 and q.pos_size[3] <= b_rect.h + 2.0;
        if (inside_bezel) {
            if (@abs(q.pos_size[2] - b_rect.w) < 2.0) {
                found_ambient_bezel = true;
                try std.testing.expectEqual(@as(f32, 0.0), q.color[0]);
                try std.testing.expectEqual(@as(f32, 0.0), q.color[1]);
                try std.testing.expectEqual(@as(f32, 0.0), q.color[2]);
                try std.testing.expectEqual(@as(f32, 1.0), q.params[1]);
            }
        } else if (q.color[3] > 0.5 and @abs(q.color[0] - q.color[2]) > 0.02) {
            found_colored_outside = true;
        }
    }
    try std.testing.expect(found_ambient_bezel);
    try std.testing.expect(found_colored_outside);
}

test "ShowcaseApp wear_ambient does not corrupt header/tabs when scrolled behind header" {
    var app = showcase.ShowcaseApp.init();
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const w: f32 = 320.0;
    const h: f32 = 480.0;
    app.active_tab = .widgets;
    app.wear_ambient = true;
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);

    // Scroll wear_bezel upward so its rect overlaps header/tab_bar y-range (0..108)
    const sc = app.scroll_container.?;
    arena.setScroll(sc, 0.0, 480.0);
    arena.layout(w, h);

    var quads: [2048]core.QuadInstance = undefined;
    const base_count = arena.emitQuads(&quads, 1.0);
    _ = app.emitPostQuads(&arena, &quads, base_count, w, h, 1.0, null, 1);

    // tab_widgets must retain its accent fill (not turned pure black by wear_ambient!)
    const tab_r = arena.getRect(arena.findByTestId("tab_widgets").?).?;
    var found_tab_colored = false;
    for (quads[0..base_count]) |q| {
        if (@abs(q.pos_size[0] - tab_r.x) < 1.5 and
            @abs(q.pos_size[1] - tab_r.y) < 1.5 and
            @abs(q.pos_size[2] - tab_r.w) < 1.5)
        {
            if (q.color[2] > 0.5) found_tab_colored = true;
        }
    }
    try std.testing.expect(found_tab_colored);
}

test "ShowcaseApp popups tab: corner anchor edge flipping, modal backdrop, outside-click & Escape dismissal" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 512, 512);
    defer atlas.deinit();

    var app = showcase.ShowcaseApp.init();
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var router = events.EventRouter.init();

    const w: f32 = 400.0;
    const h: f32 = 760.0;
    app.active_tab = .popups;
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);

    const body_r = arena.getRect(app.scroll_container.?).?;

    // Test all 4 corner anchor buttons keep popups inside viewport
    const corners = [_][]const u8{ "pop_tl", "pop_tr", "pop_bl", "pop_br" };
    for (corners) |cid| {
        try std.testing.expect(try tapNode(&app, &arena, &router, cid, w, h));
        try std.testing.expectEqual(@as(usize, 1), app.overlays.activeCount());
        const top = app.overlays.top().?;
        try std.testing.expect(top.rect.x >= 0.0);
        try std.testing.expect(top.rect.y >= 0.0);
        try std.testing.expect(top.rect.x + top.rect.w <= w + 0.01);
        try std.testing.expect(top.rect.y + top.rect.h <= h + 0.01);
        try std.testing.expect(!top.spec.modal);

        // Non-modal outside click dismisses overlay, clears popup_title, and consumes event
        const outside_x: f32 = if (top.rect.x > 20.0) 5.0 else w - 5.0;
        const outside_y: f32 = 10.0;
        try std.testing.expect(app.handlePointerDown(outside_x, outside_y));
        try std.testing.expectEqual(@as(usize, 0), app.overlays.activeCount());
        try std.testing.expectEqualStrings("", app.popup_title);
    }

    // Verify bottom-right anchor flipped both X and Y
    try std.testing.expect(try tapNode(&app, &arena, &router, "pop_br", w, h));
    const br_top = app.overlays.top().?;
    try std.testing.expect(br_top.placed.flipped_x);
    try std.testing.expect(br_top.placed.flipped_y);

    // Emit post quads with atlas and verify overlay + glyph quads stay inside popup rect & escape body scissor
    app.hud_budget = false;
    var quads: [2048]core.QuadInstance = undefined;
    const base_count = arena.emitQuadsWithAtlas(&quads, 2.0, &atlas, 1);
    const total = app.emitPostQuads(&arena, &quads, base_count, w, h, 2.0, &atlas, 1);
    try std.testing.expect(total > base_count + 1);

    const phys_pop = core.snapRectToPhysical(br_top.rect, 2.0);
    var saw_popup_glyph = false;
    for (quads[base_count..total]) |q| {
        if (q.params[3] > 0.5) {
            saw_popup_glyph = true;
            try std.testing.expect(q.clip_rect[0] >= phys_pop.x - 0.5);
            try std.testing.expect(q.clip_rect[1] >= phys_pop.y - 0.5);
            try std.testing.expect(q.clip_rect[2] <= phys_pop.x + phys_pop.w + 0.5);
            try std.testing.expect(q.clip_rect[3] <= phys_pop.y + phys_pop.h + 0.5);
        } else {
            try std.testing.expectEqual(@as(f32, 0.0), q.clip_rect[0]);
            try std.testing.expectEqual(@as(f32, 0.0), q.clip_rect[1]);
            try std.testing.expectApproxEqAbs(w * 2.0, q.clip_rect[2], 0.5);
            try std.testing.expectApproxEqAbs(h * 2.0, q.clip_rect[3], 0.5);
            // Overlay surface escapes scroll body scissor if near bottom edge
            try std.testing.expect(body_r.h < h);
        }
    }
    try std.testing.expect(saw_popup_glyph);

    // Escape shortcut dismisses overlay
    try std.testing.expect(app.handleUiEvent(.{ .shortcut = .{ .key = .escape, .mods = .{} } }, w, h));
    try std.testing.expectEqual(@as(usize, 0), app.overlays.activeCount());
    try std.testing.expectEqualStrings("", app.popup_title);

    try std.testing.expect(try tapNode(&app, &arena, &router, "pop_modal", w, h));
    try std.testing.expectEqual(@as(usize, 1), app.overlays.activeCount());
    const modal = app.overlays.top().?;
    try std.testing.expect(modal.spec.modal);

    // Clicking inside modal does NOT dismiss, but consumes click
    try std.testing.expect(app.handlePointerDown(modal.rect.x + modal.rect.w * 0.5, modal.rect.y + modal.rect.h * 0.5));
    try std.testing.expectEqual(@as(usize, 1), app.overlays.activeCount());

    // Clicking outside modal dismisses it and consumes click
    try std.testing.expect(app.handlePointerDown(2.0, 2.0));
    try std.testing.expectEqual(@as(usize, 0), app.overlays.activeCount());

    // Switching tabs clears any open overlay
    try std.testing.expect(try tapNode(&app, &arena, &router, "pop_tl", w, h));
    try std.testing.expectEqual(@as(usize, 1), app.overlays.activeCount());
    try std.testing.expect(app.handleUiEvent(.{ .clicked = .{ .id = .{ .index = 0, .gen = 1 }, .test_id = "tab_hud" } }, w, h));
    try std.testing.expectEqual(@as(usize, 0), app.overlays.activeCount());
    try std.testing.expectEqualStrings("", app.popup_title);
}

test "ShowcaseApp hud tab toggles and emitPostQuads bounds, targets, and budget bar" {
    var app = showcase.ShowcaseApp.init();
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var router = events.EventRouter.init();

    const w: f32 = 412.0;
    const h: f32 = 892.0;
    app.active_tab = .hud;
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);

    try std.testing.expect(arena.findByTestId("hud_bounds") != null);
    try std.testing.expect(arena.findByTestId("hud_targets") != null);
    try std.testing.expect(arena.findByTestId("hud_budget") != null);

    // Enable bounds and targets
    try std.testing.expect(try tapNode(&app, &arena, &router, "hud_bounds", w, h));
    try std.testing.expect(try tapNode(&app, &arena, &router, "hud_targets", w, h));
    try std.testing.expect(app.hud_bounds);
    try std.testing.expect(app.hud_targets);
    try std.testing.expect(app.hud_budget);

    var quads: [2048]core.QuadInstance = undefined;
    const base_count = arena.emitQuads(&quads, 2.0);

    // Under budget -> green bar, and budget bar sits above header.stats (no overlap)
    app.last_frame_ms = 2.5;
    const total_ok = app.emitPostQuads(&arena, &quads, base_count, w, h, 2.0, null, 1);
    try std.testing.expect(total_ok > base_count + 4);

    const bar_ok = quads[total_ok - 1];
    try std.testing.expectApproxEqAbs(core.Nord.aurora_green[0], bar_ok.color[0], 0.01);
    try std.testing.expectApproxEqAbs(core.Nord.aurora_green[1], bar_ok.color[1], 0.01);
    const stats_r = arena.getRect(arena.findByTestId("header.stats").?).?;
    try std.testing.expect(bar_ok.pos_size[1] + bar_ok.pos_size[3] < stats_r.y * 2.0);

    // Tight buffer reserves 2 slots for hud_budget instead of starving it
    var tight_quads: [64]core.QuadInstance = undefined;
    @memset(&tight_quads, .{
        .pos_size = .{ 0, 0, 0, 0 },
        .color = core.Nord.transparent,
        .border_color = core.Nord.transparent,
        .params = .{ 0, 0, 0, 0 },
    });
    const tight_total = app.emitPostQuads(&arena, &tight_quads, 60, w, h, 1.0, null, 1);
    try std.testing.expectEqual(@as(usize, 64), tight_total);
    try std.testing.expectApproxEqAbs(core.Nord.aurora_green[0], tight_quads[tight_total - 1].color[0], 0.01);

    // Over budget -> Aurora Red
    app.last_frame_ms = 22.0;
    const total_over = app.emitPostQuads(&arena, &quads, base_count, w, h, 2.0, null, 2);
    const bar_over = quads[total_over - 1];
    try std.testing.expectApproxEqAbs(core.Nord.aurora_red[0], bar_over.color[0], 0.01);
    try std.testing.expectApproxEqAbs(core.Nord.aurora_red[1], bar_over.color[1], 0.01);

    // Disable all HUD flags -> only the gliding active tab underline quad is emitted when no overlays open
    try std.testing.expect(try tapNode(&app, &arena, &router, "hud_bounds", w, h));
    try std.testing.expect(try tapNode(&app, &arena, &router, "hud_targets", w, h));
    try std.testing.expect(try tapNode(&app, &arena, &router, "hud_budget", w, h));
    const base_clean = arena.emitQuads(&quads, 1.0);
    const total_clean = app.emitPostQuads(&arena, &quads, base_clean, w, h, 1.0, null, 3);
    try std.testing.expectEqual(base_clean + 1, total_clean);
}

test "ShowcaseApp gliding active tab underline and bouncy popup scale-in animations" {
    var app = showcase.ShowcaseApp.init();
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var router = events.EventRouter.init();

    const w: f32 = 412.0;
    const h: f32 = 892.0;
    app.hud_budget = false;
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);

    var quads: [2048]core.QuadInstance = undefined;
    const base0 = arena.emitQuads(&quads, 1.0);
    const total0 = app.emitPostQuads(&arena, &quads, base0, w, h, 1.0, null, 1);
    try std.testing.expectEqual(base0 + 1, total0);
    try std.testing.expect(!app.isAnimating());
    const ind_scroll_x = quads[total0 - 1].pos_size[0];

    // Switch to HUD tab -> indicator_x starts at tab_scroll and glides to tab_hud
    try std.testing.expect(try tapNode(&app, &arena, &router, "tab_hud", w, h));
    const base1 = arena.emitQuads(&quads, 1.0);
    const total1 = app.emitPostQuads(&arena, &quads, base1, w, h, 1.0, null, 2);
    try std.testing.expectEqual(base1 + 1, total1);
    try std.testing.expect(app.isAnimating());
    try std.testing.expectApproxEqAbs(ind_scroll_x, quads[total1 - 1].pos_size[0], 1.5);

    _ = app.stepAnimations(1.0 / 60.0);
    const total_mid = app.emitPostQuads(&arena, &quads, base1, w, h, 1.0, null, 3);
    const ind_mid_x = quads[total_mid - 1].pos_size[0];
    try std.testing.expect(ind_mid_x > ind_scroll_x + 5.0);

    var steps: usize = 0;
    while (app.isAnimating() and steps < 240) : (steps += 1) {
        _ = app.stepAnimations(1.0 / 60.0);
    }
    try std.testing.expect(!app.isAnimating());
    const total_settled = app.emitPostQuads(&arena, &quads, base1, w, h, 1.0, null, 4);
    const hud_r = arena.getRect(arena.findByTestId("tab_hud").?).?;
    const ind_settled = quads[total_settled - 1];
    try std.testing.expect(ind_settled.pos_size[0] >= hud_r.x);
    try std.testing.expect(ind_settled.pos_size[0] + ind_settled.pos_size[2] <= hud_r.x + hud_r.w + 0.5);

    // Switch to Popups tab and settle tab indicator
    try std.testing.expect(try tapNode(&app, &arena, &router, "tab_popups", w, h));
    _ = app.emitPostQuads(&arena, &quads, arena.emitQuads(&quads, 1.0), w, h, 1.0, null, 5);
    steps = 0;
    while (app.isAnimating() and steps < 240) : (steps += 1) {
        _ = app.stepAnimations(1.0 / 60.0);
    }
    try std.testing.expect(!app.isAnimating());

    // Open modal popup -> bouncy scale-in from 0.88 -> 1.0 around center
    try std.testing.expect(try tapNode(&app, &arena, &router, "pop_modal", w, h));
    try std.testing.expect(app.isAnimating());
    const modal_rect = app.overlays.top().?.rect;
    const base_pop = arena.emitQuads(&quads, 1.0);
    const total_pop0 = app.emitPostQuads(&arena, &quads, base_pop, w, h, 1.0, null, 6);
    // Quads emitted after base_pop: [tab_indicator, modal_backdrop, modal_surface]
    try std.testing.expectEqual(base_pop + 3, total_pop0);
    const pop_q0 = quads[total_pop0 - 1];
    try std.testing.expectApproxEqAbs(modal_rect.w * 0.88, pop_q0.pos_size[2], 1.5);
    try std.testing.expectApproxEqAbs(modal_rect.h * 0.88, pop_q0.pos_size[3], 1.5);
    try std.testing.expectApproxEqAbs(
        modal_rect.x + modal_rect.w * 0.5,
        pop_q0.pos_size[0] + pop_q0.pos_size[2] * 0.5,
        1.0,
    );

    // Dismissing popup mid-flight snaps popup_scale so app drops to 0% idle CPU
    try std.testing.expect(app.handlePointerDown(2.0, 2.0));
    try std.testing.expect(!app.isAnimating());
}

test "ShowcaseApp adversarial regressions: immediate tab wake, resize snap, live popup border morph, tight orphan text, and EventRouter handle rebind" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);
    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 512, 512);
    defer atlas.deinit();

    var app = showcase.ShowcaseApp.init();
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var router = events.EventRouter.init();

    const w: f32 = 412.0;
    const h: f32 = 892.0;
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);
    var quads: [2048]core.QuadInstance = undefined;
    _ = app.emitPostQuads(&arena, &quads, arena.emitQuads(&quads, 1.0), w, h, 1.0, &atlas, 1);
    try std.testing.expect(!app.isAnimating());

    // 1. Finding #6a: Switching tab immediately wakes app.isAnimating() BEFORE emitPostQuads
    try std.testing.expect(app.handleUiEvent(.{ .clicked = .{ .id = .{ .index = 0, .gen = 1 }, .test_id = "tab_popups" } }, w, h));
    try std.testing.expect(app.isAnimating());
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);
    while (app.isAnimating()) _ = app.stepAnimations(1.0 / 60.0);
    _ = app.emitPostQuads(&arena, &quads, arena.emitQuads(&quads, 1.0), w, h, 1.0, &atlas, 2);
    while (app.isAnimating()) _ = app.stepAnimations(1.0 / 60.0);

    // 2. Finding #6b: Viewport resize snaps tab indicator without triggering spring animation
    const w_wide: f32 = 640.0;
    try app.buildScene(&arena, w_wide, h);
    arena.layout(w_wide, h);
    _ = app.emitPostQuads(&arena, &quads, arena.emitQuads(&quads, 1.0), w_wide, h, 1.0, &atlas, 3);
    try std.testing.expect(!app.isAnimating());

    // 3. Finding #3: Popup border_color morphs live to final target accent even if opened mid-morph
    app.accent_idx = 2; // aurora_purple
    try app.buildScene(&arena, w_wide, h); // starts theme/accent morph from frost_1 -> aurora_purple
    arena.layout(w_wide, h);
    try std.testing.expect(app.isAnimating());
    try std.testing.expect(try tapNode(&app, &arena, &router, "pop_modal", w_wide, h));
    while (app.isAnimating()) {
        _ = app.stepAnimations(1.0 / 60.0);
        try app.buildScene(&arena, w_wide, h);
        arena.layout(w_wide, h);
    }
    const base_m = arena.emitQuads(&quads, 1.0);
    const total_m = app.emitPostQuads(&arena, &quads, base_m, w_wide, h, 1.0, &atlas, 4);
    var found_modal_surface = false;
    for (quads[base_m..total_m]) |q| {
        if (q.params[3] == 0.0 and q.pos_size[2] > 200.0 and q.pos_size[3] > 100.0 and q.pos_size[2] < w_wide - 1.0) {
            found_modal_surface = true;
            try std.testing.expectApproxEqAbs(showcase.ACCENTS[2][0], q.border_color[0], 1e-4);
            try std.testing.expectApproxEqAbs(showcase.ACCENTS[2][1], q.border_color[1], 1e-4);
            try std.testing.expectApproxEqAbs(showcase.ACCENTS[2][2], q.border_color[2], 1e-4);
        }
    }
    try std.testing.expect(found_modal_surface);

    // 4. Finding #4: Tight buffer where modal needs 2 slots and only 1 slot remains before hud_limit -> NO orphan glyph quads!
    var tight_quads: [64]core.QuadInstance = undefined;
    app.hud_budget = true;
    // start_idx = 60, len = 64 -> budget reserves 2 (62..64), tab_indicator takes 60, leaving 1 slot (61..62) -> ov_n == 0!
    const tight_total = app.emitPostQuads(&arena, &tight_quads, 60, w_wide, h, 1.0, &atlas, 5);
    try std.testing.expectEqual(@as(usize, 63), tight_total); // 60 + 1 tab indicator + 2 budget = 63, NO orphan text at slot 61!
    for (tight_quads[60..tight_total]) |q| {
        try std.testing.expectEqual(@as(f32, 0.0), q.params[3]);
    }
    try std.testing.expect(app.handlePointerDown(2.0, 2.0));

    // 5. Finding #1: EventRouter handles survive mid-tap scene rebuild during animation
    try std.testing.expect(try tapNode(&app, &arena, &router, "tab_widgets", w_wide, h));
    const inc_r = arena.getRect(arena.findByTestId("btn_inc").?).?;
    const cx = inc_r.x + inc_r.w * 0.5;
    const cy = inc_r.y + inc_r.h * 0.5;
    router.dispatch(&arena, .{ .pointer_down = .{ .pointer_id = 9, .x = cx, .y = cy, .is_touch = true } });
    try std.testing.expect(router.pressed_node != null);

    // Simulate VSync animation frame rebuild while finger is held down
    const saved = router.saveHandles(&arena);
    try app.buildScene(&arena, w_wide, h);
    arena.layout(w_wide, h);
    router.restoreHandles(&arena, &saved);
    try std.testing.expect(router.pressed_node != null);

    router.dispatch(&arena, .{ .pointer_up = .{ .pointer_id = 9, .x = cx, .y = cy, .is_touch = true } });
    var saw_inc_click = false;
    while (router.nextEvent()) |ev| {
        if (app.handleUiEvent(ev, w_wide, h)) saw_inc_click = true;
    }
    try std.testing.expect(saw_inc_click);
    try std.testing.expectEqual(@as(i32, 43), app.counter);
}

test "ShowcaseApp narrow Wear OS 200x200 and landscape 640x360 layouts + NaN sanitization" {
    var app = showcase.ShowcaseApp.init();
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    // 200x200 narrow & 240x240 Wear OS / 768x1024 tablet viewports: 5 tabs fit cleanly with no overlaps
    const tabs = [_]showcase.Tab{ .scroll, .widgets, .kit, .popups, .hud };
    const tab_ids = [_][]const u8{ "tab_scroll", "tab_widgets", "tab_kit", "tab_popups", "tab_hud" };
    for (tabs) |tab| {
        app.active_tab = tab;
        try app.buildScene(&arena, 200.0, 200.0);
        arena.layout(200.0, 200.0);
        for (tab_ids) |tid| {
            const tr = arena.getRect(arena.findByTestId(tid).?).?;
            try std.testing.expect(tr.w >= 36.0);
            try std.testing.expect(tr.h >= 48.0);
        }

        try app.buildScene(&arena, 240.0, 240.0);
        arena.layout(240.0, 240.0);
        for (tab_ids) |tid| {
            const tr = arena.getRect(arena.findByTestId(tid).?).?;
            try std.testing.expect(tr.w >= 44.0);
            try std.testing.expect(tr.h >= 48.0);
        }

        try app.buildScene(&arena, 768.0, 1024.0);
        arena.layout(768.0, 1024.0);
        for (tab_ids) |tid| {
            const tr = arena.getRect(arena.findByTestId(tid).?).?;
            try std.testing.expect(tr.w >= 44.0);
            try std.testing.expect(tr.h >= 48.0);
        }
    }

    app.active_tab = .widgets;
    try app.buildScene(&arena, 200.0, 200.0);
    arena.layout(200.0, 200.0);
    const wear_card_r = arena.getRect(arena.findByTestId("widgets.wear_card").?).?;
    const bezel_r = arena.getRect(arena.findByTestId("wear_bezel").?).?;
    try std.testing.expect(bezel_r.x >= wear_card_r.x);
    try std.testing.expect(bezel_r.x + bezel_r.w <= wear_card_r.x + wear_card_r.w + 0.01);
    const counter_r = arena.getRect(arena.findByTestId("counter_display").?).?;
    try std.testing.expect(counter_r.w >= 24.0);

    // 640x360 landscape popups tab: mid does not overlap bot_row, pop_tl/pop_tr do not overlap
    app.active_tab = .popups;
    try app.buildScene(&arena, 640.0, 360.0);
    arena.layout(640.0, 360.0);
    const desc_r = arena.getRect(arena.findByTestId("popups.desc_card").?).?;
    const modal_btn_r = arena.getRect(arena.findByTestId("pop_modal").?).?;
    const bl_r = arena.getRect(arena.findByTestId("pop_bl").?).?;
    try std.testing.expect(desc_r.y + desc_r.h <= modal_btn_r.y + 0.01);
    try std.testing.expect(modal_btn_r.y + modal_btn_r.h <= bl_r.y + 0.01);

    // NaN/Inf sanitization
    app.slider_value = std.math.nan(f32);
    app.last_frame_ms = std.math.nan(f32);
    try app.buildScene(&arena, 200.0, 200.0);
    arena.layout(200.0, 200.0);
    try std.testing.expect(!app.handlePointerDown(std.math.nan(f32), 10.0));
    _ = app.handleUiEvent(.{ .clicked = .{ .id = .{ .index = 0, .gen = 1 }, .test_id = "pop_tl" } }, 0.0, 0.0);
    try std.testing.expectEqual(@as(usize, 0), app.overlays.activeCount());

    var quads: [128]core.QuadInstance = undefined;
    try std.testing.expectEqual(@as(usize, 128), app.emitPostQuads(&arena, &quads, 999, 200.0, 200.0, 1.0, null, 1));
    try std.testing.expectEqual(@as(usize, 0), app.emitPostQuads(&arena, &quads, 0, std.math.nan(f32), 200.0, 1.0, null, 1));
}

test "ShowcaseApp widgets Wear OS preview: wear_frunk 1.5s hold-to-confirm, 360 firework arc, early release & tab switch cancel" {
    var app = showcase.ShowcaseApp.init();
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var router = events.EventRouter.init();

    const w: f32 = 412.0;
    const h: f32 = 892.0;
    const scale: f32 = 2.0;
    app.active_tab = .widgets;
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);

    // Verify wear_title, wear_status, wear_frunk inside wear_safe_square
    const safe_r = arena.getRect(arena.findByTestId("wear_safe_square").?).?;
    const title_id = arena.findByTestId("wear_title").?;
    const status_id = arena.findByTestId("wear_status").?;
    const frunk_id = arena.findByTestId("wear_frunk").?;
    try std.testing.expectEqualStrings("TESLA KEY", arena.nodes.items(.label)[title_id.index]);
    try std.testing.expectEqualStrings("LOCKED", arena.nodes.items(.label)[status_id.index]);
    try std.testing.expectEqualStrings("HOLD FRUNK", arena.nodes.items(.label)[frunk_id.index]);
    try std.testing.expectEqual(@as(?bool, true), arena.nodes.items(.focusable)[frunk_id.index]);
    const frunk_r = arena.getRect(frunk_id).?;
    try std.testing.expect(frunk_r.h >= 38.0 and frunk_r.h <= 44.0);
    try std.testing.expect(frunk_r.y >= safe_r.y and frunk_r.y + frunk_r.h <= safe_r.y + safe_r.h + 0.01);
    try std.testing.expect(!app.frunk_open);
    try std.testing.expect(!app.isAnimating());

    const fx = frunk_r.x + frunk_r.w * 0.5;
    const fy = frunk_r.y + frunk_r.h * 0.5;

    // 1. Early release cancels without opening frunk and settles back to !isAnimating()
    try std.testing.expect(app.onWearPointerDown(&arena, 1, fx, fy));
    try std.testing.expect(app.isAnimating());
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);
    const hold_node = arena.findByTestId("wear_frunk").?;
    try std.testing.expectEqualStrings("HOLD...", arena.nodes.items(.label)[hold_node.index]);
    try std.testing.expectApproxEqAbs(core.Nord.aurora_orange[0], arena.nodes.items(.fill)[hold_node.index][0], 1e-5);
    _ = app.stepAnimations(0.5);
    app.onWearPointerUp(1);
    var settle_steps: usize = 0;
    while (app.isAnimating() and settle_steps < 240) : (settle_steps += 1) {
        _ = app.stepAnimations(1.0 / 60.0);
    }
    try std.testing.expect(!app.isAnimating());
    try std.testing.expect(!app.frunk_open);

    // 2. Switching tabs mid-hold cancels/resets hold_confirm cleanly
    try std.testing.expect(app.onWearPointerDown(&arena, 2, fx, fy));
    _ = app.stepAnimations(0.5);
    try std.testing.expect(app.frunk_hold.holding);
    try std.testing.expect(try tapNode(&app, &arena, &router, "tab_scroll", w, h));
    try std.testing.expect(!app.frunk_hold.holding);
    try std.testing.expectEqual(@as(f32, 0.0), app.frunk_hold.progress);
    settle_steps = 0;
    while (app.isAnimating() and settle_steps < 240) : (settle_steps += 1) {
        _ = app.stepAnimations(1.0 / 60.0);
    }
    try std.testing.expect(!app.isAnimating());
    try std.testing.expect(!app.frunk_open);

    // Return to Widgets tab and settle tab indicator
    try std.testing.expect(try tapNode(&app, &arena, &router, "tab_widgets", w, h));
    settle_steps = 0;
    while (app.isAnimating() and settle_steps < 240) : (settle_steps += 1) {
        _ = app.stepAnimations(1.0 / 60.0);
    }
    try std.testing.expect(!app.isAnimating());

    // 3. Toggling wear_ambient ON resets hold and blocks new holds
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);
    const frunk_r2 = arena.getRect(arena.findByTestId("wear_frunk").?).?;
    const fx2 = frunk_r2.x + frunk_r2.w * 0.5;
    const fy2 = frunk_r2.y + frunk_r2.h * 0.5;
    try std.testing.expect(app.onWearPointerDown(&arena, 3, fx2, fy2));
    _ = app.stepAnimations(0.3);
    try std.testing.expect(try tapNode(&app, &arena, &router, "wear_ambient", w, h));
    try std.testing.expect(app.wear_ambient);
    try std.testing.expect(!app.frunk_hold.holding);
    try std.testing.expect(!app.isAnimating());
    try std.testing.expect(!app.onWearPointerDown(&arena, 4, fx2, fy2));
    try std.testing.expect(try tapNode(&app, &arena, &router, "wear_ambient", w, h));
    try std.testing.expect(!app.wear_ambient);

    // 4. Full 1.5s hold fires frunk_open, emits firework quads clipped within showcase.body & wear_bezel, and settles
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);
    try std.testing.expect(app.onWearPointerDown(&arena, 5, fx2, fy2));
    app.onWearPointerMove(&arena, 5, fx2 + 4.0, fy2);
    try std.testing.expect(app.frunk_hold.holding);
    var hold_steps: usize = 0;
    while (hold_steps < 95 and !app.frunk_open) : (hold_steps += 1) {
        _ = app.stepAnimations(1.0 / 60.0);
    }
    try std.testing.expect(app.frunk_open);
    try std.testing.expectEqual(@as(?android_platform.HapticKind, .double_pulse), app.takePendingHaptic());
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);
    try std.testing.expectEqualStrings("FRUNK OPEN!", arena.nodes.items(.label)[arena.findByTestId("wear_status").?.index]);
    const open_node = arena.findByTestId("wear_frunk").?;
    try std.testing.expectEqualStrings("OPEN!", arena.nodes.items(.label)[open_node.index]);
    try std.testing.expectApproxEqAbs(core.Nord.aurora_green[0], arena.nodes.items(.fill)[open_node.index][0], 1e-5);

    const bezel_r = arena.getRect(arena.findByTestId("wear_bezel").?).?;
    const body_r = arena.getRect(arena.findByTestId("showcase.body").?).?;
    var quads: [2048]core.QuadInstance = undefined;
    const base_count = arena.emitQuads(&quads, scale);
    const total_fw = app.emitPostQuads(&arena, &quads, base_count, w, h, scale, null, 1);
    try std.testing.expect(total_fw > base_count + 10);

    var fw_count: usize = 0;
    for (quads[base_count..total_fw]) |q| {
        if (@abs(q.params[3] - wearos.AMBIENT_FG_SDF_MODE) < 1e-5) {
            fw_count += 1;
            const qcx = q.pos_size[0] + q.pos_size[2] * 0.5;
            const qcy = q.pos_size[1] + q.pos_size[3] * 0.5;
            try std.testing.expect(qcx >= bezel_r.x * scale and qcx <= (bezel_r.x + bezel_r.w) * scale);
            try std.testing.expect(qcy >= bezel_r.y * scale and qcy <= (bezel_r.y + bezel_r.h) * scale);
            try std.testing.expect(q.clip_rect[1] >= body_r.y * scale - 1.0);
            try std.testing.expect(q.clip_rect[3] <= (body_r.y + body_r.h) * scale + 1.0);
        }
    }
    try std.testing.expect(fw_count > 10);

    app.onWearPointerUp(5);
    settle_steps = 0;
    while (app.isAnimating() and settle_steps < 240) : (settle_steps += 1) {
        _ = app.stepAnimations(1.0 / 60.0);
    }
    try std.testing.expect(!app.isAnimating());

    // 5. Slipping outside button bounds cancels hold cleanly
    try std.testing.expect(app.onWearPointerDown(&arena, 6, fx2, fy2));
    app.onWearPointerMove(&arena, 6, fx2 + 200.0, fy2 + 200.0);
    try std.testing.expect(!app.frunk_hold.holding);
    app.onWearPointerCancel();
    settle_steps = 0;
    while (app.isAnimating() and settle_steps < 240) : (settle_steps += 1) {
        _ = app.stepAnimations(1.0 / 60.0);
    }
    try std.testing.expect(!app.isAnimating());
}

test "ShowcaseApp Kit tab: theme presets, VIN TextInput + keycodes, controls, toast, haptics & SDF post quads" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);
    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 512, 512);
    defer atlas.deinit();

    var app = showcase.ShowcaseApp.init();
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var router = events.EventRouter.init();

    const w: f32 = 412.0;
    const h: f32 = 892.0;
    try app.buildScene(&arena, w, h);
    arena.layout(w, h);

    try std.testing.expect(try tapNode(&app, &arena, &router, "tab_kit", w, h));
    try std.testing.expectEqual(showcase.Tab.kit, app.active_tab);
    var settle: usize = 0;
    while (app.isAnimating() and settle < 240) : (settle += 1) {
        _ = app.stepAnimations(1.0 / 60.0);
    }
    try std.testing.expect(!app.isAnimating());

    // 1. Switch all 4 theme presets and verify live TokenTable + root/card colors
    const preset_cases = [_]struct {
        id: []const u8,
        preset: theme.ThemePreset,
    }{
        .{ .id = "kit_theme_nord_light", .preset = .nord_light },
        .{ .id = "kit_theme_oled", .preset = .oled_dark },
        .{ .id = "kit_theme_hc", .preset = .high_contrast_dark },
        .{ .id = "kit_theme_nord_dark", .preset = .nord_dark },
    };
    for (preset_cases) |pc| {
        try std.testing.expect(try tapNode(&app, &arena, &router, pc.id, w, h));
        try std.testing.expectEqual(pc.preset, app.theme_preset);
        try std.testing.expect(app.token_table.isValid());
        try std.testing.expectEqual(@as(?android_platform.HapticKind, .tap), app.takePendingHaptic());
        try std.testing.expectEqual(@as(?android_platform.HapticKind, null), app.takePendingHaptic());

        const root_fill = arena.nodes.items(.fill)[arena.findByTestId("showcase.root").?.index];
        const expected_bg = app.token_table.bg_base.toSrgb();
        try std.testing.expectApproxEqAbs(expected_bg[0], root_fill[0], 1e-4);
        try std.testing.expectApproxEqAbs(expected_bg[1], root_fill[1], 1e-4);
        try std.testing.expectApproxEqAbs(expected_bg[2], root_fill[2], 1e-4);
    }

    // 2. VIN TextInput: tap focuses & requests soft keyboard, keycodes uppercase + backspace + max 17 + enter blurs
    try std.testing.expect(!app.vin_focused);
    try std.testing.expect(!app.want_keyboard);
    try std.testing.expect(try tapNode(&app, &arena, &router, "kit_vin_box", w, h));
    try std.testing.expect(app.vin_focused);
    try std.testing.expect(app.want_keyboard);
    try std.testing.expect(app.isAnimating());
    try std.testing.expectEqual(@as(?android_platform.HapticKind, .tap), app.takePendingHaptic());

    // Type lowercase 'a' (AKEYCODE_A = 29), 'b' (30), '1' (8) -> "AB1"
    try std.testing.expect(app.onKeyInput(29, false));
    try std.testing.expect(app.onKeyInput(30, false));
    try std.testing.expect(app.onKeyInput(8, false));
    try std.testing.expectEqualStrings("AB1", app.vin_buf[0..app.vin_len]);

    // Backspace (AKEYCODE_DEL = 67) -> "AB"
    try std.testing.expect(app.onKeyInput(67, false));
    try std.testing.expectEqualStrings("AB", app.vin_buf[0..app.vin_len]);

    // Type 20 more chars -> clamps at 17
    for (0..20) |_| {
        _ = app.onKeyInput(31, false); // 'C'
    }
    try std.testing.expectEqual(@as(usize, 17), app.vin_len);
    try std.testing.expect(!app.onKeyInput(31, false));

    // Enter (AKEYCODE_ENTER = 66) blurs & hides keyboard + emits confirm haptic
    try std.testing.expect(app.onKeyInput(66, false));
    try std.testing.expect(!app.vin_focused);
    try std.testing.expect(!app.want_keyboard);
    try std.testing.expectEqual(@as(?android_platform.HapticKind, .confirm), app.takePendingHaptic());

    // Clear & Fill buttons
    try std.testing.expect(try tapNode(&app, &arena, &router, "kit_vin_clear", w, h));
    try std.testing.expectEqual(@as(usize, 0), app.vin_len);
    _ = app.takePendingHaptic();
    try std.testing.expect(try tapNode(&app, &arena, &router, "kit_vin_fill", w, h));
    try std.testing.expectEqualStrings("5YJ3E1EA7LF000001", app.vin_buf[0..app.vin_len]);
    try std.testing.expectEqual(@as(?android_platform.HapticKind, .confirm), app.takePendingHaptic());

    // 3. Controls: Checkbox tri-state cycle, RadioGroup, Switch, Toast
    try std.testing.expectEqual(controls.CheckboxState.checked, app.kit_checkbox);
    try std.testing.expect(try tapNode(&app, &arena, &router, "kit_checkbox", w, h));
    try std.testing.expectEqual(controls.CheckboxState.indeterminate, app.kit_checkbox);
    try std.testing.expect(try tapNode(&app, &arena, &router, "kit_checkbox", w, h));
    try std.testing.expectEqual(controls.CheckboxState.unchecked, app.kit_checkbox);
    try std.testing.expect(try tapNode(&app, &arena, &router, "kit_checkbox", w, h));
    try std.testing.expectEqual(controls.CheckboxState.checked, app.kit_checkbox);

    try std.testing.expectEqual(@as(usize, 0), app.kit_radio.selected);
    try std.testing.expect(try tapNode(&app, &arena, &router, "kit_radio_2", w, h));
    try std.testing.expectEqual(@as(usize, 2), app.kit_radio.selected);

    try std.testing.expect(app.kit_switch);
    try std.testing.expect(try tapNode(&app, &arena, &router, "kit_switch", w, h));
    try std.testing.expect(!app.kit_switch);

    try std.testing.expect(try tapNode(&app, &arena, &router, "kit_toast_btn", w, h));
    try std.testing.expect(app.kit_toasts.top() != null);
    try std.testing.expect(app.isAnimating());
    _ = app.takePendingHaptic();

    // 4. emitPostQuads renders Checkbox/Switch/Radio/Progress/Spinner/Skeleton/Alert/Badge/Toast + all 8 CarIcons
    try std.testing.expect(try tapNode(&app, &arena, &router, "kit_vin_box", w, h));
    app.hud_budget = false;
    var quads: [2048]core.QuadInstance = undefined;
    const base_count = arena.emitQuadsWithAtlas(&quads, 2.0, &atlas, 1);
    const total = app.emitPostQuads(&arena, &quads, base_count, w, h, 2.0, &atlas, 1);
    // Should include tab indicator + badge (+text) + caret + checkbox(2) + switch(2) + 3 radios(4) + progress(2) + spinner(8) + skeleton(1) + alert(2+text) + 8 icons(>=24) + toast(1+text)
    try std.testing.expect(total >= base_count + 50);

    // Verify all 8 CarIcon slots emit SDF icon quads when scrolled into view
    arena.setScroll(app.scroll_container.?, 0.0, 140.0);
    arena.layout(w, h);
    const total_scrolled = app.emitPostQuads(&arena, &quads, arena.emitQuadsWithAtlas(&quads, 2.0, &atlas, 2), w, h, 2.0, &atlas, 2);
    const icon_ids = [8][]const u8{
        "kit_icon_0", "kit_icon_1", "kit_icon_2", "kit_icon_3",
        "kit_icon_4", "kit_icon_5", "kit_icon_6", "kit_icon_7",
    };
    for (icon_ids) |iid| {
        const ir = arena.getRect(arena.findByTestId(iid).?).?;
        var hits: usize = 0;
        for (quads[0..total_scrolled]) |q| {
            if (@abs(q.params[3] - wearos.AMBIENT_FG_SDF_MODE) < 1e-5) {
                const cx = (q.pos_size[0] + q.pos_size[2] * 0.5) / 2.0;
                const cy = (q.pos_size[1] + q.pos_size[3] * 0.5) / 2.0;
                if (cx >= ir.x and cx <= ir.x + ir.w and cy >= ir.y and cy <= ir.y + ir.h) {
                    hits += 1;
                }
            }
        }
        try std.testing.expect(hits >= 2);
    }

    // Toast expires and switching away blurs VIN -> returns to 0% idle CPU
    _ = app.onKeyInput(66, false);
    var t_steps: usize = 0;
    while (app.isAnimating() and t_steps < 300) : (t_steps += 1) {
        _ = app.stepAnimations(1.0 / 60.0);
    }
    try std.testing.expect(app.kit_toasts.top() == null);
    try std.testing.expect(!app.isAnimating());

    // Switching tabs away from .kit while focused blurs VIN and clears want_keyboard
    try std.testing.expect(try tapNode(&app, &arena, &router, "kit_vin_box", w, h));
    try std.testing.expect(app.vin_focused);
    try std.testing.expect(app.want_keyboard);
    try std.testing.expect(try tapNode(&app, &arena, &router, "tab_scroll", w, h));
    try std.testing.expect(!app.vin_focused);
    try std.testing.expect(!app.want_keyboard);
}
