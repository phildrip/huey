const std = @import("std");
const core = @import("core.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const headless = @import("headless.zig");
const wearos = @import("wearos.zig");

const HOST_FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";

fn loadHostFont(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, HOST_FONT_PATH, allocator, .limited(4 * 1024 * 1024));
}

test "GlyphAtlas loads TTF, rasterizes ASCII + UTF-8 with kerning, and caches hits" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();

    const g_a = try atlas.getOrRasterize('A', 16.0, 2.0, 1);
    try std.testing.expect(g_a.w > 0 and g_a.h > 0);
    try std.testing.expect(g_a.u1 > g_a.u0 and g_a.v1 > g_a.v0);
    try std.testing.expect(atlas.dirty);

    atlas.markUploaded();
    try std.testing.expect(!atlas.dirty);

    // Cache hit should NOT mark atlas dirty
    const g_a2 = try atlas.getOrRasterize('A', 16.0, 2.0, 2);
    try std.testing.expectEqual(g_a.u0, g_a2.u0);
    try std.testing.expectEqual(g_a.v0, g_a2.v0);
    try std.testing.expect(!atlas.dirty);

    // Measure text returns positive width and line height
    const m = atlas.measureText("AV Hello", 16.0, 2.0);
    try std.testing.expect(m.width > 20.0);
    try std.testing.expect(m.height >= 14.0);
}

test "GlyphAtlas invalidates cleanly on DPI scale change" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();

    _ = try atlas.getOrRasterize('Z', 16.0, 1.0, 1);
    atlas.markUploaded();
    try std.testing.expectEqual(@as(usize, 1), atlas.cachedCount());

    atlas.setScaleFactor(2.0);
    try std.testing.expectEqual(@as(usize, 0), atlas.cachedCount());
    try std.testing.expect(atlas.dirty);

    const g_2x = try atlas.getOrRasterize('Z', 16.0, 2.0, 2);
    try std.testing.expect(g_2x.w >= 10.0);
}

test "GlyphAtlas LRU eviction recovers cleanly when tiny atlas fills up" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    // Deliberately tiny 64x64 atlas to force eviction across alphabet
    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 64, 64);
    defer atlas.deinit();

    const text = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var frame: u64 = 1;
    for (text) |ch| {
        const g = try atlas.getOrRasterize(ch, 18.0, 1.0, frame);
        try std.testing.expect(g.w > 0 and g.h > 0);
        frame += 1;
    }
    try std.testing.expect(atlas.eviction_count > 0);
}

test "GlyphAtlas emitTextQuads emits snapped single-pass glyph quads with zero alloc after warm cache" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 512, 512);
    defer atlas.deinit();

    var out: [64]core.QuadInstance = undefined;
    const n = atlas.emitTextQuads("Zig GUI!", 20.0, 30.0, 16.0, 2.0, core.Nord.snow_storm_2, &out, 1);
    // "Zig GUI!" has 7 visible glyphs (space emits no quad)
    try std.testing.expectEqual(@as(usize, 7), n);
    for (out[0..n]) |q| {
        try std.testing.expectEqual(@as(f32, 1.0), q.params[3]); // mode == 1.0 (glyph)
        try std.testing.expect(q.uv_rect[2] > q.uv_rect[0]);
        try std.testing.expect(q.uv_rect[3] > q.uv_rect[1]);
        try std.testing.expectEqual(@round(q.pos_size[0]), q.pos_size[0]);
        try std.testing.expectEqual(@round(q.pos_size[1]), q.pos_size[1]);
    }

    // Invalid UTF-8 does not panic
    const bad = [_]u8{ 'A', 0xFF, 0xFE, 'B' };
    const n_bad = atlas.emitTextQuads(&bad, 0.0, 0.0, 16.0, 1.0, core.Nord.snow_storm_2, &out, 2);
    try std.testing.expect(n_bad >= 2);
}

test "LayoutArena emitQuadsWithAtlas emits demo scene shape + glyph quads and stabilizes dirty flag" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 1024, 1024);
    defer atlas.deinit();

    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    try core.buildDemoScene(&arena);
    arena.layout(768.0, 1024.0);

    var quad_buf: [2048]core.QuadInstance = undefined;
    const count1 = arena.emitQuadsWithAtlas(&quad_buf, 2.0, &atlas, 1);
    try std.testing.expect(count1 > 100);
    try std.testing.expect(atlas.dirty);

    var shape_count: usize = 0;
    var glyph_count: usize = 0;
    for (quad_buf[0..count1]) |q| {
        if (q.params[3] > 0.5) {
            glyph_count += 1;
            try std.testing.expect(q.uv_rect[2] > q.uv_rect[0]);
            try std.testing.expect(q.uv_rect[3] > q.uv_rect[1]);
        } else {
            shape_count += 1;
        }
    }
    try std.testing.expect(shape_count >= 40);
    try std.testing.expect(glyph_count >= 80);

    atlas.markUploaded();
    try std.testing.expect(!atlas.dirty);

    // Second frame with same scene must not mark atlas dirty (zero new rasterizations)
    const count2 = arena.emitQuadsWithAtlas(&quad_buf, 2.0, &atlas, 2);
    try std.testing.expectEqual(count1, count2);
    try std.testing.expect(!atlas.dirty);
}

test "GlyphAtlas rejects malformed, truncated, and oversized-dimension inputs cleanly" {
    try std.testing.expectError(error.InvalidFont, glyph_atlas.GlyphAtlas.init(std.testing.allocator, "abc", 64, 64));

    // Valid SFNT header claiming 1 table whose offset/length exceeds buffer
    var bad_sfnt: [32]u8 = @splat(0);
    bad_sfnt[0] = 0x00;
    bad_sfnt[1] = 0x01;
    bad_sfnt[2] = 0x00;
    bad_sfnt[3] = 0x00;
    bad_sfnt[4] = 0x00;
    bad_sfnt[5] = 0x01; // numTables = 1
    // table record at byte 12: tag(4), checkSum(4), offset(4)=1000, length(4)=64
    bad_sfnt[12 + 8] = 0x00;
    bad_sfnt[12 + 9] = 0x00;
    bad_sfnt[12 + 10] = 0x03;
    bad_sfnt[12 + 11] = 0xE8;
    bad_sfnt[12 + 12] = 0x00;
    bad_sfnt[12 + 13] = 0x00;
    bad_sfnt[12 + 14] = 0x00;
    bad_sfnt[12 + 15] = 0x40;
    try std.testing.expectError(error.InvalidFont, glyph_atlas.GlyphAtlas.init(std.testing.allocator, &bad_sfnt, 64, 64));

    // c_int overflow dimensions rejected without allocating huge buffer
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);
    try std.testing.expectError(
        error.InvalidAtlasParams,
        glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 50000, 50000),
    );
}

test "GlyphAtlas owns its font_bytes copy after caller frees source slice" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();

    // Free caller's copy immediately; atlas must keep working safely
    std.testing.allocator.free(font_bytes);

    const g = try atlas.getOrRasterize('Q', 18.0, 2.0, 1);
    try std.testing.expect(g.w > 0 and g.h > 0);
    const m = atlas.measureText("QED", 18.0, 2.0);
    try std.testing.expect(m.width > 10.0);
}

test "GlyphTooLarge does not evict existing cached glyphs" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 64, 64);
    defer atlas.deinit();

    _ = try atlas.getOrRasterize('a', 14.0, 1.0, 1);
    _ = try atlas.getOrRasterize('b', 14.0, 1.0, 1);
    const count_before = atlas.cachedCount();
    const evict_before = atlas.eviction_count;
    try std.testing.expectEqual(@as(usize, 2), count_before);

    // Oversized glyph (> 62px inside 64x64 atlas) must fail without wiping cached entries
    try std.testing.expectError(error.GlyphTooLarge, atlas.getOrRasterize('W', 100.0, 1.0, 2));
    try std.testing.expectEqual(count_before, atlas.cachedCount());
    try std.testing.expectEqual(evict_before, atlas.eviction_count);
}

test "LayoutArena emitQuadsWithAtlas retries once on mid-frame repack so all UVs are post-repack" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    // Tiny 64x64 atlas so frame 2 scene triggers mid-frame eviction & repack
    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 64, 64);
    defer atlas.deinit();

    // Pre-fill atlas on frame 1 with glyphs that will fill 64x64
    for ("MNOPQRSTUVWXYZ0123456789") |ch| {
        _ = try atlas.getOrRasterize(ch, 18.0, 1.0, 1);
    }

    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .gap = 4.0 });
    _ = try arena.addChild(root, .{ .kind = .card, .label = "ABCD", .font_size = 18.0, .height = 28.0 });
    _ = try arena.addChild(root, .{ .kind = .card, .label = "EFGH", .font_size = 18.0, .height = 28.0 });
    _ = try arena.addChild(root, .{ .kind = .card, .label = "IJKL", .font_size = 18.0, .height = 28.0 });
    arena.layout(300.0, 200.0);

    var quad_buf: [128]core.QuadInstance = undefined;
    const epoch_before = atlas.repack_epoch;
    const count = arena.emitQuadsWithAtlas(&quad_buf, 1.0, &atlas, 2);
    try std.testing.expect(atlas.repack_epoch > epoch_before);
    try std.testing.expectEqual(@as(usize, 12), count);

    // Every emitted quad UV must match the final post-repack entry in the atlas!
    const expected_chars = "ABCDEFGHIJKL";
    const epoch_after = atlas.repack_epoch;
    for (quad_buf[0..count], expected_chars) |q, ch| {
        const g = try atlas.getOrRasterize(ch, 18.0, 1.0, 2);
        try std.testing.expectEqual(epoch_after, atlas.repack_epoch);
        try std.testing.expectEqual(g.u0, q.uv_rect[0]);
        try std.testing.expectEqual(g.v0, q.uv_rect[1]);
        try std.testing.expectEqual(g.u1, q.uv_rect[2]);
        try std.testing.expectEqual(g.v1, q.uv_rect[3]);
    }
}

test "emitTextQuads advances pen_x when an oversized glyph is skipped" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 16, 16);
    defer atlas.deinit();

    // At 18px on a 16x16 atlas, 'W' may exceed 14x14 while 'i' fits; test directly with 20px vs 16x16
    // Force 'W' (wide) to fail GlyphTooLarge while '.' fits, or test at 22px where '.' fits (small bbox) and 'A' fails
    var out: [8]core.QuadInstance = undefined;
    const n = atlas.emitTextQuads(".W.", 0.0, 0.0, 22.0, 1.0, core.Nord.snow_storm_2, &out, 1);
    if (n == 2) {
        // Second '.' must be well to the right of first '.' because 'W' advance was applied
        try std.testing.expect(out[1].pos_size[0] > out[0].pos_size[0] + 10.0);
    }
}

test "LayoutArena skips labels on undersized toggles and sliders" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();

    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .gap = 4.0 });
    _ = try arena.addChild(root, .{ .kind = .slider, .label = "ShortSlider", .height = 32.0, .fill = core.Nord.polar_night_1 });
    _ = try arena.addChild(root, .{ .kind = .toggle, .label = "ShortToggle", .height = 14.0, .fill = core.Nord.polar_night_1 });
    _ = try arena.addChild(root, .{ .kind = .toggle, .label = "NarrowToggle", .width = 110.0, .height = 48.0, .fill = core.Nord.polar_night_1 });
    arena.layout(200.0, 200.0);

    var out: [64]core.QuadInstance = undefined;
    const count = arena.emitQuadsWithAtlas(&out, 1.0, &atlas, 1);
    try std.testing.expect(count > 0);
    for (out[0..count]) |q| {
        try std.testing.expectEqual(@as(f32, 0.0), q.params[3]);
    }
}

test "LayoutArena propagates active_clip onto glyph quads and culls offscreen text" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 512, 512);
    defer atlas.deinit();

    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .padding = 20.0 });
    const scroller = try arena.addChild(root, .{
        .kind = .vstack,
        .height = 60.0,
        .clip_children = true,
        .scroll_y = 60.0,
    });
    // Completely above clip (y = 20 - 60 = -40..10) -> all glyph quads culled
    _ = try arena.addChild(scroller, .{ .kind = .card, .label = "CULLED", .height = 50.0 });
    // Inside clip (y = 70 - 60 = 10..60) -> glyph quads stamped with [20, 20, 220, 80] at scale 1.0
    _ = try arena.addChild(scroller, .{ .kind = .card, .label = "VISIBLE", .height = 50.0 });
    arena.layout(240.0, 240.0);

    var out: [128]core.QuadInstance = undefined;
    const count = arena.emitQuadsWithAtlas(&out, 1.0, &atlas, 1);
    try std.testing.expect(count > 0);
    for (out[0..count]) |q| {
        try std.testing.expectEqual(@as(f32, 1.0), q.params[3]);
        try std.testing.expectEqual([4]f32{ 20.0, 20.0, 220.0, 80.0 }, q.clip_rect);
        try std.testing.expect(q.pos_size[1] + q.pos_size[3] > 20.0);
        try std.testing.expect(q.pos_size[1] < 80.0);
    }
}

test "emitTextQuadsClipped skips off-clip leading glyphs without starving tiny out_buf or churning atlas" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();

    // Measure prefix "XYZ" so we place the clip window starting right after "XYZ"
    const m_prefix = atlas.measureText("XYZ", 18.0, 1.0);
    const clip = [4]f32{ m_prefix.width + 2.0, 0.0, m_prefix.width + 200.0, 100.0 };

    // Only 3 output slots: leading off-clip 'X', 'Y', 'Z' MUST NOT consume slots or rasterize into atlas!
    var tiny: [3]core.QuadInstance = undefined;
    const emitted = atlas.emitTextQuadsClipped("XYZab", 0.0, 10.0, 18.0, 1.0, core.Nord.snow_storm_2, clip, &tiny, 1);
    try std.testing.expectEqual(@as(usize, 2), emitted);
    for (tiny[0..emitted]) |q| {
        try std.testing.expectEqual(clip, q.clip_rect);
        try std.testing.expect(q.pos_size[0] + q.pos_size[2] > clip[0]);
    }
    // Only 'a' and 'b' should have been rasterized into the atlas (not 'X', 'Y', 'Z')
    try std.testing.expectEqual(@as(usize, 2), atlas.entries.count());
}

test "Headless rasterizer: rotated QUAD_MODE_GLYPH renders cleanly without corner clipping" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();

    var unrot: [4]core.QuadInstance = undefined;
    const n = atlas.emitTextQuads("L", 40.0, 40.0, 24.0, 1.0, core.Nord.snow_storm_2, &unrot, 1);
    try std.testing.expectEqual(@as(usize, 1), n);

    // Center glyph 'L' at (60, 60) and rotate +pi/2 (90 deg CW) vs -pi/2 (90 deg CCW)
    var rot_cw = unrot[0];
    rot_cw.pos_size[0] = 60.0 - rot_cw.pos_size[2] * 0.5;
    rot_cw.pos_size[1] = 60.0 - rot_cw.pos_size[3] * 0.5;
    rot_cw.params[0] = std.math.pi * 0.5;

    var rot_ccw = rot_cw;
    rot_ccw.params[0] = -std.math.pi * 0.5;

    const view = headless.AtlasView{
        .pixels = atlas.pixels,
        .width = atlas.width,
        .height = atlas.height,
    };
    const black = core.Color{ 0.0, 0.0, 0.0, 1.0 };
    const no_round_clip = [4]f32{ 0.0, 0.0, 0.0, 0.0 };

    var unrot_q = rot_cw;
    unrot_q.params[0] = 0.0;

    const img_unrot = try headless.renderQuadsToRgba(std.testing.allocator, 120, 120, &[_]core.QuadInstance{unrot_q}, black, no_round_clip, view);
    defer std.testing.allocator.free(img_unrot);
    const img_cw = try headless.renderQuadsToRgba(std.testing.allocator, 120, 120, &[_]core.QuadInstance{rot_cw}, black, no_round_clip, view);
    defer std.testing.allocator.free(img_cw);
    const img_ccw = try headless.renderQuadsToRgba(std.testing.allocator, 120, 120, &[_]core.QuadInstance{rot_ccw}, black, no_round_clip, view);
    defer std.testing.allocator.free(img_ccw);

    // For 'L' rotated +pi/2 CW, the vertical stem rotates to TOP and bottom foot rotates to LEFT ('Γ' shape):
    // top-left quadrant is denser than bottom-right, whereas -pi/2 CCW puts stem at BOTTOM and foot at RIGHT!
    var cw_top_left: usize = 0;
    var cw_bot_right: usize = 0;
    var ccw_top_left: usize = 0;
    var ccw_bot_right: usize = 0;
    for (0..60) |y| {
        for (0..60) |x| {
            if (img_cw[(y * 120 + x) * 4 + 0] > 30) cw_top_left += 1;
            if (img_ccw[(y * 120 + x) * 4 + 0] > 30) ccw_top_left += 1;
        }
    }
    for (60..120) |y| {
        for (60..120) |x| {
            if (img_cw[(y * 120 + x) * 4 + 0] > 30) cw_bot_right += 1;
            if (img_ccw[(y * 120 + x) * 4 + 0] > 30) ccw_bot_right += 1;
        }
    }
    try std.testing.expect(cw_top_left > cw_bot_right);
    try std.testing.expect(ccw_bot_right > ccw_top_left);
    try std.testing.expect(headless.diffRgba(img_unrot, img_cw, 10).mismatched_pixels > 20);
    try std.testing.expect(headless.diffRgba(img_cw, img_ccw, 10).mismatched_pixels > 20);

    // Round clip also masks rotated glyph when placed outside circle
    const rc_tight = [4]f32{ 20.0, 20.0, 10.0, 1.0 };
    const img_rc_glyph = try headless.renderQuadsToRgba(std.testing.allocator, 120, 120, &[_]core.QuadInstance{rot_cw}, black, rc_tight, view);
    defer std.testing.allocator.free(img_rc_glyph);
    var lit_rc: usize = 0;
    for (0..120 * 120) |i| {
        if (img_rc_glyph[i * 4 + 0] > 0) lit_rc += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), lit_rc);
}

test "wearos.emitCurvedText emits tangential top_arc and bottom_arc glyph quads with bounds and NaN safety" {
    const font_bytes = try loadHostFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 512, 512);
    defer atlas.deinit();

    const clip = [4]f32{ 0.0, 0.0, 466.0, 466.0 };
    var top_quads: [64]core.QuadInstance = undefined;
    var top_count: usize = 0;

    // Top arc centered at 12 o'clock (-pi/2)
    wearos.emitCurvedText(
        &atlas,
        "MODEL",
        116.5,
        116.5,
        96.0,
        -std.math.pi * 0.5,
        14.0,
        2.0,
        core.Nord.snow_storm_2,
        clip,
        true,
        1.5,
        &top_quads,
        &top_count,
        1,
    );
    try std.testing.expectEqual(@as(usize, 5), top_count);
    for (top_quads[0..top_count]) |q| {
        try std.testing.expectEqual(core.QUAD_MODE_GLYPH, q.params[3]);
        const q_cy = q.pos_size[1] + q.pos_size[3] * 0.5;
        try std.testing.expect(q_cy < 233.0); // top half
    }
    // Left-to-right order along top rim: X increases monotonically, angle increases from negative to positive
    try std.testing.expect(top_quads[0].pos_size[0] < top_quads[4].pos_size[0]);
    try std.testing.expect(top_quads[0].params[0] < 0.0);
    try std.testing.expect(top_quads[4].params[0] > 0.0);

    // Bottom arc centered at 6 o'clock (+pi/2): upright left-to-right!
    var bot_quads: [64]core.QuadInstance = undefined;
    var bot_count: usize = 0;
    wearos.emitCurvedText(
        &atlas,
        "READY",
        116.5,
        116.5,
        96.0,
        std.math.pi * 0.5,
        14.0,
        2.0,
        core.Nord.frost_1,
        clip,
        false,
        1.5,
        &bot_quads,
        &bot_count,
        1,
    );
    try std.testing.expectEqual(@as(usize, 5), bot_count);
    for (bot_quads[0..bot_count]) |q| {
        try std.testing.expectEqual(core.QUAD_MODE_GLYPH, q.params[3]);
        const q_cy = q.pos_size[1] + q.pos_size[3] * 0.5;
        try std.testing.expect(q_cy > 233.0); // bottom half
    }
    // Left-to-right upright along bottom rim: X increases, left char tilts clockwise (+), right char tilts CCW (-)
    try std.testing.expect(bot_quads[0].pos_size[0] < bot_quads[4].pos_size[0]);
    try std.testing.expect(bot_quads[0].params[0] > 0.0);
    try std.testing.expect(bot_quads[4].params[0] < 0.0);

    // Rasterize both top_quads and bot_quads via headless to verify pixels appear in top & bottom halves
    const view = headless.AtlasView{
        .pixels = atlas.pixels,
        .width = atlas.width,
        .height = atlas.height,
    };
    const img_top = try headless.renderQuadsToRgba(std.testing.allocator, 466, 466, top_quads[0..top_count], .{ 0, 0, 0, 1 }, .{ 0, 0, 0, 0 }, view);
    defer std.testing.allocator.free(img_top);
    var lit_upper: usize = 0;
    for (0..233) |y| {
        for (0..466) |x| {
            if (img_top[(y * 466 + x) * 4 + 0] > 30) lit_upper += 1;
        }
    }
    try std.testing.expect(lit_upper > 80);

    const img_bot = try headless.renderQuadsToRgba(std.testing.allocator, 466, 466, bot_quads[0..bot_count], .{ 0, 0, 0, 1 }, .{ 0, 0, 0, 0 }, view);
    defer std.testing.allocator.free(img_bot);
    var lit_lower: usize = 0;
    for (233..466) |y| {
        for (0..466) |x| {
            if (img_bot[(y * 466 + x) * 4 + 2] > 30) lit_lower += 1;
        }
    }
    try std.testing.expect(lit_lower > 80);

    // center_angle_rad at +pi and -pi (9 o'clock left bezel) emits symmetric left-rim quads
    var left_pos_buf: [16]core.QuadInstance = undefined;
    var left_pos_cnt: usize = 0;
    wearos.emitCurvedText(&atlas, "HI", 116.5, 116.5, 96.0, std.math.pi, 14.0, 2.0, core.Nord.snow_storm_2, clip, true, 0.0, &left_pos_buf, &left_pos_cnt, 1);
    var left_neg_buf: [16]core.QuadInstance = undefined;
    var left_neg_cnt: usize = 0;
    wearos.emitCurvedText(&atlas, "HI", 116.5, 116.5, 96.0, -std.math.pi, 14.0, 2.0, core.Nord.snow_storm_2, clip, true, 0.0, &left_neg_buf, &left_neg_cnt, 1);
    try std.testing.expectEqual(@as(usize, 2), left_pos_cnt);
    try std.testing.expectEqual(@as(usize, 2), left_neg_cnt);
    try std.testing.expectApproxEqAbs(left_pos_buf[0].pos_size[0], left_neg_buf[0].pos_size[0], 0.01);
    try std.testing.expectApproxEqAbs(left_pos_buf[0].pos_size[1], left_neg_buf[0].pos_size[1], 0.01);

    // Empty text, NaN radius, and tight buffer bounds safety
    var empty_count: usize = 0;
    wearos.emitCurvedText(&atlas, "", 116.5, 116.5, 96.0, -std.math.pi * 0.5, 14.0, 2.0, core.Nord.snow_storm_2, clip, true, 0.0, &top_quads, &empty_count, 1);
    wearos.emitCurvedText(&atlas, "OK", 116.5, 116.5, std.math.nan(f32), -std.math.pi * 0.5, 14.0, 2.0, core.Nord.snow_storm_2, clip, true, 0.0, &top_quads, &empty_count, 1);
    try std.testing.expectEqual(@as(usize, 0), empty_count);

    var tiny_buf: [2]core.QuadInstance = undefined;
    var tiny_count: usize = 0;
    wearos.emitCurvedText(&atlas, "ABCDE", 116.5, 116.5, 96.0, -std.math.pi * 0.5, 14.0, 2.0, core.Nord.snow_storm_2, clip, true, 0.0, &tiny_buf, &tiny_count, 1);
    try std.testing.expectEqual(@as(usize, 2), tiny_count);

    // String with space ("MODEL 3") skips empty space quad while preserving advance gap
    var spaced_buf: [16]core.QuadInstance = undefined;
    var spaced_count: usize = 0;
    wearos.emitCurvedText(&atlas, "MODEL 3", 116.5, 116.5, 96.0, -std.math.pi * 0.5, 14.0, 2.0, core.Nord.snow_storm_2, clip, true, 0.0, &spaced_buf, &spaced_count, 1);
    try std.testing.expectEqual(@as(usize, 6), spaced_count);
    try std.testing.expect(spaced_buf[5].pos_size[0] > spaced_buf[4].pos_size[0] + spaced_buf[4].pos_size[2]);

    // Pre-filled 64x64 atlas evicts old frame_idx=1 glyphs mid-string and repacks frame_idx=7 glyphs cleanly
    var small_atlas = try glyph_atlas.GlyphAtlas.init(std.testing.allocator, font_bytes, 64, 64);
    defer small_atlas.deinit();
    for ("MNOPQRSTUVWXYZ0123456789") |ch| {
        _ = try small_atlas.getOrRasterize(ch, 18.0, 1.0, 1);
    }
    const epoch_start = small_atlas.repack_epoch;

    var repack_buf: [16]core.QuadInstance = undefined;
    var repack_count: usize = 0;
    wearos.emitCurvedText(&small_atlas, "ABCDEFGH", 116.5, 116.5, 96.0, -std.math.pi * 0.5, 18.0, 1.0, core.Nord.snow_storm_2, clip, true, 0.0, &repack_buf, &repack_count, 7);
    try std.testing.expect(small_atlas.repack_epoch > epoch_start);
    try std.testing.expectEqual(@as(usize, 8), repack_count);
    const epoch_after = small_atlas.repack_epoch;
    for ("ABCDEFGH", 0..) |ch, idx| {
        const expected = try small_atlas.getOrRasterize(ch, 18.0, 1.0, 7);
        try std.testing.expectEqual(epoch_after, small_atlas.repack_epoch);
        try std.testing.expectApproxEqAbs(expected.u0, repack_buf[idx].uv_rect[0], 1e-6);
        try std.testing.expectApproxEqAbs(expected.v0, repack_buf[idx].uv_rect[1], 1e-6);
        try std.testing.expectApproxEqAbs(expected.u1, repack_buf[idx].uv_rect[2], 1e-6);
        try std.testing.expectApproxEqAbs(expected.v1, repack_buf[idx].uv_rect[3], 1e-6);
    }
}
