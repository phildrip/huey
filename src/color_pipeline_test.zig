const std = @import("std");
const core = @import("core.zig");
const headless = @import("headless.zig");

test "sRGB <-> Linear color conversion round-trips accurately and blends 50% white-on-black at ~0.735 sRGB (not 0.50)" {
    const samples = [_]core.Color{
        core.Nord.polar_night_0,
        core.Nord.frost_1,
        core.Nord.aurora_red,
        core.Nord.aurora_green,
        core.Nord.snow_storm_2,
    };
    for (samples) |c| {
        const lin = core.srgbToLinearColor(c);
        const back = core.linearToSrgbColor(lin);
        for (0..4) |i| {
            try std.testing.expectApproxEqAbs(c[i], back[i], 1e-4);
        }
    }

    // 50% linear blend of white (1.0) over black (0.0) = 0.5 linear -> ~0.7353 sRGB (eliminates dark AA halos!)
    const blended = core.blendOverLinear(.{ 1.0, 1.0, 1.0, 0.5 }, .{ 0.0, 0.0, 0.0, 1.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.7353), blended[0], 0.005);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), blended[3], 0.001);
}

test "srgbToLinearColor, linearToSrgbColor, and blendOverLinear clamp NaN/Inf/negative/out-of-range safely and guard transparent-on-transparent" {
    const nan = std.math.nan(f32);
    const pos_inf = std.math.inf(f32);
    const neg_inf = -std.math.inf(f32);

    const weird_inputs = [_]core.Color{
        .{ nan, pos_inf, neg_inf, nan },
        .{ -0.5, 1.5, -10.0, 2.0 },
        .{ 0.0, 1.0, 0.04045, 0.5 },
        .{ -0.0, std.math.floatTrueMin(f32), 0.0031308, 0.04046 },
    };

    for (weird_inputs) |in_c| {
        const lin = core.srgbToLinearColor(in_c);
        const srgb = core.linearToSrgbColor(in_c);
        for (0..4) |i| {
            try std.testing.expect(std.math.isFinite(lin[i]));
            try std.testing.expect(lin[i] >= 0.0 and lin[i] <= 1.0);
            try std.testing.expect(!std.math.signbit(lin[i]));
            try std.testing.expect(std.math.isFinite(srgb[i]));
            try std.testing.expect(srgb[i] >= 0.0 and srgb[i] <= 1.0);
            try std.testing.expect(!std.math.signbit(srgb[i]));
        }
    }

    // Piecewise threshold and linear -> sRGB -> linear symmetry
    const threshold_lin = [_]core.Color{
        .{ 0.0, 0.0031308, 0.0031309, 1.0 },
        .{ 0.04045, 0.04046, 0.5, 0.25 },
    };
    for (threshold_lin) |c| {
        const srgb = core.linearToSrgbColor(c);
        const back = core.srgbToLinearColor(srgb);
        for (0..4) |i| {
            try std.testing.expectApproxEqAbs(c[i], back[i], 1e-4);
        }
    }

    // Negative and >1.0 finite inputs clamp cleanly to [0, 1]
    const clamped_srgb = core.srgbToLinearColor(.{ -0.25, 1.75, 0.5, -1.0 });
    try std.testing.expectEqual(@as(f32, 0.0), clamped_srgb[0]);
    try std.testing.expectEqual(@as(f32, 1.0), clamped_srgb[1]);
    try std.testing.expectEqual(@as(f32, 0.0), clamped_srgb[3]);

    const clamped_lin = core.linearToSrgbColor(.{ -0.25, 1.75, 0.5, 2.5 });
    try std.testing.expectEqual(@as(f32, 0.0), clamped_lin[0]);
    try std.testing.expectEqual(@as(f32, 1.0), clamped_lin[1]);
    try std.testing.expectEqual(@as(f32, 1.0), clamped_lin[3]);

    // Blend with weird inputs produces finite [0, 1] outputs
    const weird_blend = core.blendOverLinear(.{ nan, 2.0, -1.0, pos_inf }, .{ neg_inf, -0.5, 1.5, 0.5 });
    for (0..4) |i| {
        try std.testing.expect(std.math.isFinite(weird_blend[i]));
        try std.testing.expect(weird_blend[i] >= 0.0 and weird_blend[i] <= 1.0);
    }

    // Transparent-on-transparent (including sub-epsilon alpha <= 1e-6) returns {0, 0, 0, 0} without NaN
    const zero_zero = core.blendOverLinear(.{ 1.0, 0.5, 0.25, 0.0 }, .{ 0.2, 0.4, 0.6, 0.0 });
    try std.testing.expectEqual([4]f32{ 0.0, 0.0, 0.0, 0.0 }, zero_zero);

    const tiny_alpha = core.blendOverLinear(.{ 1.0, 1.0, 1.0, 1e-7 }, .{ 1.0, 0.0, 0.0, 1e-7 });
    try std.testing.expectEqual([4]f32{ 0.0, 0.0, 0.0, 0.0 }, tiny_alpha);

    // Partial destination alpha (dst_a < 1.0) and just-above-epsilon out_a
    const zero_over_half = core.blendOverLinear(.{ 0.0, 0.0, 0.0, 0.0 }, .{ 1.0, 0.5, 0.0, 0.5 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), zero_over_half[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), zero_over_half[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), zero_over_half[3], 1e-5);

    const half_over_half = core.blendOverLinear(.{ 1.0, 1.0, 1.0, 0.5 }, .{ 0.0, 0.0, 0.0, 0.5 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), half_over_half[3], 1e-5);
    // Linear RGB = (1.0 * 0.5 + 0) / 0.75 = 2/3 -> linearToSrgb(2/3) ~ 0.8358
    try std.testing.expectApproxEqAbs(@as(f32, 0.8358), half_over_half[0], 0.005);

    const just_above_eps = core.blendOverLinear(.{ 1.0, 1.0, 1.0, 2e-6 }, .{ 0.0, 0.0, 0.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), just_above_eps[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 2e-6), just_above_eps[3], 1e-7);
}

test "LayoutArena.addNode and emitQuads sanitize NaN/Inf/out-of-range node colors" {
    const nan = std.math.nan(f32);
    const pos_inf = std.math.inf(f32);
    const neg_inf = -std.math.inf(f32);

    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .zstack,
        .role = .container,
        .test_id = "root",
        .fill = .{ nan, pos_inf, -0.5, 2.0 },
        .border = .{ neg_inf, 1.5, 0.5, nan },
        .border_width = 2.0,
    });
    _ = try arena.addChild(root, .{
        .kind = .card,
        .role = .panel,
        .test_id = "child",
        .width = 40.0,
        .height = 40.0,
        .fill = .{ 1.5, -0.2, 0.5, 1.0 },
    });

    arena.layout(100.0, 100.0);
    var quads: [16]core.QuadInstance = undefined;
    const count = arena.emitQuads(&quads, 1.0);
    try std.testing.expect(count >= 2);
    for (quads[0..count]) |q| {
        for (0..4) |i| {
            try std.testing.expect(std.math.isFinite(q.color[i]));
            try std.testing.expect(q.color[i] >= 0.0 and q.color[i] <= 1.0);
            try std.testing.expect(std.math.isFinite(q.border_color[i]));
            try std.testing.expect(q.border_color[i] >= 0.0 and q.border_color[i] <= 1.0);
        }
    }
}

test "HeadlessSession.renderSnapshotRgba blends 50% white over black (~188/255), chromatic 50% red over green (~188,188,0), borders, and shadows linearly" {
    // 1. 50% white over black + chromatic 50% red over green
    {
        var session = try headless.HeadlessSession.init(std.testing.allocator, 64.0, 64.0, 1.0);
        defer session.deinit();

        const root = try session.arena.addNode(.{
            .kind = .zstack,
            .role = .container,
            .test_id = "root",
            .fill = .{ 0.0, 0.0, 0.0, 1.0 },
        });
        _ = try session.arena.addChild(root, .{
            .kind = .card,
            .role = .panel,
            .test_id = "half_white",
            .width = 32.0,
            .height = 64.0,
            .fill = .{ 1.0, 1.0, 1.0, 0.5 },
        });
        const right_bg = try session.arena.addChild(root, .{
            .kind = .zstack,
            .role = .container,
            .test_id = "green_bg",
            .width = 64.0,
            .height = 32.0,
            .fill = .{ 0.0, 1.0, 0.0, 1.0 },
        });
        _ = try session.arena.addChild(right_bg, .{
            .kind = .card,
            .role = .panel,
            .test_id = "half_red",
            .width = 64.0,
            .height = 32.0,
            .fill = .{ 1.0, 0.0, 0.0, 0.5 },
        });

        _ = session.step(16.67);
        const rgba = try session.renderSnapshotRgba(std.testing.allocator, false);
        defer std.testing.allocator.free(rgba);

        // Bottom-left (16, 48): 50% white over black -> ~188/255
        const off_wb = (48 * 64 + 16) * 4;
        for (0..3) |ch| {
            const v = rgba[off_wb + ch];
            try std.testing.expect(v >= 185 and v <= 191);
        }
        try std.testing.expectEqual(@as(u8, 255), rgba[off_wb + 3]);

        // Top-right (48, 16): 50% red over green -> ~188, 188, 0
        const off_rg = (16 * 64 + 48) * 4;
        try std.testing.expect(rgba[off_rg + 0] >= 185 and rgba[off_rg + 0] <= 191);
        try std.testing.expect(rgba[off_rg + 1] >= 185 and rgba[off_rg + 1] <= 191);
        try std.testing.expectEqual(@as(u8, 0), rgba[off_rg + 2]);
        try std.testing.expectEqual(@as(u8, 255), rgba[off_rg + 3]);
    }

    // 2. Rounded corner AA edge, border transition, and shadow over white
    {
        var session = try headless.HeadlessSession.init(std.testing.allocator, 64.0, 64.0, 1.0);
        defer session.deinit();

        const root = try session.arena.addNode(.{
            .kind = .zstack,
            .role = .container,
            .test_id = "root",
            .padding = 12.0,
            .fill = .{ 1.0, 1.0, 1.0, 1.0 },
        });
        _ = try session.arena.addChild(root, .{
            .kind = .card,
            .role = .panel,
            .test_id = "bordered_shadowed",
            .width = 40.0,
            .height = 40.0,
            .corner_radius = 10.0,
            .border_width = 2.0,
            .shadow_blur = 8.0,
            .fill = .{ 1.0, 0.0, 0.0, 1.0 },
            .border = .{ 0.0, 1.0, 0.0, 1.0 },
        });

        _ = session.step(16.67);
        const rgba = try session.renderSnapshotRgba(std.testing.allocator, false);
        defer std.testing.allocator.free(rgba);

        // Shadow pixel just below card (x=32, y=54) over white should be linear-blended (~215-245), not sRGB-crushed
        const off_sh = (54 * 64 + 32) * 4;
        try std.testing.expect(rgba[off_sh + 0] < 255 and rgba[off_sh + 0] >= 200);
        try std.testing.expectEqual(@as(u8, 255), rgba[off_sh + 3]);

        // Border pixel on straight edge (x=12, y=32): linear transition between red fill & green border
        const off_bd = (32 * 64 + 12) * 4;
        try std.testing.expect(rgba[off_bd + 1] > 100);
    }
}

test "HeadlessSession.runDiagnostics low_contrast uses linear blending on translucent fills" {
    var session = try headless.HeadlessSession.init(std.testing.allocator, 200.0, 200.0, 1.0);
    defer session.deinit();

    const root = try session.arena.addNode(.{
        .kind = .zstack,
        .role = .container,
        .test_id = "root",
        .fill = .{ 0.0, 0.0, 0.0, 1.0 },
    });
    // 50% white overlay over black renders at ~0.7353 sRGB (Oklab L ~ 0.795).
    // Text at ~0.7353 sRGB has almost zero lightness contrast against the actual rendered overlay,
    // whereas sRGB compositeOver would wrongly think bg is 0.50 sRGB (L ~ 0.598, diff ~ 0.20 < 0.25 vs 0.795).
    // Conversely, text at 0.50 sRGB (L ~ 0.598) vs 50% white-on-black:
    // linear bg L = 0.795 -> |0.598 - 0.795| = 0.197 < 0.25 -> low_contrast!
    // And text at 0.35 sRGB (L ~ 0.464): linear |0.464 - 0.795| = 0.331 >= 0.25 -> passes,
    // whereas old sRGB compositeOver had bg L=0.598 -> |0.464 - 0.598| = 0.134 < 0.25 (false positive)!
    _ = try session.arena.addChild(root, .{
        .kind = .card,
        .role = .panel,
        .test_id = "translucent_card",
        .width = 160.0,
        .height = 80.0,
        .fill = .{ 1.0, 1.0, 1.0, 0.5 },
        .text_color = .{ 0.35, 0.35, 0.35, 1.0 },
        .label = "Linear contrast",
    });

    _ = session.step(16.67);
    var diags: [16]headless.Diagnostic = undefined;
    const n = session.runDiagnostics(&diags);
    for (diags[0..n]) |d| {
        if (std.mem.eql(u8, d.test_id, "translucent_card")) {
            try std.testing.expect(d.code != .low_contrast);
        }
    }
}
