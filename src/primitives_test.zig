const std = @import("std");
const prim = @import("widgets/primitives.zig");
const core = @import("core.zig");
const tokens = @import("tokens.zig");

test "Primitives: Badge, Separator, Progress, Spinner, Skeleton & Alert emit valid quads" {
    const tbl = tokens.TokenTable.nordDefault();
    var quads: [64]core.QuadInstance = undefined;
    const clip = [4]f32{ 0, 0, 800, 800 };

    const n_badge = prim.emitBadge(.{ .variant = .success }, .{ .x = 10, .y = 10, .w = 60, .h = 24 }, 2.0, &tbl, &quads, clip);
    try std.testing.expect(n_badge >= 1);

    const n_sep = prim.emitSeparator(.horizontal, .{ .x = 10, .y = 40, .w = 200, .h = 1 }, 2.0, &tbl, &quads, clip);
    try std.testing.expectEqual(@as(usize, 1), n_sep);

    const n_prog = prim.emitProgress(0.65, .{ .x = 10, .y = 50, .w = 200, .h = 8 }, 2.0, &tbl, &quads, clip);
    try std.testing.expectEqual(@as(usize, 2), n_prog);
    try std.testing.expect(quads[1].pos_size[2] > quads[0].pos_size[2] * 0.5);

    const n_spin = prim.emitSpinner(1.25, .{ .x = 100, .y = 100, .w = 32, .h = 32 }, 2.0, &tbl, &quads, clip);
    try std.testing.expect(n_spin >= 6);

    const n_skel = prim.emitSkeleton(0.5, .{ .x = 10, .y = 150, .w = 180, .h = 20 }, 2.0, &tbl, &quads, clip);
    try std.testing.expectEqual(@as(usize, 1), n_skel);

    const n_alert = prim.emitAlert(.destructive, .{ .x = 10, .y = 200, .w = 260, .h = 56 }, 2.0, &tbl, &quads, clip);
    try std.testing.expect(n_alert >= 2);
}

test "Primitives: ToastQueue auto-dismisses after TTL and drops to 0% idle" {
    var tq = prim.ToastQueue.init();
    try std.testing.expect(!tq.isAnimating());

    tq.push("Locked", .success, 3.0);
    try std.testing.expect(tq.isAnimating());
    try std.testing.expectEqual(@as(usize, 1), tq.activeCount());

    tq.step(1.5);
    try std.testing.expectEqual(@as(usize, 1), tq.activeCount());

    tq.step(2.0);
    try std.testing.expectEqual(@as(usize, 0), tq.activeCount());
    try std.testing.expect(!tq.isAnimating());
}

test "Primitives: Car/Watch SDF icon set emits crisp lock/unlock/frunk/trunk/headlights/settings" {
    var quads: [32]core.QuadInstance = undefined;
    const clip = [4]f32{ 0, 0, 466, 466 };
    const icons = [_]prim.CarIcon{ .lock, .unlock, .frunk, .trunk, .headlights, .key, .power, .settings };
    for (icons) |icon| {
        const n = prim.emitCarIcon(icon, .{ .x = 20, .y = 20, .w = 28, .h = 28 }, 2.0, core.Nord.snow_storm_2, &quads, clip);
        try std.testing.expect(n >= 2);
    }
}

test "Primitives H1/L6: ToastQueue UTF-8 codepoint-boundary truncation, FIFO eviction, top() & f64 TTL" {
    var tq = prim.ToastQueue.init();
    try std.testing.expect(tq.top() == null);

    // 63 ASCII + "€" (3 bytes = 66 bytes total) must truncate at 63 bytes without splitting "€"
    const msg_63_euro = ("a" ** 63) ++ "€";
    tq.push(msg_63_euro, .info, 10.0);
    try std.testing.expectEqual(@as(usize, 1), tq.activeCount());
    const truncated = tq.top().?.message();
    try std.testing.expectEqual(@as(usize, 63), truncated.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncated));
    try std.testing.expectEqualStrings("a" ** 63, truncated);

    // 61 ASCII + "€" + "!" (65 bytes) fits "€" completely at 64 bytes
    const msg_61_euro_bang = ("b" ** 61) ++ "€!";
    tq.push(msg_61_euro_bang, .success, 10.0);
    try std.testing.expectEqual(@as(usize, 64), tq.top().?.message().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(tq.top().?.message()));
    try std.testing.expectEqualStrings(("b" ** 61) ++ "€", tq.top().?.message());

    // 61 ASCII + 4-byte emoji (65 bytes) must not split the 4-byte codepoint
    const msg_61_emoji = ("c" ** 61) ++ "😀";
    tq.push(msg_61_emoji, .warning, 10.0);
    try std.testing.expectEqual(@as(usize, 61), tq.top().?.message().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(tq.top().?.message()));

    // FIFO eviction & top()
    tq.clear();
    tq.push("toast-1", .info, 1.0);
    tq.push("toast-2", .info, 2.0);
    tq.push("toast-3", .info, 3.0);
    tq.push("toast-4", .info, 4.0);
    try std.testing.expectEqualStrings("toast-4", tq.top().?.message());
    tq.push("toast-5", .destructive, 5.0);
    try std.testing.expectEqual(@as(usize, prim.MAX_TOASTS), tq.activeCount());
    try std.testing.expectEqualStrings("toast-5", tq.top().?.message());
    // Oldest ("toast-1", ttl=1.0) was evicted; remaining TTLs are 2, 3, 4, 5
    try std.testing.expectEqualStrings("toast-2", tq.entries[0].message());
    tq.step(2.0);
    try std.testing.expectEqual(@as(usize, 3), tq.activeCount());
    try std.testing.expectEqualStrings("toast-3", tq.entries[0].message());
    try std.testing.expectEqualStrings("toast-5", tq.top().?.message());

    // L6: f64 TTL avoids precision stall at 86400.0 with small dt
    tq.clear();
    tq.push("long-lived", .info, 86400.0);
    tq.step(0.001);
    try std.testing.expect(tq.top().?.ttl_s < 86400.0);
}

test "Primitives M2: emitProgress handles 0, 0.02 tiny capsule, NaN, and Inf" {
    const tbl = tokens.TokenTable.nordDefault();
    var quads: [8]core.QuadInstance = undefined;
    const clip = [4]f32{ 0, 0, 800, 800 };
    const rect = core.Rect{ .x = 10, .y = 20, .w = 100, .h = 8 };

    try std.testing.expectEqual(@as(usize, 1), prim.emitProgress(0.0, rect, 2.0, &tbl, &quads, clip));
    try std.testing.expectEqual(@as(usize, 1), prim.emitProgress(std.math.nan(f32), rect, 2.0, &tbl, &quads, clip));
    try std.testing.expectEqual(@as(usize, 1), prim.emitProgress(std.math.inf(f32), rect, 2.0, &tbl, &quads, clip));
    try std.testing.expectEqual(@as(usize, 1), prim.emitProgress(-std.math.inf(f32), rect, 2.0, &tbl, &quads, clip));

    const n = prim.emitProgress(0.02, rect, 2.0, &tbl, &quads, clip);
    try std.testing.expectEqual(@as(usize, 2), n);
    const track = quads[0];
    const fill = quads[1];
    // fill_w = 2.0dp (4px), fill_h = 2.0dp (4px), centered vertically inside 8dp (16px) track
    try std.testing.expectEqual(fill.pos_size[2], fill.pos_size[3]);
    try std.testing.expect(fill.pos_size[1] > track.pos_size[1]);
    try std.testing.expect(fill.pos_size[1] + fill.pos_size[3] < track.pos_size[1] + track.pos_size[3]);
    try std.testing.expectEqual(fill.pos_size[2] * 0.5, fill.params[0]);
}

test "Primitives M4: emitSkeleton handles huge finite shimmer_phase without NaN" {
    const tbl = tokens.TokenTable.nordDefault();
    var quads: [4]core.QuadInstance = undefined;
    const clip = [4]f32{ 0, 0, 800, 800 };

    for ([_]f32{ 1e38, -1e38, std.math.nan(f32), std.math.inf(f32) }) |phase| {
        const n = prim.emitSkeleton(phase, .{ .x = 0, .y = 0, .w = 120, .h = 16 }, 2.0, &tbl, &quads, clip);
        try std.testing.expectEqual(@as(usize, 1), n);
        for (quads[0].color) |c| {
            try std.testing.expect(std.math.isFinite(c));
            try std.testing.expect(c >= 0.0 and c <= 1.0);
        }
    }
}

test "Primitives M3: emitCarIcon on 1x1 and 1e-39 rects and short out_quads" {
    var quads: [32]core.QuadInstance = undefined;
    const clip = [4]f32{ -10, -10, 800, 800 };
    const icons = [_]prim.CarIcon{ .lock, .unlock, .frunk, .trunk, .headlights, .key, .power, .settings };

    for (icons) |icon| {
        const n_1x1 = prim.emitCarIcon(icon, .{ .x = 1, .y = 1, .w = 1, .h = 1 }, 2.0, core.Nord.snow_storm_2, &quads, clip);
        try std.testing.expect(n_1x1 >= 2);
        for (quads[0..n_1x1]) |q| {
            for (q.pos_size) |v| try std.testing.expect(std.math.isFinite(v));
            for (q.params) |v| try std.testing.expect(std.math.isFinite(v));
            try std.testing.expect(q.params[1] <= 0.24 * 1.0 * 2.0 + 1e-5);
        }

        const n_sub = prim.emitCarIcon(icon, .{ .x = 0, .y = 0, .w = 1e-39, .h = 1e-39 }, 2.0, core.Nord.snow_storm_2, &quads, clip);
        for (quads[0..n_sub]) |q| {
            for (q.pos_size) |v| try std.testing.expect(std.math.isFinite(v));
            for (q.params) |v| try std.testing.expect(std.math.isFinite(v));
        }
    }

    var short_quads: [1]core.QuadInstance = undefined;
    const n_short = prim.emitCarIcon(.settings, .{ .x = 10, .y = 10, .w = 24, .h = 24 }, 2.0, core.Nord.snow_storm_2, &short_quads, clip);
    try std.testing.expectEqual(@as(usize, 1), n_short);
}

test "Primitives M5/L7/L8: emitAlert on 0.5dp height, emitSpinner small rect & emitKbd" {
    const tbl = tokens.TokenTable.nordDefault();
    var quads: [16]core.QuadInstance = undefined;
    const clip = [4]f32{ 0, 0, 800, 800 };

    // M5: 0.5dp alert height must never emit a stripe taller than the container
    const n_alert_2x = prim.emitAlert(.warning, .{ .x = 10, .y = 10, .w = 100, .h = 0.5 }, 2.0, &tbl, &quads, clip);
    try std.testing.expect(n_alert_2x >= 1);
    const outer = quads[0];
    for (quads[0..n_alert_2x]) |q| {
        try std.testing.expect(q.pos_size[1] >= outer.pos_size[1]);
        try std.testing.expect(q.pos_size[1] + q.pos_size[3] <= outer.pos_size[1] + outer.pos_size[3]);
    }
    const n_alert_1x = prim.emitAlert(.info, .{ .x = 10, .y = 10, .w = 100, .h = 0.5 }, 1.0, &tbl, &quads, clip);
    try std.testing.expectEqual(@as(usize, 1), n_alert_1x);

    // L7: Spinner dot_d clamped to <= 0.35 * min_dim on tiny 4x4 rect
    const n_spin = prim.emitSpinner(0.0, .{ .x = 10, .y = 10, .w = 4, .h = 4 }, 2.0, &tbl, &quads, clip);
    try std.testing.expectEqual(@as(usize, 8), n_spin);
    for (quads[0..n_spin]) |q| {
        try std.testing.expect(q.pos_size[2] <= 4.0 * 0.35 * 2.0 + 1e-4);
        try std.testing.expect(q.pos_size[0] >= 10.0 * 2.0 - 1e-4);
        try std.testing.expect(q.pos_size[0] + q.pos_size[2] <= 14.0 * 2.0 + 1e-4);
    }

    // L8: emitKbd bevel (>4dp), flat (<=4dp), and invalid rect
    try std.testing.expectEqual(@as(usize, 2), prim.emitKbd(.{ .x = 10, .y = 10, .w = 32, .h = 20 }, 2.0, &tbl, &quads, clip));
    try std.testing.expect(quads[1].pos_size[3] < quads[0].pos_size[3]);
    try std.testing.expectEqual(@as(usize, 1), prim.emitKbd(.{ .x = 10, .y = 10, .w = 32, .h = 4 }, 2.0, &tbl, &quads, clip));
    try std.testing.expectEqual(@as(usize, 0), prim.emitKbd(.{ .x = 10, .y = 10, .w = 0, .h = 20 }, 2.0, &tbl, &quads, clip));
}
