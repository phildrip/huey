const std = @import("std");
const core = @import("../core.zig");
const tokens = @import("../tokens.zig");
const wearos = @import("../wearos.zig");

pub const MAX_TOASTS: usize = 4;
pub const MAX_TOAST_MSG_LEN: usize = 64;

const MAX_TOAST_TTL_S: f64 = 86400.0;
const MIN_TOAST_TTL_S: f64 = 0.01;
const MAX_TOAST_DT_S: f64 = 60.0;
const SPINNER_DOT_COUNT: usize = 8;

pub const BadgeVariant = enum {
    default,
    secondary,
    success,
    warning,
    destructive,
    outline,
};

pub const BadgeSpec = struct {
    variant: BadgeVariant = .default,
    label: []const u8 = "",
    pill: bool = true,
};

pub const Orientation = enum {
    horizontal,
    vertical,
};

pub const AlertVariant = enum {
    info,
    success,
    warning,
    destructive,
};

pub const CarIcon = enum {
    lock,
    unlock,
    frunk,
    trunk,
    headlights,
    key,
    power,
    settings,
};

pub const ToastEntry = struct {
    msg: [MAX_TOAST_MSG_LEN]u8 = [_]u8{0} ** MAX_TOAST_MSG_LEN,
    len: usize = 0,
    variant: AlertVariant = .info,
    ttl_s: f64 = 0.0,
    max_ttl_s: f64 = 0.0,
    active: bool = false,

    /// Returns the active message slice stored in this fixed-capacity entry.
    pub fn message(self: *const ToastEntry) []const u8 {
        const safe_len = @min(self.len, MAX_TOAST_MSG_LEN);
        return self.msg[0..safe_len];
    }
};

pub const ToastQueue = struct {
    entries: [MAX_TOASTS]ToastEntry = [_]ToastEntry{.{}} ** MAX_TOASTS,
    count: usize = 0,

    /// Creates an empty zero-allocation toast queue.
    pub fn init() ToastQueue {
        return .{};
    }

    /// Pushes a toast notification with bounded message and TTL; evicts oldest if full.
    pub fn push(self: *ToastQueue, msg: []const u8, variant: AlertVariant, ttl_s: f32) void {
        if (!std.math.isFinite(ttl_s) or ttl_s <= 0.0) return;
        const clamped_ttl = std.math.clamp(@as(f64, ttl_s), MIN_TOAST_TTL_S, MAX_TOAST_TTL_S);

        if (self.count >= MAX_TOASTS) {
            var i: usize = 1;
            while (i < MAX_TOASTS) : (i += 1) {
                self.entries[i - 1] = self.entries[i];
            }
            self.count = MAX_TOASTS - 1;
        }

        var entry = ToastEntry{
            .variant = variant,
            .ttl_s = clamped_ttl,
            .max_ttl_s = clamped_ttl,
            .active = true,
        };
        var copy_len = msg.len;
        if (copy_len > MAX_TOAST_MSG_LEN) {
            var i: usize = 0;
            while (i < MAX_TOAST_MSG_LEN) {
                const seq_len = std.unicode.utf8ByteSequenceLength(msg[i]) catch {
                    i += 1;
                    continue;
                };
                if (i + seq_len > MAX_TOAST_MSG_LEN) break;
                i += seq_len;
            }
            copy_len = i;
        }
        if (copy_len > 0) {
            @memcpy(entry.msg[0..copy_len], msg[0..copy_len]);
        }
        entry.len = copy_len;

        self.entries[self.count] = entry;
        self.count += 1;
    }

    /// Advances active toast TTLs by `dt_s` (ignoring non-finite or `<= 0`) and compacts expired entries.
    pub fn step(self: *ToastQueue, dt_s: f32) void {
        if (!std.math.isFinite(dt_s) or dt_s <= 0.0) return;
        const dt = @min(@as(f64, dt_s), MAX_TOAST_DT_S);

        var write_idx: usize = 0;
        var read_idx: usize = 0;
        while (read_idx < self.count) : (read_idx += 1) {
            var e = self.entries[read_idx];
            if (!e.active) continue;
            e.ttl_s -= dt;
            if (e.ttl_s > 0.0 and std.math.isFinite(e.ttl_s)) {
                self.entries[write_idx] = e;
                write_idx += 1;
            }
        }
        var clear_idx = write_idx;
        while (clear_idx < MAX_TOASTS) : (clear_idx += 1) {
            self.entries[clear_idx] = .{};
        }
        self.count = write_idx;
    }

    /// Returns the number of active toasts currently in the queue.
    pub fn activeCount(self: *const ToastQueue) usize {
        return self.count;
    }

    /// Returns true while any toast remains active and counting down.
    pub fn isAnimating(self: *const ToastQueue) bool {
        return self.count > 0;
    }

    /// Returns the newest active toast entry, or `null` if the queue is empty.
    pub fn top(self: *const ToastQueue) ?*const ToastEntry {
        if (self.count == 0) return null;
        return &self.entries[self.count - 1];
    }

    /// Immediately dismisses all toasts and resets queue state.
    pub fn clear(self: *ToastQueue) void {
        for (&self.entries) |*e| {
            e.* = .{};
        }
        self.count = 0;
    }
};

fn sanitizeNonNeg(v: f32) f32 {
    if (!std.math.isFinite(v) or v < 0.0) return 0.0;
    return v;
}

fn sanitizeUnit(v: f32) f32 {
    if (!std.math.isFinite(v) or v <= 0.0) return 0.0;
    if (v >= 1.0) return 1.0;
    return v;
}

fn isValidInputs(rect: core.Rect, scale: f32, clip_rect: [4]f32) bool {
    if (!std.math.isFinite(scale) or scale <= 0.0) return false;
    if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
        !std.math.isFinite(rect.w) or !std.math.isFinite(rect.h))
    {
        return false;
    }
    if (rect.w <= 0.0 or rect.h <= 0.0) return false;
    for (clip_rect) |v| {
        if (!std.math.isFinite(v)) return false;
    }
    return clip_rect[2] > clip_rect[0] and clip_rect[3] > clip_rect[1];
}

fn intersectsClip(x0: f32, y0: f32, x1: f32, y1: f32, clip: [4]f32) bool {
    return x1 > clip[0] and x0 < clip[2] and y1 > clip[1] and y0 < clip[3];
}

fn pushQuad(
    out_quads: []core.QuadInstance,
    count: *usize,
    quad: core.QuadInstance,
    clip_rect: [4]f32,
) void {
    if (count.* >= out_quads.len) return;
    for (quad.pos_size) |v| {
        if (!std.math.isFinite(v)) return;
    }
    if (quad.pos_size[2] <= 0.0 or quad.pos_size[3] <= 0.0) return;

    var q = quad;
    q.color = core.sanitizeColor(q.color);
    q.border_color = core.sanitizeColor(q.border_color);
    q.params[0] = sanitizeNonNeg(q.params[0]);
    q.params[1] = sanitizeNonNeg(q.params[1]);
    q.params[2] = sanitizeNonNeg(q.params[2]);
    if (!std.math.isFinite(q.params[3])) q.params[3] = 0.0;

    const pad: f32 = if (q.params[3] > 0.5) 0.0 else (q.params[2] * 1.5 + 2.0);
    if (!intersectsClip(
        q.pos_size[0] - pad,
        q.pos_size[1] - pad,
        q.pos_size[0] + q.pos_size[2] + pad,
        q.pos_size[1] + q.pos_size[3] + pad,
        clip_rect,
    )) {
        return;
    }
    q.clip_rect = clip_rect;
    out_quads[count.*] = q;
    count.* += 1;
}

fn emitSnappedRect(
    out_quads: []core.QuadInstance,
    count: *usize,
    rect: core.Rect,
    scale: f32,
    fill: core.Color,
    border: core.Color,
    radius_dp: f32,
    bw_dp: f32,
    blur_dp: f32,
    mode: f32,
    clip_rect: [4]f32,
) void {
    const phys = core.snapRectToPhysical(rect, scale);
    if (phys.w <= 0.0 or phys.h <= 0.0) return;
    pushQuad(out_quads, count, .{
        .pos_size = .{ phys.x, phys.y, phys.w, phys.h },
        .color = fill,
        .border_color = border,
        .params = .{
            sanitizeNonNeg(radius_dp) * scale,
            sanitizeNonNeg(bw_dp) * scale,
            sanitizeNonNeg(blur_dp) * scale,
            mode,
        },
    }, clip_rect);
}

fn oklabMix(a: tokens.OklabColor, b: tokens.OklabColor, t_raw: f32) tokens.OklabColor {
    const t = sanitizeUnit(t_raw);
    return .{
        .l = std.math.clamp(a.l + (b.l - a.l) * t, 0.0, 1.0),
        .a = std.math.clamp(a.a + (b.a - a.a) * t, -1.0, 1.0),
        .b = std.math.clamp(a.b + (b.b - a.b) * t, -1.0, 1.0),
        .alpha = std.math.clamp(a.alpha + (b.alpha - a.alpha) * t, 0.0, 1.0),
    };
}

fn alertAccentToken(tbl: *const tokens.TokenTable, variant: AlertVariant) tokens.OklabColor {
    return switch (variant) {
        .info => tbl.accent_primary,
        .success => tbl.accent_success,
        .warning => tbl.accent_warn,
        .destructive => tbl.accent_danger,
    };
}

/// Emits a pill or rounded status badge quad styled from semantic token variants.
pub fn emitBadge(
    spec: BadgeSpec,
    rect: core.Rect,
    scale: f32,
    tbl: *const tokens.TokenTable,
    out_quads: []core.QuadInstance,
    clip_rect: [4]f32,
) usize {
    if (!isValidInputs(rect, scale, clip_rect)) return 0;

    const fill: core.Color = switch (spec.variant) {
        .default => tbl.accent_primary.toSrgb(),
        .secondary => tbl.bg_elevated.toSrgb(),
        .success => tbl.accent_success.toSrgb(),
        .warning => tbl.accent_warn.toSrgb(),
        .destructive => tbl.accent_danger.toSrgb(),
        .outline => core.Nord.transparent,
    };
    const border: core.Color = switch (spec.variant) {
        .secondary, .outline => tbl.border_default.toSrgb(),
        else => core.Nord.transparent,
    };
    const bw_dp: f32 = switch (spec.variant) {
        .secondary, .outline => @max(1.0, tbl.border_width_default),
        else => 0.0,
    };
    const radius_dp = if (spec.pill)
        @min(rect.w, rect.h) * 0.5
    else
        @min(tbl.corner_radius_sm, @min(rect.w, rect.h) * 0.5);

    var count: usize = 0;
    emitSnappedRect(out_quads, &count, rect, scale, fill, border, radius_dp, bw_dp, 0.0, 0.0, clip_rect);
    return count;
}

/// Emits a crisp 1dp horizontal or vertical hairline separator centered inside `rect`.
pub fn emitSeparator(
    orient: Orientation,
    rect: core.Rect,
    scale: f32,
    tbl: *const tokens.TokenTable,
    out_quads: []core.QuadInstance,
    clip_rect: [4]f32,
) usize {
    if (!isValidInputs(rect, scale, clip_rect)) return 0;

    const base_thick = @max(1.0, tbl.border_width_default);
    const sep_rect: core.Rect = switch (orient) {
        .horizontal => blk: {
            const h = @min(rect.h, base_thick);
            break :blk .{
                .x = rect.x,
                .y = rect.y + (rect.h - h) * 0.5,
                .w = rect.w,
                .h = h,
            };
        },
        .vertical => blk: {
            const w = @min(rect.w, base_thick);
            break :blk .{
                .x = rect.x + (rect.w - w) * 0.5,
                .y = rect.y,
                .w = w,
                .h = rect.h,
            };
        },
    };

    var count: usize = 0;
    emitSnappedRect(
        out_quads,
        &count,
        sep_rect,
        scale,
        tbl.border_default.toSrgb(),
        core.Nord.transparent,
        0.0,
        0.0,
        0.0,
        0.0,
        clip_rect,
    );
    return count;
}

/// Emits a keyboard shortcut keycap pill with a subtle bottom bevel border.
pub fn emitKbd(
    rect: core.Rect,
    scale: f32,
    tbl: *const tokens.TokenTable,
    out_quads: []core.QuadInstance,
    clip_rect: [4]f32,
) usize {
    if (!isValidInputs(rect, scale, clip_rect)) return 0;

    const radius_dp = @min(tbl.corner_radius_sm, @min(rect.w, rect.h) * 0.5);
    const border_col = tbl.border_default.toSrgb();
    const bw_dp = @max(1.0, tbl.border_width_default);
    var count: usize = 0;

    if (rect.h > 4.0) {
        const bevel_dp = std.math.clamp(rect.h * 0.12, 1.0, 2.5);
        // Bottom bevel base
        emitSnappedRect(out_quads, &count, rect, scale, border_col, core.Nord.transparent, radius_dp, 0.0, 0.0, 0.0, clip_rect);
        // Raised keycap face
        const top_rect = core.Rect{
            .x = rect.x,
            .y = rect.y,
            .w = rect.w,
            .h = rect.h - bevel_dp,
        };
        emitSnappedRect(
            out_quads,
            &count,
            top_rect,
            scale,
            tbl.bg_elevated.toSrgb(),
            border_col,
            radius_dp,
            bw_dp,
            0.0,
            0.0,
            clip_rect,
        );
    } else {
        emitSnappedRect(
            out_quads,
            &count,
            rect,
            scale,
            tbl.bg_elevated.toSrgb(),
            border_col,
            radius_dp,
            bw_dp,
            0.0,
            0.0,
            clip_rect,
        );
    }
    return count;
}

/// Emits a progress bar track and clamped `[0, 1]` filled accent pill.
pub fn emitProgress(
    value: f32,
    rect: core.Rect,
    scale: f32,
    tbl: *const tokens.TokenTable,
    out_quads: []core.QuadInstance,
    clip_rect: [4]f32,
) usize {
    if (!isValidInputs(rect, scale, clip_rect)) return 0;

    const clamped = sanitizeUnit(value);
    const track_radius = @min(rect.w, rect.h) * 0.5;
    var count: usize = 0;

    emitSnappedRect(
        out_quads,
        &count,
        rect,
        scale,
        tbl.bg_surface.toSrgb(),
        tbl.border_default.toSrgb(),
        track_radius,
        tbl.border_width_default,
        0.0,
        0.0,
        clip_rect,
    );

    if (clamped > 0.0) {
        const fill_w = rect.w * clamped;
        const fill_h = @min(fill_w, rect.h);
        const fill_rect = core.Rect{
            .x = rect.x,
            .y = rect.y + (rect.h - fill_h) * 0.5,
            .w = fill_w,
            .h = fill_h,
        };
        const fill_radius = fill_h * 0.5;
        emitSnappedRect(
            out_quads,
            &count,
            fill_rect,
            scale,
            tbl.accent_primary.toSrgb(),
            core.Nord.transparent,
            fill_radius,
            0.0,
            0.0,
            0.0,
            clip_rect,
        );
    }
    return count;
}

/// Emits 8 circular SDF dots arranged around a ring with fading tail alpha rotating by `phase_rad`.
pub fn emitSpinner(
    phase_rad: f32,
    rect: core.Rect,
    scale: f32,
    tbl: *const tokens.TokenTable,
    out_quads: []core.QuadInstance,
    clip_rect: [4]f32,
) usize {
    if (!isValidInputs(rect, scale, clip_rect)) return 0;

    const safe_phase = if (std.math.isFinite(phase_rad)) @mod(phase_rad, std.math.tau) else 0.0;
    const min_dim = @min(rect.w, rect.h);
    const dot_d = @min(min_dim * 0.35, @max(1.5, min_dim * 0.18));
    const ring_r = @max(0.0, min_dim * 0.5 - dot_d * 0.5);
    const cx = rect.x + rect.w * 0.5;
    const cy = rect.y + rect.h * 0.5;

    const base_col = tbl.accent_primary.toSrgb();
    const d_px = dot_d * scale;
    const r_px = d_px * 0.5;

    var count: usize = 0;
    for (0..SPINNER_DOT_COUNT) |i| {
        if (count >= out_quads.len) break;
        const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SPINNER_DOT_COUNT));
        const angle = safe_phase - frac * std.math.tau;
        const dx = cx + ring_r * @cos(angle) - dot_d * 0.5;
        const dy = cy + ring_r * @sin(angle) - dot_d * 0.5;
        const alpha_mul = 1.0 - 0.82 * frac;
        const dot_col = core.Color{
            base_col[0],
            base_col[1],
            base_col[2],
            base_col[3] * alpha_mul,
        };
        pushQuad(out_quads, &count, .{
            .pos_size = .{ dx * scale, dy * scale, d_px, d_px },
            .color = dot_col,
            .border_color = core.Nord.transparent,
            .params = .{ r_px, 0.0, 0.0, wearos.AMBIENT_FG_SDF_MODE },
        }, clip_rect);
    }
    return count;
}

/// Emits an Oklab luminance-pulsing skeleton placeholder rectangle.
pub fn emitSkeleton(
    shimmer_phase: f32,
    rect: core.Rect,
    scale: f32,
    tbl: *const tokens.TokenTable,
    out_quads: []core.QuadInstance,
    clip_rect: [4]f32,
) usize {
    if (!isValidInputs(rect, scale, clip_rect)) return 0;

    const safe_phase = if (std.math.isFinite(shimmer_phase)) shimmer_phase else 0.0;
    const frac = @mod(safe_phase, 1.0);
    const pulse = 0.5 + 0.5 * @sin(frac * std.math.tau);
    var col_ok = tbl.bg_elevated;
    col_ok.l = std.math.clamp(col_ok.l + (pulse - 0.5) * 0.14, 0.0, 1.0);

    const radius_dp = @min(tbl.corner_radius_sm, @min(rect.w, rect.h) * 0.5);
    var count: usize = 0;
    emitSnappedRect(
        out_quads,
        &count,
        rect,
        scale,
        col_ok.toSrgb(),
        core.Nord.transparent,
        radius_dp,
        0.0,
        0.0,
        0.0,
        clip_rect,
    );
    return count;
}

/// Emits an alert container quad with a left semantic accent stripe.
pub fn emitAlert(
    variant: AlertVariant,
    rect: core.Rect,
    scale: f32,
    tbl: *const tokens.TokenTable,
    out_quads: []core.QuadInstance,
    clip_rect: [4]f32,
) usize {
    if (!isValidInputs(rect, scale, clip_rect)) return 0;

    const accent_ok = alertAccentToken(tbl, variant);
    const accent_col = accent_ok.toSrgb();
    const bg_col = oklabMix(tbl.bg_surface, accent_ok, 0.10).toSrgb();
    const radius_dp = @min(tbl.corner_radius_md, @min(rect.w, rect.h) * 0.5);

    var count: usize = 0;
    emitSnappedRect(
        out_quads,
        &count,
        rect,
        scale,
        bg_col,
        accent_col,
        radius_dp,
        tbl.border_width_default,
        0.0,
        0.0,
        clip_rect,
    );

    const stripe_w = @min(4.0, rect.w * 0.25);
    const pad_x = @min(4.0, (rect.w - stripe_w) * 0.5);
    const pad_y = @min(6.0, rect.h * 0.2);
    const stripe_rect = core.Rect{
        .x = rect.x + pad_x,
        .y = rect.y + pad_y,
        .w = stripe_w,
        .h = @min(rect.h - pad_y * 2.0, @max(0.0, rect.h - pad_y * 2.0)),
    };
    emitSnappedRect(
        out_quads,
        &count,
        stripe_rect,
        scale,
        accent_col,
        core.Nord.transparent,
        stripe_w * 0.5,
        0.0,
        0.0,
        0.0,
        clip_rect,
    );
    return count;
}

fn emitNormIconQuad(
    out_quads: []core.QuadInstance,
    count: *usize,
    ox: f32,
    oy: f32,
    size_dp: f32,
    scale: f32,
    nx: f32,
    ny: f32,
    nw: f32,
    nh: f32,
    nr: f32,
    fill: core.Color,
    border: core.Color,
    bw_norm: f32,
    clip_rect: [4]f32,
) void {
    const px = (ox + nx * size_dp) * scale;
    const py = (oy + ny * size_dp) * scale;
    const pw = nw * size_dp * scale;
    const ph = nh * size_dp * scale;
    const pr = nr * size_dp * scale;
    const pbw = bw_norm * size_dp * scale;
    pushQuad(out_quads, count, .{
        .pos_size = .{ px, py, pw, ph },
        .color = fill,
        .border_color = border,
        .params = .{ pr, pbw, 0.0, wearos.AMBIENT_FG_SDF_MODE },
    }, clip_rect);
}

/// Emits crisp procedural multi-quad SDF Watch/Car icons tagged with `AMBIENT_FG_SDF_MODE`.
pub fn emitCarIcon(
    icon: CarIcon,
    rect: core.Rect,
    scale: f32,
    color: core.Color,
    out_quads: []core.QuadInstance,
    clip_rect: [4]f32,
) usize {
    if (!isValidInputs(rect, scale, clip_rect)) return 0;

    const s = @min(rect.w, rect.h);
    const ox = rect.x + (rect.w - s) * 0.5;
    const oy = rect.y + (rect.h - s) * 0.5;
    const col = core.sanitizeColor(color);
    const none = core.Nord.transparent;
    const stroke_n: f32 = @min(0.24, @max(1.5 / @max(s, 1.0), 0.095));
    var count: usize = 0;

    switch (icon) {
        .lock => {
            // Closed shackle ring + solid body
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.27, 0.10, 0.46, 0.42, 0.23, none, col, stroke_n, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.18, 0.42, 0.64, 0.46, 0.10, col, none, 0.0, clip_rect);
        },
        .unlock => {
            // Open shackle (left post + top arch + short right tip) + solid body
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.27, 0.12, stroke_n, 0.34, stroke_n * 0.5, col, none, 0.0, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.27, 0.10, 0.46, stroke_n, stroke_n * 0.5, col, none, 0.0, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.73 - stroke_n, 0.10, stroke_n, 0.16, stroke_n * 0.5, col, none, 0.0, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.18, 0.44, 0.64, 0.44, 0.10, col, none, 0.0, clip_rect);
        },
        .frunk => {
            // Car front nose + cabin + raised front hood + strut
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.12, 0.58, 0.76, 0.22, 0.08, col, none, 0.0, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.48, 0.38, 0.36, 0.22, 0.06, col, none, 0.0, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.14, 0.28, 0.34, stroke_n, stroke_n * 0.5, col, none, 0.0, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.28, 0.36, stroke_n, 0.22, stroke_n * 0.5, col, none, 0.0, clip_rect);
        },
        .trunk => {
            // Car rear body + cabin + raised rear boot + strut
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.12, 0.58, 0.76, 0.22, 0.08, col, none, 0.0, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.16, 0.38, 0.36, 0.22, 0.06, col, none, 0.0, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.52, 0.28, 0.34, stroke_n, stroke_n * 0.5, col, none, 0.0, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.64, 0.36, stroke_n, 0.22, stroke_n * 0.5, col, none, 0.0, clip_rect);
        },
        .headlights => {
            // Lamp housing + 3 beam rays
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.14, 0.24, 0.32, 0.52, 0.16, col, none, 0.0, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.54, 0.25, 0.32, stroke_n, stroke_n * 0.5, col, none, 0.0, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.54, 0.50 - stroke_n * 0.5, 0.34, stroke_n, stroke_n * 0.5, col, none, 0.0, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.54, 0.75 - stroke_n, 0.32, stroke_n, stroke_n * 0.5, col, none, 0.0, clip_rect);
        },
        .key => {
            // Key bow ring + blade + 2 teeth
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.10, 0.31, 0.36, 0.38, 0.19, none, col, stroke_n, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.44, 0.50 - stroke_n * 0.5, 0.46, stroke_n, stroke_n * 0.5, col, none, 0.0, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.66, 0.50 + stroke_n * 0.2, stroke_n, 0.14, stroke_n * 0.5, col, none, 0.0, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.80, 0.50 + stroke_n * 0.2, stroke_n, 0.18, stroke_n * 0.5, col, none, 0.0, clip_rect);
        },
        .power => {
            // Outer circle ring + top vertical stem
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.16, 0.20, 0.68, 0.68, 0.34, none, col, stroke_n, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.50 - stroke_n * 0.5, 0.08, stroke_n, 0.38, stroke_n * 0.5, col, none, 0.0, clip_rect);
        },
        .settings => {
            // Outer gear ring + inner hub + 8 radial teeth
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.22, 0.22, 0.56, 0.56, 0.28, none, col, stroke_n, clip_rect);
            emitNormIconQuad(out_quads, &count, ox, oy, s, scale, 0.40, 0.40, 0.20, 0.20, 0.10, col, none, 0.0, clip_rect);
            const tooth_d: f32 = 0.15;
            const tooth_r: f32 = 0.33;
            for (0..8) |i| {
                const angle = @as(f32, @floatFromInt(i)) * (std.math.tau / 8.0);
                const tx = 0.5 + tooth_r * @cos(angle) - tooth_d * 0.5;
                const ty = 0.5 + tooth_r * @sin(angle) - tooth_d * 0.5;
                emitNormIconQuad(out_quads, &count, ox, oy, s, scale, tx, ty, tooth_d, tooth_d, tooth_d * 0.5, col, none, 0.0, clip_rect);
            }
        },
    }
    return count;
}

test "primitives: Badge variants, Separator orientations & Kbd bevel" {
    const tbl = tokens.TokenTable.nordDefault();
    var quads: [16]core.QuadInstance = undefined;
    const clip = [4]f32{ 0, 0, 800, 800 };

    const variants = [_]BadgeVariant{ .default, .secondary, .success, .warning, .destructive, .outline };
    for (variants) |v| {
        const n = emitBadge(.{ .variant = v }, .{ .x = 10, .y = 10, .w = 48, .h = 20 }, 2.0, &tbl, &quads, clip);
        try std.testing.expectEqual(@as(usize, 1), n);
    }

    const n_vsep = emitSeparator(.vertical, .{ .x = 20, .y = 10, .w = 8, .h = 100 }, 2.0, &tbl, &quads, clip);
    try std.testing.expectEqual(@as(usize, 1), n_vsep);
    try std.testing.expectEqual(@as(f32, 2.0), quads[0].pos_size[2]);

    const n_kbd = emitKbd(.{ .x = 10, .y = 10, .w = 36, .h = 24 }, 2.0, &tbl, &quads, clip);
    try std.testing.expectEqual(@as(usize, 2), n_kbd);
    try std.testing.expect(quads[1].pos_size[3] < quads[0].pos_size[3]);
}

test "primitives: Progress clamping, Skeleton shimmer, Alert variants & sanitization" {
    const tbl = tokens.TokenTable.nordDefault();
    var quads: [16]core.QuadInstance = undefined;
    const clip = [4]f32{ 0, 0, 800, 800 };

    try std.testing.expectEqual(@as(usize, 1), emitProgress(-0.5, .{ .x = 0, .y = 0, .w = 100, .h = 8 }, 2.0, &tbl, &quads, clip));
    try std.testing.expectEqual(@as(usize, 1), emitProgress(std.math.nan(f32), .{ .x = 0, .y = 0, .w = 100, .h = 8 }, 2.0, &tbl, &quads, clip));
    try std.testing.expectEqual(@as(usize, 2), emitProgress(2.5, .{ .x = 0, .y = 0, .w = 100, .h = 8 }, 2.0, &tbl, &quads, clip));
    try std.testing.expectEqual(quads[0].pos_size[2], quads[1].pos_size[2]);

    _ = emitSkeleton(0.25, .{ .x = 0, .y = 0, .w = 100, .h = 16 }, 1.0, &tbl, &quads, clip);
    const bright = quads[0].color[0];
    _ = emitSkeleton(0.75, .{ .x = 0, .y = 0, .w = 100, .h = 16 }, 1.0, &tbl, &quads, clip);
    const dim = quads[0].color[0];
    try std.testing.expect(bright > dim);

    for ([_]AlertVariant{ .info, .success, .warning, .destructive }) |av| {
        try std.testing.expectEqual(@as(usize, 2), emitAlert(av, .{ .x = 10, .y = 10, .w = 200, .h = 48 }, 2.0, &tbl, &quads, clip));
    }

    try std.testing.expectEqual(@as(usize, 0), emitSpinner(0.0, .{ .x = 0, .y = 0, .w = 32, .h = 32 }, 0.0, &tbl, &quads, clip));
    try std.testing.expectEqual(@as(usize, 0), emitCarIcon(.lock, .{ .x = 0, .y = 0, .w = 0, .h = 28 }, 2.0, core.Nord.snow_storm_2, &quads, clip));
}

test "primitives: ToastQueue capacity, truncation, non-finite dt & clear" {
    var tq = ToastQueue.init();
    try std.testing.expect(tq.top() == null);

    tq.push("bad", .info, 0.0);
    tq.push("bad_nan", .info, std.math.nan(f32));
    try std.testing.expectEqual(@as(usize, 0), tq.activeCount());

    const long_msg = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef_EXTRA";
    tq.push("first", .info, 5.0);
    tq.push("second", .success, 5.0);
    tq.push("third", .warning, 5.0);
    tq.push("fourth", .destructive, 5.0);
    tq.push(long_msg, .info, 5.0);
    try std.testing.expectEqual(@as(usize, MAX_TOASTS), tq.activeCount());
    const top_entry = tq.top().?;
    try std.testing.expectEqual(@as(usize, MAX_TOAST_MSG_LEN), top_entry.message().len);

    tq.step(0.0);
    tq.step(-1.0);
    tq.step(std.math.nan(f32));
    try std.testing.expectEqual(@as(usize, MAX_TOASTS), tq.activeCount());

    tq.clear();
    try std.testing.expectEqual(@as(usize, 0), tq.activeCount());
    try std.testing.expect(!tq.isAnimating());
    try std.testing.expect(tq.top() == null);
}

test "primitives: CarIcon quads carry AMBIENT_FG_SDF_MODE and survive ambient transform" {
    var quads: [32]core.QuadInstance = undefined;
    const clip = [4]f32{ 0, 0, 466, 466 };
    for ([_]CarIcon{ .lock, .unlock, .frunk, .trunk, .headlights, .key, .power, .settings }) |icon| {
        const n = emitCarIcon(icon, .{ .x = 20, .y = 20, .w = 28, .h = 28 }, 2.0, core.Nord.snow_storm_2, &quads, clip);
        try std.testing.expect(n >= 2);
        for (quads[0..n]) |q| {
            try std.testing.expectEqual(wearos.AMBIENT_FG_SDF_MODE, q.params[3]);
        }
        wearos.transformQuadsForAmbient(quads[0..n], false);
        for (quads[0..n]) |q| {
            const has_fg = (q.color[3] > 0.0 and q.color[0] > 0.1) or
                (q.border_color[3] > 0.0 and q.border_color[0] > 0.1);
            try std.testing.expect(has_fg);
        }
    }
}
