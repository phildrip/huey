const std = @import("std");
const core = @import("core.zig");
const tokens = @import("tokens.zig");

pub const ColorScheme = enum(u8) {
    dark,
    light,
};

pub const ThemePreset = enum(u8) {
    nord_dark,
    nord_light,
    oled_dark,
    high_contrast_dark,
    high_contrast_light,
};

pub const OsThemeHint = struct {
    scheme: ColorScheme = .dark,
    accent_seed: ?core.Color = null,
    prefer_oled: bool = false,
    high_contrast: bool = false,
};

fn allFiniteColor(c: core.Color) bool {
    return std.math.isFinite(c[0]) and
        std.math.isFinite(c[1]) and
        std.math.isFinite(c[2]) and
        std.math.isFinite(c[3]);
}

/// WCAG 2.1 relative luminance using IEC 61966-2-1 sRGB linearization.
pub fn relativeLuminance(c: core.Color) f32 {
    if (!allFiniteColor(c)) return 0.0;
    const lin = core.srgbToLinearColor(c);
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2];
}

/// WCAG 2.1 contrast ratio in `[1.0, 21.0]`, returning `0.0` on non-finite inputs
/// and compositing translucent `fg` over `bg` in linear space.
pub fn contrastRatio(fg: core.Color, bg: core.Color) f32 {
    if (!allFiniteColor(fg) or !allFiniteColor(bg)) return 0.0;
    const eff_fg: core.Color = if (fg[3] <= 0.0)
        bg
    else if (fg[3] < 1.0)
        core.blendOverLinear(fg, bg)
    else
        fg;
    const l_fg = relativeLuminance(eff_fg);
    const l_bg = relativeLuminance(bg);
    const lighter = @max(l_fg, l_bg);
    const darker = @min(l_fg, l_bg);
    return (lighter + 0.05) / (darker + 0.05);
}

/// Builds one of the built-in theme presets with a valid CRC32 checksum.
pub fn buildPreset(preset: ThemePreset) tokens.TokenTable {
    var t: tokens.TokenTable = switch (preset) {
        .nord_dark => tokens.TokenTable.nordDefault(),
        .nord_light => .{
            .bg_base = tokens.OklabColor.fromSrgbHex(0xECEFF4), // snow_storm_2
            .bg_surface = tokens.OklabColor.fromSrgbHex(0xE5E9F0), // snow_storm_1
            .bg_elevated = tokens.OklabColor.fromSrgbHex(0xD8DEE9), // snow_storm_0
            .border_default = tokens.OklabColor.fromSrgbHex(0xB8C2D2),
            .border_focus = fitHexAtLightness(0x5E81AC, 0.44),
            .text_primary = tokens.OklabColor.fromSrgbHex(0x2E3440), // polar_night_0
            .text_muted = tokens.OklabColor.fromSrgbHex(0x3B4252), // polar_night_1
            .accent_primary = fitHexAtLightness(0x5E81AC, 0.44),
            .accent_success = fitHexAtLightness(0x4E7A45, 0.44),
            .accent_warn = fitHexAtLightness(0x9E6B1E, 0.44),
            .accent_danger = fitHexAtLightness(0xA83E48, 0.44),
        },
        .oled_dark => .{
            .bg_base = tokens.OklabColor.fromSrgbHex(0x000000),
            .bg_surface = tokens.OklabColor.fromSrgbHex(0x141820),
            .bg_elevated = tokens.OklabColor.fromSrgbHex(0x1E2430),
            .border_default = tokens.OklabColor.fromSrgbHex(0x2E3440),
            .border_focus = tokens.OklabColor.fromSrgbHex(0x88C0D0), // frost_1
            .text_primary = tokens.OklabColor.fromSrgbHex(0xECEFF4), // snow_storm_2
            .text_muted = tokens.OklabColor.fromSrgbHex(0x9099AB),
            .accent_primary = tokens.OklabColor.fromSrgbHex(0x88C0D0), // frost_1
            .accent_success = tokens.OklabColor.fromSrgbHex(0xA3BE8C),
            .accent_warn = tokens.OklabColor.fromSrgbHex(0xEBCB8B),
            .accent_danger = tokens.OklabColor.fromSrgbHex(0xBF616A),
        },
        .high_contrast_dark => .{
            .bg_base = tokens.OklabColor.fromSrgbHex(0x000000),
            .bg_surface = tokens.OklabColor.fromSrgbHex(0x0D1117),
            .bg_elevated = tokens.OklabColor.fromSrgbHex(0x181E26),
            .border_default = tokens.OklabColor.fromSrgbHex(0xA0AEC0),
            .border_focus = tokens.OklabColor.fromSrgbHex(0x66E0FF),
            .text_primary = tokens.OklabColor.fromSrgbHex(0xFFFFFF),
            .text_muted = tokens.OklabColor.fromSrgbHex(0xCBD5E1),
            .accent_primary = tokens.OklabColor.fromSrgbHex(0x66E0FF),
            .accent_success = tokens.OklabColor.fromSrgbHex(0x6EE7B7),
            .accent_warn = tokens.OklabColor.fromSrgbHex(0xFDE047),
            .accent_danger = tokens.OklabColor.fromSrgbHex(0xFCA5A5),
        },
        .high_contrast_light => .{
            .bg_base = tokens.OklabColor.fromSrgbHex(0xFFFFFF),
            .bg_surface = tokens.OklabColor.fromSrgbHex(0xF3F5F8),
            .bg_elevated = tokens.OklabColor.fromSrgbHex(0xE6E9EF),
            .border_default = tokens.OklabColor.fromSrgbHex(0x333333),
            .border_focus = tokens.OklabColor.fromSrgbHex(0x0055AA),
            .text_primary = tokens.OklabColor.fromSrgbHex(0x000000),
            .text_muted = tokens.OklabColor.fromSrgbHex(0x2B2B2B),
            .accent_primary = tokens.OklabColor.fromSrgbHex(0x0055AA),
            .accent_success = tokens.OklabColor.fromSrgbHex(0x166534),
            .accent_warn = tokens.OklabColor.fromSrgbHex(0x854D0E),
            .accent_danger = tokens.OklabColor.fromSrgbHex(0x991B1B),
        },
    };
    t.checksum = t.computeChecksum();
    return t;
}

fn oklabToLinearRaw(l_ok: f32, a_ok: f32, b_ok: f32) [3]f32 {
    const l_ = l_ok + 0.3963377774 * a_ok + 0.2158037573 * b_ok;
    const m_ = l_ok - 0.1055613458 * a_ok - 0.0638541728 * b_ok;
    const s_ = l_ok - 0.0894841775 * a_ok - 1.2914855480 * b_ok;

    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;

    return .{
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    };
}

fn isInLinearSrgbGamut(l_ok: f32, a_ok: f32, b_ok: f32) bool {
    const lin = oklabToLinearRaw(l_ok, a_ok, b_ok);
    return std.math.isFinite(lin[0]) and lin[0] >= 0.0 and lin[0] <= 1.0 and
        std.math.isFinite(lin[1]) and lin[1] >= 0.0 and lin[1] <= 1.0 and
        std.math.isFinite(lin[2]) and lin[2] >= 0.0 and lin[2] <= 1.0;
}

/// Binary-searches Oklab chroma `c in [0, target_c]` (12 iterations) at fixed `(L, hue)`
/// so raw linear sRGB stays strictly inside `[0.0, 1.0]` with zero hue shift.
pub fn fitOklabInSrgbGamut(L: f32, cos_h: f32, sin_h: f32, target_c: f32) tokens.OklabColor {
    if (!std.math.isFinite(L) or !std.math.isFinite(cos_h) or !std.math.isFinite(sin_h) or !std.math.isFinite(target_c)) {
        return .{ .l = 0.5, .a = 0.0, .b = 0.0, .alpha = 1.0 };
    }
    const l_clamped = std.math.clamp(L, 0.0, 1.0);
    if (target_c <= 0.0) {
        return .{ .l = l_clamped, .a = 0.0, .b = 0.0, .alpha = 1.0 };
    }

    var lo: f32 = 0.0;
    var hi: f32 = target_c;
    if (isInLinearSrgbGamut(l_clamped, hi * cos_h, hi * sin_h)) {
        lo = hi;
    } else {
        for (0..12) |_| {
            const mid = 0.5 * (lo + hi);
            if (isInLinearSrgbGamut(l_clamped, mid * cos_h, mid * sin_h)) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
    }

    return .{
        .l = l_clamped,
        .a = std.math.clamp(lo * cos_h, -1.0, 1.0),
        .b = std.math.clamp(lo * sin_h, -1.0, 1.0),
        .alpha = 1.0,
    };
}

fn fitHexAtLightness(comptime rgb: u24, target_l: f32) tokens.OklabColor {
    const ok = tokens.OklabColor.fromSrgbHex(rgb);
    const c = @sqrt(ok.a * ok.a + ok.b * ok.b);
    if (c < 1e-5) {
        return .{ .l = std.math.clamp(target_l, 0.0, 1.0), .a = 0.0, .b = 0.0, .alpha = 1.0 };
    }
    return fitOklabInSrgbGamut(target_l, ok.a / c, ok.b / c, c);
}

/// Generates a perceptually uniform TokenTable in Oklab space from an arbitrary seed sRGB color.
pub fn generateFromSeed(seed: core.Color, scheme: ColorScheme, prefer_oled: bool) tokens.TokenTable {
    const frost_a: f32 = -0.04;
    const frost_b: f32 = -0.04;

    const all_finite = std.math.isFinite(seed[0]) and
        std.math.isFinite(seed[1]) and
        std.math.isFinite(seed[2]);

    var hue_a = frost_a;
    var hue_b = frost_b;
    var eff_chroma: f32 = @sqrt(frost_a * frost_a + frost_b * frost_b);

    if (all_finite) {
        const safe = core.sanitizeColor(seed);
        const ok = tokens.OklabColor.fromSrgb(safe);
        const chroma = @sqrt(ok.a * ok.a + ok.b * ok.b);
        if (std.math.isFinite(chroma) and chroma >= 0.02) {
            hue_a = ok.a;
            hue_b = ok.b;
            eff_chroma = chroma;
        }
    }

    const hue_len = @sqrt(hue_a * hue_a + hue_b * hue_b);
    const cos_h = hue_a / hue_len;
    const sin_h = hue_b / hue_len;
    const accent_chroma = std.math.clamp(eff_chroma, 0.08, 0.16);

    var t: tokens.TokenTable = switch (scheme) {
        .dark => .{
            .bg_base = if (prefer_oled)
                tokens.OklabColor.fromSrgbHex(0x000000)
            else
                fitOklabInSrgbGamut(0.22, cos_h, sin_h, 0.014),
            .bg_surface = fitOklabInSrgbGamut(if (prefer_oled) 0.18 else 0.25, cos_h, sin_h, 0.018),
            .bg_elevated = fitOklabInSrgbGamut(if (prefer_oled) 0.24 else 0.28, cos_h, sin_h, 0.022),
            .border_default = fitOklabInSrgbGamut(0.38, cos_h, sin_h, 0.025),
            .border_focus = fitOklabInSrgbGamut(0.76, cos_h, sin_h, accent_chroma),
            .text_primary = fitOklabInSrgbGamut(0.95, cos_h, sin_h, 0.006),
            .text_muted = fitOklabInSrgbGamut(0.70, cos_h, sin_h, 0.020),
            .accent_primary = fitOklabInSrgbGamut(0.72, cos_h, sin_h, accent_chroma),
            .accent_success = fitHexAtLightness(0xA3BE8C, 0.72),
            .accent_warn = fitHexAtLightness(0xEBCB8B, 0.72),
            .accent_danger = fitHexAtLightness(0xBF616A, 0.72),
        },
        .light => .{
            .bg_base = fitOklabInSrgbGamut(0.955, cos_h, sin_h, 0.008),
            .bg_surface = fitOklabInSrgbGamut(0.93, cos_h, sin_h, 0.012),
            .bg_elevated = fitOklabInSrgbGamut(0.90, cos_h, sin_h, 0.016),
            .border_default = fitOklabInSrgbGamut(0.76, cos_h, sin_h, 0.024),
            .border_focus = fitOklabInSrgbGamut(0.44, cos_h, sin_h, accent_chroma),
            .text_primary = fitOklabInSrgbGamut(0.24, cos_h, sin_h, 0.015),
            .text_muted = fitOklabInSrgbGamut(0.42, cos_h, sin_h, 0.025),
            .accent_primary = fitOklabInSrgbGamut(0.44, cos_h, sin_h, accent_chroma),
            .accent_success = fitHexAtLightness(0x4E7A45, 0.44),
            .accent_warn = fitHexAtLightness(0x9E6B1E, 0.44),
            .accent_danger = fitHexAtLightness(0xA83E48, 0.44),
        },
    };

    // Guarantee primary text meets >= 7:1 contrast against bg_base.
    if (contrastRatio(t.text_primary.toSrgb(), t.bg_base.toSrgb()) < 7.0) {
        t.text_primary = switch (scheme) {
            .dark => tokens.OklabColor.fromSrgbHex(0xFFFFFF),
            .light => tokens.OklabColor.fromSrgbHex(0x000000),
        };
    }

    t.checksum = t.computeChecksum();
    return t;
}

/// Maps Android NDK `ACONFIGURATION_UI_MODE_NIGHT_*` (`0x01` NO, `0x02` YES) and
/// Java `Configuration.UI_MODE_NIGHT_*` (`0x10` NO, `0x20` YES) flags to `ColorScheme`.
pub fn schemeFromAndroidNightMode(ui_mode_night: u32) ColorScheme {
    const java_bits = ui_mode_night & 0x30;
    if (java_bits == 0x20) return .dark;
    if (java_bits == 0x10) return .light;

    const ndk_bits = ui_mode_night & 0x03;
    if (ndk_bits == 0x02) return .dark;
    if (ndk_bits == 0x01) return .light;

    return .dark;
}

/// Maps XDG Desktop Portal `org.freedesktop.appearance` `color-scheme`
/// (`1` = dark, `2` = light, `0`/other = `null`).
pub fn schemeFromXdgPortal(color_scheme: u32) ?ColorScheme {
    return switch (color_scheme) {
        1 => .dark,
        2 => .light,
        else => null,
    };
}

/// Parses GTK theme name hints by matching `"dark"` (ASCII case-insensitive) as a whole
/// delimiter-separated token, honoring `prefer_dark_flag`, and defaulting empty names to `.dark`.
pub fn parseGtkThemePreference(theme_name: []const u8, prefer_dark_flag: bool) ColorScheme {
    if (prefer_dark_flag) return .dark;
    if (theme_name.len == 0) return .dark;

    var pos: usize = 0;
    while (pos + 4 <= theme_name.len) {
        const rel = std.ascii.indexOfIgnoreCase(theme_name[pos..], "dark") orelse break;
        const idx = pos + rel;
        const before_ok = (idx == 0) or !std.ascii.isAlphanumeric(theme_name[idx - 1]);
        const after_ok = (idx + 4 == theme_name.len) or !std.ascii.isAlphanumeric(theme_name[idx + 4]);
        if (before_ok and after_ok) return .dark;
        pos = idx + 1;
    }
    return .light;
}

/// Resolves an OS theme hint into a validated `TokenTable`.
pub fn resolveOsTheme(hint: OsThemeHint) tokens.TokenTable {
    if (hint.high_contrast) {
        return buildPreset(if (hint.scheme == .dark) .high_contrast_dark else .high_contrast_light);
    }
    if (hint.accent_seed) |seed| {
        return generateFromSeed(seed, hint.scheme, hint.prefer_oled);
    }
    return switch (hint.scheme) {
        .dark => buildPreset(if (hint.prefer_oled) .oled_dark else .nord_dark),
        .light => buildPreset(.nord_light),
    };
}
