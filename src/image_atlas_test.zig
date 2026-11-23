const std = @import("std");
const ia = @import("image_atlas.zig");

test "ImageAtlas packs RGBA8 icons, tracks memory budget, and evicts LRU entries cleanly on overflow" {
    // 128x128 RGBA8 atlas = 64 KB budget
    var atlas = try ia.ImageAtlas.init(std.testing.allocator, 128, 128);
    defer atlas.deinit();
    try std.testing.expectEqual(@as(usize, 128 * 128 * 4), atlas.memoryBytes());

    var px: [32 * 32 * 4]u8 = undefined;
    @memset(&px, 0xFF);

    const k0 = ia.IconKey{ .id_hash = 100, .size_px = 32 };
    const uv0 = try atlas.insertRgba(k0, 32, 32, &px, 1);
    try std.testing.expect(uv0[2] > uv0[0] and uv0[3] > uv0[1]);
    try std.testing.expect(atlas.dirty);
    atlas.markUploaded();

    // Cache hit returns identical UVs without marking dirty
    const uv0_hit = atlas.getUv(k0, 2).?;
    try std.testing.expectEqualSlices(f32, &uv0, &uv0_hit);
    try std.testing.expect(!atlas.dirty);

    // Insert 20 icons of 32x32 into 128x128 (fits ~9 per page with 1px pad) -> triggers LRU eviction cleanly!
    var i: u64 = 1;
    while (i <= 20) : (i += 1) {
        const k = ia.IconKey{ .id_hash = 100 + i, .size_px = 32 };
        const uv = try atlas.insertRgba(k, 32, 32, &px, 2 + i);
        try std.testing.expect(uv[2] > uv[0]);
    }
    try std.testing.expect(atlas.eviction_count > 0);
    try std.testing.expect(atlas.repack_epoch > 0);
}

test "ImageAtlas rasterizes built-in crisp DPI-independent vector icons (lock, wifi, battery, volume, search)" {
    var atlas = try ia.ImageAtlas.init(std.testing.allocator, 256, 256);
    defer atlas.deinit();

    for ([_]ia.BuiltinIcon{ .lock, .wifi, .battery, .volume, .search, .close }) |icon| {
        const uv = try atlas.getOrRasterizeIcon(icon, 24, 2.0, 1);
        try std.testing.expect(uv[2] > uv[0] and uv[3] > uv[1]);
    }
    try std.testing.expectEqual(@as(usize, 6), atlas.cachedCount());
}

test "ImageAtlas ImageTooLarge error preserves existing cached entries and state" {
    var atlas = try ia.ImageAtlas.init(std.testing.allocator, 64, 64);
    defer atlas.deinit();

    var small_px: [16 * 16 * 4]u8 = undefined;
    @memset(&small_px, 0xAB);

    const k1 = ia.IconKey{ .id_hash = 1, .size_px = 16 };
    const k2 = ia.IconKey{ .id_hash = 2, .size_px = 16 };
    const uv1 = try atlas.insertRgba(k1, 16, 16, &small_px, 1);
    const uv2 = try atlas.insertRgba(k2, 16, 16, &small_px, 1);
    atlas.markUploaded();

    const count_before = atlas.cachedCount();
    const evictions_before = atlas.eviction_count;
    const epoch_before = atlas.repack_epoch;

    // 63x16 exceeds 64 - 2 = 62 max inner width due to 1px border padding
    var too_wide: [63 * 16 * 4]u8 = undefined;
    @memset(&too_wide, 0xFF);
    const k_big = ia.IconKey{ .id_hash = 999, .size_px = 63 };
    try std.testing.expectError(error.ImageTooLarge, atlas.insertRgba(k_big, 63, 16, &too_wide, 2));

    try std.testing.expectEqual(count_before, atlas.cachedCount());
    try std.testing.expectEqual(evictions_before, atlas.eviction_count);
    try std.testing.expectEqual(epoch_before, atlas.repack_epoch);
    try std.testing.expect(!atlas.dirty);
    try std.testing.expectEqualSlices(f32, &uv1, &atlas.getUv(k1, 2).?);
    try std.testing.expectEqualSlices(f32, &uv2, &atlas.getUv(k2, 2).?);
    try std.testing.expect(atlas.getUv(k_big, 2) == null);
}

test "ImageAtlas InvalidImageData on wrong rgba.len or zero dimensions" {
    var atlas = try ia.ImageAtlas.init(std.testing.allocator, 64, 64);
    defer atlas.deinit();

    const k = ia.IconKey{ .id_hash = 42, .size_px = 8 };
    const short_buf = [_]u8{0xFF} ** (8 * 8 * 4 - 1);
    const long_buf = [_]u8{0xFF} ** (8 * 8 * 4 + 4);

    try std.testing.expectError(error.InvalidImageData, atlas.insertRgba(k, 8, 8, &short_buf, 1));
    try std.testing.expectError(error.InvalidImageData, atlas.insertRgba(k, 8, 8, &long_buf, 1));
    try std.testing.expectError(error.InvalidImageData, atlas.insertRgba(k, 0, 8, &[_]u8{}, 1));
    try std.testing.expectError(error.InvalidImageData, atlas.insertRgba(k, 8, 0, &[_]u8{}, 1));
    try std.testing.expectEqual(@as(usize, 0), atlas.cachedCount());
    try std.testing.expect(!atlas.dirty);
}

test "ImageAtlas in-place update of existing key overwrites pixels without repack" {
    var atlas = try ia.ImageAtlas.init(std.testing.allocator, 64, 64);
    defer atlas.deinit();

    var px_a: [12 * 12 * 4]u8 = undefined;
    for (0..12 * 12) |i| {
        px_a[i * 4 + 0] = 10;
        px_a[i * 4 + 1] = 20;
        px_a[i * 4 + 2] = 30;
        px_a[i * 4 + 3] = 255;
    }

    const k = ia.IconKey{ .id_hash = 77, .size_px = 12 };
    const uv_first = try atlas.insertRgba(k, 12, 12, &px_a, 1);
    atlas.markUploaded();

    const epoch_before = atlas.repack_epoch;
    const evictions_before = atlas.eviction_count;

    var px_b: [12 * 12 * 4]u8 = undefined;
    for (0..12 * 12) |i| {
        px_b[i * 4 + 0] = 200;
        px_b[i * 4 + 1] = 150;
        px_b[i * 4 + 2] = 100;
        px_b[i * 4 + 3] = 250;
    }

    const uv_second = try atlas.insertRgba(k, 12, 12, &px_b, 5);
    try std.testing.expectEqualSlices(f32, &uv_first, &uv_second);
    try std.testing.expect(atlas.dirty);
    try std.testing.expectEqual(epoch_before, atlas.repack_epoch);
    try std.testing.expectEqual(evictions_before, atlas.eviction_count);
    try std.testing.expectEqual(@as(usize, 1), atlas.cachedCount());

    // Verify atlas shadow buffer actually contains the updated RGBA pixels
    const entry = atlas.entries.get(k).?;
    try std.testing.expectEqual(@as(u64, 5), entry.last_used_frame);
    const off = (@as(usize, entry.y) * atlas.width + @as(usize, entry.x)) * 4;
    try std.testing.expectEqual(@as(u8, 200), atlas.pixels[off + 0]);
    try std.testing.expectEqual(@as(u8, 150), atlas.pixels[off + 1]);
    try std.testing.expectEqual(@as(u8, 100), atlas.pixels[off + 2]);
    try std.testing.expectEqual(@as(u8, 250), atlas.pixels[off + 3]);
}

test "ImageAtlas built-in SDF icons have non-zero pixel coverage, white RGB, and transparent 1px border" {
    var atlas = try ia.ImageAtlas.init(std.testing.allocator, 512, 512);
    defer atlas.deinit();

    const all_icons = [_]ia.BuiltinIcon{
        .lock,
        .unlock,
        .wifi,
        .battery,
        .volume,
        .bluetooth,
        .search,
        .close,
        .settings,
        .check,
    };

    for (all_icons) |icon| {
        const uv = try atlas.getOrRasterizeIcon(icon, 24, 2.0, 1);
        try std.testing.expect(uv[0] > 0.0 and uv[1] > 0.0);
        try std.testing.expect(uv[2] < 1.0 and uv[3] < 1.0);
        try std.testing.expect(uv[2] > uv[0] and uv[3] > uv[1]);

        const key = ia.builtinIconKey(icon, 48);
        const entry = atlas.entries.get(key).?;
        try std.testing.expectEqual(@as(u32, 48), entry.w);
        try std.testing.expectEqual(@as(u32, 48), entry.h);

        var non_zero_alpha: usize = 0;
        var full_alpha: usize = 0;
        var y: u32 = 0;
        while (y < entry.h) : (y += 1) {
            var x: u32 = 0;
            while (x < entry.w) : (x += 1) {
                const off = (@as(usize, entry.y + y) * atlas.width + @as(usize, entry.x + x)) * 4;
                try std.testing.expectEqual(@as(u8, 255), atlas.pixels[off + 0]);
                try std.testing.expectEqual(@as(u8, 255), atlas.pixels[off + 1]);
                try std.testing.expectEqual(@as(u8, 255), atlas.pixels[off + 2]);
                const a = atlas.pixels[off + 3];
                if (a > 0) non_zero_alpha += 1;
                if (a == 255) full_alpha += 1;
            }
        }
        try std.testing.expect(non_zero_alpha > 100);
        try std.testing.expect(full_alpha > 50);

        // 1px transparent border around icon
        var bx: u32 = entry.x - 1;
        while (bx <= entry.x + entry.w) : (bx += 1) {
            const top_off = (@as(usize, entry.y - 1) * atlas.width + bx) * 4;
            const bot_off = (@as(usize, entry.y + entry.h) * atlas.width + bx) * 4;
            try std.testing.expectEqual(@as(u8, 0), atlas.pixels[top_off + 3]);
            try std.testing.expectEqual(@as(u8, 0), atlas.pixels[bot_off + 3]);
        }
    }
    try std.testing.expectEqual(@as(usize, all_icons.len), atlas.cachedCount());
}

test "ImageAtlas init validates dimensions, memory budget, and getOrRasterizeIcon validates scale" {
    try std.testing.expectError(error.InvalidAtlasParams, ia.ImageAtlas.init(std.testing.allocator, 3, 64));
    try std.testing.expectError(error.InvalidAtlasParams, ia.ImageAtlas.init(std.testing.allocator, 64, 3));
    try std.testing.expectError(error.InvalidAtlasParams, ia.ImageAtlas.init(std.testing.allocator, 4097, 4096));
    try std.testing.expectError(error.InvalidAtlasParams, ia.ImageAtlas.init(std.testing.allocator, 100_000, 100_000));

    var atlas = try ia.ImageAtlas.init(std.testing.allocator, 64, 64);
    defer atlas.deinit();

    try std.testing.expectError(error.InvalidScale, atlas.getOrRasterizeIcon(.check, 16, 0.0, 1));
    try std.testing.expectError(error.InvalidScale, atlas.getOrRasterizeIcon(.check, 16, -1.5, 1));
    try std.testing.expectError(error.InvalidScale, atlas.getOrRasterizeIcon(.check, 16, std.math.nan(f32), 1));
    try std.testing.expectError(error.InvalidScale, atlas.getOrRasterizeIcon(.check, 16, std.math.inf(f32), 1));
}

test "ImageAtlas LRU eviction preserves recently accessed and current-frame entries with intact pixels" {
    // 66x66 atlas: each 30x30 icon needs 31px step, so 2x2 = 4 icons fit per epoch
    var atlas = try ia.ImageAtlas.init(std.testing.allocator, 66, 66);
    defer atlas.deinit();

    var px_keep: [30 * 30 * 4]u8 = undefined;
    var px_old: [30 * 30 * 4]u8 = undefined;
    @memset(&px_keep, 0xCC);
    @memset(&px_old, 0x33);

    const k_hot = ia.IconKey{ .id_hash = 10, .size_px = 30 };
    const k_old1 = ia.IconKey{ .id_hash = 11, .size_px = 30 };
    const k_old2 = ia.IconKey{ .id_hash = 12, .size_px = 30 };
    const k_old3 = ia.IconKey{ .id_hash = 13, .size_px = 30 };

    _ = try atlas.insertRgba(k_hot, 30, 30, &px_keep, 1);
    _ = try atlas.insertRgba(k_old1, 30, 30, &px_old, 2);
    _ = try atlas.insertRgba(k_old2, 30, 30, &px_old, 3);
    _ = try atlas.insertRgba(k_old3, 30, 30, &px_old, 4);

    // Touch k_hot at frame 10 so it becomes MRU (current frame)
    _ = atlas.getUv(k_hot, 10).?;

    // Insert k_new at frame 10 -> triggers eviction of oldest entries while preserving k_hot
    const k_new = ia.IconKey{ .id_hash = 14, .size_px = 30 };
    _ = try atlas.insertRgba(k_new, 30, 30, &px_old, 10);

    try std.testing.expect(atlas.getUv(k_hot, 10) != null);
    try std.testing.expect(atlas.getUv(k_new, 10) != null);
    try std.testing.expect(atlas.getUv(k_old1, 10) == null);

    // Verify k_hot pixels remained 0xCC after repack
    const hot_entry = atlas.entries.get(k_hot).?;
    const off = (@as(usize, hot_entry.y) * atlas.width + @as(usize, hot_entry.x)) * 4;
    try std.testing.expectEqual(@as(u8, 0xCC), atlas.pixels[off]);
}

test "ImageAtlas replacing sole entry with different dimensions succeeds cleanly without wedging" {
    var atlas = try ia.ImageAtlas.init(std.testing.allocator, 64, 64);
    defer atlas.deinit();

    var px40: [40 * 40 * 4]u8 = undefined;
    @memset(&px40, 0xAA);
    const k = ia.IconKey{ .id_hash = 555, .size_px = 40 };
    _ = try atlas.insertRgba(k, 40, 40, &px40, 1);

    // Replace sole entry with 32x32 (previously would have failed to fit beside 40x40 on 64x64!)
    var px32: [32 * 32 * 4]u8 = undefined;
    @memset(&px32, 0x55);
    const uv32 = try atlas.insertRgba(k, 32, 32, &px32, 2);
    try std.testing.expect(uv32[2] > uv32[0] and uv32[3] > uv32[1]);
    try std.testing.expectEqual(@as(usize, 1), atlas.cachedCount());
    try std.testing.expectEqual(@as(usize, 0), atlas.eviction_count);

    const entry = atlas.entries.get(k).?;
    try std.testing.expectEqual(@as(u32, 32), entry.w);
    try std.testing.expectEqual(@as(u32, 32), entry.h);
    const off = (@as(usize, entry.y) * atlas.width + @as(usize, entry.x)) * 4;
    try std.testing.expectEqual(@as(u8, 0x55), atlas.pixels[off]);
}

test "ImageAtlas OOM during insertRgba replacement preserves previous entry and pixels intact" {
    var backing_buf: [256 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing_buf);
    var fail_alloc = std.testing.FailingAllocator.init(fba.allocator(), .{});

    var atlas = try ia.ImageAtlas.init(fail_alloc.allocator(), 64, 64);
    defer atlas.deinit();

    var px1: [30 * 30 * 4]u8 = undefined;
    @memset(&px1, 0x11);
    var px2: [30 * 30 * 4]u8 = undefined;
    @memset(&px2, 0x22);
    var px3: [30 * 30 * 4]u8 = undefined;
    @memset(&px3, 0x33);

    const k1 = ia.IconKey{ .id_hash = 1, .size_px = 30 };
    const k2 = ia.IconKey{ .id_hash = 2, .size_px = 30 };
    const k3 = ia.IconKey{ .id_hash = 3, .size_px = 30 };
    const uv1 = try atlas.insertRgba(k1, 30, 30, &px1, 1);
    _ = try atlas.insertRgba(k2, 30, 30, &px2, 2);
    _ = try atlas.insertRgba(k3, 30, 30, &px3, 3);
    atlas.markUploaded();

    // Force OOM on the next allocation (triggered during replacement repack)
    fail_alloc.fail_index = fail_alloc.alloc_index;

    // Replacing k1 with 35x35 cannot fit alongside k2/k3 without eviction repack, which hits OOM
    var px_new: [35 * 35 * 4]u8 = undefined;
    @memset(&px_new, 0x77);
    try std.testing.expectError(error.OutOfMemory, atlas.insertRgba(k1, 35, 35, &px_new, 4));

    // Disable forced failure and verify k1, k2, k3 and k1's original pixels are 100% intact
    fail_alloc.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(usize, 3), atlas.cachedCount());
    try std.testing.expect(!atlas.dirty);
    try std.testing.expectEqualSlices(f32, &uv1, &atlas.getUv(k1, 4).?);
    const e1 = atlas.entries.get(k1).?;
    try std.testing.expectEqual(@as(u32, 30), e1.w);
    const off1 = (@as(usize, e1.y) * atlas.width + @as(usize, e1.x)) * 4;
    try std.testing.expectEqual(@as(u8, 0x11), atlas.pixels[off1]);
}

test "ImageAtlas single-frame overflow evicts oldest-sequence entries cleanly via access_seq" {
    // 66x66 atlas holds four 30x30 icons
    var atlas = try ia.ImageAtlas.init(std.testing.allocator, 66, 66);
    defer atlas.deinit();

    var px: [30 * 30 * 4]u8 = undefined;
    @memset(&px, 0xDD);

    const k1 = ia.IconKey{ .id_hash = 1001, .size_px = 30 };
    const k2 = ia.IconKey{ .id_hash = 1002, .size_px = 30 };
    const k3 = ia.IconKey{ .id_hash = 1003, .size_px = 30 };
    const k4 = ia.IconKey{ .id_hash = 1004, .size_px = 30 };
    const k5 = ia.IconKey{ .id_hash = 1005, .size_px = 30 };

    // Insert all on the exact same frame_idx = 1
    _ = try atlas.insertRgba(k1, 30, 30, &px, 1);
    _ = try atlas.insertRgba(k2, 30, 30, &px, 1);
    _ = try atlas.insertRgba(k3, 30, 30, &px, 1);
    _ = try atlas.insertRgba(k4, 30, 30, &px, 1);

    // Touch k1 on frame 1 so it has higher access_seq than k2 and k3
    _ = atlas.getUv(k1, 1).?;

    // Inserting k5 on frame 1 must evict oldest-sequence (k2, k3) and preserve k1, k4, k5
    _ = try atlas.insertRgba(k5, 30, 30, &px, 1);
    try std.testing.expect(atlas.eviction_count >= 2);
    try std.testing.expect(atlas.getUv(k1, 1) != null);
    try std.testing.expect(atlas.getUv(k4, 1) != null);
    try std.testing.expect(atlas.getUv(k5, 1) != null);
    try std.testing.expect(atlas.getUv(k2, 1) == null);
    try std.testing.expect(atlas.getUv(k3, 1) == null);
}

test "ImageAtlas getOrRasterizeIcon rejects size_logical == 0, clamps 1e35 to 256, and rasterizes at px=8" {
    var atlas = try ia.ImageAtlas.init(std.testing.allocator, 512, 512);
    defer atlas.deinit();

    try std.testing.expectError(error.InvalidImageData, atlas.getOrRasterizeIcon(.check, 0, 1.0, 1));

    // Extreme scale clamps to 256px without overflow/panic
    const uv_max = try atlas.getOrRasterizeIcon(.search, 10, 1e35, 1);
    try std.testing.expect(uv_max[2] > uv_max[0]);
    const e_max = atlas.entries.get(ia.builtinIconKey(.search, 256)).?;
    try std.testing.expectEqual(@as(u32, 256), e_max.w);

    // Smallest 8x8 rasterization works for all 10 built-in icons with non-zero alpha
    const all_icons = [_]ia.BuiltinIcon{
        .lock,
        .unlock,
        .wifi,
        .battery,
        .volume,
        .bluetooth,
        .search,
        .close,
        .settings,
        .check,
    };
    for (all_icons) |icon| {
        const uv = try atlas.getOrRasterizeIcon(icon, 4, 1.0, 2);
        try std.testing.expect(uv[2] > uv[0] and uv[3] > uv[1]);
        const e = atlas.entries.get(ia.builtinIconKey(icon, 8)).?;
        try std.testing.expectEqual(@as(u32, 8), e.w);
        var any_alpha = false;
        var y: u32 = 0;
        while (y < 8) : (y += 1) {
            var x: u32 = 0;
            while (x < 8) : (x += 1) {
                const off = (@as(usize, e.y + y) * atlas.width + @as(usize, e.x + x)) * 4;
                if (atlas.pixels[off + 3] > 0) any_alpha = true;
            }
        }
        try std.testing.expect(any_alpha);
    }
}

