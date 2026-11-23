const std = @import("std");
const core = @import("../core.zig");
const tokens = @import("../tokens.zig");
const anim = @import("../animation.zig");

pub const ButtonVariant = enum {
    primary,
    secondary,
    outline,
    ghost,
    destructive,
};

pub const ButtonShape = enum {
    rounded,
    pill,
    circle,
};

pub const ButtonSpec = struct {
    id: []const u8,
    label: []const u8 = "",
    variant: ButtonVariant = .primary,
    shape: ButtonShape = .rounded,
    hovered: bool = false,
    pressed: bool = false,
    disabled: bool = false,
    focused: bool = false,
    loading: bool = false,
};

pub const Orientation = enum {
    horizontal,
    vertical,
};

pub const ButtonGroupSpec = struct {
    id: []const u8,
    items: []const ButtonSpec,
    orientation: Orientation = .horizontal,
    gap: f32 = 2.0,
    attached: bool = true,
};

pub const CheckboxState = enum {
    unchecked,
    checked,
    indeterminate,
};

pub const CheckboxSpec = struct {
    id: []const u8,
    state: CheckboxState = .unchecked,
    disabled: bool = false,
    focused: bool = false,
};

pub const SwitchSpec = struct {
    id: []const u8,
    checked: bool = false,
    disabled: bool = false,
    focused: bool = false,
};

pub const RadioSpec = struct {
    id: []const u8,
    selected: bool = false,
    disabled: bool = false,
    focused: bool = false,
};

pub const RadioGroup = struct {
    count: usize,
    selected: usize,

    pub fn init(count: usize, initial: usize) RadioGroup {
        return .{
            .count = count,
            .selected = if (count == 0) 0 else @min(initial, count - 1),
        };
    }

    pub fn select(self: *RadioGroup, idx: usize) void {
        if (self.count == 0 or idx >= self.count) return;
        self.selected = idx;
    }

    pub fn selectNext(self: *RadioGroup) void {
        if (self.count == 0) return;
        if (self.selected >= self.count) self.selected = 0;
        self.selected = (self.selected + 1) % self.count;
    }

    pub fn selectPrev(self: *RadioGroup) void {
        if (self.count == 0) return;
        if (self.selected >= self.count) self.selected = 0;
        self.selected = if (self.selected == 0) self.count - 1 else self.selected - 1;
    }
};

pub const ToggleGroup = struct {
    count: usize,
    multi: bool,
    mask: u32 = 0,

    pub fn init(count: usize, multi: bool) ToggleGroup {
        return .{
            .count = @min(count, 32),
            .multi = multi,
            .mask = 0,
        };
    }

    pub fn toggle(self: *ToggleGroup, idx: usize) void {
        if (idx >= self.count or idx >= 32) return;
        const bit: u32 = @as(u32, 1) << @intCast(idx);
        if (self.multi) {
            self.mask ^= bit;
        } else {
            self.mask = if (self.mask == bit) 0 else bit;
        }
    }

    pub fn select(self: *ToggleGroup, idx: usize) void {
        if (idx >= self.count or idx >= 32) return;
        const bit: u32 = @as(u32, 1) << @intCast(idx);
        if (self.multi) {
            self.mask |= bit;
        } else {
            self.mask = bit;
        }
    }

    pub fn clear(self: *ToggleGroup) void {
        self.mask = 0;
    }

    pub fn isSelected(self: *const ToggleGroup, idx: usize) bool {
        if (idx >= self.count or idx >= 32) return false;
        const bit: u32 = @as(u32, 1) << @intCast(idx);
        return (self.mask & bit) != 0;
    }
};

pub const ToggleGroupSpec = struct {
    id: []const u8,
    labels: []const []const u8,
    group: *const ToggleGroup,
    disabled: bool = false,
    focused_idx: ?usize = null,
};

fn sanitizeNonNeg(v: f32) f32 {
    if (!std.math.isFinite(v) or v < 0.0) return 0.0;
    return v;
}

fn isValidRectAndScale(rect: core.Rect, scale: f32) bool {
    if (!std.math.isFinite(scale) or scale <= 0.0) return false;
    if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
        !std.math.isFinite(rect.w) or !std.math.isFinite(rect.h))
    {
        return false;
    }
    return rect.w > 0.0 and rect.h > 0.0;
}

fn isClipEmpty(clip: [4]f32) bool {
    for (clip) |v| {
        if (!std.math.isFinite(v)) return true;
    }
    return !(clip[2] > clip[0] and clip[3] > clip[1]);
}

fn intersectsClip(x0: f32, y0: f32, x1: f32, y1: f32, clip: [4]f32) bool {
    return x1 > clip[0] and x0 < clip[2] and y1 > clip[1] and y0 < clip[3];
}

fn pushQuad(out_buf: []core.QuadInstance, count: *usize, quad: core.QuadInstance, active_clip: [4]f32) void {
    if (count.* >= out_buf.len) return;
    for (quad.pos_size) |v| {
        if (!std.math.isFinite(v)) return;
    }
    if (quad.pos_size[2] <= 0.0 or quad.pos_size[3] <= 0.0) return;
    if (isClipEmpty(active_clip)) return;
    var q = quad;
    q.color = core.sanitizeColor(q.color);
    q.border_color = core.sanitizeColor(q.border_color);
    q.params[0] = sanitizeNonNeg(q.params[0]);
    q.params[1] = sanitizeNonNeg(q.params[1]);
    q.params[2] = sanitizeNonNeg(q.params[2]);
    const is_glyph = q.params[3] > 0.5;
    const pad: f32 = if (is_glyph) 0.0 else (q.params[2] * 1.5 + 2.0);
    if (!intersectsClip(
        q.pos_size[0] - pad,
        q.pos_size[1] - pad,
        q.pos_size[0] + q.pos_size[2] + pad,
        q.pos_size[1] + q.pos_size[3] + pad,
        active_clip,
    )) {
        return;
    }
    q.clip_rect = active_clip;
    out_buf[count.*] = q;
    count.* += 1;
}

fn contrastingOklabText(fill_ok: tokens.OklabColor) tokens.OklabColor {
    return if (fill_ok.l >= 0.58)
        .{ .l = 0.14, .a = 0.0, .b = 0.0, .alpha = 1.0 }
    else
        .{ .l = 0.98, .a = 0.0, .b = 0.0, .alpha = 1.0 };
}

fn applyDisabledOklab(c: *tokens.OklabColor) void {
    c.alpha = std.math.clamp(c.alpha * 0.55, 0.0, 1.0);
}

fn muteTextOklab(text_ok: *tokens.OklabColor, muted: tokens.OklabColor) void {
    text_ok.l = std.math.clamp(text_ok.l + (muted.l - text_ok.l) * 0.65, 0.0, 1.0);
    text_ok.a = std.math.clamp(text_ok.a + (muted.a - text_ok.a) * 0.65, -1.0, 1.0);
    text_ok.b = std.math.clamp(text_ok.b + (muted.b - text_ok.b) * 0.65, -1.0, 1.0);
    text_ok.alpha = std.math.clamp(text_ok.alpha + (muted.alpha - text_ok.alpha) * 0.65, 0.0, 1.0);
}

/// Resolves Oklab-derived fill, border, text, and geometry tokens for a `ButtonSpec`.
pub fn resolveButtonStyle(spec: ButtonSpec, tbl: *const tokens.TokenTable) tokens.ResolvedStyle {
    var fill_ok: tokens.OklabColor = switch (spec.variant) {
        .primary => tbl.accent_primary,
        .secondary => tbl.bg_elevated,
        .outline => .{ .l = tbl.bg_surface.l, .a = tbl.bg_surface.a, .b = tbl.bg_surface.b, .alpha = 0.0 },
        .ghost => .{ .l = tbl.bg_elevated.l, .a = tbl.bg_elevated.a, .b = tbl.bg_elevated.b, .alpha = 0.0 },
        .destructive => tbl.accent_danger,
    };
    var border_ok: tokens.OklabColor = switch (spec.variant) {
        .primary => tbl.accent_primary,
        .secondary, .outline => tbl.border_default,
        .ghost => .{ .l = tbl.border_default.l, .a = tbl.border_default.a, .b = tbl.border_default.b, .alpha = 0.0 },
        .destructive => tbl.accent_danger,
    };
    var text_ok: tokens.OklabColor = switch (spec.variant) {
        .primary, .destructive => contrastingOklabText(fill_ok),
        .secondary, .outline, .ghost => tbl.text_primary,
    };
    var accent_ok: tokens.OklabColor = switch (spec.variant) {
        .destructive => tbl.accent_danger,
        else => tbl.accent_primary,
    };
    var border_width: f32 = switch (spec.variant) {
        .ghost => 0.0,
        else => tbl.border_width_default,
    };
    const shadow_blur: f32 = switch (spec.variant) {
        .primary, .destructive => tbl.shadow_sm,
        .secondary, .outline, .ghost => 0.0,
    };

    if (!spec.disabled) {
        if (spec.pressed) {
            switch (spec.variant) {
                .outline, .ghost => {
                    fill_ok = tbl.bg_elevated;
                    fill_ok.alpha = 0.72;
                },
                else => {
                    fill_ok.l = std.math.clamp(fill_ok.l - 0.04, 0.0, 1.0);
                    if (spec.variant == .primary or spec.variant == .destructive) {
                        text_ok = contrastingOklabText(fill_ok);
                    }
                },
            }
        } else if (spec.hovered) {
            switch (spec.variant) {
                .outline, .ghost => {
                    fill_ok = tbl.bg_elevated;
                    fill_ok.alpha = 0.42;
                },
                else => {
                    fill_ok.l = std.math.clamp(fill_ok.l + 0.04, 0.0, 1.0);
                    if (spec.variant == .primary or spec.variant == .destructive) {
                        text_ok = contrastingOklabText(fill_ok);
                    }
                },
            }
        }
        if (spec.focused) {
            border_ok = tbl.border_focus;
            border_width = tbl.border_width_focus;
        }
    } else {
        applyDisabledOklab(&fill_ok);
        applyDisabledOklab(&border_ok);
        applyDisabledOklab(&accent_ok);
        muteTextOklab(&text_ok, tbl.text_muted);
    }

    return .{
        .fill = fill_ok.toSrgb(),
        .border = border_ok.toSrgb(),
        .text = text_ok.toSrgb(),
        .accent = accent_ok.toSrgb(),
        .corner_radius = tbl.corner_radius_md,
        .border_width = border_width,
        .shadow_blur = shadow_blur,
    };
}

/// Emits SDF quad(s) for a `ButtonSpec` with spring corner-radius shape morphing for `.pill` and `.circle`.
pub fn emitButton(
    spec: ButtonSpec,
    rect: core.Rect,
    scale: f32,
    tbl: *const tokens.TokenTable,
    pool: *anim.AnimationPool,
    out_quads: []core.QuadInstance,
    clip_rect: [4]f32,
) usize {
    if (!isValidRectAndScale(rect, scale) or out_quads.len == 0 or isClipEmpty(clip_rect)) return 0;

    const style = resolveButtonStyle(spec, tbl);
    const min_dim = @min(rect.w, rect.h);
    const radius: f32 = switch (spec.shape) {
        .rounded => @min(style.corner_radius, min_dim * 0.5),
        .pill, .circle => blk: {
            const target_r = if (spec.pressed and !spec.disabled) min_dim * 0.24 else min_dim * 0.5;
            const animated_r = pool.animateSpring(anim.hashKey(spec.id, "radius"), target_r, anim.SpringConfig.snappy);
            break :blk std.math.clamp(animated_r, 0.0, min_dim * 0.5);
        },
    };

    const phys = core.snapRectToPhysical(rect, scale);
    var count: usize = 0;
    pushQuad(out_quads, &count, .{
        .pos_size = .{ phys.x, phys.y, phys.w, phys.h },
        .color = style.fill,
        .border_color = style.border,
        .params = .{ radius * scale, style.border_width * scale, style.shadow_blur * scale, 0.0 },
    }, clip_rect);

    return count;
}

/// Emits a `ButtonGroupSpec` laying out items evenly along `spec.orientation`.
pub fn emitButtonGroup(
    spec: ButtonGroupSpec,
    rect: core.Rect,
    scale: f32,
    tbl: *const tokens.TokenTable,
    pool: *anim.AnimationPool,
    out_quads: []core.QuadInstance,
    clip_rect: [4]f32,
) usize {
    if (!isValidRectAndScale(rect, scale) or spec.items.len == 0 or out_quads.len == 0 or isClipEmpty(clip_rect)) return 0;

    const n = spec.items.len;
    const gap = if (spec.attached) 0.0 else sanitizeNonNeg(spec.gap);
    const total_gap = gap * @as(f32, @floatFromInt(n - 1));
    const n_f: f32 = @floatFromInt(n);

    var emitted: usize = 0;
    for (spec.items, 0..) |item, i| {
        if (emitted >= out_quads.len) break;
        const i_f: f32 = @floatFromInt(i);
        const item_rect: core.Rect = switch (spec.orientation) {
            .horizontal => blk: {
                const avail_w = @max(0.0, rect.w - total_gap);
                const cell_w = avail_w / n_f;
                break :blk .{
                    .x = rect.x + i_f * (cell_w + gap),
                    .y = rect.y,
                    .w = cell_w,
                    .h = rect.h,
                };
            },
            .vertical => blk: {
                const avail_h = @max(0.0, rect.h - total_gap);
                const cell_h = avail_h / n_f;
                break :blk .{
                    .x = rect.x,
                    .y = rect.y + i_f * (cell_h + gap),
                    .w = rect.w,
                    .h = cell_h,
                };
            },
        };
        emitted += emitButton(item, item_rect, scale, tbl, pool, out_quads[emitted..], clip_rect);
    }
    return emitted;
}

/// Emits outer rounded box + spring-animated check/indeterminate indicator quad for a `CheckboxSpec`.
pub fn emitCheckbox(
    spec: CheckboxSpec,
    rect: core.Rect,
    scale: f32,
    tbl: *const tokens.TokenTable,
    pool: *anim.AnimationPool,
    out_quads: []core.QuadInstance,
    clip_rect: [4]f32,
) usize {
    if (!isValidRectAndScale(rect, scale) or out_quads.len == 0 or isClipEmpty(clip_rect)) return 0;

    const side = @min(rect.w, rect.h);
    const box_rect = core.Rect{
        .x = rect.x + (rect.w - side) * 0.5,
        .y = rect.y + (rect.h - side) * 0.5,
        .w = side,
        .h = side,
    };

    const is_active = spec.state != .unchecked;
    var fill_ok = if (is_active) tbl.accent_primary else tbl.bg_surface;
    var border_ok = if (spec.focused and !spec.disabled)
        tbl.border_focus
    else if (is_active)
        tbl.accent_primary
    else
        tbl.border_default;
    const bw = if (spec.focused and !spec.disabled) tbl.border_width_focus else tbl.border_width_default;

    if (spec.disabled) {
        applyDisabledOklab(&fill_ok);
        applyDisabledOklab(&border_ok);
    }

    const box_radius = @min(tbl.corner_radius_sm, side * 0.35);
    const phys_box = core.snapRectToPhysical(box_rect, scale);

    var count: usize = 0;
    pushQuad(out_quads, &count, .{
        .pos_size = .{ phys_box.x, phys_box.y, phys_box.w, phys_box.h },
        .color = fill_ok.toSrgb(),
        .border_color = border_ok.toSrgb(),
        .params = .{ box_radius * scale, bw * scale, 0.0, 0.0 },
    }, clip_rect);

    const target_scale: f32 = if (is_active) 1.0 else 0.0;
    const anim_scale = std.math.clamp(
        pool.animateSpring(anim.hashKey(spec.id, "check"), target_scale, anim.SpringConfig.snappy),
        0.0,
        1.15,
    );

    if (anim_scale > 0.01 and count < out_quads.len) {
        var ind_ok = contrastingOklabText(tbl.accent_primary);
        if (spec.disabled) {
            applyDisabledOklab(&ind_ok);
        }
        const ind_rect: core.Rect = switch (spec.state) {
            .indeterminate => blk: {
                const w = side * 0.56 * anim_scale;
                const h = @min(side * 0.35, @max(@min(2.0, side * 0.35), side * 0.16)) * anim_scale;
                break :blk .{
                    .x = box_rect.x + (side - w) * 0.5,
                    .y = box_rect.y + (side - h) * 0.5,
                    .w = w,
                    .h = h,
                };
            },
            .checked, .unchecked => blk: {
                const s = side * 0.48 * anim_scale;
                break :blk .{
                    .x = box_rect.x + (side - s) * 0.5,
                    .y = box_rect.y + (side - s) * 0.5,
                    .w = s,
                    .h = s,
                };
            },
        };
        const ind_radius = if (spec.state == .indeterminate)
            ind_rect.h * 0.5
        else
            @min(tbl.corner_radius_sm * 0.5, ind_rect.h * 0.35);
        const phys_ind = core.snapRectToPhysical(ind_rect, scale);
        pushQuad(out_quads, &count, .{
            .pos_size = .{ phys_ind.x, phys_ind.y, phys_ind.w, phys_ind.h },
            .color = ind_ok.toSrgb(),
            .border_color = core.Nord.transparent,
            .params = .{ ind_radius * scale, 0.0, 0.0, 0.0 },
        }, clip_rect);
    }

    return count;
}

/// Emits pill track (with Oklab color morph) + spring-sliding circular thumb for a `SwitchSpec`.
pub fn emitSwitch(
    spec: SwitchSpec,
    rect: core.Rect,
    scale: f32,
    tbl: *const tokens.TokenTable,
    pool: *anim.AnimationPool,
    out_quads: []core.QuadInstance,
    clip_rect: [4]f32,
) usize {
    if (!isValidRectAndScale(rect, scale) or out_quads.len == 0 or isClipEmpty(clip_rect)) return 0;

    const target_track_color = if (spec.checked) tbl.accent_primary.toSrgb() else tbl.bg_elevated.toSrgb();
    var track_color = pool.animateColor(anim.hashKey(spec.id, "track"), target_track_color, anim.SpringConfig.snappy);

    var border_color = if (spec.focused and !spec.disabled)
        tbl.border_focus.toSrgb()
    else if (spec.checked)
        track_color
    else
        tbl.border_default.toSrgb();
    const bw = if (spec.focused and !spec.disabled) tbl.border_width_focus else tbl.border_width_default;

    if (spec.disabled) {
        track_color[3] *= 0.55;
        border_color[3] *= 0.55;
    }

    const track_r = @min(rect.w, rect.h) * 0.5;
    const phys_track = core.snapRectToPhysical(rect, scale);

    var count: usize = 0;
    pushQuad(out_quads, &count, .{
        .pos_size = .{ phys_track.x, phys_track.y, phys_track.w, phys_track.h },
        .color = track_color,
        .border_color = border_color,
        .params = .{ track_r * scale, bw * scale, 0.0, 0.0 },
    }, clip_rect);

    const thumb_t = std.math.clamp(
        pool.animateSpring(anim.hashKey(spec.id, "thumb"), if (spec.checked) 1.0 else 0.0, anim.SpringConfig.snappy),
        0.0,
        1.0,
    );

    const pad = @min(3.0, @min(rect.w, rect.h) * 0.15);
    const thumb_d = @max(0.0, @min(rect.w, rect.h) - pad * 2.0);
    if (thumb_d > 0.0 and count < out_quads.len) {
        const travel = @max(0.0, rect.w - pad * 2.0 - thumb_d);
        const thumb_x = rect.x + pad + travel * thumb_t;
        const thumb_y = rect.y + (rect.h - thumb_d) * 0.5;
        const phys_thumb = core.snapRectToPhysical(.{ .x = thumb_x, .y = thumb_y, .w = thumb_d, .h = thumb_d }, scale);

        var thumb_color = contrastingOklabText(tokens.OklabColor.fromSrgb(track_color)).toSrgb();
        if (spec.disabled) {
            thumb_color[3] *= 0.65;
        }
        pushQuad(out_quads, &count, .{
            .pos_size = .{ phys_thumb.x, phys_thumb.y, phys_thumb.w, phys_thumb.h },
            .color = thumb_color,
            .border_color = core.Nord.transparent,
            .params = .{ (thumb_d * 0.5) * scale, 0.0, 1.5 * scale, 0.0 },
        }, clip_rect);
    }

    return count;
}

/// Emits outer circular ring + spring-animated inner selection dot for a `RadioSpec`.
pub fn emitRadio(
    spec: RadioSpec,
    rect: core.Rect,
    scale: f32,
    tbl: *const tokens.TokenTable,
    pool: *anim.AnimationPool,
    out_quads: []core.QuadInstance,
    clip_rect: [4]f32,
) usize {
    if (!isValidRectAndScale(rect, scale) or out_quads.len == 0 or isClipEmpty(clip_rect)) return 0;

    const side = @min(rect.w, rect.h);
    const ring_rect = core.Rect{
        .x = rect.x + (rect.w - side) * 0.5,
        .y = rect.y + (rect.h - side) * 0.5,
        .w = side,
        .h = side,
    };

    var fill_ok = tbl.bg_surface;
    var border_ok = if (spec.focused and !spec.disabled)
        tbl.border_focus
    else if (spec.selected)
        tbl.accent_primary
    else
        tbl.border_default;
    const bw = if ((spec.focused or spec.selected) and !spec.disabled)
        tbl.border_width_focus
    else
        tbl.border_width_default;

    if (spec.disabled) {
        applyDisabledOklab(&fill_ok);
        applyDisabledOklab(&border_ok);
    }

    const phys_ring = core.snapRectToPhysical(ring_rect, scale);
    var count: usize = 0;
    pushQuad(out_quads, &count, .{
        .pos_size = .{ phys_ring.x, phys_ring.y, phys_ring.w, phys_ring.h },
        .color = fill_ok.toSrgb(),
        .border_color = border_ok.toSrgb(),
        .params = .{ (side * 0.5) * scale, bw * scale, 0.0, 0.0 },
    }, clip_rect);

    const dot_scale = std.math.clamp(
        pool.animateSpring(anim.hashKey(spec.id, "radio"), if (spec.selected) 1.0 else 0.0, anim.SpringConfig.snappy),
        0.0,
        1.15,
    );
    if (dot_scale > 0.01 and count < out_quads.len) {
        const dot_d = side * 0.5 * dot_scale;
        const dot_rect = core.Rect{
            .x = ring_rect.x + (side - dot_d) * 0.5,
            .y = ring_rect.y + (side - dot_d) * 0.5,
            .w = dot_d,
            .h = dot_d,
        };
        var dot_ok = tbl.accent_primary;
        if (spec.disabled) {
            applyDisabledOklab(&dot_ok);
        }
        const phys_dot = core.snapRectToPhysical(dot_rect, scale);
        pushQuad(out_quads, &count, .{
            .pos_size = .{ phys_dot.x, phys_dot.y, phys_dot.w, phys_dot.h },
            .color = dot_ok.toSrgb(),
            .border_color = core.Nord.transparent,
            .params = .{ (dot_d * 0.5) * scale, 0.0, 0.0, 0.0 },
        }, clip_rect);
    }

    return count;
}

/// Emits a segmented pill track and per-segment selection pills for a `ToggleGroupSpec`.
pub fn emitToggleGroup(
    spec: ToggleGroupSpec,
    rect: core.Rect,
    scale: f32,
    tbl: *const tokens.TokenTable,
    pool: *anim.AnimationPool,
    out_quads: []core.QuadInstance,
    clip_rect: [4]f32,
) usize {
    if (!isValidRectAndScale(rect, scale) or out_quads.len == 0 or isClipEmpty(clip_rect)) return 0;

    const seg_count = if (spec.labels.len > 0) @min(spec.group.count, spec.labels.len) else spec.group.count;
    if (seg_count == 0) return 0;

    var track_fill = tbl.bg_surface;
    var track_border = tbl.border_default;
    if (spec.disabled) {
        applyDisabledOklab(&track_fill);
        applyDisabledOklab(&track_border);
    }

    const track_r = @min(rect.w, rect.h) * 0.5;
    const phys_track = core.snapRectToPhysical(rect, scale);
    var count: usize = 0;
    pushQuad(out_quads, &count, .{
        .pos_size = .{ phys_track.x, phys_track.y, phys_track.w, phys_track.h },
        .color = track_fill.toSrgb(),
        .border_color = track_border.toSrgb(),
        .params = .{ track_r * scale, tbl.border_width_default * scale, 0.0, 0.0 },
    }, clip_rect);

    const pad = @min(3.0, @min(rect.w, rect.h) * 0.12);
    const inner_w = @max(0.0, rect.w - pad * 2.0);
    const inner_h = @max(0.0, rect.h - pad * 2.0);
    if (inner_w <= 0.0 or inner_h <= 0.0) return count;

    const seg_w = inner_w / @as(f32, @floatFromInt(seg_count));
    for (0..seg_count) |i| {
        if (count >= out_quads.len) break;
        const selected = spec.group.isSelected(i);
        const focused = if (spec.focused_idx) |fi| fi == i else false;

        const seg_key = anim.hashKey(spec.id, "seg") ^ (@as(u64, i) *% 0x9E3779B97F4A7C15);
        const target_alpha: f32 = if (selected) 1.0 else 0.0;
        const anim_a = std.math.clamp(
            pool.animateSpring(seg_key, target_alpha, anim.SpringConfig.snappy),
            0.0,
            1.0,
        );
        if (anim_a <= 0.01 and !(focused and !spec.disabled)) continue;

        var seg_fill = tbl.accent_primary;
        seg_fill.alpha *= anim_a;
        var seg_border = if (focused and !spec.disabled) tbl.border_focus else seg_fill;
        if (spec.disabled) {
            applyDisabledOklab(&seg_fill);
            applyDisabledOklab(&seg_border);
        }

        const seg_rect = core.Rect{
            .x = rect.x + pad + @as(f32, @floatFromInt(i)) * seg_w,
            .y = rect.y + pad,
            .w = seg_w,
            .h = inner_h,
        };
        const phys_seg = core.snapRectToPhysical(seg_rect, scale);
        const seg_r = @min(seg_rect.w, seg_rect.h) * 0.5;
        const bw = if (focused and !spec.disabled) tbl.border_width_focus else 0.0;
        pushQuad(out_quads, &count, .{
            .pos_size = .{ phys_seg.x, phys_seg.y, phys_seg.w, phys_seg.h },
            .color = seg_fill.toSrgb(),
            .border_color = seg_border.toSrgb(),
            .params = .{ seg_r * scale, bw * scale, 0.0, 0.0 },
        }, clip_rect);
    }

    return count;
}

test "Button: all variants, states, and input sanitization" {
    const tbl = tokens.TokenTable.nordDefault();
    var pool = anim.AnimationPool.init();
    var quads: [8]core.QuadInstance = undefined;
    const clip = [4]f32{ 0, 0, 500, 500 };

    const variants = [_]ButtonVariant{ .primary, .secondary, .outline, .ghost, .destructive };
    for (variants) |v| {
        const st = resolveButtonStyle(.{ .id = "b", .variant = v }, &tbl);
        try std.testing.expect(st.text[3] > 0.9);
        const n = emitButton(.{ .id = "b_emit", .variant = v, .shape = .circle }, .{ .x = 10, .y = 10, .w = 48, .h = 48 }, 2.0, &tbl, &pool, &quads, clip);
        try std.testing.expectEqual(@as(usize, 1), n);
    }

    // Invalid inputs emit 0 quads safely
    try std.testing.expectEqual(@as(usize, 0), emitButton(.{ .id = "bad" }, .{ .x = 0, .y = 0, .w = -5, .h = 20 }, 2.0, &tbl, &pool, &quads, clip));
    try std.testing.expectEqual(@as(usize, 0), emitButton(.{ .id = "bad" }, .{ .x = 0, .y = 0, .w = 20, .h = 20 }, 0.0, &tbl, &pool, &quads, clip));
    try std.testing.expectEqual(@as(usize, 0), emitButton(.{ .id = "bad" }, .{ .x = 0, .y = 0, .w = 20, .h = 20 }, 2.0, &tbl, &pool, quads[0..0], clip));
    try std.testing.expectEqual(@as(usize, 0), emitButton(.{ .id = "bad" }, .{ .x = 0, .y = 0, .w = 20, .h = 20 }, 2.0, &tbl, &pool, &quads, .{ 10, 10, 10, 20 }));
}

test "Checkbox, Switch, Radio, ButtonGroup & ToggleGroup behavior" {
    const tbl = tokens.TokenTable.nordDefault();
    var pool = anim.AnimationPool.init();
    var quads: [16]core.QuadInstance = undefined;
    const clip = [4]f32{ 0, 0, 600, 600 };

    // Checkbox transitions
    try std.testing.expectEqual(@as(usize, 1), emitCheckbox(.{ .id = "cb_t", .state = .unchecked }, .{ .x = 10, .y = 10, .w = 24, .h = 24 }, 2.0, &tbl, &pool, &quads, clip));
    try std.testing.expectEqual(@as(usize, 2), emitCheckbox(.{ .id = "cb_ind", .state = .indeterminate }, .{ .x = 10, .y = 10, .w = 24, .h = 24 }, 2.0, &tbl, &pool, &quads, clip));
    try std.testing.expect(quads[1].pos_size[2] > quads[1].pos_size[3]);

    // Radio emit
    try std.testing.expectEqual(@as(usize, 2), emitRadio(.{ .id = "rd1", .selected = true }, .{ .x = 10, .y = 40, .w = 24, .h = 24 }, 2.0, &tbl, &pool, &quads, clip));

    // ToggleGroup single-select & multi-select
    var tg_single = ToggleGroup.init(3, false);
    tg_single.toggle(0);
    try std.testing.expect(tg_single.isSelected(0));
    tg_single.toggle(2);
    try std.testing.expect(!tg_single.isSelected(0));
    try std.testing.expect(tg_single.isSelected(2));
    tg_single.toggle(2);
    try std.testing.expect(!tg_single.isSelected(2));

    var tg_multi = ToggleGroup.init(4, true);
    tg_multi.toggle(1);
    tg_multi.toggle(3);
    tg_multi.toggle(99); // out of bounds safe no-op
    try std.testing.expect(tg_multi.isSelected(1));
    try std.testing.expect(tg_multi.isSelected(3));
    try std.testing.expect(!tg_multi.isSelected(0));
    try std.testing.expect(!tg_multi.isSelected(99));

    const n_tg = emitToggleGroup(.{ .id = "tg1", .labels = &.{ "A", "B", "C", "D" }, .group = &tg_multi }, .{ .x = 10, .y = 80, .w = 200, .h = 36 }, 2.0, &tbl, &pool, &quads, clip);
    try std.testing.expectEqual(@as(usize, 3), n_tg);

    // ButtonGroup
    const items = [_]ButtonSpec{
        .{ .id = "bg_0", .label = "One", .variant = .secondary },
        .{ .id = "bg_1", .label = "Two", .variant = .primary },
    };
    const n_bg = emitButtonGroup(.{ .id = "bg", .items = &items }, .{ .x = 10, .y = 130, .w = 200, .h = 40 }, 2.0, &tbl, &pool, &quads, clip);
    try std.testing.expectEqual(@as(usize, 2), n_bg);
}
