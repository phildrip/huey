const std = @import("std");
const core = @import("core.zig");
const glyph_atlas = @import("glyph_atlas.zig");

pub const AMBIENT_FG_SDF_MODE: f32 = 0.25;

fn sanitizeFinite(v: f32) f32 {
    if (!std.math.isFinite(v)) return 0.0;
    return v;
}

fn sanitizeNonNeg(v: f32) f32 {
    if (!std.math.isFinite(v) or v < 0.0) return 0.0;
    return v;
}

fn sanitizeUnit(v: f32) f32 {
    if (!std.math.isFinite(v)) return 0.0;
    return std.math.clamp(v, 0.0, 1.0);
}

fn allFinite4(v: [4]f32) bool {
    return std.math.isFinite(v[0]) and std.math.isFinite(v[1]) and
        std.math.isFinite(v[2]) and std.math.isFinite(v[3]);
}

pub const RingPoint = struct {
    x: f32,
    y: f32,
};

pub const WearConfig = struct {
    width_dp: f32,
    height_dp: f32,
    is_round: bool,
    chin_dp: f32,
    ambient: bool = false,
    low_bit_ambient: bool = false,
    burn_in_protection: bool = false,

    /// Initializes a WearConfig while sanitizing non-finite and negative dimensions.
    pub fn init(w: f32, h: f32, is_round: bool, chin_dp: f32) WearConfig {
        const safe_w = sanitizeNonNeg(w);
        const safe_h = sanitizeNonNeg(h);
        const safe_chin = @min(sanitizeNonNeg(chin_dp), safe_h);
        return .{
            .width_dp = safe_w,
            .height_dp = safe_h,
            .is_round = is_round,
            .chin_dp = safe_chin,
        };
    }

    /// Computes the safe content rectangle (inscribed square for round displays, clamped above chin).
    pub fn safeRect(self: *const WearConfig) core.Rect {
        const w = sanitizeNonNeg(self.width_dp);
        const h = sanitizeNonNeg(self.height_dp);
        const chin = @min(sanitizeNonNeg(self.chin_dp), h);
        const usable_h = @max(0.0, h - chin);
        if (w <= 0.0 or usable_h <= 0.0) {
            return .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };
        }
        if (!self.is_round) {
            return .{ .x = 0.0, .y = 0.0, .w = w, .h = usable_h };
        }

        const diameter = @min(w, h);
        const side = diameter * std.math.sqrt1_2;
        const inset_x = (w - side) * 0.5;
        const inset_y = (h - side) * 0.5;
        const clamped_bottom = @min(inset_y + side, usable_h);
        const clamped_h = @max(0.0, clamped_bottom - inset_y);
        if (clamped_h <= 0.0) {
            return .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };
        }
        return .{
            .x = inset_x,
            .y = inset_y,
            .w = side,
            .h = clamped_h,
        };
    }

    /// Returns the outer bezel ring radius in logical dp for circular progress or RSSI gauges.
    pub fn ringRadius(self: *const WearConfig, margin_dp: f32) f32 {
        if (!std.math.isFinite(margin_dp)) return 0.0;
        const w = sanitizeNonNeg(self.width_dp);
        const h = sanitizeNonNeg(self.height_dp);
        const margin = sanitizeNonNeg(margin_dp);
        return @max(0.0, @min(w, h) * 0.5 - margin);
    }

    /// Returns the display center in logical dp.
    pub fn center(self: *const WearConfig) RingPoint {
        return .{
            .x = sanitizeNonNeg(self.width_dp) * 0.5,
            .y = sanitizeNonNeg(self.height_dp) * 0.5,
        };
    }
};

/// Computes a point on a circle at `angle_rad` (radians, standard screen coordinates).
pub fn ringPoint(cx: f32, cy: f32, radius: f32, angle_rad: f32) RingPoint {
    const safe_cx = if (std.math.isFinite(cx)) cx else 0.0;
    const safe_cy = if (std.math.isFinite(cy)) cy else 0.0;
    const safe_r = sanitizeNonNeg(radius);
    const safe_a = if (std.math.isFinite(angle_rad)) angle_rad else 0.0;
    return .{
        .x = safe_cx + safe_r * @cos(safe_a),
        .y = safe_cy + safe_r * @sin(safe_a),
    };
}

/// Emits SDF circle dots along a circular arc into `out_buf` for bezel progress/RSSI gauges.
pub fn emitArcDots(
    cx: f32,
    cy: f32,
    radius: f32,
    start_angle_rad: f32,
    sweep_angle_rad: f32,
    progress: f32,
    thickness_dp: f32,
    scale: f32,
    color: core.Color,
    out_buf: []core.QuadInstance,
) usize {
    if (out_buf.len == 0) return 0;
    if (!std.math.isFinite(cx) or !std.math.isFinite(cy)) return 0;
    if (!std.math.isFinite(start_angle_rad) or !std.math.isFinite(sweep_angle_rad)) return 0;
    if (!std.math.isFinite(scale) or scale <= 0.0) return 0;

    const safe_r = sanitizeNonNeg(radius);
    const safe_thick = sanitizeNonNeg(thickness_dp);
    const safe_prog = sanitizeUnit(progress);
    const safe_alpha = sanitizeUnit(color[3]);
    if (safe_r <= 0.0 or safe_thick <= 0.0 or safe_prog <= 0.0 or sweep_angle_rad == 0.0 or safe_alpha <= 0.0) {
        return 0;
    }

    const d_px = safe_thick * scale;
    const r_px = d_px * 0.5;
    if (!std.math.isFinite(d_px) or !std.math.isFinite(r_px)) return 0;

    const arc_len_f64 = @as(f64, safe_r) * @abs(@as(f64, sweep_angle_rad)) * @as(f64, safe_prog);
    if (!std.math.isFinite(arc_len_f64)) return 0;

    const step_f64 = @max(1.0, @as(f64, safe_thick) * 0.5);
    const raw_count_f64 = @ceil(arc_len_f64 / step_f64) + 1.0;
    const max_out_f64: f64 = @floatFromInt(out_buf.len);
    const count: usize = if (!std.math.isFinite(raw_count_f64) or raw_count_f64 >= max_out_f64)
        out_buf.len
    else
        @max(@as(usize, 1), @as(usize, @intFromFloat(raw_count_f64)));

    const is_full_circle = (@abs(@as(f64, sweep_angle_rad)) * @as(f64, safe_prog) >= std.math.tau - 1e-4) and count > 1;
    const denom_f64: f64 = if (is_full_circle)
        @floatFromInt(count)
    else if (count <= 1)
        1.0
    else
        @floatFromInt(count - 1);

    const half_thick_f64 = @as(f64, safe_thick) * 0.5;
    const cx_f64 = @as(f64, cx);
    const cy_f64 = @as(f64, cy);
    const r_f64 = @as(f64, safe_r);
    const start_f64 = @as(f64, start_angle_rad);
    const span_f64 = @as(f64, sweep_angle_rad) * @as(f64, safe_prog);
    const scale_f64 = @as(f64, scale);

    const safe_color: core.Color = .{
        sanitizeUnit(color[0]),
        sanitizeUnit(color[1]),
        sanitizeUnit(color[2]),
        safe_alpha,
    };

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const t_f64: f64 = if (count <= 1) 0.0 else @as(f64, @floatFromInt(i)) / denom_f64;
        const angle_f64 = start_f64 + span_f64 * t_f64;
        const pt_x = cx_f64 + r_f64 * @cos(angle_f64);
        const pt_y = cy_f64 + r_f64 * @sin(angle_f64);
        const px_x: f32 = @floatCast((pt_x - half_thick_f64) * scale_f64);
        const px_y: f32 = @floatCast((pt_y - half_thick_f64) * scale_f64);
        if (!std.math.isFinite(px_x) or !std.math.isFinite(px_y)) {
            return i;
        }
        out_buf[i] = .{
            .pos_size = .{ px_x, px_y, d_px, d_px },
            .color = safe_color,
            .border_color = core.Nord.transparent,
            .params = .{ r_px, 0.0, 0.0, AMBIENT_FG_SDF_MODE },
        };
    }
    return count;
}

/// Emits a 1-quad anti-aliased SDF circular arc (`QUAD_MODE_ARC`) with round caps and optional colored glow.
pub fn emitArcQuad(
    cx: f32,
    cy: f32,
    radius: f32,
    start_angle_rad: f32,
    sweep_angle_rad: f32,
    thickness_dp: f32,
    glow_blur_dp: f32,
    scale: f32,
    color: core.Color,
    clip_rect: [4]f32,
    out_quads: []core.QuadInstance,
    count: *usize,
) void {
    if (count.* >= out_quads.len) return;
    if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or
        !std.math.isFinite(radius) or !std.math.isFinite(start_angle_rad) or
        !std.math.isFinite(sweep_angle_rad) or !std.math.isFinite(thickness_dp) or
        !std.math.isFinite(glow_blur_dp) or !std.math.isFinite(scale))
    {
        return;
    }
    if (!allFinite4(clip_rect) or !(clip_rect[2] > clip_rect[0] and clip_rect[3] > clip_rect[1])) {
        return;
    }
    if (scale <= 0.0 or radius <= 0.0 or thickness_dp <= 0.0 or sweep_angle_rad <= 0.0) {
        return;
    }

    const safe_col = core.sanitizeColor(color);
    if (safe_col[3] <= 0.0) return;

    const r_px = radius * scale;
    const thick_px = thickness_dp * scale;
    const glow_px = sanitizeNonNeg(glow_blur_dp) * scale;
    const cx_px = cx * scale;
    const cy_px = cy * scale;
    const half_ext = r_px + thick_px * 0.5;
    const box_w = half_ext * 2.0;
    const box_x = cx_px - half_ext;
    const box_y = cy_px - half_ext;
    const pad = glow_px * 1.5 + 2.0;
    if (!std.math.isFinite(r_px) or !std.math.isFinite(thick_px) or
        !std.math.isFinite(glow_px) or !std.math.isFinite(half_ext) or
        !std.math.isFinite(box_x) or !std.math.isFinite(box_y) or
        !std.math.isFinite(box_w) or !std.math.isFinite(pad))
    {
        return;
    }

    if (!(box_x + box_w + pad > clip_rect[0] and box_x - pad < clip_rect[2] and
        box_y + box_w + pad > clip_rect[1] and box_y - pad < clip_rect[3]))
    {
        return;
    }

    const sweep = std.math.clamp(sweep_angle_rad, 0.0, std.math.tau);
    out_quads[count.*] = .{
        .pos_size = .{ box_x, box_y, box_w, box_w },
        .uv_rect = .{ start_angle_rad, sweep, 0.0, 0.0 },
        .color = safe_col,
        .border_color = core.Nord.transparent,
        .params = .{ r_px, thick_px, glow_px, core.QUAD_MODE_ARC },
        .clip_rect = clip_rect,
    };
    count.* += 1;
}

/// Emits rotated `QUAD_MODE_GLYPH` quads positioned tangentially along a circular bezel arc.
/// When `top_arc` is `true`, text reads left-to-right along the top rim; when `false`, reads
/// left-to-right upright along the bottom rim.
pub fn emitCurvedText(
    atlas: *glyph_atlas.GlyphAtlas,
    text: []const u8,
    cx: f32,
    cy: f32,
    radius: f32,
    center_angle_rad: f32,
    font_size: f32,
    scale: f32,
    color: core.Color,
    clip_rect: [4]f32,
    top_arc: bool,
    tracking_px: f32,
    out_quads: []core.QuadInstance,
    count: *usize,
    frame_idx: u64,
) void {
    if (text.len == 0 or count.* >= out_quads.len) return;
    if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or
        !std.math.isFinite(radius) or !std.math.isFinite(center_angle_rad) or
        !std.math.isFinite(font_size) or !std.math.isFinite(scale) or
        !std.math.isFinite(tracking_px))
    {
        return;
    }
    if (!allFinite4(clip_rect) or !(clip_rect[2] > clip_rect[0] and clip_rect[3] > clip_rect[1])) {
        return;
    }
    if (radius <= 0.0 or font_size <= 0.0 or scale <= 0.0) return;

    const safe_col = core.sanitizeColor(color);
    if (safe_col[3] <= 0.0) return;

    const r_px = radius * scale;
    const cx_px = cx * scale;
    const cy_px = cy * scale;
    if (!std.math.isFinite(r_px) or r_px <= 0.0 or
        !std.math.isFinite(cx_px) or !std.math.isFinite(cy_px))
    {
        return;
    }

    const vm = atlas.vMetricsPx(font_size, scale);
    const cap_mid_from_baseline = -(vm.ascent + vm.descent) * 0.5;

    var total_w_px: f32 = 0.0;
    var prev_cp_m: ?u21 = null;
    var idx_m: usize = 0;
    while (idx_m < text.len) {
        const cp = glyph_atlas.GlyphAtlas.decodeNextCodepoint(text, &idx_m);
        if (prev_cp_m) |p| {
            total_w_px += atlas.kernAdvancePx(p, cp, vm.stb_scale);
        }
        total_w_px += atlas.codepointAdvancePx(cp, vm.stb_scale);
        if (idx_m < text.len) {
            total_w_px += tracking_px;
        }
        prev_cp_m = cp;
    }
    if (!std.math.isFinite(total_w_px) or total_w_px <= 0.0) return;

    const total_arc = total_w_px / r_px;
    const start_theta = if (top_arc)
        center_angle_rad - total_arc * 0.5
    else
        center_angle_rad + total_arc * 0.5;

    const start_count = count.*;
    var epoch_before = atlas.repack_epoch;
    var retried = false;

    while (true) {
        count.* = start_count;
        var pen_x_px: f32 = 0.0;
        var prev_cp: ?u21 = null;
        var idx: usize = 0;
        while (idx < text.len and count.* < out_quads.len) {
            const cp = glyph_atlas.GlyphAtlas.decodeNextCodepoint(text, &idx);
            if (prev_cp) |p| {
                pen_x_px += atlas.kernAdvancePx(p, cp, vm.stb_scale);
            }

            const g = atlas.getOrRasterize(cp, font_size, scale, frame_idx) catch {
                pen_x_px += atlas.codepointAdvancePx(cp, vm.stb_scale);
                if (idx < text.len) pen_x_px += tracking_px;
                prev_cp = cp;
                continue;
            };

            if (g.w > 0.0 and g.h > 0.0) {
                const glyph_arc_pos = pen_x_px + g.x_off + g.w * 0.5;
                const theta = if (top_arc)
                    start_theta + glyph_arc_pos / r_px
                else
                    start_theta - glyph_arc_pos / r_px;
                const dy_from_mid = (g.y_off + g.h * 0.5) - cap_mid_from_baseline;
                const eff_r = if (top_arc) r_px - dy_from_mid else r_px + dy_from_mid;
                const raw_angle = if (top_arc) theta + std.math.pi * 0.5 else theta - std.math.pi * 0.5;
                const angle_rad = std.math.atan2(@sin(raw_angle), @cos(raw_angle));

                const gx_center = cx_px + eff_r * @cos(theta);
                const gy_center = cy_px + eff_r * @sin(theta);

                const cg = @cos(angle_rad);
                const sg = @sin(angle_rad);
                const hx = g.w * 0.5;
                const hy = g.h * 0.5;
                const rot_hx = @abs(cg) * hx + @abs(sg) * hy + 1.0;
                const rot_hy = @abs(sg) * hx + @abs(cg) * hy + 1.0;

                if (gx_center + rot_hx > clip_rect[0] and gx_center - rot_hx < clip_rect[2] and
                    gy_center + rot_hy > clip_rect[1] and gy_center - rot_hy < clip_rect[3])
                {
                    out_quads[count.*] = .{
                        .pos_size = .{ gx_center - hx, gy_center - hy, g.w, g.h },
                        .uv_rect = .{ g.u0, g.v0, g.u1, g.v1 },
                        .color = safe_col,
                        .border_color = core.Nord.transparent,
                        .params = .{ angle_rad, 0.0, 0.0, core.QUAD_MODE_GLYPH },
                        .clip_rect = clip_rect,
                    };
                    count.* += 1;
                }
            }

            pen_x_px += g.advance;
            if (idx < text.len) {
                pen_x_px += tracking_px;
            }
            prev_cp = cp;
        }
        if (!retried and atlas.repack_epoch != epoch_before) {
            retried = true;
            epoch_before = atlas.repack_epoch;
            continue;
        }
        break;
    }
}

pub const CurvedMetrics = struct {
    scale: f32,
    alpha: f32,
    chord_width: f32,
};

/// Computes Wear OS circular pole scaling, alpha fade, and horizontal chord width for a vertical position.
pub fn curvedScrollMetrics(card_cy: f32, vp_cy: f32, radius: f32) CurvedMetrics {
    if (!std.math.isFinite(card_cy) or !std.math.isFinite(vp_cy) or !std.math.isFinite(radius) or radius <= 0.0) {
        return .{ .scale = 1.0, .alpha = 1.0, .chord_width = 0.0 };
    }
    const dy_f64: f64 = @abs(@as(f64, card_cy) - @as(f64, vp_cy));
    const r_f64: f64 = @as(f64, radius);
    const norm_f64: f64 = std.math.clamp(dy_f64 / r_f64, 0.0, 1.0);
    const chord_f64: f64 = 2.0 * r_f64 * @sqrt(@max(0.0, 1.0 - norm_f64 * norm_f64));
    const max_f32: f64 = @as(f64, std.math.floatMax(f32));
    const chord_width: f32 = @floatCast(std.math.clamp(chord_f64, 0.0, max_f32));
    const norm: f32 = @floatCast(norm_f64);
    const scale: f32 = 1.0 - 0.22 * (norm * norm);
    const alpha: f32 = 1.0 - 0.55 * (norm * norm * norm);
    return .{
        .scale = scale,
        .alpha = alpha,
        .chord_width = chord_width,
    };
}

fn applyCurvedQuadWithClipRadius(
    q: *core.QuadInstance,
    group_cy_px: f32,
    vp_cx_px: f32,
    clip_radius_px: f32,
    m: CurvedMetrics,
) void {
    if (!std.math.isFinite(group_cy_px) or !std.math.isFinite(vp_cx_px)) return;
    if (!std.math.isFinite(m.scale) or m.scale <= 0.0) return;

    const x = q.pos_size[0];
    const y = q.pos_size[1];
    const w = q.pos_size[2];
    const h = q.pos_size[3];
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        !std.math.isFinite(w) or !std.math.isFinite(h))
    {
        return;
    }
    if (w <= 0.0 or h <= 0.0) return;

    const s: f64 = @as(f64, m.scale);
    const max_f32: f64 = @as(f64, std.math.floatMax(f32));
    const new_x_f64 = @as(f64, vp_cx_px) + (@as(f64, x) - @as(f64, vp_cx_px)) * s;
    const new_y_f64 = @as(f64, group_cy_px) + (@as(f64, y) - @as(f64, group_cy_px)) * s;
    const new_w_f64 = @as(f64, w) * s;
    const new_h_f64 = @as(f64, h) * s;
    if (!std.math.isFinite(new_x_f64) or !std.math.isFinite(new_y_f64) or
        !std.math.isFinite(new_w_f64) or !std.math.isFinite(new_h_f64))
    {
        return;
    }

    q.pos_size[0] = @floatCast(std.math.clamp(new_x_f64, -max_f32, max_f32));
    q.pos_size[1] = @floatCast(std.math.clamp(new_y_f64, -max_f32, max_f32));
    q.pos_size[2] = @floatCast(std.math.clamp(new_w_f64, 0.0, max_f32));
    q.pos_size[3] = @floatCast(std.math.clamp(new_h_f64, 0.0, max_f32));

    const mode = if (std.math.isFinite(q.params[3])) q.params[3] else core.QUAD_MODE_RECT;
    if (mode < 0.5 or mode >= 1.5) {
        q.params[0] = @floatCast(std.math.clamp(@as(f64, sanitizeNonNeg(q.params[0])) * s, 0.0, max_f32));
        q.params[1] = @floatCast(std.math.clamp(@as(f64, sanitizeNonNeg(q.params[1])) * s, 0.0, max_f32));
        q.params[2] = @floatCast(std.math.clamp(@as(f64, sanitizeNonNeg(q.params[2])) * s, 0.0, max_f32));
    }

    const safe_alpha = sanitizeUnit(m.alpha);
    q.color[3] = sanitizeUnit(q.color[3]) * safe_alpha;
    q.border_color[3] = sanitizeUnit(q.border_color[3]) * safe_alpha;

    if (std.math.isFinite(clip_radius_px) and clip_radius_px > 0.0 and
        std.math.isFinite(q.clip_rect[0]) and std.math.isFinite(q.clip_rect[1]) and
        std.math.isFinite(q.clip_rect[2]) and std.math.isFinite(q.clip_rect[3]))
    {
        const clip_w_f64: f64 = @as(f64, q.clip_rect[2]) - @as(f64, q.clip_rect[0]);
        const clip_h_f64: f64 = @as(f64, q.clip_rect[3]) - @as(f64, q.clip_rect[1]);
        const thresh_f64: f64 = @as(f64, clip_radius_px) * 1.95;
        if (clip_w_f64 < thresh_f64 or clip_h_f64 < thresh_f64) {
            const c0 = @as(f64, vp_cx_px) + (@as(f64, q.clip_rect[0]) - @as(f64, vp_cx_px)) * s;
            const c1 = @as(f64, group_cy_px) + (@as(f64, q.clip_rect[1]) - @as(f64, group_cy_px)) * s;
            const c2 = @as(f64, vp_cx_px) + (@as(f64, q.clip_rect[2]) - @as(f64, vp_cx_px)) * s;
            const c3 = @as(f64, group_cy_px) + (@as(f64, q.clip_rect[3]) - @as(f64, group_cy_px)) * s;
            if (std.math.isFinite(c0) and std.math.isFinite(c1) and
                std.math.isFinite(c2) and std.math.isFinite(c3))
            {
                q.clip_rect[0] = @floatCast(std.math.clamp(c0, -max_f32, max_f32));
                q.clip_rect[1] = @floatCast(std.math.clamp(c1, -max_f32, max_f32));
                q.clip_rect[2] = @floatCast(std.math.clamp(c2, -max_f32, max_f32));
                q.clip_rect[3] = @floatCast(std.math.clamp(c3, -max_f32, max_f32));
            }
        }
    }
}

/// Rigidly scales and fades a single quad around `(vp_cx_px, group_cy_px)` using precomputed `CurvedMetrics`.
pub fn applyCurvedQuadWithMetrics(
    q: *core.QuadInstance,
    group_cy_px: f32,
    vp_cx_px: f32,
    m: CurvedMetrics,
) void {
    applyCurvedQuadWithClipRadius(q, group_cy_px, vp_cx_px, vp_cx_px, m);
}

/// Rigidly scales and fades all non-background quads in a group around `(vp_cx_px, group_cy_px)`.
pub fn applyCurvedGroupTransform(
    quads: []core.QuadInstance,
    group_cy_px: f32,
    vp_cx_px: f32,
    vp_cy_px: f32,
    radius_px: f32,
) void {
    if (!std.math.isFinite(group_cy_px) or !std.math.isFinite(vp_cx_px) or
        !std.math.isFinite(vp_cy_px) or !std.math.isFinite(radius_px) or radius_px <= 0.0)
    {
        return;
    }
    const m = curvedScrollMetrics(group_cy_px, vp_cy_px, radius_px);
    const bg_thresh_f64: f64 = @as(f64, radius_px) * 1.95;
    for (quads) |*q| {
        const w = q.pos_size[2];
        const h = q.pos_size[3];
        if (!std.math.isFinite(w) or !std.math.isFinite(h) or w <= 0.0 or h <= 0.0) {
            continue;
        }
        if (@as(f64, w) >= bg_thresh_f64 and @as(f64, h) >= bg_thresh_f64) {
            continue;
        }
        applyCurvedQuadWithClipRadius(q, group_cy_px, vp_cx_px, radius_px, m);
    }
}

/// Scales and fades emitted quads toward the viewport horizontal center as they scroll into circular poles.
pub fn applyCurvedEdgeTransform(quads: []core.QuadInstance, vp_cx_px: f32, vp_cy_px: f32, radius_px: f32) void {
    if (!std.math.isFinite(vp_cx_px) or !std.math.isFinite(vp_cy_px) or !std.math.isFinite(radius_px) or radius_px <= 0.0) {
        return;
    }
    const bg_thresh_f64: f64 = @as(f64, radius_px) * 1.95;
    const max_f32: f64 = @as(f64, std.math.floatMax(f32));
    for (quads) |*q| {
        const x = q.pos_size[0];
        const y = q.pos_size[1];
        const w = q.pos_size[2];
        const h = q.pos_size[3];
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(w) or !std.math.isFinite(h)) {
            continue;
        }
        if (w <= 0.0 or h <= 0.0) continue;
        if (@as(f64, w) >= bg_thresh_f64 and @as(f64, h) >= bg_thresh_f64) {
            continue;
        }

        const q_cy_f64: f64 = @as(f64, y) + @as(f64, h) * 0.5;
        if (!std.math.isFinite(q_cy_f64) or @abs(q_cy_f64) > max_f32) continue;
        const q_cy: f32 = @floatCast(q_cy_f64);

        const m = curvedScrollMetrics(q_cy, vp_cy_px, radius_px);
        applyCurvedQuadWithClipRadius(q, q_cy, vp_cx_px, radius_px, m);
    }
}

/// Computes a centered rectangle at `angle_deg` clockwise from 12 o'clock along `orbit_radius`.
pub fn radialPosition(cx: f32, cy: f32, orbit_radius: f32, angle_deg: f32, item_w: f32, item_h: f32) core.Rect {
    if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or
        !std.math.isFinite(orbit_radius) or !std.math.isFinite(angle_deg) or
        !std.math.isFinite(item_w) or !std.math.isFinite(item_h))
    {
        return .{};
    }
    const safe_r = sanitizeNonNeg(orbit_radius);
    const safe_w = sanitizeNonNeg(item_w);
    const safe_h = sanitizeNonNeg(item_h);
    const rad: f64 = @as(f64, angle_deg) * (std.math.pi / 180.0);
    const px = @as(f64, cx) + @as(f64, safe_r) * @sin(rad) - @as(f64, safe_w) * 0.5;
    const py = @as(f64, cy) - @as(f64, safe_r) * @cos(rad) - @as(f64, safe_h) * 0.5;
    if (!std.math.isFinite(px) or !std.math.isFinite(py)) return .{};
    const max_f32: f64 = @as(f64, std.math.floatMax(f32));
    if (@abs(px) > max_f32 or @abs(py) > max_f32) return .{};
    return .{
        .x = @floatCast(px),
        .y = @floatCast(py),
        .w = safe_w,
        .h = safe_h,
    };
}

/// CPU mirror of the GPU circular SDF clip coverage (`1.0 - smoothstep(-0.5, 0.5, d)`).
pub fn roundClipAlpha(px: f32, py: f32, cx: f32, cy: f32, radius: f32) f32 {
    if (!std.math.isFinite(px) or !std.math.isFinite(py) or
        !std.math.isFinite(cx) or !std.math.isFinite(cy) or
        !std.math.isFinite(radius) or radius <= 0.0)
    {
        return 0.0;
    }
    const dx: f64 = @as(f64, px) - @as(f64, cx);
    const dy: f64 = @as(f64, py) - @as(f64, cy);
    const d: f64 = std.math.hypot(dx, dy) - @as(f64, radius);
    const t: f64 = std.math.clamp(d + 0.5, 0.0, 1.0);
    const smooth: f64 = t * t * (3.0 - 2.0 * t);
    return @floatCast(1.0 - smooth);
}

/// Emits a curved scroll-track arc (9 track dots + 3 highlighted thumb dots) along the right bezel (65..115 deg).
pub fn emitCurvedScrollArc(
    out_quads: []core.QuadInstance,
    cx: f32,
    cy: f32,
    radius: f32,
    progress: f32,
    thickness: f32,
    accent: core.Color,
    clip_rect: [4]f32,
) usize {
    if (out_quads.len == 0) return 0;
    if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or
        !std.math.isFinite(radius) or radius <= 0.0 or
        !std.math.isFinite(thickness) or thickness <= 0.0)
    {
        return 0;
    }
    for (clip_rect) |v| {
        if (!std.math.isFinite(v)) return 0;
    }

    const TRACK_COUNT: usize = 9;
    const THUMB_COUNT: usize = 3;
    const START_DEG: f32 = 65.0;
    const END_DEG: f32 = 115.0;
    const THUMB_STEP_DEG: f32 = 4.0;

    const safe_prog = sanitizeUnit(progress);
    const safe_accent = core.sanitizeColor(accent);
    const track_col: core.Color = .{
        core.Nord.polar_night_3[0],
        core.Nord.polar_night_3[1],
        core.Nord.polar_night_3[2],
        0.70,
    };

    const track_d: f32 = @min(thickness, @max(1.0, thickness * 0.65));
    const track_r: f32 = track_d * 0.5;
    var written: usize = 0;

    for (0..TRACK_COUNT) |i| {
        if (written >= out_quads.len) return written;
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(TRACK_COUNT - 1));
        const angle_deg = START_DEG + t * (END_DEG - START_DEG);
        const rect = radialPosition(cx, cy, radius, angle_deg, track_d, track_d);
        if (rect.w <= 0.0 or rect.h <= 0.0) continue;
        out_quads[written] = .{
            .pos_size = .{ rect.x, rect.y, rect.w, rect.h },
            .color = track_col,
            .border_color = core.Nord.transparent,
            .params = .{ track_r, 0.0, 0.0, AMBIENT_FG_SDF_MODE },
            .clip_rect = clip_rect,
        };
        written += 1;
    }

    const thumb_center_deg = (START_DEG + THUMB_STEP_DEG) +
        safe_prog * ((END_DEG - START_DEG) - 2.0 * THUMB_STEP_DEG);
    const thumb_d: f32 = thickness;
    const thumb_r: f32 = thumb_d * 0.5;
    for (0..THUMB_COUNT) |i| {
        if (written >= out_quads.len) return written;
        const offset: f32 = @as(f32, @floatFromInt(i)) - 1.0;
        const angle_deg = thumb_center_deg + offset * THUMB_STEP_DEG;
        const rect = radialPosition(cx, cy, radius, angle_deg, thumb_d, thumb_d);
        if (rect.w <= 0.0 or rect.h <= 0.0) continue;
        out_quads[written] = .{
            .pos_size = .{ rect.x, rect.y, rect.w, rect.h },
            .color = safe_accent,
            .border_color = core.Nord.transparent,
            .params = .{ thumb_r, 0.0, 0.0, AMBIENT_FG_SDF_MODE },
            .clip_rect = clip_rect,
        };
        written += 1;
    }

    return written;
}

pub const RotaryDelta = struct {
    scroll_dy: f32,
    detent_steps: i32,
};

pub const WearRotaryAdapter = struct {
    dp_per_detent: f32,
    accum: f32 = 0.0,

    const DEFAULT_DP_PER_DETENT: f32 = 36.0;

    /// Initializes the rotary crown adapter, sanitizing dp_per_detent (> 0, finite; fallback 36.0).
    pub fn init(dp_per_detent: f32) WearRotaryAdapter {
        const safe_dp = if (std.math.isFinite(dp_per_detent) and dp_per_detent > 0.0)
            dp_per_detent
        else
            DEFAULT_DP_PER_DETENT;
        return .{
            .dp_per_detent = safe_dp,
            .accum = 0.0,
        };
    }

    /// Maps Android AXIS_SCROLL (negative = clockwise down -> positive scroll_dy) and extracts discrete detent steps.
    pub fn onRotaryDelta(self: *WearRotaryAdapter, axis_scroll: f32) RotaryDelta {
        if (!std.math.isFinite(axis_scroll)) {
            return .{ .scroll_dy = 0.0, .detent_steps = 0 };
        }
        const safe_dp = if (std.math.isFinite(self.dp_per_detent) and self.dp_per_detent > 0.0)
            self.dp_per_detent
        else
            DEFAULT_DP_PER_DETENT;
        if (!std.math.isFinite(self.accum)) {
            self.accum = 0.0;
        }

        const detents_f64: f64 = -@as(f64, axis_scroll);
        const raw_scroll_dy: f64 = detents_f64 * @as(f64, safe_dp);
        const f32_max_f64: f64 = @as(f64, std.math.floatMax(f32));
        const scroll_dy: f32 = @floatCast(std.math.clamp(raw_scroll_dy, -f32_max_f64, f32_max_f64));

        const next_accum: f64 = @as(f64, self.accum) + detents_f64;
        const whole_f: f64 = @trunc(next_accum);
        const min_i32_f: f64 = @floatFromInt(std.math.minInt(i32));
        const max_i32_f: f64 = @floatFromInt(std.math.maxInt(i32));
        if (!std.math.isFinite(whole_f) or whole_f < min_i32_f or whole_f > max_i32_f) {
            self.accum = 0.0;
            const clamped: i32 = if (whole_f < 0.0) std.math.minInt(i32) else std.math.maxInt(i32);
            return .{ .scroll_dy = scroll_dy, .detent_steps = clamped };
        }

        const steps: i32 = @intFromFloat(whole_f);
        self.accum = @floatCast(next_accum - whole_f);
        return .{
            .scroll_dy = scroll_dy,
            .detent_steps = steps,
        };
    }

    /// Clears accumulated sub-detent rotation.
    pub fn reset(self: *WearRotaryAdapter) void {
        self.accum = 0.0;
    }
};

/// Transforms a color for OLED ambient mode (pure black backgrounds, Oklab grayscale foregrounds).
pub fn ambientTransformColor(c: core.Color, is_background: bool, low_bit: bool) core.Color {
    const alpha = sanitizeUnit(c[3]);
    if (is_background) {
        return .{ 0.0, 0.0, 0.0, alpha };
    }
    const l = core.srgbToOklabL(c);
    const mono = if (low_bit)
        (if (l >= 0.25) @as(f32, 0.85) else @as(f32, 0.0))
    else
        l;
    return .{ mono, mono, mono, alpha };
}

fn ambientVisibleFg(c: core.Color, low_bit: bool) core.Color {
    var out = ambientTransformColor(c, false, low_bit);
    if (out[0] == 0.0 and out[1] == 0.0 and out[2] == 0.0 and out[3] > 0.0) {
        const fallback: f32 = if (low_bit) 0.85 else 0.5;
        out[0] = fallback;
        out[1] = fallback;
        out[2] = fallback;
    }
    return out;
}

fn isForegroundSdfIndicator(q: *const core.QuadInstance) bool {
    const mode = q.params[3];
    if (std.math.isFinite(mode) and mode > 0.1 and mode <= 0.5) {
        return true;
    }
    const w = q.pos_size[2];
    const h = q.pos_size[3];
    if (!std.math.isFinite(w) or !std.math.isFinite(h) or w <= 0.0 or h <= 0.0) {
        return false;
    }
    const max_dim = @max(w, h);
    const min_dim = @min(w, h);
    return max_dim <= 32.0 and q.params[0] >= min_dim * 0.45 and q.params[1] <= 0.05;
}

/// In-place zero-alloc pass converting an emitted QuadInstance buffer for Wear OS ambient mode.
pub fn transformQuadsForAmbient(quads: []core.QuadInstance, low_bit: bool) void {
    for (quads) |*q| {
        const mode = if (std.math.isFinite(q.params[3])) q.params[3] else core.QUAD_MODE_RECT;
        q.params[2] = 0.0; // Strip shadow/glow blur for OLED power & burn-in protection

        if (mode >= 0.5 and mode < 1.5) {
            // QUAD_MODE_GLYPH: preserve signed rotation angle in params[0]
            q.params[0] = sanitizeFinite(q.params[0]);
            q.params[1] = sanitizeNonNeg(q.params[1]);
            q.color = ambientVisibleFg(q.color, low_bit);
            continue;
        }

        q.params[0] = sanitizeNonNeg(q.params[0]);
        q.params[1] = sanitizeNonNeg(q.params[1]);

        const orig_fill = q.color;
        const has_fill = std.math.isFinite(orig_fill[3]) and orig_fill[3] > 0.0;
        const has_border = std.math.isFinite(q.border_color[3]) and q.border_color[3] > 0.0;

        if (mode >= 1.5 and mode < 2.5) {
            // QUAD_MODE_ARC: preserve visible outline stroke in ambient
            q.color = if (has_fill) ambientVisibleFg(orig_fill, low_bit) else core.Nord.transparent;
            q.border_color = core.Nord.transparent;
            continue;
        }

        if (mode >= 3.5) {
            // QUAD_MODE_CAPSULE: preserve foreground stroke in ambient
            q.uv_rect[0] = sanitizeFinite(q.uv_rect[0]);
            q.color = if (has_fill) ambientVisibleFg(orig_fill, low_bit) else core.Nord.transparent;
            if (has_border) {
                q.border_color = ambientVisibleFg(q.border_color, low_bit);
                if (q.params[1] > 1.0) {
                    q.params[1] = 1.0;
                }
            } else {
                q.border_color = core.Nord.transparent;
            }
            continue;
        }

        if (mode >= 2.5 and mode < 3.5) {
            // QUAD_MODE_SURFACE: strip gradient/specular rim, blacken fill + 1px outline
            q.uv_rect = .{ 0.0, 0.0, 0.0, 0.0 };
            if (has_fill) {
                q.color = ambientTransformColor(orig_fill, true, low_bit);
                q.params[1] = 1.0;
                const outline_src = if (has_border) q.border_color else orig_fill;
                var outline = ambientVisibleFg(outline_src, low_bit);
                if (!has_border) {
                    outline[3] = sanitizeUnit(orig_fill[3]);
                }
                q.border_color = outline;
            } else {
                q.color = core.Nord.transparent;
                if (has_border) {
                    q.border_color = ambientVisibleFg(q.border_color, low_bit);
                    if (q.params[1] > 1.0) {
                        q.params[1] = 1.0;
                    }
                } else {
                    q.border_color = core.Nord.transparent;
                }
            }
            continue;
        }

        if (isForegroundSdfIndicator(q)) {
            if (has_fill) {
                q.color = ambientVisibleFg(orig_fill, low_bit);
            } else {
                q.color = .{ 0.0, 0.0, 0.0, 0.0 };
            }
            if (has_border) {
                q.border_color = ambientVisibleFg(q.border_color, low_bit);
                if (q.params[1] > 1.0) {
                    q.params[1] = 1.0;
                }
            }
            continue;
        }

        if (has_fill) {
            q.color = ambientTransformColor(orig_fill, true, low_bit);
            q.params[1] = 1.0; // Crisp 1px outline
            const outline_src = if (has_border) q.border_color else orig_fill;
            var outline = ambientVisibleFg(outline_src, low_bit);
            if (!has_border) {
                outline[3] = sanitizeUnit(orig_fill[3]);
            }
            q.border_color = outline;
        } else {
            q.color = .{ 0.0, 0.0, 0.0, 0.0 };
            if (has_border) {
                q.border_color = ambientVisibleFg(q.border_color, low_bit);
                if (q.params[1] > 1.0) {
                    q.params[1] = 1.0;
                }
            }
        }
    }
}

pub const SurfaceHostState = enum {
    detached,
    attached,
    ambient,
    paused,
};

/// Pure state machine tracking a Wear OS SurfaceView + AmbientCallback host lifecycle.
pub const SurfaceHost = struct {
    state: SurfaceHostState = .detached,
    native_window: ?*anyopaque = null,
    width_px: u32 = 0,
    height_px: u32 = 0,
    low_bit_ambient: bool = false,
    burn_in_protection: bool = false,
    pending_ambient: bool = false,
    needs_redraw: bool = false,
    ambient_updates: u64 = 0,
    generation: u64 = 0,

    pub fn init() SurfaceHost {
        return .{};
    }

    pub fn onSurfaceCreated(self: *SurfaceHost, window: ?*anyopaque) void {
        if (window == null) {
            self.onSurfaceDestroyed();
            return;
        }
        if (window != self.native_window) {
            self.width_px = 0;
            self.height_px = 0;
        }
        self.native_window = window;
        self.generation +%= 1;
        if (self.state != .paused) {
            self.state = if (self.pending_ambient) .ambient else .attached;
            self.needs_redraw = true;
        }
    }

    pub fn onSurfaceChanged(self: *SurfaceHost, width_px: u32, height_px: u32) void {
        if (self.state == .detached or self.native_window == null) return;
        self.width_px = width_px;
        self.height_px = height_px;
        self.needs_redraw = (width_px > 0 and height_px > 0);
    }

    pub fn onSurfaceDestroyed(self: *SurfaceHost) void {
        self.state = .detached;
        self.native_window = null;
        self.width_px = 0;
        self.height_px = 0;
        self.needs_redraw = false;
    }

    pub fn onEnterAmbient(self: *SurfaceHost, low_bit_ambient: bool, burn_in_protection: bool) void {
        self.low_bit_ambient = low_bit_ambient;
        self.burn_in_protection = burn_in_protection;
        self.pending_ambient = true;
        if (self.state == .detached or self.state == .paused) return;
        self.state = .ambient;
        self.needs_redraw = true;
    }

    pub fn onExitAmbient(self: *SurfaceHost) void {
        self.pending_ambient = false;
        if (self.state == .ambient) {
            self.state = .attached;
            self.needs_redraw = true;
        }
    }

    pub fn onAmbientUpdate(self: *SurfaceHost) void {
        if (self.state != .ambient) return;
        self.ambient_updates +%= 1;
        self.needs_redraw = true;
    }

    pub fn onPause(self: *SurfaceHost) void {
        if (self.state == .attached or self.state == .ambient) {
            self.state = .paused;
            self.needs_redraw = false;
        }
    }

    pub fn onResume(self: *SurfaceHost) void {
        if (self.state == .paused) {
            self.state = if (self.pending_ambient) .ambient else .attached;
            self.needs_redraw = true;
        }
    }

    pub fn canDraw(self: *const SurfaceHost) bool {
        return (self.state == .attached or self.state == .ambient) and
            self.native_window != null and
            self.width_px > 0 and
            self.height_px > 0;
    }

    pub fn consumeRedraw(self: *SurfaceHost) bool {
        if (!self.needs_redraw or !self.canDraw()) return false;
        self.needs_redraw = false;
        return true;
    }

    pub fn applyToConfig(self: *const SurfaceHost, cfg: *WearConfig) void {
        cfg.ambient = (self.state == .ambient);
        cfg.low_bit_ambient = self.low_bit_ambient;
        cfg.burn_in_protection = self.burn_in_protection;
    }
};

pub const BubbleOrb = struct {
    home_x: f32,
    home_y: f32,
    base_radius: f32,
};

pub const ProjectedOrb = struct {
    x: f32,
    y: f32,
    radius: f32,
    scale: f32,
    alpha: f32,
    visible: bool,
};

fn bubbleSmoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    if (edge1 <= edge0) return if (x >= edge1) 1.0 else 0.0;
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn bubbleLerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn positiveOrDefault(v: f32, fallback: f32) f32 {
    if (!std.math.isFinite(v) or v <= 0.0) return fallback;
    return v;
}

/// Zero-allocation spatial watch launcher grid with spherical fisheye projection,
/// inertial drag with rubber-band bounds, nearest-orb detent snap, and press ripple.
pub const BubbleGrid = struct {
    pub const MAX_ORBS: usize = 19;

    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    vel_x: f32 = 0.0,
    vel_y: f32 = 0.0,
    dragging: bool = false,
    drag_last_x: f32 = 0.0,
    drag_last_y: f32 = 0.0,
    pressed_orb: ?usize = null,
    ripple_orb: ?usize = null,
    press_t: f32 = 0.0,
    press_vel: f32 = 0.0,
    settled: bool = true,
    max_pan_radius: f32 = 84.0,
    lens_radius: f32 = 116.5,
    spacing_dp: f32 = 64.0,

    const DEFAULT_MAX_PAN_RADIUS: f32 = 84.0;
    const DEFAULT_LENS_RADIUS: f32 = 116.5;
    const DEFAULT_SPACING_DP: f32 = 64.0;

    /// Initializes a `BubbleGrid` while sanitizing non-finite or non-positive geometry parameters.
    pub fn init(max_pan_radius: f32, lens_radius: f32, spacing_dp: f32) BubbleGrid {
        return .{
            .max_pan_radius = positiveOrDefault(max_pan_radius, DEFAULT_MAX_PAN_RADIUS),
            .lens_radius = positiveOrDefault(lens_radius, DEFAULT_LENS_RADIUS),
            .spacing_dp = positiveOrDefault(spacing_dp, DEFAULT_SPACING_DP),
        };
    }

    /// Computes symmetric hexagonal grid home offsets:
    /// - Slot 0: `(0, 0)`
    /// - Slots 1..6: Ring 1 at distance `spacing` at `-120°, -60°, 0°, 60°, 120°, 180°`
    /// - Slots 7..12: Ring 2 staggered at distance `spacing * sqrt(3)` at `-150°, -90°, -30°, 30°, 90°, 150°`
    /// - Slots 13..18: Ring 2 outer at distance `2 * spacing` at `-120°, -60°, 0°, 60°, 120°, 180°`
    pub fn hexOffset(ring_slot: u8, spacing: f32) RingPoint {
        if (!std.math.isFinite(spacing) or spacing <= 0.0) {
            return .{ .x = 0.0, .y = 0.0 };
        }
        if (ring_slot == 0) {
            return .{ .x = 0.0, .y = 0.0 };
        }
        const pi_3: f32 = std.math.pi / 3.0;
        if (ring_slot <= 6) {
            const k: f32 = @floatFromInt(ring_slot - 1);
            const angle = -2.0 * pi_3 + k * pi_3;
            return .{
                .x = spacing * @cos(angle),
                .y = spacing * @sin(angle),
            };
        }
        if (ring_slot <= 12) {
            const k: f32 = @floatFromInt(ring_slot - 7);
            const angle = -5.0 * (std.math.pi / 6.0) + k * pi_3;
            const r = spacing * @sqrt(@as(f32, 3.0));
            return .{
                .x = r * @cos(angle),
                .y = r * @sin(angle),
            };
        }
        if (ring_slot <= 18) {
            const k: f32 = @floatFromInt(ring_slot - 13);
            const angle = -2.0 * pi_3 + k * pi_3;
            const r = spacing * 2.0;
            return .{
                .x = r * @cos(angle),
                .y = r * @sin(angle),
            };
        }
        return .{ .x = 0.0, .y = 0.0 };
    }

    pub fn beginDrag(self: *BubbleGrid, x: f32, y: f32) void {
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;
        self.dragging = true;
        self.drag_last_x = x;
        self.drag_last_y = y;
        self.vel_x = 0.0;
        self.vel_y = 0.0;
        self.pressed_orb = null;
        self.settled = false;
    }

    pub fn updateDrag(self: *BubbleGrid, x: f32, y: f32, dt: f32) void {
        if (!self.dragging) return;
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(dt) or dt <= 0.0) return;

        self.pan_x = sanitizeFinite(self.pan_x);
        self.pan_y = sanitizeFinite(self.pan_y);
        self.vel_x = sanitizeFinite(self.vel_x);
        self.vel_y = sanitizeFinite(self.vel_y);

        const dx_f64: f64 = @as(f64, x) - @as(f64, self.drag_last_x);
        const dy_f64: f64 = @as(f64, y) - @as(f64, self.drag_last_y);
        if (!std.math.isFinite(dx_f64) or !std.math.isFinite(dy_f64)) return;

        const max_r_f64: f64 = @as(f64, positiveOrDefault(self.max_pan_radius, DEFAULT_MAX_PAN_RADIUS));
        const pan_x_f64: f64 = @as(f64, self.pan_x);
        const pan_y_f64: f64 = @as(f64, self.pan_y);
        const pan_r_f64: f64 = std.math.hypot(pan_x_f64, pan_y_f64);

        var eff_dx = dx_f64;
        var eff_dy = dy_f64;
        if (pan_r_f64 > max_r_f64 and pan_r_f64 > 1e-6) {
            const nx = pan_x_f64 / pan_r_f64;
            const ny = pan_y_f64 / pan_r_f64;
            const radial_dot = dx_f64 * nx + dy_f64 * ny;
            if (radial_dot > 0.0) {
                eff_dx -= 0.65 * radial_dot * nx;
                eff_dy -= 0.65 * radial_dot * ny;
            }
        }

        const pan_limit = max_r_f64 * 8.0;
        const next_px = std.math.clamp(pan_x_f64 + eff_dx, -pan_limit, pan_limit);
        const next_py = std.math.clamp(pan_y_f64 + eff_dy, -pan_limit, pan_limit);
        self.pan_x = @floatCast(next_px);
        self.pan_y = @floatCast(next_py);

        const eff_dt = @max(@as(f64, dt), 1e-4);
        const inst_vx: f32 = @floatCast(std.math.clamp(eff_dx / eff_dt, -2500.0, 2500.0));
        const inst_vy: f32 = @floatCast(std.math.clamp(eff_dy / eff_dt, -2500.0, 2500.0));
        const blend: f32 = @floatCast(1.0 - @exp(-@min(eff_dt, 0.1) * 20.0));
        self.vel_x += (inst_vx - self.vel_x) * blend;
        self.vel_y += (inst_vy - self.vel_y) * blend;

        self.drag_last_x = x;
        self.drag_last_y = y;
        self.settled = false;
    }

    pub fn endDrag(self: *BubbleGrid) void {
        self.dragging = false;
        self.settled = false;
    }

    pub fn setPressedOrb(self: *BubbleGrid, idx: ?usize) void {
        self.pressed_orb = idx;
        if (idx != null) {
            self.ripple_orb = idx;
        }
        self.settled = false;
    }

    pub fn recenter(self: *BubbleGrid) void {
        self.pan_x = 0.0;
        self.pan_y = 0.0;
        self.vel_x = 0.0;
        self.vel_y = 0.0;
        self.dragging = false;
        self.pressed_orb = null;
        self.ripple_orb = null;
        self.press_t = 0.0;
        self.press_vel = 0.0;
        self.settled = true;
    }

    pub fn isAnimating(self: *const BubbleGrid) bool {
        const target_press: f32 = if (self.pressed_orb != null) 1.0 else 0.0;
        return self.dragging or
            !self.settled or
            @abs(self.vel_x) > 0.0 or
            @abs(self.vel_y) > 0.0 or
            @abs(self.press_t - target_press) > 0.001 or
            @abs(self.press_vel) > 0.001;
    }

    fn isValidOrbIdx(idx: ?usize, orbs: []const BubbleOrb) bool {
        const i = idx orelse return false;
        const count = @min(orbs.len, MAX_ORBS);
        if (i >= count) return false;
        const o = orbs[i];
        return std.math.isFinite(o.home_x) and
            std.math.isFinite(o.home_y) and
            std.math.isFinite(o.base_radius) and
            o.base_radius > 0.0;
    }

    /// Returns the index of the valid orb closest to `(0, 0)` under the current pan,
    /// or `null` if pan is non-finite or no valid orb exists within `MAX_ORBS`.
    pub fn focusedOrb(self: *const BubbleGrid, orbs: []const BubbleOrb) ?usize {
        if (!std.math.isFinite(self.pan_x) or !std.math.isFinite(self.pan_y)) return null;
        const count = @min(orbs.len, MAX_ORBS);
        if (count == 0) return null;

        var best_idx: ?usize = null;
        var best_dist: f64 = std.math.inf(f64);
        const px_f64: f64 = @as(f64, self.pan_x);
        const py_f64: f64 = @as(f64, self.pan_y);
        for (0..count) |i| {
            const o = orbs[i];
            if (!std.math.isFinite(o.home_x) or !std.math.isFinite(o.home_y) or
                !std.math.isFinite(o.base_radius) or o.base_radius <= 0.0)
            {
                continue;
            }
            const d = std.math.hypot(@as(f64, o.home_x) + px_f64, @as(f64, o.home_y) + py_f64);
            if (std.math.isFinite(d) and d < best_dist) {
                best_dist = d;
                best_idx = i;
            }
        }
        return best_idx;
    }

    fn nearestDetent(self: *const BubbleGrid, orbs: []const BubbleOrb, max_r: f32) RingPoint {
        const idx = self.focusedOrb(orbs) orelse return .{ .x = 0.0, .y = 0.0 };
        var tx: f64 = -@as(f64, orbs[idx].home_x);
        var ty: f64 = -@as(f64, orbs[idx].home_y);
        if (!std.math.isFinite(tx) or !std.math.isFinite(ty)) {
            return .{ .x = 0.0, .y = 0.0 };
        }
        const max_r_f64: f64 = @as(f64, max_r);
        const tr = std.math.hypot(tx, ty);
        if (tr > max_r_f64 and tr > 1e-4) {
            const s = max_r_f64 / tr;
            tx *= s;
            ty *= s;
        }
        const ftx: f32 = @floatCast(tx);
        const fty: f32 = @floatCast(ty);
        if (!std.math.isFinite(ftx) or !std.math.isFinite(fty)) {
            return .{ .x = 0.0, .y = 0.0 };
        }
        return .{ .x = ftx, .y = fty };
    }

    /// Advances inertial scroll, rubber-band bounds, detent snap, and press ripple spring.
    /// Returns `true` while still animating.
    pub fn step(self: *BubbleGrid, dt: f32, orbs: []const BubbleOrb) bool {
        if (!std.math.isFinite(dt) or dt <= 0.0) {
            return self.isAnimating();
        }

        self.pan_x = sanitizeFinite(self.pan_x);
        self.pan_y = sanitizeFinite(self.pan_y);
        self.vel_x = sanitizeFinite(self.vel_x);
        self.vel_y = sanitizeFinite(self.vel_y);
        self.press_t = sanitizeUnit(self.press_t);
        self.press_vel = sanitizeFinite(self.press_vel);

        if (self.pressed_orb != null and !isValidOrbIdx(self.pressed_orb, orbs)) {
            self.pressed_orb = null;
        }
        if (self.ripple_orb != null and !isValidOrbIdx(self.ripple_orb, orbs)) {
            self.ripple_orb = null;
        }

        const max_r = positiveOrDefault(self.max_pan_radius, DEFAULT_MAX_PAN_RADIUS);
        const clamped_dt = @min(dt, 0.5);
        const substeps: usize = @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(clamped_dt / 0.02))));
        const sub_dt = clamped_dt / @as(f32, @floatFromInt(substeps));

        const target_press: f32 = if (self.pressed_orb != null) 1.0 else 0.0;
        var target_pan: RingPoint = .{ .x = 0.0, .y = 0.0 };

        for (0..substeps) |_| {
            // Press spring (critically damped, omega = 28)
            const omega: f32 = 28.0;
            const pf = self.press_t - target_press;
            const pa = -omega * omega * pf - 2.0 * omega * self.press_vel;
            self.press_vel += pa * sub_dt;
            self.press_t = std.math.clamp(self.press_t + self.press_vel * sub_dt, 0.0, 1.0);
            if (@abs(self.press_t - target_press) < 0.001 and @abs(self.press_vel) < 0.005) {
                self.press_t = target_press;
                self.press_vel = 0.0;
            }

            if (!self.dragging) {
                const damp = @exp(-sub_dt * 7.5);
                self.vel_x *= damp;
                self.vel_y *= damp;

                const pan_r = std.math.hypot(self.pan_x, self.pan_y);
                if (pan_r > max_r and pan_r > 1e-4) {
                    const excess = pan_r - max_r;
                    const nx = self.pan_x / pan_r;
                    const ny = self.pan_y / pan_r;
                    // Radial rubber-band pullback + extra out-of-bounds damping to prevent opposite-edge slingshot
                    const extra_damp = @exp(-sub_dt * 6.0);
                    self.vel_x = self.vel_x * extra_damp - nx * excess * 80.0 * sub_dt;
                    self.vel_y = self.vel_y * extra_damp - ny * excess * 80.0 * sub_dt;
                }

                self.pan_x += self.vel_x * sub_dt;
                self.pan_y += self.vel_y * sub_dt;

                target_pan = self.nearestDetent(orbs, max_r);
                const speed = std.math.hypot(self.vel_x, self.vel_y);
                if (speed < 18.0 and std.math.hypot(self.pan_x, self.pan_y) <= max_r + 1.0) {
                    const pull = 1.0 - @exp(-sub_dt * 12.0);
                    self.pan_x += (target_pan.x - self.pan_x) * pull;
                    self.pan_y += (target_pan.y - self.pan_y) * pull;
                }
            }
        }

        if (self.pressed_orb == null and self.press_t <= 0.001 and @abs(self.press_vel) <= 0.001) {
            self.press_t = 0.0;
            self.press_vel = 0.0;
            self.ripple_orb = null;
        }

        if (!self.dragging) {
            target_pan = self.nearestDetent(orbs, max_r);
            const speed = std.math.hypot(self.vel_x, self.vel_y);
            const dist_to_detent = std.math.hypot(self.pan_x - target_pan.x, self.pan_y - target_pan.y);
            const press_converged = @abs(self.press_t - target_press) <= 0.001 and @abs(self.press_vel) <= 0.001;
            if (speed < 0.5 and dist_to_detent < 0.15 and press_converged) {
                self.pan_x = target_pan.x;
                self.pan_y = target_pan.y;
                self.vel_x = 0.0;
                self.vel_y = 0.0;
                self.press_t = target_press;
                self.press_vel = 0.0;
                if (self.pressed_orb == null) {
                    self.ripple_orb = null;
                }
                self.settled = true;
            } else {
                self.settled = false;
            }
        } else {
            self.settled = false;
        }

        return self.isAnimating();
    }

    /// Projects `orbs[orb_idx]` through the spherical fisheye lens centered at `(cx, cy)`.
    pub fn project(self: *const BubbleGrid, orb_idx: usize, orbs: []const BubbleOrb, cx: f32, cy: f32) ProjectedOrb {
        const invisible: ProjectedOrb = .{
            .x = 0.0,
            .y = 0.0,
            .radius = 0.0,
            .scale = 0.0,
            .alpha = 0.0,
            .visible = false,
        };
        if (orb_idx >= orbs.len or orb_idx >= MAX_ORBS) return invisible;
        if (!std.math.isFinite(cx) or !std.math.isFinite(cy)) return invisible;
        if (!std.math.isFinite(self.pan_x) or !std.math.isFinite(self.pan_y)) return invisible;

        const safe_lens = positiveOrDefault(self.lens_radius, DEFAULT_LENS_RADIUS);
        const orb = orbs[orb_idx];
        if (!std.math.isFinite(orb.home_x) or !std.math.isFinite(orb.home_y) or
            !std.math.isFinite(orb.base_radius) or orb.base_radius <= 0.0)
        {
            return invisible;
        }

        var wx = orb.home_x + self.pan_x;
        var wy = orb.home_y + self.pan_y;
        if (!std.math.isFinite(wx) or !std.math.isFinite(wy)) return invisible;

        const safe_press_t = sanitizeUnit(self.press_t);
        if (self.ripple_orb) |r_idx| {
            if (r_idx < orbs.len and r_idx < MAX_ORBS and r_idx != orb_idx and safe_press_t > 0.001) {
                const rippled = orbs[r_idx];
                if (std.math.isFinite(rippled.home_x) and std.math.isFinite(rippled.home_y)) {
                    const px = rippled.home_x + self.pan_x;
                    const py = rippled.home_y + self.pan_y;
                    const dx = wx - px;
                    const dy = wy - py;
                    const d = std.math.hypot(dx, dy);
                    const spacing = positiveOrDefault(self.spacing_dp, DEFAULT_SPACING_DP);
                    const ripple_range = 1.45 * spacing;
                    if (std.math.isFinite(d) and d > 0.01 and d < ripple_range) {
                        const nudge = 2.6 * safe_press_t * (1.0 - d / ripple_range);
                        wx += (dx / d) * nudge;
                        wy += (dy / d) * nudge;
                    }
                }
            }
        }
        if (!std.math.isFinite(wx) or !std.math.isFinite(wy)) return invisible;

        const r_f64 = std.math.hypot(@as(f64, wx), @as(f64, wy));
        const safe_lens_f64: f64 = @as(f64, safe_lens);
        const u_f64 = r_f64 / safe_lens_f64;
        // Closed-form integral-matched honeycomb lens: d(r_proj)/dr == scale(u) for all u >= 0
        const LENS_S_MIN: f64 = 0.24;
        const LENS_K: f64 = 1.65;
        const LENS_SQRT_K: f64 = @sqrt(LENS_K);
        const scale_f64 = LENS_S_MIN + (1.0 - LENS_S_MIN) / (1.0 + LENS_K * u_f64 * u_f64);
        const r_proj_f64 = safe_lens_f64 * (LENS_S_MIN * u_f64 + (1.0 - LENS_S_MIN) * std.math.atan(LENS_SQRT_K * u_f64) / LENS_SQRT_K);
        if (!std.math.isFinite(r_proj_f64)) return invisible;

        const proj_x: f32 = if (r_f64 > 1e-4) @floatCast(@as(f64, cx) + @as(f64, wx) * (r_proj_f64 / r_f64)) else cx;
        const proj_y: f32 = if (r_f64 > 1e-4) @floatCast(@as(f64, cy) + @as(f64, wy) * (r_proj_f64 / r_f64)) else cy;
        if (!std.math.isFinite(proj_x) or !std.math.isFinite(proj_y)) return invisible;

        const u: f32 = @floatCast(@min(u_f64, 1e6));
        var scale: f32 = std.math.clamp(@as(f32, @floatCast(scale_f64)), @as(f32, @floatCast(LENS_S_MIN)), 1.0);
        if (self.ripple_orb == orb_idx) {
            scale *= (1.0 - 0.10 * safe_press_t);
        }
        const radius = orb.base_radius * scale;
        const inner_alpha = bubbleLerp(1.0, 0.50, bubbleSmoothstep(0.70, 1.35, u));
        const far_fade = 1.0 - bubbleSmoothstep(1.55, 2.05, u);
        const alpha = std.math.clamp(inner_alpha * far_fade, 0.0, 1.0);
        const visible = alpha > 0.02 and radius > 0.5;

        return .{
            .x = proj_x,
            .y = proj_y,
            .radius = radius,
            .scale = scale,
            .alpha = alpha,
            .visible = visible,
        };
    }

    /// Hit-tests `(px, py)` against projected visible orbs, returning the matching orb with highest `scale`.
    pub fn hitTest(self: *const BubbleGrid, orbs: []const BubbleOrb, cx: f32, cy: f32, px: f32, py: f32) ?usize {
        if (!std.math.isFinite(px) or !std.math.isFinite(py) or
            !std.math.isFinite(cx) or !std.math.isFinite(cy))
        {
            return null;
        }
        const count = @min(orbs.len, MAX_ORBS);
        var best_idx: ?usize = null;
        var best_scale: f32 = -1.0;

        for (0..count) |i| {
            const p = self.project(i, orbs, cx, cy);
            if (!p.visible) continue;
            const dist = std.math.hypot(@as(f64, px) - @as(f64, p.x), @as(f64, py) - @as(f64, p.y));
            if (dist <= @as(f64, p.radius)) {
                if (p.scale > best_scale) {
                    best_scale = p.scale;
                    best_idx = i;
                }
            }
        }
        return best_idx;
    }
};
