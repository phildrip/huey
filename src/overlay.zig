const std = @import("std");
const core = @import("core.zig");
const wayland = @import("wayland.zig");

pub const MAX_OVERLAYS: usize = 16;

pub const AnchorRect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

pub const Placement = enum {
    bottom_start,
    bottom_end,
    top_start,
    top_end,
    right_start,
    left_start,
};

pub const PopupSpec = struct {
    anchor: AnchorRect = .{},
    width: f32 = 0,
    height: f32 = 0,
    placement: Placement = .bottom_start,
    gap: f32 = 0,
    flip_x: bool = true,
    flip_y: bool = true,
    slide_x: bool = true,
    slide_y: bool = true,
    modal: bool = false,
    bg_color: core.Color = core.Nord.polar_night_1,
    backdrop_color: core.Color = core.Nord.transparent,
    border_color: core.Color = core.Nord.transparent,
    corner_radius: f32 = 0,
    border_width: f32 = 0,
    shadow_blur: f32 = 0,
};

pub const OverlaySpec = PopupSpec;

pub const PlacedPopup = struct {
    rect: core.Rect,
    flipped_x: bool = false,
    flipped_y: bool = false,
    clamped: bool = false,
};

fn sanitizeFinite(v: f32) f64 {
    if (!std.math.isFinite(v)) return 0.0;
    return @as(f64, v);
}

fn sanitizeNonNeg(v: f32) f64 {
    if (!std.math.isFinite(v) or v < 0.0) return 0.0;
    return @as(f64, v);
}

fn toFiniteF32(v: f64) f32 {
    if (!std.math.isFinite(v)) return 0.0;
    const max_f: f64 = std.math.floatMax(f32);
    const f: f32 = @floatCast(std.math.clamp(v, -max_f, max_f));
    if (!std.math.isFinite(f) or f == 0.0) return 0.0;
    return f;
}

fn toNonNegF32(v: f64) f32 {
    const f = toFiniteF32(v);
    return if (f <= 0.0) 0.0 else f;
}

fn axisOverflow(pos: f64, size: f64, limit: f64) f64 {
    return @max(0.0, -pos) + @max(0.0, pos + size - limit);
}

/// Computes popup placement relative to `spec.anchor` inside `[0, viewport_w] x [0, viewport_h]`,
/// sanitizing NaN/Inf/negative inputs and applying viewport-edge flipping and sliding.
pub fn placePopup(spec: PopupSpec, viewport_w: f32, viewport_h: f32) PlacedPopup {
    const vw = sanitizeNonNeg(viewport_w);
    const vh = sanitizeNonNeg(viewport_h);

    var pw = sanitizeNonNeg(spec.width);
    var ph = sanitizeNonNeg(spec.height);

    if (vw <= 0.0 or vh <= 0.0) {
        return .{
            .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .flipped_x = false,
            .flipped_y = false,
            .clamped = (pw > 0.0 or ph > 0.0),
        };
    }

    const ax = sanitizeFinite(spec.anchor.x);
    const ay = sanitizeFinite(spec.anchor.y);
    const aw = sanitizeNonNeg(spec.anchor.w);
    const ah = sanitizeNonNeg(spec.anchor.h);
    const gap = sanitizeNonNeg(spec.gap);

    var clamped = false;
    if (pw > vw) {
        pw = vw;
        clamped = true;
    }
    if (ph > vh) {
        ph = vh;
        clamped = true;
    }

    var x: f64 = switch (spec.placement) {
        .bottom_start, .top_start => ax,
        .bottom_end, .top_end => ax + aw - pw,
        .right_start => ax + aw + gap,
        .left_start => ax - gap - pw,
    };

    var y: f64 = switch (spec.placement) {
        .bottom_start, .bottom_end => ay + ah + gap,
        .top_start, .top_end => ay - gap - ph,
        .right_start, .left_start => ay,
    };

    var flipped_x = false;
    var flipped_y = false;

    // Flip on Y axis only when flipping strictly reduces total edge overflow.
    if (spec.flip_y) {
        const alt_y: f64 = switch (spec.placement) {
            .bottom_start, .bottom_end => ay - gap - ph,
            .top_start, .top_end => ay + ah + gap,
            .right_start, .left_start => ay + ah - ph,
        };
        const orig_ov = axisOverflow(y, ph, vh);
        const alt_ov = axisOverflow(alt_y, ph, vh);
        if (orig_ov > 0.0 and alt_ov < orig_ov) {
            y = alt_y;
            flipped_y = true;
        }
    }

    // Flip on X axis only when flipping strictly reduces total edge overflow.
    if (spec.flip_x) {
        const alt_x: f64 = switch (spec.placement) {
            .bottom_start, .top_start => ax + aw - pw,
            .bottom_end, .top_end => ax,
            .right_start => ax - gap - pw,
            .left_start => ax + aw + gap,
        };
        const orig_ov = axisOverflow(x, pw, vw);
        const alt_ov = axisOverflow(alt_x, pw, vw);
        if (orig_ov > 0.0 and alt_ov < orig_ov) {
            x = alt_x;
            flipped_x = true;
        }
    }

    // Slide/clamp into [0, vw] x [0, vh].
    if (spec.slide_x) {
        const max_x = @max(0.0, vw - pw);
        const clamped_x = std.math.clamp(x, 0.0, max_x);
        if (clamped_x != x) {
            x = clamped_x;
            clamped = true;
        }
    }
    if (spec.slide_y) {
        const max_y = @max(0.0, vh - ph);
        const clamped_y = std.math.clamp(y, 0.0, max_y);
        if (clamped_y != y) {
            y = clamped_y;
            clamped = true;
        }
    }

    var x_f32 = toFiniteF32(x);
    var y_f32 = toFiniteF32(y);
    const w_f32 = toNonNegF32(pw);
    const h_f32 = toNonNegF32(ph);

    // Prevent f64->f32 round-to-even from nudging a slid popup past the viewport edge.
    if (spec.slide_x and @as(f64, x_f32) + @as(f64, w_f32) > vw and x_f32 > 0.0) {
        x_f32 = @max(0.0, std.math.nextAfter(f32, x_f32, -std.math.inf(f32)));
    }
    if (spec.slide_y and @as(f64, y_f32) + @as(f64, h_f32) > vh and y_f32 > 0.0) {
        y_f32 = @max(0.0, std.math.nextAfter(f32, y_f32, -std.math.inf(f32)));
    }

    return .{
        .rect = .{
            .x = x_f32,
            .y = y_f32,
            .w = w_f32,
            .h = h_f32,
        },
        .flipped_x = flipped_x,
        .flipped_y = flipped_y,
        .clamped = clamped,
    };
}

pub const OverlayEntry = struct {
    id: u32,
    spec: PopupSpec,
    placed: PlacedPopup,
    rect: core.Rect,
};

pub const OverlayManager = struct {
    entries: [MAX_OVERLAYS]OverlayEntry = undefined,
    count: usize = 0,
    next_id: u32 = 1,

    pub fn init() OverlayManager {
        return .{};
    }

    fn allocId(self: *OverlayManager) u32 {
        while (true) {
            const candidate = self.next_id;
            self.next_id = if (self.next_id == std.math.maxInt(u32)) 1 else self.next_id + 1;
            if (candidate != 0 and !self.isOpen(candidate)) {
                return candidate;
            }
        }
    }

    pub fn open(self: *OverlayManager, spec: PopupSpec, viewport_w: f32, viewport_h: f32) !u32 {
        if (self.count >= MAX_OVERLAYS) {
            return error.TooManyOverlays;
        }
        const placed = placePopup(spec, viewport_w, viewport_h);
        const id = self.allocId();
        self.entries[self.count] = .{
            .id = id,
            .spec = spec,
            .placed = placed,
            .rect = placed.rect,
        };
        self.count += 1;
        return id;
    }

    pub fn close(self: *OverlayManager, id: u32) bool {
        if (id == 0) return false;
        for (self.entries[0..self.count], 0..) |entry, i| {
            if (entry.id == id) {
                var j = i;
                while (j + 1 < self.count) : (j += 1) {
                    self.entries[j] = self.entries[j + 1];
                }
                self.count -= 1;
                return true;
            }
        }
        return false;
    }

    pub fn closeTop(self: *OverlayManager) bool {
        if (self.count == 0) return false;
        self.count -= 1;
        return true;
    }

    pub fn closeAll(self: *OverlayManager) void {
        self.count = 0;
    }

    pub fn isOpen(self: *const OverlayManager, id: u32) bool {
        if (id == 0) return false;
        for (self.entries[0..self.count]) |entry| {
            if (entry.id == id) return true;
        }
        return false;
    }

    pub fn activeCount(self: *const OverlayManager) usize {
        return self.count;
    }

    pub fn top(self: *const OverlayManager) ?*const OverlayEntry {
        if (self.count == 0) return null;
        return &self.entries[self.count - 1];
    }

    pub fn handleOutsideClick(self: *OverlayManager, x: f32, y: f32) bool {
        if (self.count == 0) return false;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
        const entry = self.entries[self.count - 1];
        if (!entry.spec.modal) return false;
        const r = entry.rect;
        const px = @as(f64, x);
        const py = @as(f64, y);
        const rx = @as(f64, r.x);
        const ry = @as(f64, r.y);
        const rw = @as(f64, r.w);
        const rh = @as(f64, r.h);
        const inside = rw > 0.0 and rh > 0.0 and
            px >= rx and px <= rx + rw and
            py >= ry and py <= ry + rh;
        if (inside) return false;
        _ = self.closeTop();
        return true;
    }

    /// Emits portal quads for all active overlays with full-viewport `clip_rect`
    /// escaping any parent scissor at scale 1.0.
    pub fn emitOverlayQuads(
        self: *const OverlayManager,
        viewport_w: f32,
        viewport_h: f32,
        out_quads: []core.QuadInstance,
    ) usize {
        return self.emitOverlayQuadsScaled(viewport_w, viewport_h, 1.0, out_quads);
    }

    /// Emits portal quads for all active overlays scaled by `scale_factor` into physical pixels,
    /// skipping zero-area overlays and emitting modal backdrop + surface atomically.
    pub fn emitOverlayQuadsScaled(
        self: *const OverlayManager,
        viewport_w: f32,
        viewport_h: f32,
        scale_factor: f32,
        out_quads: []core.QuadInstance,
    ) usize {
        if (!std.math.isFinite(viewport_w) or !std.math.isFinite(viewport_h) or
            viewport_w <= 0.0 or viewport_h <= 0.0)
        {
            return 0;
        }
        if (!std.math.isFinite(scale_factor) or scale_factor <= 0.0) {
            return 0;
        }
        const sf = @as(f64, scale_factor);
        const vw = toNonNegF32(@as(f64, viewport_w) * sf);
        const vh = toNonNegF32(@as(f64, viewport_h) * sf);
        if (vw <= 0.0 or vh <= 0.0) return 0;
        const full_clip: [4]f32 = .{ 0.0, 0.0, vw, vh };

        var out_count: usize = 0;
        for (self.entries[0..self.count]) |entry| {
            if (entry.rect.w <= 0.0 or entry.rect.h <= 0.0) continue;

            const backdrop = core.sanitizeColor(entry.spec.backdrop_color);
            const has_backdrop = entry.spec.modal and backdrop[3] > 0.0;
            const needed: usize = if (has_backdrop) 2 else 1;
            if (out_count + needed > out_quads.len) break;

            if (has_backdrop) {
                out_quads[out_count] = .{
                    .pos_size = .{ 0.0, 0.0, vw, vh },
                    .color = backdrop,
                    .border_color = core.Nord.transparent,
                    .params = .{ 0.0, 0.0, 0.0, 0.0 },
                    .clip_rect = full_clip,
                };
                out_count += 1;
            }

            out_quads[out_count] = .{
                .pos_size = .{
                    toFiniteF32(@as(f64, entry.rect.x) * sf),
                    toFiniteF32(@as(f64, entry.rect.y) * sf),
                    toNonNegF32(@as(f64, entry.rect.w) * sf),
                    toNonNegF32(@as(f64, entry.rect.h) * sf),
                },
                .color = core.sanitizeColor(entry.spec.bg_color),
                .border_color = core.sanitizeColor(entry.spec.border_color),
                .params = .{
                    toNonNegF32(sanitizeNonNeg(entry.spec.corner_radius) * sf),
                    toNonNegF32(sanitizeNonNeg(entry.spec.border_width) * sf),
                    toNonNegF32(sanitizeNonNeg(entry.spec.shadow_blur) * sf),
                    0.0,
                },
                .clip_rect = full_clip,
            };
            out_count += 1;
        }
        return out_count;
    }
};

// Wayland xdg_positioner & zwlr_layer_surface_v1.get_popup wire protocol encoders.

pub const XdgAnchor = enum(u32) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 3,
    right = 4,
    top_left = 5,
    bottom_left = 6,
    top_right = 7,
    bottom_right = 8,
};

pub const XdgGravity = enum(u32) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 3,
    right = 4,
    top_left = 5,
    bottom_left = 6,
    top_right = 7,
    bottom_right = 8,
};

pub const ConstraintAdjustment = packed struct(u32) {
    slide_x: bool = false,
    slide_y: bool = false,
    flip_x: bool = false,
    flip_y: bool = false,
    resize_x: bool = false,
    resize_y: bool = false,
    _pad: u26 = 0,
};

pub const XdgPositionerSpec = struct {
    width: i32,
    height: i32,
    anchor_x: i32,
    anchor_y: i32,
    anchor_w: i32,
    anchor_h: i32,
    anchor: XdgAnchor = .none,
    gravity: XdgGravity = .none,
    constraint_adjustment: ConstraintAdjustment = .{},
    offset_x: i32 = 0,
    offset_y: i32 = 0,
};

const XDG_POSITIONER_SET_SIZE: u16 = 1;
const XDG_POSITIONER_SET_ANCHOR_RECT: u16 = 2;
const XDG_POSITIONER_SET_ANCHOR: u16 = 3;
const XDG_POSITIONER_SET_GRAVITY: u16 = 4;
const XDG_POSITIONER_SET_CONSTRAINT_ADJUSTMENT: u16 = 5;
const XDG_POSITIONER_SET_OFFSET: u16 = 6;
const ZWLR_LAYER_SURFACE_GET_POPUP: u16 = 5;

pub fn encodeXdgPositioner(
    enc: *wayland.WireEncoder,
    positioner_id: u32,
    spec: XdgPositionerSpec,
) !void {
    if (enc.msg_open and enc.pos > enc.msg_start + 8) return error.MessageAlreadyOpen;
    if (positioner_id == 0) return error.InvalidObjectId;
    if (spec.width <= 0 or spec.height <= 0) return error.InvalidSize;
    if (spec.anchor_w <= 0 or spec.anchor_h <= 0) return error.InvalidAnchorRect;

    const saved_pos = enc.pos;
    const saved_start = enc.msg_start;
    const saved_open = enc.msg_open;
    errdefer {
        enc.pos = saved_pos;
        enc.msg_start = saved_start;
        enc.msg_open = saved_open;
    }

    // 1. set_size(width, height)
    try enc.writeI32(spec.width);
    try enc.writeI32(spec.height);
    _ = try enc.finish(positioner_id, XDG_POSITIONER_SET_SIZE);

    // 2. set_anchor_rect(x, y, width, height)
    try enc.writeI32(spec.anchor_x);
    try enc.writeI32(spec.anchor_y);
    try enc.writeI32(spec.anchor_w);
    try enc.writeI32(spec.anchor_h);
    _ = try enc.finish(positioner_id, XDG_POSITIONER_SET_ANCHOR_RECT);

    // 3. set_anchor(anchor)
    try enc.writeU32(@backingInt(spec.anchor));
    _ = try enc.finish(positioner_id, XDG_POSITIONER_SET_ANCHOR);

    // 4. set_gravity(gravity)
    try enc.writeU32(@backingInt(spec.gravity));
    _ = try enc.finish(positioner_id, XDG_POSITIONER_SET_GRAVITY);

    // 5. set_constraint_adjustment(constraint_adjustment)
    try enc.writeU32(@as(u32, @bitCast(spec.constraint_adjustment)) & 0x3F);
    _ = try enc.finish(positioner_id, XDG_POSITIONER_SET_CONSTRAINT_ADJUSTMENT);

    // 6. set_offset(x, y)
    try enc.writeI32(spec.offset_x);
    try enc.writeI32(spec.offset_y);
    _ = try enc.finish(positioner_id, XDG_POSITIONER_SET_OFFSET);
}

pub fn encodeLayerGetPopup(
    enc: *wayland.WireEncoder,
    layer_surface_id: u32,
    popup_id: u32,
) !void {
    if (enc.msg_open and enc.pos > enc.msg_start + 8) return error.MessageAlreadyOpen;
    if (layer_surface_id == 0 or popup_id == 0 or layer_surface_id == popup_id) return error.InvalidObjectId;

    const saved_pos = enc.pos;
    const saved_start = enc.msg_start;
    const saved_open = enc.msg_open;
    errdefer {
        enc.pos = saved_pos;
        enc.msg_start = saved_start;
        enc.msg_open = saved_open;
    }

    try enc.writeU32(popup_id);
    _ = try enc.finish(layer_surface_id, ZWLR_LAYER_SURFACE_GET_POPUP);
}

test "placePopup: covers all placements, Inf/negative sanitization, and flip/slide toggles" {
    // top_start flips down when overflowing top
    const top_flip = placePopup(.{
        .anchor = .{ .x = 50, .y = 10, .w = 80, .h = 24 },
        .width = 120,
        .height = 100,
        .placement = .top_start,
        .gap = 4,
    }, 800, 600);
    try std.testing.expect(top_flip.flipped_y);
    try std.testing.expectApproxEqAbs(@as(f32, 38), top_flip.rect.y, 0.01);

    // right_start flips left when overflowing right
    const right_flip = placePopup(.{
        .anchor = .{ .x = 700, .y = 100, .w = 40, .h = 30 },
        .width = 150,
        .height = 80,
        .placement = .right_start,
        .gap = 6,
    }, 800, 600);
    try std.testing.expect(right_flip.flipped_x);
    try std.testing.expectApproxEqAbs(@as(f32, 544), right_flip.rect.x, 0.01);

    // left_start flips right when overflowing left
    const left_flip = placePopup(.{
        .anchor = .{ .x = 20, .y = 100, .w = 40, .h = 30 },
        .width = 150,
        .height = 80,
        .placement = .left_start,
        .gap = 6,
    }, 800, 600);
    try std.testing.expect(left_flip.flipped_x);
    try std.testing.expectApproxEqAbs(@as(f32, 66), left_flip.rect.x, 0.01);

    // Inf and negative dimensions sanitize cleanly
    const inf_res = placePopup(.{
        .anchor = .{ .x = -std.math.inf(f32), .y = std.math.inf(f32), .w = -10, .h = -5 },
        .width = -50,
        .height = std.math.inf(f32),
        .gap = -4,
    }, -100, std.math.nan(f32));
    try std.testing.expect(std.math.isFinite(inf_res.rect.x));
    try std.testing.expect(std.math.isFinite(inf_res.rect.y));
    try std.testing.expectEqual(@as(f32, 0), inf_res.rect.w);
    try std.testing.expectEqual(@as(f32, 0), inf_res.rect.h);
}

test "OverlayManager: stack operations, capacity limit, and NaN-safe outside click" {
    var mgr = OverlayManager.init();
    try std.testing.expect(mgr.top() == null);
    try std.testing.expect(!mgr.closeTop());
    try std.testing.expect(!mgr.close(0));

    var ids: [MAX_OVERLAYS]u32 = undefined;
    for (&ids, 0..) |*slot, i| {
        slot.* = try mgr.open(.{
            .anchor = .{ .x = @floatFromInt(i * 10), .y = 20, .w = 40, .h = 20 },
            .width = 100,
            .height = 60,
        }, 1280, 720);
        try std.testing.expect(slot.* != 0);
        try std.testing.expect(mgr.isOpen(slot.*));
    }
    try std.testing.expectEqual(MAX_OVERLAYS, mgr.activeCount());
    try std.testing.expectError(error.TooManyOverlays, mgr.open(.{}, 1280, 720));

    // NaN click must not dismiss top overlay
    try std.testing.expect(!mgr.handleOutsideClick(std.math.nan(f32), 10));
    try std.testing.expectEqual(MAX_OVERLAYS, mgr.activeCount());

    // Close middle entry preserves top
    const middle_id = ids[5];
    const top_id = ids[MAX_OVERLAYS - 1];
    try std.testing.expect(mgr.close(middle_id));
    try std.testing.expect(!mgr.isOpen(middle_id));
    try std.testing.expectEqual(top_id, mgr.top().?.id);

    mgr.closeAll();
    try std.testing.expectEqual(@as(usize, 0), mgr.activeCount());
    try std.testing.expect(mgr.top() == null);
}

test "XdgPositioner: decodes all 7 wire frames and validates constraints" {
    var buf: [256]u8 = undefined;
    var enc = wayland.WireEncoder.init(&buf);

    try std.testing.expectError(error.InvalidSize, encodeXdgPositioner(&enc, 42, .{
        .width = 0,
        .height = 100,
        .anchor_x = 0,
        .anchor_y = 0,
        .anchor_w = 10,
        .anchor_h = 10,
    }));
    try std.testing.expectError(error.InvalidAnchorRect, encodeXdgPositioner(&enc, 42, .{
        .width = 100,
        .height = 100,
        .anchor_x = 0,
        .anchor_y = 0,
        .anchor_w = 10,
        .anchor_h = 0,
    }));
    try std.testing.expectEqual(@as(usize, 0), enc.written().len);

    try encodeXdgPositioner(&enc, 42, .{
        .width = 200,
        .height = 160,
        .anchor_x = 12,
        .anchor_y = -4,
        .anchor_w = 80,
        .anchor_h = 28,
        .anchor = .bottom_left,
        .gravity = .bottom_right,
        .constraint_adjustment = .{ .flip_x = true, .flip_y = true, .slide_x = true },
        .offset_x = 2,
        .offset_y = 4,
    });
    try encodeLayerGetPopup(&enc, 10, 43);

    const bytes = enc.written();
    try std.testing.expectEqual(@as(usize, 104), bytes.len);

    var off: usize = 0;
    // 1. set_size
    var d1 = try wayland.WireDecoder.init(bytes[off..]);
    try std.testing.expectEqual(@as(u16, 1), d1.opcode);
    try std.testing.expectEqual(@as(i32, 200), try d1.readI32());
    try std.testing.expectEqual(@as(i32, 160), try d1.readI32());
    off += d1.size;
    // 2. set_anchor_rect
    var d2 = try wayland.WireDecoder.init(bytes[off..]);
    try std.testing.expectEqual(@as(u16, 2), d2.opcode);
    try std.testing.expectEqual(@as(i32, 12), try d2.readI32());
    try std.testing.expectEqual(@as(i32, -4), try d2.readI32());
    try std.testing.expectEqual(@as(i32, 80), try d2.readI32());
    try std.testing.expectEqual(@as(i32, 28), try d2.readI32());
    off += d2.size;
    // 3. set_anchor
    var d3 = try wayland.WireDecoder.init(bytes[off..]);
    try std.testing.expectEqual(@as(u16, 3), d3.opcode);
    try std.testing.expectEqual(@as(u32, 6), try d3.readU32());
    off += d3.size;
    // 4. set_gravity
    var d4 = try wayland.WireDecoder.init(bytes[off..]);
    try std.testing.expectEqual(@as(u16, 4), d4.opcode);
    try std.testing.expectEqual(@as(u32, 8), try d4.readU32());
    off += d4.size;
    // 5. set_constraint_adjustment (slide_x=1 | flip_x=4 | flip_y=8 = 13)
    var d5 = try wayland.WireDecoder.init(bytes[off..]);
    try std.testing.expectEqual(@as(u16, 5), d5.opcode);
    try std.testing.expectEqual(@as(u32, 13), try d5.readU32());
    off += d5.size;
    // 6. set_offset
    var d6 = try wayland.WireDecoder.init(bytes[off..]);
    try std.testing.expectEqual(@as(u16, 6), d6.opcode);
    try std.testing.expectEqual(@as(i32, 2), try d6.readI32());
    try std.testing.expectEqual(@as(i32, 4), try d6.readI32());
    off += d6.size;
    // 7. zwlr_layer_surface_v1.get_popup
    var d7 = try wayland.WireDecoder.init(bytes[off..]);
    try std.testing.expectEqual(@as(u32, 10), d7.object_id);
    try std.testing.expectEqual(@as(u16, 5), d7.opcode);
    try std.testing.expectEqual(@as(u32, 43), try d7.readU32());
    off += d7.size;

    try std.testing.expectEqual(bytes.len, off);
}
