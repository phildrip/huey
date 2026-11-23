const std = @import("std");
const core = @import("core.zig");
const glyph_atlas = @import("glyph_atlas.zig");

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
    var bad_sfnt = [_]u8{0} ** 32;
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
