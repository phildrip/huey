const std = @import("std");
const core = @import("core.zig");
const events = @import("events.zig");
const overlay = @import("overlay.zig");
const wearos = @import("wearos.zig");
const glyph_atlas = @import("glyph_atlas.zig");

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
    flash_count: u32 = 0,
    accent_idx: u8 = 0,
    wear_ambient: bool = false,
    counter: i32 = 42,
    slider_value: f32 = 0.68,

    overlays: overlay.OverlayManager = overlay.OverlayManager.init(),
    scroll_container: ?core.NodeId = null,
    last_frame_ms: f32 = 1.8,
    last_quad_count: usize = 0,

    flash_buf: [32]u8 = undefined,
    stats_buf: [64]u8 = undefined,
    counter_buf: [32]u8 = undefined,
    slider_buf: [32]u8 = undefined,

    pub fn init() WearShowcaseApp {
        return .{};
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

        const cur_accent = self.accent();
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
        const lock_col = if (self.locked) core.Nord.frost_1 else core.Nord.aurora_green;
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
        const flash_label = if (self.flash_count == 0)
            "FLASH"
        else
            (std.fmt.bufPrint(&self.flash_buf, "FLASH {d}", .{self.flash_count}) catch "FLASH");
        _ = try arena.addChild(action_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_flash",
            .label = flash_label,
            .font_size = 12.5,
            .text_color = core.Nord.snow_storm_2,
            .height = 44.0,
            .corner_radius = 22.0,
            .border_width = 1.5,
            .fill = core.Nord.polar_night_2,
            .border = if (self.flash_count > 0) core.Nord.aurora_yellow else cur_accent,
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

    pub fn handlePointerDown(self: *WearShowcaseApp, x: f32, y: f32) bool {
        if (self.overlays.activeCount() == 0) return false;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
        return self.overlays.handleOutsideClick(x, y);
    }

    fn applyIdAction(self: *WearShowcaseApp, test_id: []const u8, toggled_val: ?bool) bool {
        if (std.mem.eql(u8, test_id, "wear_lock")) {
            self.locked = !self.locked;
            return true;
        }
        if (std.mem.eql(u8, test_id, "wear_trunk")) {
            self.trunk_open = !self.trunk_open;
            return true;
        }
        if (std.mem.eql(u8, test_id, "wear_flash")) {
            self.flash_count +|= 1;
            return true;
        }
        if (parseIndexSuffix(test_id, "wear_accent_", ACCENTS.len)) |idx| {
            self.accent_idx = @intCast(idx);
            return true;
        }
        if (std.mem.eql(u8, test_id, "wear_ambient")) {
            self.wear_ambient = toggled_val orelse !self.wear_ambient;
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
        self: *const WearShowcaseApp,
        arena: *const core.LayoutArena,
        out_quads: []core.QuadInstance,
        start_idx: usize,
        logical_w: f32,
        logical_h: f32,
        scale_factor: f32,
        atlas: ?*glyph_atlas.GlyphAtlas,
        frame_idx: u64,
    ) usize {
        _ = arena;
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

        var count: usize = safe_start;
        if (self.overlays.activeCount() > 0 and count < out_quads.len) {
            count += self.overlays.emitOverlayQuadsScaled(vw, vh, s, out_quads[count..]);
        }

        const ring_dim = @min(vw, vh);
        if (count < out_quads.len and ring_dim > 4.0) {
            out_quads[count] = .{
                .pos_size = .{ 2.0 * s, 2.0 * s, (vw - 4.0) * s, (vh - 4.0) * s },
                .color = core.Nord.transparent,
                .border_color = core.sanitizeColor(self.accent()),
                .params = .{ (ring_dim * 0.5 - 2.0) * s, 2.0 * s, 0.0, 0.0 },
                .clip_rect = .{ 0.0, 0.0, vw_px, vh_px },
            };
            count += 1;
        }

        if (self.wear_ambient and count > 0) {
            wearos.transformQuadsForAmbient(out_quads[0..count], false);
        }

        return count;
    }
};
