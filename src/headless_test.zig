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
