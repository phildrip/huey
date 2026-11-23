const std = @import("std");
const huey = @import("huey");
const core = huey.core;
const events = huey.events;
const overlay = huey.overlay;
const wearos = huey.wearos;
const hold_confirm = huey.hold_confirm;
const glyph_atlas = huey.glyph_atlas;
const animation = huey.animation;
const android_platform = huey.android_platform;

pub const ACCENTS = [_][4]f32{
    core.Nord.frost_1, // #88C0D0 Nord Frost
    core.Nord.aurora_green, // #A3BE8C Aurora Green
    core.Nord.aurora_purple, // #B48EAD Aurora Purple
    core.Nord.aurora_orange, // #D08770 Aurora Orange
};

const ACCENT_IDS = [_][]const u8{
    "wear_accent_0",
    "wear_accent_1",
    "wear_accent_2",
    "wear_accent_3",
};

const FRAME_BUDGET_MS: f32 = 16.67;

fn sanitizePositive(v: f32, fallback: f32) f32 {
    if (!std.math.isFinite(v) or v <= 0.0) return fallback;
    return v;
}

fn sanitizeUnit(v: f32) f32 {
    if (!std.math.isFinite(v) or v <= 0.0) return 0.0;
    if (v >= 1.0) return 1.0;
    return v;
}

fn sanitizeFrameMs(v: f32) f32 {
    if (!std.math.isFinite(v) or v < 0.0) return 0.0;
    return v;
}

fn parseIndexSuffix(test_id: []const u8, prefix: []const u8, max_count: usize) ?usize {
    if (!std.mem.startsWith(u8, test_id, prefix)) return null;
    const tail = test_id[prefix.len..];
    if (tail.len == 0) return null;
    const val = std.fmt.parseInt(usize, tail, 10) catch return null;
    if (val >= max_count) return null;
    return val;
}

pub const WearShowcaseApp = struct {
    locked: bool = true,
    trunk_open: bool = false,
    frunk_hold: hold_confirm.HoldToConfirm = hold_confirm.HoldToConfirm.init(1.5),
    frunk_open: bool = false,
    accent_idx: u8 = 0,
    wear_ambient: bool = false,
    counter: i32 = 42,
    slider_value: f32 = 0.68,

    overlays: overlay.OverlayManager = overlay.OverlayManager.init(),
    anims: animation.AnimationPool = animation.AnimationPool.init(),
    scroll_container: ?core.NodeId = null,
    scroll_progress: f32 = 0.0,
    last_frame_ms: f32 = 1.8,
    last_quad_count: usize = 0,
    pending_haptic: ?android_platform.HapticKind = null,

    stats_buf: [64]u8 = undefined,
    counter_buf: [32]u8 = undefined,
    slider_buf: [32]u8 = undefined,

    pub fn init() WearShowcaseApp {
        return .{};
    }

    pub fn isAnimating(self: *const WearShowcaseApp) bool {
        return self.anims.isAnimating() or (!self.wear_ambient and self.frunk_hold.isAnimating());
    }

    pub fn stepAnimations(self: *WearShowcaseApp, dt_s: f32) bool {
        const anim_active = self.anims.step(dt_s);
        if (self.wear_ambient) {
            self.frunk_hold.reset();
            return anim_active;
        }
        if (self.frunk_hold.step(dt_s)) {
            self.frunk_open = !self.frunk_open;
            self.pending_haptic = .double_pulse;
            self.triggerBezelPulse();
        }
        return anim_active or self.frunk_hold.isAnimating();
    }

    pub fn takePendingHaptic(self: *WearShowcaseApp) ?android_platform.HapticKind {
        const h = self.pending_haptic;
        self.pending_haptic = null;
        return h;
    }

    pub fn accent(self: *const WearShowcaseApp) core.Color {
        const idx = @min(@as(usize, self.accent_idx), ACCENTS.len - 1);
        return ACCENTS[idx];
    }

    pub fn buildScene(self: *WearShowcaseApp, arena: *core.LayoutArena, logical_w: f32, logical_h: f32) !void {
        const vw = sanitizePositive(logical_w, 233.0);
        const vh = sanitizePositive(logical_h, 233.0);

        arena.reset();
        self.scroll_container = null;

        const cur_accent = self.anims.animateColor(
            animation.hashKey("theme", "accent"),
            self.accent(),
            animation.SpringConfig.gentle,
        );
        const safe = wearos.WearConfig.init(vw, vh, true, 0.0).safeRect();
        const body_pad = @max(12.0, safe.x);

        const safe_ms = sanitizeFrameMs(self.last_frame_ms);
        const fps: u32 = if (safe_ms <= FRAME_BUDGET_MS)
            60
        else
            @max(1, @as(u32, @intFromFloat(@round(1000.0 / safe_ms))));

        const stats_str = if (safe_ms > 99999.0)
            std.fmt.bufPrint(&self.stats_buf, "1 FPS | >99s", .{}) catch "1 FPS"
        else
            std.fmt.bufPrint(&self.stats_buf, "{d} FPS | {d:.1} ms", .{ fps, safe_ms }) catch "60 FPS";

        const root = try arena.addNode(.{
            .kind = .vstack,
            .role = .container,
            .test_id = "wear.root",
            .fill = .{ 0.0, 0.0, 0.0, 1.0 },
            .clip_children = true,
        });

        const body_id = try arena.addChild(root, .{
            .kind = .vstack,
            .role = .container,
            .test_id = "wear.body",
            .flex = 1.0,
            .padding = body_pad,
            .gap = 10.0,
            .clip_children = true,
            .fill = core.Nord.transparent,
        });
        self.scroll_container = body_id;

        // Card 1: Tesla Key Preview
        const lock_col = self.anims.animateColor(
            animation.hashKey("wear", "lock_color"),
            if (self.locked) self.accent() else core.Nord.aurora_green,
            animation.SpringConfig.snappy,
        );
        const lock_label = if (self.locked) "LOCKED" else "UNLOCKED";
        const tesla_card = try arena.addChild(body_id, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_tesla_card",
            .height = 164.0,
            .padding = 10.0,
            .gap = 8.0,
            .corner_radius = 18.0,
            .border_width = 1.5,
            .shadow_blur = 6.0,
            .fill = core.Nord.polar_night_1,
            .border = lock_col,
        });
        _ = try arena.addChild(tesla_card, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_tesla_header",
            .label = "MODEL Y",
            .sublabel = lock_label,
            .font_size = 14.0,
            .text_color = core.Nord.snow_storm_2,
            .height = 36.0,
            .fill = core.Nord.transparent,
        });
        _ = try arena.addChild(tesla_card, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_lock",
            .label = lock_label,
            .font_size = 15.0,
            .text_color = core.Nord.polar_night_0,
            .height = 48.0,
            .corner_radius = 24.0,
            .border_width = 1.5,
            .fill = lock_col,
            .border = lock_col,
            .focusable = true,
        });
        const action_row = try arena.addChild(tesla_card, .{
            .kind = .hstack,
            .role = .container,
            .gap = 8.0,
            .height = 44.0,
        });
        _ = try arena.addChild(action_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_trunk",
            .label = if (self.trunk_open) "OPEN" else "TRUNK",
            .font_size = 12.5,
            .text_color = if (self.trunk_open) core.Nord.polar_night_0 else core.Nord.snow_storm_2,
            .height = 44.0,
            .corner_radius = 22.0,
            .border_width = 1.5,
            .fill = if (self.trunk_open) core.Nord.aurora_orange else core.Nord.polar_night_2,
            .border = if (self.trunk_open) core.Nord.aurora_orange else cur_accent,
            .focusable = true,
        });
        const frunk_label = if (self.frunk_hold.holding)
            "HOLD..."
        else if (self.frunk_open)
            "OPEN!"
        else
            "FRUNK";
        const frunk_fill = if (self.frunk_hold.holding)
            core.Nord.aurora_orange
        else if (self.frunk_open)
            core.Nord.aurora_green
        else
            core.Nord.polar_night_2;
        const frunk_border = if (self.frunk_hold.holding)
            core.Nord.aurora_orange
        else if (self.frunk_open)
            core.Nord.aurora_green
        else
            cur_accent;
        const frunk_text_color = if (self.frunk_hold.holding or self.frunk_open)
            core.Nord.polar_night_0
        else
            core.Nord.snow_storm_2;
        _ = try arena.addChild(action_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_frunk",
            .label = frunk_label,
            .font_size = 12.5,
            .text_color = frunk_text_color,
            .height = 44.0,
            .corner_radius = 22.0,
            .border_width = 1.5,
            .fill = frunk_fill,
            .border = frunk_border,
            .focusable = true,
        });

        // Card 2: Nord Theme & OLED Ambient
        const theme_card = try arena.addChild(body_id, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_theme_card",
            .height = 138.0,
            .padding = 10.0,
            .gap = 8.0,
            .corner_radius = 18.0,
            .border_width = 1.5,
            .shadow_blur = 6.0,
            .fill = core.Nord.polar_night_1,
            .border = cur_accent,
        });
        _ = try arena.addChild(theme_card, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_theme_header",
            .label = "Nord & OLED",
            .font_size = 13.0,
            .text_color = core.Nord.snow_storm_2,
            .height = 20.0,
            .fill = core.Nord.transparent,
        });
        const swatch_row = try arena.addChild(theme_card, .{
            .kind = .hstack,
            .role = .container,
            .gap = 6.0,
            .height = 36.0,
        });
        for (0..ACCENTS.len) |i| {
            _ = try arena.addChild(swatch_row, .{
                .kind = .toggle,
                .role = .swatch,
                .test_id = ACCENT_IDS[i],
                .height = 36.0,
                .corner_radius = 18.0,
                .border_width = 1.5,
                .fill = ACCENTS[i],
                .border = core.Nord.polar_night_3,
                .accent = ACCENTS[i],
                .checked = (self.accent_idx == i),
            });
        }
        _ = try arena.addChild(theme_card, .{
            .kind = .toggle,
            .role = .switch_control,
            .test_id = "wear_ambient",
            .label = "Ambient",
            .font_size = 12.0,
            .text_color = core.Nord.snow_storm_2,
            .height = 46.0,
            .corner_radius = 14.0,
            .border_width = 1.5,
            .fill = core.Nord.polar_night_0,
            .border = if (self.wear_ambient) cur_accent else core.Nord.polar_night_3,
            .accent = cur_accent,
            .checked = self.wear_ambient,
        });

        // Card 3: Live 60Hz Telemetry & Counter
        const stats_card = try arena.addChild(body_id, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_stats_card",
            .height = 158.0,
            .padding = 10.0,
            .gap = 8.0,
            .corner_radius = 18.0,
            .border_width = 1.5,
            .shadow_blur = 6.0,
            .fill = core.Nord.polar_night_1,
            .border = core.Nord.polar_night_3,
        });
        _ = try arena.addChild(stats_card, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_stats",
            .label = stats_str,
            .font_size = 13.0,
            .text_color = cur_accent,
            .height = 24.0,
            .fill = core.Nord.transparent,
        });
        const counter_row = try arena.addChild(stats_card, .{
            .kind = .hstack,
            .role = .container,
            .gap = 8.0,
            .height = 44.0,
        });
        const btn_w = @min(44.0, @max(28.0, (safe.w - 44.0) * 0.4));
        _ = try arena.addChild(counter_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_dec",
            .label = "-",
            .font_size = 18.0,
            .text_color = core.Nord.snow_storm_2,
            .width = btn_w,
            .height = 44.0,
            .corner_radius = 12.0,
            .border_width = 1.5,
            .fill = core.Nord.polar_night_2,
            .border = core.Nord.polar_night_3,
            .focusable = true,
        });
        const counter_str = std.fmt.bufPrint(&self.counter_buf, "{d}", .{self.counter}) catch "42";
        _ = try arena.addChild(counter_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_counter",
            .label = counter_str,
            .font_size = 18.0,
            .text_color = cur_accent,
            .height = 44.0,
            .corner_radius = 12.0,
            .border_width = 1.0,
            .fill = core.Nord.polar_night_0,
            .border = core.Nord.polar_night_3,
        });
        _ = try arena.addChild(counter_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_inc",
            .label = "+",
            .font_size = 18.0,
            .text_color = core.Nord.snow_storm_2,
            .width = btn_w,
            .height = 44.0,
            .corner_radius = 12.0,
            .border_width = 1.5,
            .fill = core.Nord.polar_night_2,
            .border = cur_accent,
            .focusable = true,
        });

        const safe_slider = sanitizeUnit(self.slider_value);
        const pct: u32 = @intFromFloat(@round(safe_slider * 100.0));
        const slider_str = std.fmt.bufPrint(&self.slider_buf, "Level: {d}%", .{pct}) catch "Level";
        _ = try arena.addChild(stats_card, .{
            .kind = .slider,
            .role = .slider,
            .test_id = "wear_slider",
            .label = slider_str,
            .font_size = 12.0,
            .text_color = core.Nord.snow_storm_1,
            .height = 54.0,
            .corner_radius = 12.0,
            .border_width = 1.5,
            .fill = core.Nord.polar_night_0,
            .border = core.Nord.polar_night_3,
            .accent = cur_accent,
            .slider_val = safe_slider,
        });
    }

    pub fn onWearPointerDown(self: *WearShowcaseApp, arena: *const core.LayoutArena, pointer_id: i32, x: f32, y: f32) bool {
        if (self.wear_ambient) return false;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
        if (self.overlays.activeCount() > 0) return false;
        const frunk_id = arena.findByTestId("wear_frunk") orelse return false;
        const hit_id = arena.hitTest(x, y) orelse return false;
        if (hit_id.index == frunk_id.index and hit_id.gen == frunk_id.gen) {
            if (!self.frunk_hold.holding) {
                self.frunk_hold.beginHold(pointer_id);
            }
            return true;
        }
        return false;
    }

    pub fn onWearPointerMove(self: *WearShowcaseApp, arena: *const core.LayoutArena, pointer_id: i32, x: f32, y: f32) void {
        if (!self.frunk_hold.holding) return;
        const bounds = if (arena.findByTestId("wear_frunk")) |nid|
            (arena.getRect(nid) orelse core.Rect{})
        else
            core.Rect{};
        self.frunk_hold.updatePointerMove(pointer_id, x, y, bounds);
    }

    pub fn onWearPointerUp(self: *WearShowcaseApp, pointer_id: i32) void {
        self.frunk_hold.endHold(pointer_id);
    }

    pub fn onWearPointerCancel(self: *WearShowcaseApp) void {
        self.frunk_hold.cancel();
    }

    pub fn handlePointerDown(self: *WearShowcaseApp, x: f32, y: f32) bool {
        if (self.overlays.activeCount() == 0) return false;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
        return self.overlays.handleOutsideClick(x, y);
    }

    fn triggerBezelPulse(self: *WearShowcaseApp) void {
        self.anims.restartSpring(
            animation.hashKey("wear", "bezel_w"),
            5.0,
            2.0,
            animation.SpringConfig.snappy,
        );
    }

    fn applyIdAction(self: *WearShowcaseApp, test_id: []const u8, toggled_val: ?bool) bool {
        if (std.mem.eql(u8, test_id, "wear_lock")) {
            self.locked = !self.locked;
            self.triggerBezelPulse();
            return true;
        }
        if (std.mem.eql(u8, test_id, "wear_trunk")) {
            self.trunk_open = !self.trunk_open;
            self.triggerBezelPulse();
            return true;
        }
        if (parseIndexSuffix(test_id, "wear_accent_", ACCENTS.len)) |idx| {
            self.accent_idx = @intCast(idx);
            return true;
        }
        if (std.mem.eql(u8, test_id, "wear_ambient")) {
            self.wear_ambient = toggled_val orelse !self.wear_ambient;
            self.anims.setReducedMotion(self.wear_ambient);
            if (self.wear_ambient) {
                self.frunk_hold.reset();
            }
            return true;
        }
        if (std.mem.eql(u8, test_id, "wear_dec")) {
            if (self.counter > std.math.minInt(i32)) self.counter -= 1;
            return true;
        }
        if (std.mem.eql(u8, test_id, "wear_inc")) {
            if (self.counter < std.math.maxInt(i32)) self.counter += 1;
            return true;
        }
        return false;
    }

    pub fn handleUiEvent(self: *WearShowcaseApp, ev: events.UiEvent, logical_w: f32, logical_h: f32) bool {
        _ = logical_w;
        _ = logical_h;
        switch (ev) {
            .clicked => |c| return self.applyIdAction(c.test_id, null),
            .toggled => |t| return self.applyIdAction(t.test_id, t.checked),
            .changed_f32 => |ch| {
                if (std.mem.eql(u8, ch.test_id, "wear_slider")) {
                    if (std.math.isFinite(ch.value)) {
                        self.slider_value = sanitizeUnit(ch.value);
                        return true;
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn emitPostQuads(
        self: *WearShowcaseApp,
        arena: *const core.LayoutArena,
        out_quads: []core.QuadInstance,
        start_idx: usize,
        logical_w: f32,
        logical_h: f32,
        scale_factor: f32,
        atlas: ?*glyph_atlas.GlyphAtlas,
        frame_idx: u64,
    ) usize {
        _ = atlas;
        _ = frame_idx;
        const safe_start = @min(start_idx, out_quads.len);
        if (!std.math.isFinite(logical_w) or !std.math.isFinite(logical_h) or
            logical_w <= 0.0 or logical_h <= 0.0 or
            !std.math.isFinite(scale_factor) or scale_factor <= 0.0)
        {
            return safe_start;
        }
        const s = scale_factor;
        const vw = logical_w;
        const vh = logical_h;
        const vw_px = vw * s;
        const vh_px = vh * s;
        if (!std.math.isFinite(vw_px) or !std.math.isFinite(vh_px) or vw_px <= 0.0 or vh_px <= 0.0) {
            return safe_start;
        }

        const ring_dim = @min(vw, vh);
        if (safe_start > 0 and ring_dim > 0.0) {
            const vp_cx_px = vw * 0.5 * s;
            const vp_cy_px = vh * 0.5 * s;
            const radius_px = ring_dim * 0.5 * s;
            const bg_thresh_f64: f64 = @as(f64, radius_px) * 1.95;

            const CardGroup = struct {
                y0: f32,
                y1: f32,
                cy: f32,
                metrics: wearos.CurvedMetrics,
            };
            const card_ids = [_][]const u8{ "wear_tesla_card", "wear_theme_card", "wear_stats_card" };
            var groups: [card_ids.len]CardGroup = undefined;
            var group_count: usize = 0;

            for (card_ids) |cid| {
                if (arena.findByTestId(cid)) |nid| {
                    if (arena.getRect(nid)) |r| {
                        if (std.math.isFinite(r.y) and std.math.isFinite(r.h) and r.h > 0.0) {
                            const y0 = r.y * s;
                            const y1 = (r.y + r.h) * s;
                            const cy = (y0 + y1) * 0.5;
                            if (std.math.isFinite(y0) and std.math.isFinite(y1) and std.math.isFinite(cy)) {
                                groups[group_count] = .{
                                    .y0 = y0,
                                    .y1 = y1,
                                    .cy = cy,
                                    .metrics = wearos.curvedScrollMetrics(cy, vp_cy_px, radius_px),
                                };
                                group_count += 1;
                            }
                        }
                    }
                }
            }

            const max_f32: f64 = @as(f64, std.math.floatMax(f32));
            for (0..safe_start) |i| {
                const x = out_quads[i].pos_size[0];
                const y = out_quads[i].pos_size[1];
                const w = out_quads[i].pos_size[2];
                const h = out_quads[i].pos_size[3];
                if (!std.math.isFinite(x) or !std.math.isFinite(y) or
                    !std.math.isFinite(w) or !std.math.isFinite(h) or
                    w <= 0.0 or h <= 0.0)
                {
                    continue;
                }
                if (@as(f64, w) >= bg_thresh_f64 and @as(f64, h) >= bg_thresh_f64) {
                    continue;
                }
                const q_cy_f64: f64 = @as(f64, y) + @as(f64, h) * 0.5;
                if (!std.math.isFinite(q_cy_f64) or @abs(q_cy_f64) > max_f32) continue;
                const q_cy: f32 = @floatCast(q_cy_f64);

                var best_idx: ?usize = null;
                var best_dist: f32 = std.math.floatMax(f32);
                for (groups[0..group_count], 0..) |g, gi| {
                    if (q_cy >= g.y0 - 16.0 and q_cy <= g.y1 + 16.0) {
                        const dist = @max(@as(f32, 0.0), @max(g.y0 - q_cy, q_cy - g.y1));
                        if (best_idx == null or dist < best_dist) {
                            best_dist = dist;
                            best_idx = gi;
                        }
                    }
                }

                if (best_idx) |gi| {
                    const g = groups[gi];
                    wearos.applyCurvedQuadWithMetrics(&out_quads[i], g.cy, vp_cx_px, g.metrics);
                } else {
                    wearos.applyCurvedEdgeTransform(out_quads[i .. i + 1], vp_cx_px, vp_cy_px, radius_px);
                }
            }
        }

        var count: usize = safe_start;
        if (self.overlays.activeCount() > 0 and count < out_quads.len) {
            count += self.overlays.emitOverlayQuadsScaled(vw, vh, s, out_quads[count..]);
        }

        if (count < out_quads.len and ring_dim > 4.0) {
            const bezel_col = self.anims.animateColor(
                animation.hashKey("theme", "accent"),
                self.accent(),
                animation.SpringConfig.gentle,
            );
            if (ring_dim > 20.0) {
                count += wearos.emitCurvedScrollArc(
                    out_quads[count..],
                    vw * 0.5 * s,
                    vh * 0.5 * s,
                    (ring_dim * 0.5 - 8.0) * s,
                    self.scroll_progress,
                    3.0 * s,
                    bezel_col,
                    .{ 0.0, 0.0, vw_px, vh_px },
                );
            }
            if (count < out_quads.len) {
                const bezel_w = @max(1.0, self.anims.animateSpring(
                    animation.hashKey("wear", "bezel_w"),
                    2.0,
                    animation.SpringConfig.snappy,
                ));
                out_quads[count] = .{
                    .pos_size = .{ 2.0 * s, 2.0 * s, (vw - 4.0) * s, (vh - 4.0) * s },
                    .color = core.Nord.transparent,
                    .border_color = core.sanitizeColor(bezel_col),
                    .params = .{ (ring_dim * 0.5 - 2.0) * s, bezel_w * s, 0.0, 0.0 },
                    .clip_rect = .{ 0.0, 0.0, vw_px, vh_px },
                };
                count += 1;
            }
            if (count < out_quads.len and ring_dim > 10.0) {
                count += self.frunk_hold.emitPerimeterFireworkQuads(
                    out_quads[count..],
                    vw * 0.5 * s,
                    vh * 0.5 * s,
                    ring_dim * 0.5 * s - 4.0 * s,
                    4.5 * s,
                    .{ 0.0, 0.0, vw_px, vh_px },
                );
            }
        }

        if (self.wear_ambient and count > 0) {
            wearos.transformQuadsForAmbient(out_quads[0..count], false);
        }

        return count;
    }
};
