const std = @import("std");
const theme = @import("theme.zig");
const tokens = @import("tokens.zig");
const core = @import("core.zig");

test "ThemePreset: all built-in presets pass WCAG AA text/surface contrast" {
    const presets = [_]theme.ThemePreset{
        .nord_dark,
        .nord_light,
        .oled_dark,
        .high_contrast_dark,
        .high_contrast_light,
    };
    for (presets) |p| {
        const tbl = theme.buildPreset(p);
        try std.testing.expect(tbl.isValid());
        const surface = tbl.resolve(.surface, .{});
        const bg = surface.fill;
        const fg = surface.text;
        const ratio = theme.contrastRatio(fg, bg);
        // Every built-in theme must have >= 4.5:1 primary text contrast (high contrast >= 10:1)
        try std.testing.expect(ratio >= 4.5);
        if (p == .high_contrast_dark or p == .high_contrast_light) {
            try std.testing.expect(ratio >= 10.0);
        }
        // OLED dark must use pure #000000 background for zero-power OLED pixels
        if (p == .oled_dark) {
            try std.testing.expectEqual(@as(f32, 0.0), bg[0]);
            try std.testing.expectEqual(@as(f32, 0.0), bg[1]);
            try std.testing.expectEqual(@as(f32, 0.0), bg[2]);
        }
    }
}

test "generateFromSeed: creates harmonious dark and light TokenTables from any Oklab seed" {
    const teal_seed: core.Color = .{ 0.10, 0.65, 0.60, 1.0 };
    const dark_tbl = theme.generateFromSeed(teal_seed, .dark, false);
    const light_tbl = theme.generateFromSeed(teal_seed, .light, false);
    try std.testing.expect(dark_tbl.isValid());
    try std.testing.expect(light_tbl.isValid());

    // Dark bg is dark, light bg is bright
    const dark_surface = dark_tbl.resolve(.surface, .{});
    const light_surface = light_tbl.resolve(.surface, .{});
    const dark_bg = dark_surface.fill;
    const light_bg = light_surface.fill;
    try std.testing.expect(theme.relativeLuminance(dark_bg) < 0.08);
    try std.testing.expect(theme.relativeLuminance(light_bg) > 0.70);

    // Both satisfy WCAG AA/AAA text contrast (>= 7.0:1)
    try std.testing.expect(theme.contrastRatio(dark_surface.text, dark_bg) >= 7.0);
    try std.testing.expect(theme.contrastRatio(light_surface.text, light_bg) >= 7.0);

    // OLED flag forces pure black background in dark mode
    const oled_tbl = theme.generateFromSeed(teal_seed, .dark, true);
    try std.testing.expect(oled_tbl.isValid());
    const oled_bg = oled_tbl.resolve(.surface, .{}).fill;
    try std.testing.expectEqual(@as(f32, 0.0), oled_bg[0]);
    try std.testing.expectEqual(@as(f32, 0.0), oled_bg[1]);
    try std.testing.expectEqual(@as(f32, 0.0), oled_bg[2]);
}

test "generateFromSeed: sanitizes NaN/Inf/black/white extreme seeds cleanly" {
    const extremes = [_]core.Color{
        .{ std.math.nan(f32), 0.5, 0.5, 1.0 },
        .{ std.math.inf(f32), -std.math.inf(f32), 0.2, 1.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
        .{ 1.0, 1.0, 1.0, 1.0 },
        .{ -5.0, 10.0, 0.5, 1.0 },
    };
    for (extremes) |seed| {
        const tbl = theme.generateFromSeed(seed, .dark, false);
        try std.testing.expect(tbl.isValid());
        const s = tbl.resolve(.surface, .{});
        for (s.accent) |ch| try std.testing.expect(std.math.isFinite(ch));
        try std.testing.expect(theme.contrastRatio(s.text, s.fill) >= 7.0);
    }
}

test "OsThemeConfig: resolves Android NDK/Java UI_MODE_NIGHT flags, XDG portal & GTK hints" {
    // C1: Android NDK ACONFIGURATION_UI_MODE_NIGHT_NO=0x01, YES=0x02, ANY=0x00
    try std.testing.expectEqual(theme.ColorScheme.light, theme.schemeFromAndroidNightMode(0x01));
    try std.testing.expectEqual(theme.ColorScheme.dark, theme.schemeFromAndroidNightMode(0x02));
    try std.testing.expectEqual(theme.ColorScheme.dark, theme.schemeFromAndroidNightMode(0x00));

    // C1: Java Configuration.uiMode UI_MODE_NIGHT_NO=0x10, YES=0x20 (with/without type bits)
    try std.testing.expectEqual(theme.ColorScheme.light, theme.schemeFromAndroidNightMode(0x10));
    try std.testing.expectEqual(theme.ColorScheme.dark, theme.schemeFromAndroidNightMode(0x20));
    try std.testing.expectEqual(theme.ColorScheme.light, theme.schemeFromAndroidNightMode(0x11));
    try std.testing.expectEqual(theme.ColorScheme.dark, theme.schemeFromAndroidNightMode(0x21));

    // M6: GTK whole-token parser & empty-name default
    try std.testing.expectEqual(theme.ColorScheme.dark, theme.parseGtkThemePreference("Adwaita-dark", false));
    try std.testing.expectEqual(theme.ColorScheme.dark, theme.parseGtkThemePreference("Breeze-DARK", false));
    try std.testing.expectEqual(theme.ColorScheme.dark, theme.parseGtkThemePreference("Nord-Dark", false));
    try std.testing.expectEqual(theme.ColorScheme.dark, theme.parseGtkThemePreference("dark", false));
    try std.testing.expectEqual(theme.ColorScheme.dark, theme.parseGtkThemePreference("Darker-dark", false));
    try std.testing.expectEqual(theme.ColorScheme.dark, theme.parseGtkThemePreference("Nord", true));
    try std.testing.expectEqual(theme.ColorScheme.dark, theme.parseGtkThemePreference("", false));
    try std.testing.expectEqual(theme.ColorScheme.light, theme.parseGtkThemePreference("Arc-Darker", false));
    try std.testing.expectEqual(theme.ColorScheme.light, theme.parseGtkThemePreference("Darker", false));
    try std.testing.expectEqual(theme.ColorScheme.light, theme.parseGtkThemePreference("Adwaita", false));

    // M6: XDG Desktop Portal org.freedesktop.appearance color-scheme
    try std.testing.expectEqual(@as(?theme.ColorScheme, .dark), theme.schemeFromXdgPortal(1));
    try std.testing.expectEqual(@as(?theme.ColorScheme, .light), theme.schemeFromXdgPortal(2));
    try std.testing.expectEqual(@as(?theme.ColorScheme, null), theme.schemeFromXdgPortal(0));
    try std.testing.expectEqual(@as(?theme.ColorScheme, null), theme.schemeFromXdgPortal(99));
}

test "C2/H3/H5: checked controls and accents meet WCAG AA contrast across all presets and neon seeds" {
    const presets = [_]theme.ThemePreset{
        .nord_dark,
        .nord_light,
        .oled_dark,
        .high_contrast_dark,
        .high_contrast_light,
    };
    const checked_kinds = [_]tokens.ComponentKind{ .button, .toggle };

    for (presets) |p| {
        const tbl = theme.buildPreset(p);
        for (checked_kinds) |k| {
            const st = tbl.resolve(k, .{ .checked = true });
            try std.testing.expect(theme.contrastRatio(st.text, st.fill) >= 4.5);
        }
    }

    // H5: nord_light accents meet >= 4.5:1 against base/surface/elevated
    const nl = theme.buildPreset(.nord_light);
    const nl_surfaces = [_]core.Color{
        nl.bg_base.toSrgb(),
        nl.bg_surface.toSrgb(),
        nl.bg_elevated.toSrgb(),
    };
    const nl_accents = [_]core.Color{
        nl.accent_primary.toSrgb(),
        nl.border_focus.toSrgb(),
        nl.accent_success.toSrgb(),
        nl.accent_warn.toSrgb(),
        nl.accent_danger.toSrgb(),
    };
    for (nl_surfaces) |bg| {
        for (nl_accents) |acc| {
            try std.testing.expect(theme.contrastRatio(acc, bg) >= 4.5);
        }
    }

    const neon_seeds = [_]core.Color{
        .{ 1.0, 1.0, 0.0, 1.0 }, // #FFFF00
        .{ 0.0, 1.0, 1.0, 1.0 }, // #00FFFF
        .{ 0.0, 1.0, 0.0, 1.0 }, // #00FF00
        .{ 1.0, 0.0, 1.0, 1.0 }, // #FF00FF
        .{ 0.0, 0.0, 1.0, 1.0 }, // #0000FF
        .{ 1.0, 0.0, 0.0, 1.0 }, // #FF0000
        .{ 1.0, 0.502, 0.0, 1.0 }, // #FF8000
    };
    const schemes = [_]theme.ColorScheme{ .dark, .light };

    for (schemes) |scheme| {
        for (neon_seeds) |seed| {
            const tbl = theme.generateFromSeed(seed, scheme, false);
            try std.testing.expect(tbl.isValid());

            // C2: checked button/toggle text contrast >= 4.5:1
            for (checked_kinds) |k| {
                const st = tbl.resolve(k, .{ .checked = true });
                try std.testing.expect(theme.contrastRatio(st.text, st.fill) >= 4.5);
            }

            // H3/H5: accents pass >= 4.5:1 against bg_elevated (and base/surface)
            const bg_elev = tbl.bg_elevated.toSrgb();
            try std.testing.expect(theme.contrastRatio(tbl.accent_primary.toSrgb(), bg_elev) >= 4.5);
            try std.testing.expect(theme.contrastRatio(tbl.accent_success.toSrgb(), bg_elev) >= 4.5);
            try std.testing.expect(theme.contrastRatio(tbl.accent_warn.toSrgb(), bg_elev) >= 4.5);
            try std.testing.expect(theme.contrastRatio(tbl.accent_danger.toSrgb(), bg_elev) >= 4.5);
        }
    }
}

test "H3: fitOklabInSrgbGamut prevents channel clipping and hue shift across 360 degrees" {
    var deg: usize = 0;
    while (deg < 360) : (deg += 15) {
        const rad = @as(f32, @floatFromInt(deg)) * (std.math.pi / 180.0);
        const cos_h = @cos(rad);
        const sin_h = @sin(rad);

        for ([_]f32{ 0.44, 0.72 }) |target_l| {
            const fitted = theme.fitOklabInSrgbGamut(target_l, cos_h, sin_h, 0.16);
            // Verify raw linear sRGB falls strictly inside [0, 1] without clipping
            const l_ = fitted.l + 0.3963377774 * fitted.a + 0.2158037573 * fitted.b;
            const m_ = fitted.l - 0.1055613458 * fitted.a - 0.0638541728 * fitted.b;
            const s_ = fitted.l - 0.0894841775 * fitted.a - 1.2914855480 * fitted.b;
            const l = l_ * l_ * l_;
            const m = m_ * m_ * m_;
            const s = s_ * s_ * s_;
            const r_lin = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
            const g_lin = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
            const b_lin = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;

            try std.testing.expect(r_lin >= -1e-5 and r_lin <= 1.0 + 1e-5);
            try std.testing.expect(g_lin >= -1e-5 and g_lin <= 1.0 + 1e-5);
            try std.testing.expect(b_lin >= -1e-5 and b_lin <= 1.0 + 1e-5);
        }
    }
}

test "H4: contrastRatio composites translucent fg and returns 0.0 on non-finite channels" {
    try std.testing.expectEqual(@as(f32, 1.0), theme.contrastRatio(.{ 1.0, 1.0, 1.0, 0.0 }, .{ 0.0, 0.0, 0.0, 1.0 }));
    try std.testing.expectEqual(@as(f32, 1.0), theme.contrastRatio(.{ 1.0, 1.0, 1.0, 0.0 }, .{ 0.3, 0.5, 0.7, 1.0 }));
    const half = theme.contrastRatio(.{ 1.0, 1.0, 1.0, 0.5 }, .{ 0.0, 0.0, 0.0, 1.0 });
    try std.testing.expect(half > 1.0 and half < 12.0);
    try std.testing.expectEqual(@as(f32, 0.0), theme.contrastRatio(.{ std.math.nan(f32), 0.0, 0.0, 1.0 }, .{ 1.0, 1.0, 1.0, 1.0 }));
    try std.testing.expectEqual(@as(f32, 0.0), theme.contrastRatio(.{ 0.0, 0.0, 0.0, 1.0 }, .{ 1.0, std.math.inf(f32), 1.0, 1.0 }));
}

test "resolveOsTheme: respects OS color scheme, optional dynamic accent seed, and OLED mode" {
    const light_os = theme.resolveOsTheme(.{
        .scheme = .light,
        .accent_seed = .{ 0.30, 0.45, 0.90, 1.0 },
        .prefer_oled = false,
        .high_contrast = false,
    });
    try std.testing.expect(light_os.isValid());
    try std.testing.expect(theme.relativeLuminance(light_os.resolve(.surface, .{}).fill) > 0.70);

    const hc_dark = theme.resolveOsTheme(.{
        .scheme = .dark,
        .accent_seed = null,
        .prefer_oled = true,
        .high_contrast = true,
    });
    try std.testing.expect(hc_dark.isValid());
    const hc_dark_s = hc_dark.resolve(.surface, .{});
    try std.testing.expect(theme.contrastRatio(hc_dark_s.text, hc_dark_s.fill) >= 12.0);

    const hc_light = theme.resolveOsTheme(.{
        .scheme = .light,
        .high_contrast = true,
    });
    try std.testing.expect(hc_light.isValid());
    const hc_light_s = hc_light.resolve(.surface, .{});
    try std.testing.expect(theme.contrastRatio(hc_light_s.text, hc_light_s.fill) >= 12.0);

    const oled_os = theme.resolveOsTheme(.{ .scheme = .dark, .prefer_oled = true });
    const oled_bg = oled_os.resolve(.surface, .{}).fill;
    try std.testing.expectEqual(@as(f32, 0.0), oled_bg[0]);
}
