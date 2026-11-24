const std = @import("std");
const core = @import("core.zig");
const events = @import("events.zig");
const headless = @import("headless.zig");

test "HeadlessSession act -> step -> inspect drives demo scene across multi-DPI matrix" {
    var session = try headless.HeadlessSession.init(std.testing.allocator, 768.0, 976.0, 2.0);
    defer session.deinit();
    try core.buildDemoScene(&session.arena);

    const r0 = session.step(16.67);
    try std.testing.expect(r0.quad_count >= 60);

    // Semantic click on settings.oklab_palette toggle (starts unchecked)
    try session.act(.{ .click_id = "settings.oklab_palette" });
    const r1 = session.step(16.67);
    try std.testing.expectEqual(@as(usize, 1), r1.events.len);
    try std.testing.expectEqualStrings("settings.oklab_palette", r1.events[0].toggled.test_id);
    try std.testing.expect(r1.events[0].toggled.checked);

    // Semantic slider set
    try session.act(.{ .set_slider_id = .{ .id = "settings.shadow_softness", .value = 0.85 } });
    const r2 = session.step(16.67);
    try std.testing.expect(r2.events.len >= 1);

    // Multi-DPI matrix: 1.0x, 1.25x, 1.5x, 2.0x all produce zero layout errors on Nexus 9 viewport
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        session.setViewport(768.0, 976.0, scale);
        _ = session.step(16.67);
        var diags: [32]headless.Diagnostic = undefined;
        const n_diag = session.runDiagnostics(&diags);
        for (diags[0..n_diag]) |d| {
            try std.testing.expect(d.code != .overflow and d.code != .zero_size and d.code != .occluded_target and d.code != .low_contrast);
        }
    }

    // JSON semantic + diagnostic dump is valid structured output
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try session.dumpJson(&aw.writer);
    const json = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"settings.oklab_palette\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"diagnostics\"") != null);
}

test "HeadlessSession automatic UI lints catch OVERFLOW, ZERO_SIZE, OCCLUDED_TARGET, LOW_CONTRAST, and SMALL_TOUCH_TARGET" {
    var session = try headless.HeadlessSession.init(std.testing.allocator, 200.0, 200.0, 1.0);
    defer session.deinit();
    session.touch_profile = true;

    const root = try session.arena.addNode(.{
        .kind = .zstack,
        .role = .container,
        .test_id = "root",
        .fill = core.Nord.polar_night_0,
    });
    // Small touch target (< 44dp) + low contrast (dark text on dark bg)
    _ = try session.arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "bad.tiny_dark",
        .width = 30.0,
        .height = 30.0,
        .fill = core.Nord.polar_night_1,
        .text_color = core.Nord.polar_night_2, // almost identical lightness!
        .label = "Hard to read",
    });
    // Zero-size collapsed node inside a zero-inner-size container
    const zero_wrap = try session.arena.addChild(root, .{
        .kind = .vstack,
        .role = .container,
        .test_id = "bad.zero_wrap",
        .padding = 200.0,
    });
    _ = try session.arena.addChild(zero_wrap, .{
        .kind = .card,
        .role = .panel,
        .test_id = "bad.zero",
        .width = 0.0,
        .height = 0.0,
        .fill = core.Nord.polar_night_1,
    });
    // Invisible text_color (alpha = 0) on opaque card triggers low_contrast
    _ = try session.arena.addChild(root, .{
        .kind = .card,
        .role = .panel,
        .test_id = "bad.invisible_text",
        .width = 100.0,
        .height = 40.0,
        .fill = core.Nord.polar_night_1,
        .text_color = .{ 1.0, 1.0, 1.0, 0.0 },
        .label = "Invisible",
    });
    // Opaque cover occluding bad.tiny_dark
    _ = try session.arena.addChild(root, .{
        .kind = .card,
        .role = .panel,
        .test_id = "cover",
        .width = 250.0, // overflows 200dp viewport!
        .height = 200.0,
        .fill = core.Nord.polar_night_0,
    });

    _ = session.step(16.67);
    var diags: [32]headless.Diagnostic = undefined;
    const n = session.runDiagnostics(&diags);

    var saw_small = false;
    var saw_contrast = false;
    var saw_occluded = false;
    var saw_overflow = false;
    var saw_zero = false;
    var saw_invisible_contrast = false;
    for (diags[0..n]) |d| {
        switch (d.code) {
            .small_touch_target => saw_small = true,
            .low_contrast => {
                saw_contrast = true;
                if (std.mem.eql(u8, d.test_id, "bad.invisible_text")) {
                    saw_invisible_contrast = true;
                }
            },
            .occluded_target => saw_occluded = true,
            .overflow => saw_overflow = true,
            .zero_size => {
                if (std.mem.eql(u8, d.test_id, "bad.zero")) {
                    saw_zero = true;
                }
            },
        }
    }
    try std.testing.expect(saw_small);
    try std.testing.expect(saw_contrast);
    try std.testing.expect(saw_invisible_contrast);
    try std.testing.expect(saw_occluded);
    try std.testing.expect(saw_overflow);
    try std.testing.expect(saw_zero);
}

test "HeadlessSession renders deterministic UberQuad RGBA snapshots, PNG bytes, and pixel diffs" {
    var session = try headless.HeadlessSession.init(std.testing.allocator, 160.0, 120.0, 1.0);
    defer session.deinit();

    const root = try session.arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .test_id = "root",
        .padding = 12.0,
        .fill = core.Nord.polar_night_0,
    });
    _ = try session.arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "t1",
        .height = 48.0,
        .corner_radius = 12.0,
        .border_width = 2.0,
        .shadow_blur = 6.0,
        .fill = core.Nord.polar_night_1,
        .border = core.Nord.frost_1,
        .accent = core.Nord.aurora_green,
        .checked = false,
    });
    _ = session.step(16.67);

    const img_before = try session.renderSnapshotRgba(std.testing.allocator, false);
    defer std.testing.allocator.free(img_before);
    const img_same = try session.renderSnapshotRgba(std.testing.allocator, false);
    defer std.testing.allocator.free(img_same);

    // Deterministic pixel-exact identity
    const d0 = headless.diffRgba(img_before, img_same, 0);
    try std.testing.expectEqual(@as(usize, 0), d0.mismatched_pixels);

    // Toggle changes pixels measurably
    try session.act(.{ .click_id = "t1" });
    _ = session.step(16.67);
    const img_after = try session.renderSnapshotRgba(std.testing.allocator, false);
    defer std.testing.allocator.free(img_after);
    const d1 = headless.diffRgba(img_before, img_after, 4);
    try std.testing.expect(d1.mismatched_pixels > 50);

    // Annotated snapshot differs from unannotated
    const img_ann = try session.renderSnapshotRgba(std.testing.allocator, true);
    defer std.testing.allocator.free(img_ann);
    const d2 = headless.diffRgba(img_after, img_ann, 0);
    try std.testing.expect(d2.mismatched_pixels > 20);

    // Valid PNG magic header + IEND chunk
    var png_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer png_buf.deinit();
    try headless.encodePng(&png_buf.writer, 160, 120, img_after);
    const png = png_buf.written();
    try std.testing.expect(png.len > 64);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A }, png[0..8]);
    try std.testing.expect(std.mem.indexOf(u8, png, "IEND") != null);

    // Full PNG chunk CRC32 + IHDR + zlib/stored-deflate + Adler32 + pixel round-trip verification
    try verifyEncodedPng(std.testing.allocator, png, 160, 120, img_after);
}

fn adler32Verify(data: []const u8) u32 {
    var s1: u32 = 1;
    var s2: u32 = 0;
    for (data) |b| {
        s1 = (s1 + b) % 65521;
        s2 = (s2 + s1) % 65521;
    }
    return (s2 << 16) | s1;
}

fn verifyEncodedPng(
    allocator: std.mem.Allocator,
    png: []const u8,
    expected_w: u32,
    expected_h: u32,
    expected_rgba: []const u8,
) !void {
    try std.testing.expect(png.len >= 8);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A }, png[0..8]);

    var pos: usize = 8;
    var saw_ihdr = false;
    var saw_iend = false;
    var idat_bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer idat_bytes.deinit(allocator);

    while (pos < png.len) {
        try std.testing.expect(pos + 12 <= png.len);
        const chunk_len = std.mem.readInt(u32, png[pos..][0..4], .big);
        const chunk_type = png[pos + 4 .. pos + 8];
        pos += 8;
        try std.testing.expect(pos + chunk_len + 4 <= png.len);
        const chunk_data = png[pos .. pos + chunk_len];
        pos += chunk_len;
        const stored_crc = std.mem.readInt(u32, png[pos..][0..4], .big);
        pos += 4;

        var crc = std.hash.Crc32.init();
        crc.update(chunk_type);
        crc.update(chunk_data);
        try std.testing.expectEqual(stored_crc, crc.final());

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            try std.testing.expect(!saw_ihdr);
            try std.testing.expectEqual(@as(u32, 13), chunk_len);
            try std.testing.expectEqual(expected_w, std.mem.readInt(u32, chunk_data[0..4], .big));
            try std.testing.expectEqual(expected_h, std.mem.readInt(u32, chunk_data[4..8], .big));
            try std.testing.expectEqual(@as(u8, 8), chunk_data[8]);
            try std.testing.expectEqual(@as(u8, 6), chunk_data[9]);
            try std.testing.expectEqual(@as(u8, 0), chunk_data[10]);
            try std.testing.expectEqual(@as(u8, 0), chunk_data[11]);
            try std.testing.expectEqual(@as(u8, 0), chunk_data[12]);
            saw_ihdr = true;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try std.testing.expect(saw_ihdr);
            try idat_bytes.appendSlice(allocator, chunk_data);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            try std.testing.expectEqual(@as(u32, 0), chunk_len);
            saw_iend = true;
            break;
        }
    }

    try std.testing.expect(saw_ihdr and saw_iend);
    try std.testing.expectEqual(png.len, pos);

    const z = idat_bytes.items;
    try std.testing.expect(z.len >= 6);
    const cmf_flg: u16 = (@as(u16, z[0]) << 8) | z[1];
    try std.testing.expectEqual(@as(u16, 0), cmf_flg % 31);

    var raw_scanlines: std.ArrayListUnmanaged(u8) = .empty;
    defer raw_scanlines.deinit(allocator);

    var zpos: usize = 2;
    var block_count: usize = 0;
    var saw_final = false;
    while (!saw_final) {
        try std.testing.expect(zpos + 5 <= z.len - 4);
        const hdr = z[zpos];
        const bfinal = (hdr & 0x01) != 0;
        const btype = (hdr >> 1) & 0x03;
        try std.testing.expectEqual(@as(u8, 0), btype);
        const blen = std.mem.readInt(u16, z[zpos + 1 ..][0..2], .little);
        const bnlen = std.mem.readInt(u16, z[zpos + 3 ..][0..2], .little);
        try std.testing.expectEqual(@as(u16, ~blen), bnlen);
        zpos += 5;
        try std.testing.expect(zpos + blen <= z.len - 4);
        try raw_scanlines.appendSlice(allocator, z[zpos .. zpos + blen]);
        zpos += blen;
        block_count += 1;
        saw_final = bfinal;
    }
    try std.testing.expect(block_count >= 2);
    try std.testing.expectEqual(z.len - 4, zpos);

    const stored_adler = std.mem.readInt(u32, z[z.len - 4 ..][0..4], .big);
    try std.testing.expectEqual(stored_adler, adler32Verify(raw_scanlines.items));

    const row_bytes: usize = @as(usize, expected_w) * 4;
    try std.testing.expectEqual((1 + row_bytes) * @as(usize, expected_h), raw_scanlines.items.len);
    for (0..expected_h) |y| {
        const src_row = raw_scanlines.items[y * (1 + row_bytes) ..][0 .. 1 + row_bytes];
        try std.testing.expectEqual(@as(u8, 0), src_row[0]);
        try std.testing.expectEqualSlices(
            u8,
            expected_rgba[y * row_bytes ..][0..row_bytes],
            src_row[1..],
        );
    }
}

test "Regression checks for adversarial findings: JSON escaping, strict errors, NaN/huge bounds, and diffRgba" {
    var session = try headless.HeadlessSession.init(std.testing.allocator, 200.0, 200.0, 2.0);
    defer session.deinit();

    const root = try session.arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .test_id = "root\"quote\\slash\nnewline\x01ctrl",
        .fill = core.Nord.polar_night_0,
    });
    _ = try session.arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "t.toggle",
        .height = 48.0,
        .fill = core.Nord.polar_night_1,
    });
    const zero_wrap = try session.arena.addChild(root, .{
        .kind = .vstack,
        .role = .container,
        .test_id = "zero.wrap",
        .padding = 200.0,
    });
    _ = try session.arena.addChild(zero_wrap, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "zero.btn",
        .height = 48.0,
    });
    _ = try session.arena.addChild(root, .{
        .kind = .card,
        .role = .panel,
        .test_id = "huge.card",
        .width = 1e25,
        .height = 20.0,
        .fill = core.Nord.polar_night_1,
    });
    _ = session.step(16.67);

    // 1. dumpJson produces valid JSON parsed by std.json.parseFromSlice
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try session.dumpJson(&aw.writer);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const nodes_arr = parsed.value.object.get("nodes").?.array;
    try std.testing.expectEqualStrings("root\"quote\\slash\nnewline\x01ctrl", nodes_arr.items[0].object.get("test_id").?.string);

    // 2. act validates zero-size nodes and slider kind
    try std.testing.expectError(error.ZeroSizeNode, session.act(.{ .click_id = "zero.btn" }));
    try std.testing.expectError(error.NodeNotSlider, session.act(.{ .set_slider_id = .{ .id = "t.toggle", .value = 0.5 } }));

    // 3. renderSnapshotRgba(true) with huge 1e25 width does not panic
    const snap = try session.renderSnapshotRgba(std.testing.allocator, true);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqual(@as(usize, 400 * 400 * 4), snap.len);

    // 4. encodePng rejects mismatched buffer size (both too small and too large)
    var png_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer png_buf.deinit();
    const tiny_rgba = [_]u8{ 0, 0, 0, 255, 0 };
    try std.testing.expectError(error.InvalidBufferSize, headless.encodePng(&png_buf.writer, 1, 1, &tiny_rgba));

    // 5. diffRgba handles mismatched lengths < 4 and trailing % 4 bytes
    const a4 = [_]u8{ 10, 20, 30, 255 };
    const b5 = [_]u8{ 10, 20, 30, 255, 99 };
    const d_len = headless.diffRgba(&a4, &b5, 0);
    try std.testing.expect(d_len.mismatched_pixels >= 1);
    try std.testing.expectEqual(@as(u8, 255), d_len.max_diff);

    const c5 = [_]u8{ 10, 20, 30, 255, 90 };
    const d_trail = headless.diffRgba(&b5, &c5, 0);
    try std.testing.expectEqual(@as(usize, 1), d_trail.mismatched_pixels);
    try std.testing.expectEqual(@as(u8, 9), d_trail.max_diff);

    // 6. setViewport validates all 3 args atomically
    session.setViewport(300.0, 400.0, std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 200.0), session.viewport_w);
    try std.testing.expectEqual(@as(f32, 200.0), session.viewport_h);
    try std.testing.expectEqual(@as(f32, 2.0), session.scale_factor);
}

test "HeadlessSession.runDiagnostics skips overflow and occluded_target false positives inside clip_children scrollers" {
    var session = try headless.HeadlessSession.init(std.testing.allocator, 300.0, 300.0, 1.0);
    defer session.deinit();

    const root = try session.arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .test_id = "root",
        .padding = 20.0,
        .fill = core.Nord.polar_night_0,
    });
    const scroller = try session.arena.addChild(root, .{
        .kind = .vstack,
        .role = .container,
        .test_id = "scroller",
        .height = 100.0,
        .clip_children = true,
        .scroll_y = 60.0,
        .fill = core.Nord.polar_night_1,
    });
    for ([_][]const u8{ "item0", "item1", "item2", "item3", "item4" }) |tid| {
        _ = try session.arena.addChild(scroller, .{
            .kind = .toggle,
            .role = .switch_control,
            .test_id = tid,
            .height = 50.0,
            .fill = core.Nord.polar_night_2,
        });
    }

    _ = session.step(16.67);
    var diags: [32]headless.Diagnostic = undefined;
    const n_diag = session.runDiagnostics(&diags);
    for (diags[0..n_diag]) |d| {
        try std.testing.expect(d.code != .overflow);
        try std.testing.expect(d.code != .occluded_target);
    }
}

test "Headless rasterizer: QUAD_MODE_ARC covers start/mid/end, full 2*pi ring, 0-sweep empty, colored glow, and NaN/zero-thickness safety" {
    const black = core.Color{ 0.0, 0.0, 0.0, 1.0 };
    const no_round_clip = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
    const w: usize = 120;
    const h: usize = 120;
    const cx: usize = 60;
    const cy: usize = 60;

    // 1. Top-right quarter arc: start = -pi/2 (12 o'clock), sweep = pi/2 (to 3 o'clock), r = 40, thickness = 8
    const arc_col = core.Color{ 0.2, 0.8, 1.0, 1.0 };
    const q_quarter = [_]core.QuadInstance{.{
        .pos_size = .{ 16.0, 16.0, 88.0, 88.0 }, // center (60,60), half=44, auto r = 44 - 4 = 40
        .uv_rect = .{ -std.math.pi * 0.5, std.math.pi * 0.5, 0.0, 0.0 },
        .color = arc_col,
        .border_color = core.Nord.transparent,
        .params = .{ 0.0, 8.0, 0.0, core.QUAD_MODE_ARC },
    }};
    const img_q = try headless.renderQuadsToRgba(std.testing.allocator, w, h, &q_quarter, black, no_round_clip, null);
    defer std.testing.allocator.free(img_q);

    // Start (12 o'clock: 60, 20), Mid (1:30: 60 + 28, 60 - 28), End (3 o'clock: 100, 60) should be lit
    const px_start = (20 * w + 60) * 4;
    const px_mid = (32 * w + 88) * 4;
    const px_end = (60 * w + 100) * 4;
    try std.testing.expect(img_q[px_start + 2] > 200);
    try std.testing.expect(img_q[px_mid + 2] > 200);
    try std.testing.expect(img_q[px_end + 2] > 200);

    // Opposite angles (9 o'clock: 20, 60; 6 o'clock: 60, 100) and center (60, 60) must remain black
    const px_9 = (60 * w + 20) * 4;
    const px_6 = (100 * w + 60) * 4;
    const px_ctr = (cy * w + cx) * 4;
    try std.testing.expectEqual(@as(u8, 0), img_q[px_9 + 2]);
    try std.testing.expectEqual(@as(u8, 0), img_q[px_6 + 2]);
    try std.testing.expectEqual(@as(u8, 0), img_q[px_ctr + 2]);

    // 2. Full 2*pi closed ring lights all 4 cardinal points (12, 3, 6, 9) and leaves center empty
    const q_ring = [_]core.QuadInstance{.{
        .pos_size = .{ 16.0, 16.0, 88.0, 88.0 },
        .uv_rect = .{ -std.math.pi * 0.5, std.math.tau, 0.0, 0.0 },
        .color = arc_col,
        .border_color = core.Nord.transparent,
        .params = .{ 40.0, 6.0, 0.0, core.QUAD_MODE_ARC },
    }};
    const img_ring = try headless.renderQuadsToRgba(std.testing.allocator, w, h, &q_ring, black, no_round_clip, null);
    defer std.testing.allocator.free(img_ring);
    try std.testing.expect(img_ring[(20 * w + 60) * 4 + 2] > 200);
    try std.testing.expect(img_ring[(60 * w + 100) * 4 + 2] > 200);
    try std.testing.expect(img_ring[(100 * w + 60) * 4 + 2] > 200);
    try std.testing.expect(img_ring[(60 * w + 20) * 4 + 2] > 200);
    try std.testing.expectEqual(@as(u8, 0), img_ring[px_ctr + 2]);

    // 3. Zero sweep, zero thickness, and NaN inputs render empty cleanly
    const q_empty = [_]core.QuadInstance{
        .{
            .pos_size = .{ 16.0, 16.0, 88.0, 88.0 },
            .uv_rect = .{ 0.0, 0.0, 0.0, 0.0 },
            .color = arc_col,
            .border_color = core.Nord.transparent,
            .params = .{ 40.0, 6.0, 0.0, core.QUAD_MODE_ARC },
        },
        .{
            .pos_size = .{ 16.0, 16.0, 88.0, 88.0 },
            .uv_rect = .{ 0.0, std.math.pi, 0.0, 0.0 },
            .color = arc_col,
            .border_color = core.Nord.transparent,
            .params = .{ 40.0, 0.0, 0.0, core.QUAD_MODE_ARC },
        },
        .{
            .pos_size = .{ 16.0, 16.0, 88.0, 88.0 },
            .uv_rect = .{ std.math.nan(f32), std.math.pi, 0.0, 0.0 },
            .color = arc_col,
            .border_color = core.Nord.transparent,
            .params = .{ 40.0, 6.0, 0.0, core.QUAD_MODE_ARC },
        },
    };
    const img_empty = try headless.renderQuadsToRgba(std.testing.allocator, w, h, &q_empty, black, no_round_clip, null);
    defer std.testing.allocator.free(img_empty);
    for (0..w * h) |i| {
        try std.testing.expectEqual(@as(u8, 0), img_empty[i * 4 + 2]);
    }

    // 4. Colored outer glow halo (blur = 12.0) radiates outside stroke using arc color
    const q_glow = [_]core.QuadInstance{.{
        .pos_size = .{ 20.0, 20.0, 80.0, 80.0 }, // half=40, r = 40 - 3 = 37
        .uv_rect = .{ 0.0, std.math.tau, 0.0, 0.0 },
        .color = .{ 0.0, 0.5, 1.0, 1.0 },
        .border_color = core.Nord.transparent,
        .params = .{ 34.0, 6.0, 12.0, core.QUAD_MODE_ARC },
    }};
    const img_glow = try headless.renderQuadsToRgba(std.testing.allocator, w, h, &q_glow, black, no_round_clip, null);
    defer std.testing.allocator.free(img_glow);
    // Outer edge of stroke is at 60 + 37 = 97; 3px outside = x=100, y=60 must have blue > green > red == 0
    const px_halo = (60 * w + 100) * 4;
    try std.testing.expectEqual(@as(u8, 0), img_glow[px_halo + 0]);
    try std.testing.expect(img_glow[px_halo + 1] > 10);
    try std.testing.expect(img_glow[px_halo + 2] > img_glow[px_halo + 1]);
}

test "Headless rasterizer: QUAD_MODE_SURFACE vertical linear gradient, top specular rim, and colored glow halo" {
    const black = core.Color{ 0.0, 0.0, 0.0, 1.0 };
    const no_round_clip = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
    const w: usize = 100;
    const h: usize = 100;

    // 1. Vertical gradient: top pure white (1,1,1,1) -> bottom black (0,0,0), no specular, no border
    const q_grad = [_]core.QuadInstance{.{
        .pos_size = .{ 20.0, 20.0, 60.0, 60.0 },
        .uv_rect = .{ 0.0, 0.0, 0.0, 0.0 },
        .color = .{ 1.0, 1.0, 1.0, 1.0 },
        .border_color = core.Nord.transparent,
        .params = .{ 0.0, 0.0, 0.0, core.QUAD_MODE_SURFACE },
    }};
    const img_grad = try headless.renderQuadsToRgba(std.testing.allocator, w, h, &q_grad, black, no_round_clip, null);
    defer std.testing.allocator.free(img_grad);
    const px_top = (22 * w + 50) * 4;
    const px_mid = (50 * w + 50) * 4;
    const px_bot = (77 * w + 50) * 4;
    try std.testing.expect(img_grad[px_top + 0] > 235);
    // Linear-space midpoint of 1.0 and 0.0 is 0.5 linear -> ~188 sRGB (NOT 128!)
    try std.testing.expect(img_grad[px_mid + 0] >= 180 and img_grad[px_mid + 0] <= 196);
    try std.testing.expect(img_grad[px_bot + 0] < 90);

    // 2. Top specular rim + colored border glow: uniform dark fill (#161A22), top_specular_alpha = 0.5, Frost border + glow
    const dark_fill = core.Color{ 0.086, 0.102, 0.133, 1.0 };
    const q_spec = [_]core.QuadInstance{.{
        .pos_size = .{ 20.0, 20.0, 60.0, 60.0 },
        .uv_rect = .{ dark_fill[0], dark_fill[1], dark_fill[2], 0.5 },
        .color = dark_fill,
        .border_color = core.Nord.frost_1,
        .params = .{ 10.0, 2.0, 10.0, core.QUAD_MODE_SURFACE },
    }};
    const img_spec = try headless.renderQuadsToRgba(std.testing.allocator, w, h, &q_spec, black, no_round_clip, null);
    defer std.testing.allocator.free(img_spec);
    // Just inside 2px top border (y=22.5 -> row 22, x=50) must be measurably brighter than interior (row 35, x=50)
    const px_rim = (22 * w + 50) * 4;
    const px_int = (35 * w + 50) * 4;
    try std.testing.expect(img_spec[px_rim + 0] > img_spec[px_int + 0] + 30);
    // Colored glow halo 3px above top border (row 16, x=50) must match Nord Frost hue (blue > red)
    const px_halo = (16 * w + 50) * 4;
    try std.testing.expect(img_spec[px_halo + 2] > 40);
    try std.testing.expect(img_spec[px_halo + 2] > img_spec[px_halo + 0]);
}

test "Headless rasterizer: QUAD_MODE_CAPSULE rotated 45 deg and 90 deg renders without corner clipping" {
    const black = core.Color{ 0.0, 0.0, 0.0, 1.0 };
    const no_round_clip = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
    const w: usize = 100;
    const h: usize = 100;

    // 40x8 horizontal capsule centered at (50, 50), rotated 90 deg (pi/2) -> vertical 8x40 capsule!
    const q_90 = [_]core.QuadInstance{.{
        .pos_size = .{ 30.0, 46.0, 40.0, 8.0 },
        .uv_rect = .{ std.math.pi * 0.5, 0.0, 0.0, 0.0 },
        .color = core.Nord.aurora_green,
        .border_color = core.Nord.transparent,
        .params = .{ 4.0, 0.0, 0.0, core.QUAD_MODE_CAPSULE },
    }};
    const img_90 = try headless.renderQuadsToRgba(std.testing.allocator, w, h, &q_90, black, no_round_clip, null);
    defer std.testing.allocator.free(img_90);
    // Tips along Y axis at (50, 34) and (50, 66) must be painted; horizontal tips (34, 50) and (66, 50) must be black
    try std.testing.expect(img_90[(34 * w + 50) * 4 + 1] > 150);
    try std.testing.expect(img_90[(66 * w + 50) * 4 + 1] > 150);
    try std.testing.expectEqual(@as(u8, 0), img_90[(50 * w + 34) * 4 + 1]);
    try std.testing.expectEqual(@as(u8, 0), img_90[(50 * w + 66) * 4 + 1]);

    // 40x8 horizontal capsule centered at (50, 50), rotated 45 deg (pi/4) -> diagonal (+12,+12) and (-12,-12) painted
    const q_45 = [_]core.QuadInstance{.{
        .pos_size = .{ 30.0, 46.0, 40.0, 8.0 },
        .uv_rect = .{ std.math.pi * 0.25, 0.0, 0.0, 0.0 },
        .color = core.Nord.aurora_orange,
        .border_color = core.Nord.transparent,
        .params = .{ 4.0, 0.0, 6.0, core.QUAD_MODE_CAPSULE },
    }};
    const img_45 = try headless.renderQuadsToRgba(std.testing.allocator, w, h, &q_45, black, no_round_clip, null);
    defer std.testing.allocator.free(img_45);
    // Diagonal tip (62, 62) and (38, 38) painted; opposite diagonal (62, 38) has no body (at most weak glow << body)
    try std.testing.expect(img_45[(62 * w + 62) * 4 + 0] > 180);
    try std.testing.expect(img_45[(38 * w + 38) * 4 + 0] > 180);
    try std.testing.expect(img_45[(38 * w + 62) * 4 + 0] < 30);

    // Round clip masks corners of QUAD_MODE_SURFACE outside circular watch bezel
    const q_full_surf = [_]core.QuadInstance{.{
        .pos_size = .{ 0.0, 0.0, 100.0, 100.0 },
        .uv_rect = .{ 0.2, 0.4, 0.8, 0.2 },
        .color = .{ 0.4, 0.6, 0.9, 1.0 },
        .border_color = core.Nord.transparent,
        .params = .{ 0.0, 0.0, 0.0, core.QUAD_MODE_SURFACE },
    }};
    const round_clip = [4]f32{ 50.0, 50.0, 40.0, 1.0 };
    const img_rc = try headless.renderQuadsToRgba(std.testing.allocator, w, h, &q_full_surf, black, round_clip, null);
    defer std.testing.allocator.free(img_rc);
    // Center (50, 50) lit; corner (5, 5) outside r=40 remains black
    try std.testing.expect(img_rc[(50 * w + 50) * 4 + 2] > 150);
    try std.testing.expectEqual(@as(u8, 0), img_rc[(5 * w + 5) * 4 + 2]);

    // QUAD_MODE_ARC: sweep > pi (1.5*pi) and crossing +/-pi (start = 0.75*pi, sweep = pi)
    const q_reflex = [_]core.QuadInstance{.{
        .pos_size = .{ 16.0, 16.0, 68.0, 68.0 }, // center (50,50), half=34, thick=6 -> r=31
        .uv_rect = .{ -std.math.pi * 0.5, 1.5 * std.math.pi, 0.0, 0.0 }, // 12 -> 3 -> 6 -> 9 o'clock
        .color = .{ 0.2, 0.8, 1.0, 1.0 },
        .border_color = core.Nord.transparent,
        .params = .{ 0.0, 6.0, 0.0, core.QUAD_MODE_ARC },
    }};
    const img_ref = try headless.renderQuadsToRgba(std.testing.allocator, w, h, &q_reflex, black, no_round_clip, null);
    defer std.testing.allocator.free(img_ref);
    try std.testing.expect(img_ref[(19 * w + 50) * 4 + 2] > 200); // 12 o'clock
    try std.testing.expect(img_ref[(50 * w + 81) * 4 + 2] > 200); // 3 o'clock
    try std.testing.expect(img_ref[(81 * w + 50) * 4 + 2] > 200); // 6 o'clock
    try std.testing.expect(img_ref[(50 * w + 19) * 4 + 2] > 200); // 9 o'clock
    // 10:30 (28, 28) is inside the missing top-left quadrant -> stays black
    try std.testing.expectEqual(@as(u8, 0), img_ref[(28 * w + 28) * 4 + 2]);

    const q_cross_pi = [_]core.QuadInstance{.{
        .pos_size = .{ 16.0, 16.0, 68.0, 68.0 },
        .uv_rect = .{ 0.75 * std.math.pi, std.math.pi, 0.0, 0.0 }, // 7:30 -> 9 -> 10:30 -> 1:30
        .color = .{ 0.2, 0.8, 1.0, 1.0 },
        .border_color = core.Nord.transparent,
        .params = .{ 0.0, 6.0, 0.0, core.QUAD_MODE_ARC },
    }};
    const img_pi = try headless.renderQuadsToRgba(std.testing.allocator, w, h, &q_cross_pi, black, no_round_clip, null);
    defer std.testing.allocator.free(img_pi);
    try std.testing.expect(img_pi[(50 * w + 19) * 4 + 2] > 200); // 9 o'clock (exact +/-pi seam!)
    try std.testing.expect(img_pi[(19 * w + 50) * 4 + 2] > 200); // 12 o'clock
    try std.testing.expectEqual(@as(u8, 0), img_pi[(81 * w + 50) * 4 + 2]); // 6 o'clock empty
    try std.testing.expectEqual(@as(u8, 0), img_pi[(50 * w + 81) * 4 + 2]); // 3 o'clock empty

    // QUAD_MODE_CAPSULE: negative angle (-pi/4) with bw > 0 border
    const q_neg_cap = [_]core.QuadInstance{.{
        .pos_size = .{ 30.0, 44.0, 40.0, 12.0 },
        .uv_rect = .{ -std.math.pi * 0.25, 0.0, 0.0, 0.0 }, // tilts bottom-left to top-right
        .color = .{ 1.0, 0.0, 0.0, 1.0 },
        .border_color = .{ 0.0, 1.0, 0.0, 1.0 },
        .params = .{ 6.0, 2.0, 0.0, core.QUAD_MODE_CAPSULE },
    }};
    const img_nc = try headless.renderQuadsToRgba(std.testing.allocator, w, h, &q_neg_cap, black, no_round_clip, null);
    defer std.testing.allocator.free(img_nc);
    // Center (50, 50) red fill; top-right tip (60, 40) lit; off-diagonal (60, 60) black
    try std.testing.expect(img_nc[(50 * w + 50) * 4 + 0] > 200);
    try std.testing.expect(img_nc[(40 * w + 60) * 4 + 0] > 150);
    try std.testing.expectEqual(@as(u8, 0), img_nc[(60 * w + 60) * 4 + 0]);
    // Border pixel on edge of capsule along (-6, +6) perpendicular offset from center (46, 46)
    try std.testing.expect(img_nc[(46 * w + 46) * 4 + 1] > 100);

    // round_clip masks QUAD_MODE_ARC and QUAD_MODE_CAPSULE outside circle r=35
    const rc_tight = [4]f32{ 50.0, 50.0, 35.0, 1.0 };
    const q_arc_big = [_]core.QuadInstance{.{
        .pos_size = .{ 6.0, 6.0, 88.0, 88.0 }, // r = 41 > rc_tight r=35 -> clipped!
        .uv_rect = .{ 0.0, std.math.tau, 0.0, 0.0 },
        .color = .{ 0.2, 0.8, 1.0, 1.0 },
        .border_color = core.Nord.transparent,
        .params = .{ 41.0, 6.0, 0.0, core.QUAD_MODE_ARC },
    }};
    const img_rc_arc = try headless.renderQuadsToRgba(std.testing.allocator, w, h, &q_arc_big, black, rc_tight, null);
    defer std.testing.allocator.free(img_rc_arc);
    try std.testing.expectEqual(@as(u8, 0), img_rc_arc[(50 * w + 91) * 4 + 2]);

    const q_cap_big = [_]core.QuadInstance{.{
        .pos_size = .{ 5.0, 46.0, 90.0, 8.0 }, // extends to x=95 > 50+35=85
        .uv_rect = .{ 0.0, 0.0, 0.0, 0.0 },
        .color = .{ 1.0, 1.0, 1.0, 1.0 },
        .border_color = core.Nord.transparent,
        .params = .{ 4.0, 0.0, 0.0, core.QUAD_MODE_CAPSULE },
    }};
    const img_rc_cap = try headless.renderQuadsToRgba(std.testing.allocator, w, h, &q_cap_big, black, rc_tight, null);
    defer std.testing.allocator.free(img_rc_cap);
    try std.testing.expect(img_rc_cap[(50 * w + 50) * 4 + 0] > 200);
    try std.testing.expectEqual(@as(u8, 0), img_rc_cap[(50 * w + 90) * 4 + 0]);
}
