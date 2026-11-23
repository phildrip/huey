const std = @import("std");
const core = @import("core.zig");
const events = @import("events.zig");
const overlay = @import("overlay.zig");
const wearos = @import("wearos.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const animation = @import("animation.zig");

pub const Tab = enum(u8) {
    scroll,
    widgets,
    popups,
    hud,
};

pub const ACCENTS = [_][4]f32{
    core.Nord.frost_1, // #88C0D0 Nord Frost
    core.Nord.aurora_green, // #A3BE8C Aurora Green
    core.Nord.aurora_purple, // #B48EAD Aurora Purple
    core.Nord.aurora_orange, // #D08770 Aurora Orange
};

const ACCENT_NAMES = [_][]const u8{
    "Frost",
    "Green",
    "Purple",
    "Orange",
};

const ACCENT_IDS = [_][]const u8{
    "accent_0",
    "accent_1",
    "accent_2",
    "accent_3",
};

const CARD_IDS = [16][]const u8{
    "card_0",  "card_1",  "card_2",  "card_3",
    "card_4",  "card_5",  "card_6",  "card_7",
    "card_8",  "card_9",  "card_10", "card_11",
    "card_12", "card_13", "card_14", "card_15",
};

const CARD_TOGGLE_IDS = [16][]const u8{
    "card_toggle_0",  "card_toggle_1",  "card_toggle_2",  "card_toggle_3",
    "card_toggle_4",  "card_toggle_5",  "card_toggle_6",  "card_toggle_7",
    "card_toggle_8",  "card_toggle_9",  "card_toggle_10", "card_toggle_11",
    "card_toggle_12", "card_toggle_13", "card_toggle_14", "card_toggle_15",
};

const CARD_TITLES = [16][]const u8{
    "01. UberQuad Batching",
    "02. AChoreographer 60Hz",
    "03. Zero-Tick ALooper",
    "04. Linear sRGB Blend",
    "05. Oklab Perceptual L",
    "06. LayoutArena SoA",
    "07. GlyphAtlas LRU",
    "08. Touch Slop 8dp",
    "09. Portal Overlays",
    "10. Edge-Flip Popups",
    "11. Wear OS Inscribed",
    "12. OLED Ambient Wire",
    "13. SumTree Virtualize",
    "14. UAX #29 Clusters",
    "15. Wayland xdg_popup",
    "16. Zero Heap Frame",
};

const CARD_SUBTITLES = [16][]const u8{
    "Single-pass SDF rounded rects",
    "VSync-paced fling scrolling",
    "0% CPU when idle",
    "Gamma-correct AA borders",
    "Uniform Nord accent tones",
    "Zero-alloc node generation IDs",
    "Shelf-packed stb_truetype",
    "44dp ergonomic hit targets",
    "Escapes parent clip scissors",
    "Auto flip & clamp to viewport",
    "Circular bezel safe square",
    "Burn-in safe 1px outlines",
    "O(log N) variable row offsets",
    "Grapheme-aware text editing",
    "Constraint-adjusted wire spec",
    "Static scratch buffers only",
};

const CAPABILITIES = [_]struct {
    id: []const u8,
    title: []const u8,
    sub: []const u8,
}{
    .{ .id = "cap_0", .title = "UberQuad GLES 3.1", .sub = "1-pass instanced SDF" },
    .{ .id = "cap_1", .title = "AChoreographer 60Hz", .sub = "VSync frame pacing" },
    .{ .id = "cap_2", .title = "0% Idle ALooper", .sub = "On-demand redraw wake" },
    .{ .id = "cap_3", .title = "Linear sRGB Blend", .sub = "Oklab luminance ramps" },
    .{ .id = "cap_4", .title = "UAX #29 Text", .sub = "Grapheme & IME ready" },
    .{ .id = "cap_5", .title = "Wayland + Wear OS", .sub = "Portal & ambient pass" },
};

const HEADER_H: f32 = 56.0;
const TAB_BAR_H: f32 = 52.0;
const BODY_PAD: f32 = 12.0;
const POP_BTN_W: f32 = 132.0;
const POP_BTN_H: f32 = 48.0;
const FRAME_BUDGET_MS: f32 = 16.67;
const MIN_TOUCH_TARGET_DP: f32 = 44.0;

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

fn popBtnWidth(vw: f32) f32 {
    return @min(POP_BTN_W, @max(44.0, (vw - BODY_PAD * 2.0 - 8.0) * 0.5));
}

fn withAlpha(c: core.Color, alpha: f32) core.Color {
    return .{ c[0], c[1], c[2], alpha };
}

fn isPositiveFiniteRect(r: core.Rect) bool {
    return std.math.isFinite(r.x) and
        std.math.isFinite(r.y) and
        std.math.isFinite(r.w) and
        std.math.isFinite(r.h) and
        r.w > 0.0 and
        r.h > 0.0;
}

fn isClipEmpty(clip: [4]f32) bool {
    return !(clip[2] > clip[0] and clip[3] > clip[1]);
}

fn rectsIntersectClip(phys: core.Rect, clip: [4]f32) bool {
    return phys.w > 0.0 and
        phys.h > 0.0 and
        (phys.x + phys.w) > clip[0] and
        phys.x < clip[2] and
        (phys.y + phys.h) > clip[1] and
        phys.y < clip[3];
}

fn isInteractiveNode(arena: *const core.LayoutArena, idx: u16) bool {
    const slice = arena.nodes.slice();
    const gen = slice.items(.gen)[idx];
    const id = core.NodeId{ .index = idx, .gen = gen };
    if (!arena.isEnabledTree(id)) return false;
    const kind = slice.items(.kind)[idx];
    if (kind == .toggle or kind == .slider) return true;
    return slice.items(.focusable)[idx] orelse false;
}

fn parseIndexSuffix(test_id: []const u8, prefix: []const u8, max_count: usize) ?usize {
    if (!std.mem.startsWith(u8, test_id, prefix)) return null;
    const tail = test_id[prefix.len..];
    if (tail.len == 0) return null;
    const val = std.fmt.parseInt(usize, tail, 10) catch return null;
    if (val >= max_count) return null;
    return val;
}

pub const ShowcaseApp = struct {
    active_tab: Tab = .scroll,
    accent_idx: u8 = 0,
    counter: i32 = 42,
    slider_value: f32 = 0.68,
    card_toggles: [16]bool = .{
        true, false, true, false,
        true, false, true, false,
        true, false, true, false,
        true, false, true, false,
    },
    wear_ambient: bool = false,
    hud_bounds: bool = false,
    hud_targets: bool = false,
    hud_budget: bool = true,
    overlays: overlay.OverlayManager = overlay.OverlayManager.init(),
    anims: animation.AnimationPool = animation.AnimationPool.init(),
    last_tab_vw: f32 = 0.0,
    popup_title: []const u8 = "",
    scroll_container: ?core.NodeId = null,
    last_frame_ms: f32 = 1.8,
    last_quad_count: usize = 0,
    counter_buf: [32]u8 = undefined,
    stats_buf: [64]u8 = undefined,
    slider_buf: [32]u8 = undefined,

    pub fn init() ShowcaseApp {
        return .{};
    }

    pub fn isAnimating(self: *const ShowcaseApp) bool {
        return self.anims.isAnimating();
    }

    pub fn stepAnimations(self: *ShowcaseApp, dt_s: f32) bool {
        return self.anims.step(dt_s);
    }

    pub fn accent(self: *const ShowcaseApp) core.Color {
        const idx = @min(@as(usize, self.accent_idx), ACCENTS.len - 1);
        return ACCENTS[idx];
    }

    pub fn buildScene(self: *ShowcaseApp, arena: *core.LayoutArena, logical_w: f32, logical_h: f32) !void {
        const vw = sanitizePositive(logical_w, 400.0);
        const vh = sanitizePositive(logical_h, 800.0);

        arena.reset();
        self.scroll_container = null;

        const cur_accent = self.anims.animateColor(
            animation.hashKey("theme", "accent"),
            self.accent(),
            animation.SpringConfig.gentle,
        );
        const safe_ms = sanitizeFrameMs(self.last_frame_ms);
        const fps: u32 = if (safe_ms <= FRAME_BUDGET_MS)
            60
        else
            @max(1, @as(u32, @intFromFloat(@round(1000.0 / safe_ms))));

        const stats_str = if (safe_ms > 99999.0)
            std.fmt.bufPrint(&self.stats_buf, "1 FPS | >99s | {d} Q", .{self.last_quad_count}) catch "1 FPS"
        else
            std.fmt.bufPrint(&self.stats_buf, "{d} FPS | {d:.1} ms | {d} Q", .{
                fps,
                safe_ms,
                self.last_quad_count,
            }) catch "1 FPS | -- ms";

        const root = try arena.addNode(.{
            .kind = .vstack,
            .role = .container,
            .test_id = "showcase.root",
            .fill = core.Nord.polar_night_0,
            .clip_children = true,
        });

        // Pinned Header (height = 56, polar_night_1, horizontal .hstack)
        const header = try arena.addChild(root, .{
            .kind = .hstack,
            .role = .panel,
            .test_id = "showcase.header",
            .height = HEADER_H,
            .padding = 10.0,
            .gap = 8.0,
            .align_items = .center,
            .fill = core.Nord.polar_night_1,
            .border = core.Nord.polar_night_2,
            .border_width = 1.0,
        });
        _ = try arena.addChild(header, .{
            .kind = .card,
            .role = .panel,
            .test_id = "header.title",
            .label = "ZIGGUI SHOWCASE",
            .font_size = 16.0,
            .text_color = core.Nord.snow_storm_2,
            .height = 36.0,
            .fill = core.Nord.transparent,
        });
        const pill_w = @min(168.0, @max(64.0, vw * 0.42));
        _ = try arena.addChild(header, .{
            .kind = .card,
            .role = .panel,
            .test_id = "header.stats",
            .label = stats_str,
            .font_size = 11.5,
            .text_color = core.Nord.snow_storm_1,
            .width = pill_w,
            .height = 32.0,
            .corner_radius = 12.0,
            .border_width = 1.0,
            .fill = core.Nord.polar_night_0,
            .border = cur_accent,
        });

        // Pinned 4-Tab Bar (height = 52, polar_night_1, horizontal .hstack)
        // Use padding = 2.0 and responsive gap so 48dp touch-ergonomic tabs fit cleanly >= 44dp wide even at 200dp.
        const tab_gap = @min(8.0, @max(2.0, (vw - 180.0) * 0.25));
        const tab_bar = try arena.addChild(root, .{
            .kind = .hstack,
            .role = .container,
            .test_id = "showcase.tab_bar",
            .height = TAB_BAR_H,
            .padding = 2.0,
            .gap = tab_gap,
            .align_items = .center,
            .fill = core.Nord.polar_night_1,
            .border = core.Nord.polar_night_2,
            .border_width = 1.0,
        });

        const tab_specs = [_]struct {
            tab: Tab,
            id: []const u8,
            label: []const u8,
        }{
            .{ .tab = .scroll, .id = "tab_scroll", .label = "Scroll" },
            .{ .tab = .widgets, .id = "tab_widgets", .label = "Widgets" },
            .{ .tab = .popups, .id = "tab_popups", .label = "Popups" },
            .{ .tab = .hud, .id = "tab_hud", .label = "HUD" },
        };
        for (tab_specs) |ts| {
            const active = (self.active_tab == ts.tab);
            _ = try arena.addChild(tab_bar, .{
                .kind = .card,
                .role = .panel,
                .test_id = ts.id,
                .label = ts.label,
                .font_size = 14.0,
                .text_color = if (active) core.Nord.polar_night_0 else core.Nord.snow_storm_1,
                .height = 48.0,
                .corner_radius = 12.0,
                .border_width = 1.5,
                .fill = if (active) cur_accent else core.Nord.polar_night_2,
                .border = if (active) cur_accent else core.Nord.polar_night_3,
                .accent = cur_accent,
                .focusable = true,
            });
        }

        // Scrollable Body (flex = 1.0, clip_children = true)
        const body_id = try arena.addChild(root, .{
            .kind = .vstack,
            .role = .container,
            .test_id = "showcase.body",
            .flex = 1.0,
            .padding = BODY_PAD,
            .gap = 10.0,
            .clip_children = true,
            .fill = core.Nord.transparent,
        });
        self.scroll_container = body_id;

        switch (self.active_tab) {
            .scroll => try self.buildScrollTab(arena, body_id, cur_accent, vw),
            .widgets => try self.buildWidgetsTab(arena, body_id, cur_accent, vw),
            .popups => try self.buildPopupsTab(arena, body_id, cur_accent, vw, vh),
            .hud => try self.buildHudTab(arena, body_id, cur_accent),
        }
    }

    fn buildScrollTab(self: *ShowcaseApp, arena: *core.LayoutArena, body_id: core.NodeId, cur_accent: core.Color, vw: f32) !void {
        const toggle_w = @min(128.0, @max(88.0, (vw - 48.0) * 0.45));
        for (0..16) |i| {
            const on = self.card_toggles[i];
            const card = try arena.addChild(body_id, .{
                .kind = .card,
                .role = .panel,
                .test_id = CARD_IDS[i],
                .height = 84.0,
                .padding = 12.0,
                .corner_radius = 14.0,
                .border_width = 1.5,
                .shadow_blur = 6.0,
                .fill = core.Nord.polar_night_1,
                .border = if (on) cur_accent else core.Nord.polar_night_3,
                .accent = cur_accent,
            });
            const row = try arena.addChild(card, .{
                .kind = .hstack,
                .role = .container,
                .gap = 8.0,
                .align_items = .center,
            });
            _ = try arena.addChild(row, .{
                .kind = .card,
                .role = .panel,
                .label = CARD_TITLES[i],
                .sublabel = CARD_SUBTITLES[i],
                .font_size = 15.0,
                .text_color = core.Nord.snow_storm_2,
                .height = 56.0,
                .fill = core.Nord.transparent,
            });
            _ = try arena.addChild(row, .{
                .kind = .toggle,
                .role = .switch_control,
                .test_id = CARD_TOGGLE_IDS[i],
                .label = if (on) "ON" else "OFF",
                .font_size = 14.0,
                .text_color = core.Nord.snow_storm_2,
                .width = toggle_w,
                .height = 48.0,
                .corner_radius = 12.0,
                .border_width = 1.0,
                .fill = core.Nord.polar_night_0,
                .border = if (on) cur_accent else core.Nord.polar_night_3,
                .accent = cur_accent,
                .checked = on,
            });
        }
    }

    fn buildWidgetsTab(self: *ShowcaseApp, arena: *core.LayoutArena, body_id: core.NodeId, cur_accent: core.Color, vw: f32) !void {
        // 1. Theme Accent Picker Card
        const accent_card = try arena.addChild(body_id, .{
            .kind = .card,
            .role = .panel,
            .test_id = "widgets.accent_card",
            .height = 128.0,
            .padding = 12.0,
            .gap = 10.0,
            .corner_radius = 14.0,
            .border_width = 1.5,
            .shadow_blur = 6.0,
            .fill = core.Nord.polar_night_1,
            .border = core.Nord.polar_night_3,
        });
        _ = try arena.addChild(accent_card, .{
            .kind = .card,
            .role = .panel,
            .label = "Nord Accent Theme",
            .sublabel = ACCENT_NAMES[@min(@as(usize, self.accent_idx), ACCENT_NAMES.len - 1)],
            .font_size = 15.0,
            .text_color = core.Nord.snow_storm_2,
            .height = 40.0,
            .fill = core.Nord.transparent,
        });
        const swatch_row = try arena.addChild(accent_card, .{
            .kind = .hstack,
            .role = .container,
            .gap = 10.0,
            .height = 52.0,
        });
        for (0..ACCENTS.len) |i| {
            _ = try arena.addChild(swatch_row, .{
                .kind = .toggle,
                .role = .swatch,
                .test_id = ACCENT_IDS[i],
                .height = 52.0,
                .corner_radius = 14.0,
                .border_width = 1.5,
                .fill = ACCENTS[i],
                .border = core.Nord.polar_night_3,
                .accent = ACCENTS[i],
                .checked = (self.accent_idx == i),
            });
        }

        // 2. Interactive Counter & Slider Card
        const ctrl_card = try arena.addChild(body_id, .{
            .kind = .card,
            .role = .panel,
            .test_id = "widgets.counter_card",
            .height = 186.0,
            .padding = 12.0,
            .gap = 12.0,
            .corner_radius = 14.0,
            .border_width = 1.5,
            .shadow_blur = 6.0,
            .fill = core.Nord.polar_night_1,
            .border = core.Nord.polar_night_3,
        });
        _ = try arena.addChild(ctrl_card, .{
            .kind = .card,
            .role = .panel,
            .label = "Counter & Live Slider",
            .font_size = 15.0,
            .text_color = core.Nord.snow_storm_2,
            .height = 24.0,
            .fill = core.Nord.transparent,
        });
        const counter_row = try arena.addChild(ctrl_card, .{
            .kind = .hstack,
            .role = .container,
            .gap = 10.0,
            .height = 50.0,
        });
        const btn_w = @min(64.0, @max(44.0, (vw - 80.0) * 0.25));
        _ = try arena.addChild(counter_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = "btn_dec",
            .label = "-",
            .font_size = 20.0,
            .text_color = core.Nord.snow_storm_2,
            .width = btn_w,
            .height = 50.0,
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
            .test_id = "counter_display",
            .label = counter_str,
            .font_size = 20.0,
            .text_color = cur_accent,
            .height = 50.0,
            .corner_radius = 12.0,
            .border_width = 1.0,
            .fill = core.Nord.polar_night_0,
            .border = core.Nord.polar_night_3,
        });
        _ = try arena.addChild(counter_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = "btn_inc",
            .label = "+",
            .font_size = 20.0,
            .text_color = core.Nord.snow_storm_2,
            .width = btn_w,
            .height = 50.0,
            .corner_radius = 12.0,
            .border_width = 1.5,
            .fill = core.Nord.polar_night_2,
            .border = cur_accent,
            .focusable = true,
        });

        const safe_slider = sanitizeUnit(self.slider_value);
        const pct: u32 = @intFromFloat(@round(safe_slider * 100.0));
        const slider_str = std.fmt.bufPrint(&self.slider_buf, "Intensity: {d}%", .{pct}) catch "Intensity";
        _ = try arena.addChild(ctrl_card, .{
            .kind = .slider,
            .role = .slider,
            .test_id = "demo_slider",
            .label = slider_str,
            .font_size = 14.0,
            .text_color = core.Nord.snow_storm_1,
            .height = 64.0,
            .corner_radius = 12.0,
            .border_width = 1.5,
            .fill = core.Nord.polar_night_0,
            .border = core.Nord.polar_night_3,
            .accent = cur_accent,
            .slider_val = safe_slider,
        });

        // 3. Wear OS Circular Preview Card
        const bezel_size = @min(180.0, @max(64.0, vw - 48.0));
        const wear_card_h = 12.0 + 24.0 + 12.0 + bezel_size + 12.0 + 52.0 + 12.0;
        const wear_card = try arena.addChild(body_id, .{
            .kind = .card,
            .role = .panel,
            .test_id = "widgets.wear_card",
            .height = wear_card_h,
            .padding = 12.0,
            .gap = 12.0,
            .corner_radius = 14.0,
            .border_width = 1.5,
            .shadow_blur = 6.0,
            .fill = core.Nord.polar_night_1,
            .border = core.Nord.polar_night_3,
        });
        _ = try arena.addChild(wear_card, .{
            .kind = .card,
            .role = .panel,
            .label = "Wear OS Circular Preview",
            .font_size = 15.0,
            .text_color = core.Nord.snow_storm_2,
            .height = 24.0,
            .fill = core.Nord.transparent,
        });

        const wear_cfg = wearos.WearConfig.init(bezel_size, bezel_size, true, 0.0);
        const safe_sq = wear_cfg.safeRect();
        const bezel_pad = @max(0.0, (bezel_size - safe_sq.w) * 0.5);

        const bezel_row = try arena.addChild(wear_card, .{
            .kind = .hstack,
            .role = .container,
            .height = bezel_size,
            .justify = .center,
            .align_items = .center,
        });
        const wear_bezel = try arena.addChild(bezel_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_bezel",
            .width = bezel_size,
            .height = bezel_size,
            .padding = bezel_pad,
            .justify = .center,
            .align_items = .center,
            .corner_radius = bezel_size * 0.5,
            .border_width = 2.0,
            .shadow_blur = 8.0,
            .fill = core.Nord.polar_night_0,
            .border = cur_accent,
        });
        const inscribed = try arena.addChild(wear_bezel, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_safe_square",
            .width = safe_sq.w,
            .height = safe_sq.h,
            .padding = @min(10.0, safe_sq.w * 0.08),
            .gap = 4.0,
            .justify = .center,
            .corner_radius = 14.0,
            .border_width = 1.0,
            .fill = core.Nord.polar_night_1,
            .border = core.Nord.polar_night_3,
        });
        _ = try arena.addChild(inscribed, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_title",
            .label = "TESLA KEY",
            .font_size = 13.0,
            .text_color = cur_accent,
            .height = 22.0,
            .fill = core.Nord.transparent,
        });
        _ = try arena.addChild(inscribed, .{
            .kind = .card,
            .role = .panel,
            .test_id = "wear_status",
            .label = "LOCKED",
            .font_size = 16.0,
            .text_color = core.Nord.snow_storm_2,
            .height = 26.0,
            .fill = core.Nord.transparent,
        });
        _ = try arena.addChild(inscribed, .{
            .kind = .bar,
            .role = .progress_bar,
            .test_id = "wear_gauge",
            .height = 12.0,
            .corner_radius = 6.0,
            .fill = core.Nord.polar_night_0,
            .accent = cur_accent,
            .slider_val = safe_slider,
        });

        _ = try arena.addChild(wear_card, .{
            .kind = .toggle,
            .role = .switch_control,
            .test_id = "wear_ambient",
            .label = "Ambient OLED Mode",
            .font_size = 14.0,
            .text_color = core.Nord.snow_storm_2,
            .height = 52.0,
            .corner_radius = 12.0,
            .border_width = 1.5,
            .fill = core.Nord.polar_night_0,
            .border = if (self.wear_ambient) cur_accent else core.Nord.polar_night_3,
            .accent = cur_accent,
            .checked = self.wear_ambient,
        });
    }

    fn buildPopupsTab(
        self: *ShowcaseApp,
        arena: *core.LayoutArena,
        body_id: core.NodeId,
        cur_accent: core.Color,
        vw: f32,
        vh: f32,
    ) !void {
        _ = self;
        const btn_w = popBtnWidth(vw);
        const modal_btn_w = @min(220.0, @max(80.0, vw - BODY_PAD * 2.0));
        const compact_v = (vh < 420.0);

        const top_row = try arena.addChild(body_id, .{
            .kind = .hstack,
            .role = .container,
            .test_id = "popups.top_row",
            .height = POP_BTN_H,
            .justify = .space_between,
        });
        _ = try arena.addChild(top_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = "pop_tl",
            .label = "Top-Left",
            .font_size = 14.0,
            .text_color = core.Nord.snow_storm_2,
            .width = btn_w,
            .height = POP_BTN_H,
            .corner_radius = 12.0,
            .border_width = 1.5,
            .fill = core.Nord.polar_night_1,
            .border = cur_accent,
            .focusable = true,
        });
        _ = try arena.addChild(top_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = "pop_tr",
            .label = "Top-Right",
            .font_size = 14.0,
            .text_color = core.Nord.snow_storm_2,
            .width = btn_w,
            .height = POP_BTN_H,
            .corner_radius = 12.0,
            .border_width = 1.5,
            .fill = core.Nord.polar_night_1,
            .border = cur_accent,
            .focusable = true,
        });

        const mid = try arena.addChild(body_id, .{
            .kind = .vstack,
            .role = .container,
            .height = if (compact_v) 104.0 else 0.0,
            .flex = if (compact_v) 0.0 else 1.0,
            .gap = if (compact_v) 8.0 else 14.0,
            .justify = .center,
        });
        _ = try arena.addChild(mid, .{
            .kind = .card,
            .role = .panel,
            .test_id = "popups.desc_card",
            .label = "Portal Overlays & Edge Flipping",
            .sublabel = "Tap any corner anchor or open modal dialog",
            .font_size = 15.0,
            .text_color = core.Nord.snow_storm_2,
            .height = if (compact_v) 48.0 else 84.0,
            .padding = 10.0,
            .corner_radius = 14.0,
            .border_width = 1.5,
            .fill = core.Nord.polar_night_1,
            .border = core.Nord.polar_night_3,
        });
        const modal_row = try arena.addChild(mid, .{
            .kind = .hstack,
            .role = .container,
            .height = if (compact_v) 48.0 else 52.0,
            .justify = .center,
        });
        _ = try arena.addChild(modal_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = "pop_modal",
            .label = "Open Modal Dialog",
            .font_size = 15.0,
            .text_color = core.Nord.polar_night_0,
            .width = modal_btn_w,
            .height = if (compact_v) 48.0 else 52.0,
            .corner_radius = 14.0,
            .border_width = 1.5,
            .fill = cur_accent,
            .border = cur_accent,
            .focusable = true,
        });

        const bot_row = try arena.addChild(body_id, .{
            .kind = .hstack,
            .role = .container,
            .test_id = "popups.bot_row",
            .height = POP_BTN_H,
            .justify = .space_between,
        });
        _ = try arena.addChild(bot_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = "pop_bl",
            .label = "Bot-Left",
            .font_size = 14.0,
            .text_color = core.Nord.snow_storm_2,
            .width = btn_w,
            .height = POP_BTN_H,
            .corner_radius = 12.0,
            .border_width = 1.5,
            .fill = core.Nord.polar_night_1,
            .border = cur_accent,
            .focusable = true,
        });
        _ = try arena.addChild(bot_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = "pop_br",
            .label = "Bot-Right",
            .font_size = 14.0,
            .text_color = core.Nord.snow_storm_2,
            .width = btn_w,
            .height = POP_BTN_H,
            .corner_radius = 12.0,
            .border_width = 1.5,
            .fill = core.Nord.polar_night_1,
            .border = cur_accent,
            .focusable = true,
        });
    }

    fn buildHudTab(self: *ShowcaseApp, arena: *core.LayoutArena, body_id: core.NodeId, cur_accent: core.Color) !void {
        const toggles = [_]struct {
            id: []const u8,
            label: []const u8,
            checked: bool,
        }{
            .{ .id = "hud_bounds", .label = "Layout Bounds", .checked = self.hud_bounds },
            .{ .id = "hud_targets", .label = "44dp Hit Targets", .checked = self.hud_targets },
            .{ .id = "hud_budget", .label = "Frame Budget Bar", .checked = self.hud_budget },
        };
        for (toggles) |tg| {
            _ = try arena.addChild(body_id, .{
                .kind = .toggle,
                .role = .switch_control,
                .test_id = tg.id,
                .label = tg.label,
                .font_size = 15.0,
                .text_color = core.Nord.snow_storm_2,
                .height = 52.0,
                .corner_radius = 14.0,
                .border_width = 1.5,
                .shadow_blur = 6.0,
                .fill = core.Nord.polar_night_1,
                .border = if (tg.checked) cur_accent else core.Nord.polar_night_3,
                .accent = cur_accent,
                .checked = tg.checked,
            });
        }

        const matrix_card = try arena.addChild(body_id, .{
            .kind = .card,
            .role = .panel,
            .test_id = "hud.capabilities_card",
            .height = 290.0,
            .padding = 12.0,
            .gap = 10.0,
            .corner_radius = 14.0,
            .border_width = 1.5,
            .shadow_blur = 6.0,
            .fill = core.Nord.polar_night_1,
            .border = core.Nord.polar_night_3,
        });
        _ = try arena.addChild(matrix_card, .{
            .kind = .card,
            .role = .panel,
            .label = "Toolkit Capabilities Matrix",
            .font_size = 15.0,
            .text_color = cur_accent,
            .height = 26.0,
            .fill = core.Nord.transparent,
        });
        const grid = try arena.addChild(matrix_card, .{
            .kind = .grid,
            .role = .container,
            .test_id = "hud.capabilities_grid",
            .grid_cols = 2,
            .grid_col_gap = 8.0,
            .grid_row_gap = 8.0,
            .flex = 1.0,
        });
        for (CAPABILITIES) |cap| {
            _ = try arena.addChild(grid, .{
                .kind = .card,
                .role = .panel,
                .test_id = cap.id,
                .label = cap.title,
                .sublabel = cap.sub,
                .font_size = 13.0,
                .text_color = core.Nord.snow_storm_2,
                .height = 68.0,
                .padding = 8.0,
                .corner_radius = 10.0,
                .border_width = 1.0,
                .fill = core.Nord.polar_night_0,
                .border = core.Nord.polar_night_3,
            });
        }
    }

    pub fn handlePointerDown(self: *ShowcaseApp, x: f32, y: f32) bool {
        if (self.overlays.activeCount() == 0) return false;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;

        // Handles modal outside click (dismisses top modal overlay if outside).
        if (self.overlays.handleOutsideClick(x, y)) {
            if (self.overlays.activeCount() == 0) {
                self.popup_title = "";
                self.anims.snapSpring(animation.hashKey("popup", "scale"), 1.0);
            }
            return true;
        }

        const top = self.overlays.top() orelse return false;
        if (!top.spec.modal) {
            const r = top.rect;
            const px = @as(f64, x);
            const py = @as(f64, y);
            const rx = @as(f64, r.x);
            const ry = @as(f64, r.y);
            const rw = @as(f64, r.w);
            const rh = @as(f64, r.h);
            const inside = rw > 0.0 and rh > 0.0 and
                px >= rx and px <= rx + rw and
                py >= ry and py <= ry + rh;
            if (!inside) {
                _ = self.overlays.closeTop();
                if (self.overlays.activeCount() == 0) {
                    self.popup_title = "";
                    self.anims.snapSpring(animation.hashKey("popup", "scale"), 1.0);
                }
            }
        }
        return true;
    }

    fn openCornerPopup(self: *ShowcaseApp, id: []const u8, logical_w: f32, logical_h: f32) void {
        if (!std.math.isFinite(logical_w) or !std.math.isFinite(logical_h) or
            logical_w <= 0.0 or logical_h <= 0.0)
        {
            self.overlays.closeAll();
            self.popup_title = "";
            self.anims.snapSpring(animation.hashKey("popup", "scale"), 1.0);
            return;
        }
        const vw = logical_w;
        const vh = logical_h;
        const cur_accent = self.accent();
        const btn_w = popBtnWidth(vw);
        const top_y = HEADER_H + TAB_BAR_H + BODY_PAD;
        const bot_y = if (vh < 420.0)
            top_y + POP_BTN_H + 10.0 + 104.0 + 10.0
        else
            @max(top_y, vh - BODY_PAD - POP_BTN_H);
        const right_x = @max(BODY_PAD, vw - BODY_PAD - btn_w);
        const pop_w = @min(220.0, @max(120.0, vw - BODY_PAD * 2.0));
        const pop_h = @min(120.0, @max(80.0, vh - BODY_PAD * 2.0));

        self.overlays.closeAll();
        self.popup_title = "";

        var opened = false;
        if (std.mem.eql(u8, id, "pop_tl")) {
            _ = self.overlays.open(.{
                .anchor = .{ .x = BODY_PAD, .y = top_y, .w = btn_w, .h = POP_BTN_H },
                .width = pop_w,
                .height = pop_h,
                .placement = .top_start,
                .gap = 6.0,
                .bg_color = core.Nord.polar_night_2,
                .border_color = cur_accent,
                .corner_radius = 14.0,
                .border_width = 1.5,
                .shadow_blur = 12.0,
            }, vw, vh) catch return;
            self.popup_title = "Top-Left Anchor";
            opened = true;
        } else if (std.mem.eql(u8, id, "pop_tr")) {
            _ = self.overlays.open(.{
                .anchor = .{ .x = right_x, .y = top_y, .w = btn_w, .h = POP_BTN_H },
                .width = pop_w,
                .height = pop_h,
                .placement = .bottom_start,
                .gap = 6.0,
                .bg_color = core.Nord.polar_night_2,
                .border_color = cur_accent,
                .corner_radius = 14.0,
                .border_width = 1.5,
                .shadow_blur = 12.0,
            }, vw, vh) catch return;
            self.popup_title = "Top-Right Flip";
            opened = true;
        } else if (std.mem.eql(u8, id, "pop_bl")) {
            _ = self.overlays.open(.{
                .anchor = .{ .x = BODY_PAD, .y = bot_y, .w = btn_w, .h = POP_BTN_H },
                .width = pop_w,
                .height = pop_h,
                .placement = .bottom_start,
                .gap = 6.0,
                .bg_color = core.Nord.polar_night_2,
                .border_color = cur_accent,
                .corner_radius = 14.0,
                .border_width = 1.5,
                .shadow_blur = 12.0,
            }, vw, vh) catch return;
            self.popup_title = "Bot-Left Flip";
            opened = true;
        } else if (std.mem.eql(u8, id, "pop_br")) {
            _ = self.overlays.open(.{
                .anchor = .{ .x = right_x, .y = bot_y, .w = btn_w, .h = POP_BTN_H },
                .width = pop_w,
                .height = pop_h,
                .placement = .bottom_start,
                .gap = 6.0,
                .bg_color = core.Nord.polar_night_2,
                .border_color = cur_accent,
                .corner_radius = 14.0,
                .border_width = 1.5,
                .shadow_blur = 12.0,
            }, vw, vh) catch return;
            self.popup_title = "Bot-Right Dual Flip";
            opened = true;
        } else if (std.mem.eql(u8, id, "pop_modal")) {
            const modal_w = @min(280.0, @max(120.0, vw - 32.0));
            const modal_h = @min(180.0, @max(80.0, vh - 48.0));
            _ = self.overlays.open(.{
                .anchor = .{
                    .x = (vw - modal_w) * 0.5,
                    .y = (vh - modal_h) * 0.5,
                    .w = modal_w,
                    .h = 0.0,
                },
                .width = modal_w,
                .height = modal_h,
                .placement = .bottom_start,
                .modal = true,
                .bg_color = core.Nord.polar_night_1,
                .backdrop_color = .{ 0.04, 0.06, 0.09, 0.72 },
                .border_color = cur_accent,
                .corner_radius = 18.0,
                .border_width = 2.0,
                .shadow_blur = 16.0,
            }, vw, vh) catch return;
            self.popup_title = "Modal Dialog";
            opened = true;
        }

        if (opened) {
            self.anims.restartSpring(
                animation.hashKey("popup", "scale"),
                0.88,
                1.0,
                animation.SpringConfig.bouncy,
            );
        } else {
            self.anims.snapSpring(animation.hashKey("popup", "scale"), 1.0);
        }
    }

    fn approxTabIndicatorX(tab: Tab, vw: f32) f32 {
        const tab_gap = @min(8.0, @max(2.0, (vw - 180.0) * 0.25));
        const inner_w = @max(0.0, vw - 4.0 - 3.0 * tab_gap);
        const each_w = inner_w * 0.25;
        const ind_w = @min(@max(16.0, each_w * 0.56), each_w);
        const idx: f32 = @floatFromInt(@intFromEnum(tab));
        const tab_x = 2.0 + idx * (each_w + tab_gap);
        return tab_x + (each_w - ind_w) * 0.5;
    }

    fn switchTab(self: *ShowcaseApp, next_tab: Tab, logical_w: f32) void {
        const prev_tab = self.active_tab;
        self.active_tab = next_tab;
        self.overlays.closeAll();
        self.popup_title = "";
        self.anims.snapSpring(animation.hashKey("popup", "scale"), 1.0);
        if (next_tab != prev_tab and std.math.isFinite(logical_w) and logical_w > 0.0) {
            const key = animation.hashKey("tabs", "indicator_x");
            _ = self.anims.animateSpring(key, approxTabIndicatorX(prev_tab, logical_w), animation.SpringConfig.snappy);
            _ = self.anims.animateSpring(key, approxTabIndicatorX(next_tab, logical_w), animation.SpringConfig.snappy);
        }
    }

    fn applyIdAction(self: *ShowcaseApp, test_id: []const u8, toggled_val: ?bool, logical_w: f32, logical_h: f32) bool {
        if (std.mem.eql(u8, test_id, "tab_scroll")) {
            self.switchTab(.scroll, logical_w);
            return true;
        }
        if (std.mem.eql(u8, test_id, "tab_widgets")) {
            self.switchTab(.widgets, logical_w);
            return true;
        }
        if (std.mem.eql(u8, test_id, "tab_popups")) {
            self.switchTab(.popups, logical_w);
            return true;
        }
        if (std.mem.eql(u8, test_id, "tab_hud")) {
            self.switchTab(.hud, logical_w);
            return true;
        }
        if (parseIndexSuffix(test_id, "accent_", ACCENTS.len)) |idx| {
            self.accent_idx = @intCast(idx);
            return true;
        }
        if (std.mem.eql(u8, test_id, "btn_dec")) {
            if (self.counter > std.math.minInt(i32)) self.counter -= 1;
            return true;
        }
        if (std.mem.eql(u8, test_id, "btn_inc")) {
            if (self.counter < std.math.maxInt(i32)) self.counter += 1;
            return true;
        }
        if (std.mem.eql(u8, test_id, "wear_ambient")) {
            self.wear_ambient = toggled_val orelse !self.wear_ambient;
            return true;
        }
        if (std.mem.eql(u8, test_id, "hud_bounds")) {
            self.hud_bounds = toggled_val orelse !self.hud_bounds;
            return true;
        }
        if (std.mem.eql(u8, test_id, "hud_targets")) {
            self.hud_targets = toggled_val orelse !self.hud_targets;
            return true;
        }
        if (std.mem.eql(u8, test_id, "hud_budget")) {
            self.hud_budget = toggled_val orelse !self.hud_budget;
            return true;
        }
        if (std.mem.eql(u8, test_id, "pop_tl") or
            std.mem.eql(u8, test_id, "pop_tr") or
            std.mem.eql(u8, test_id, "pop_bl") or
            std.mem.eql(u8, test_id, "pop_br") or
            std.mem.eql(u8, test_id, "pop_modal"))
        {
            self.openCornerPopup(test_id, logical_w, logical_h);
            return true;
        }
        if (parseIndexSuffix(test_id, "card_toggle_", self.card_toggles.len)) |idx| {
            self.card_toggles[idx] = toggled_val orelse !self.card_toggles[idx];
            return true;
        }
        return false;
    }

    pub fn handleUiEvent(self: *ShowcaseApp, ev: events.UiEvent, logical_w: f32, logical_h: f32) bool {
        switch (ev) {
            .clicked => |c| return self.applyIdAction(c.test_id, null, logical_w, logical_h),
            .toggled => |t| return self.applyIdAction(t.test_id, t.checked, logical_w, logical_h),
            .changed_f32 => |ch| {
                if (std.mem.eql(u8, ch.test_id, "demo_slider")) {
                    if (std.math.isFinite(ch.value)) {
                        self.slider_value = sanitizeUnit(ch.value);
                        return true;
                    }
                }
                return false;
            },
            .shortcut => |s| {
                if (s.key == .escape and self.overlays.activeCount() > 0) {
                    _ = self.overlays.closeTop();
                    if (self.overlays.activeCount() == 0) {
                        self.popup_title = "";
                        self.anims.snapSpring(animation.hashKey("popup", "scale"), 1.0);
                    }
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn appendPostQuad(
        out_quads: []core.QuadInstance,
        count: *usize,
        limit: usize,
        rect: core.Rect,
        scale_factor: f32,
        color: core.Color,
        border_color: core.Color,
        corner_radius_dp: f32,
        border_width_px: f32,
        active_clip: [4]f32,
    ) void {
        if (count.* >= limit or count.* >= out_quads.len) return;
        if (!isPositiveFiniteRect(rect) or isClipEmpty(active_clip)) return;
        const phys = core.snapRectToPhysical(rect, scale_factor);
        if (!rectsIntersectClip(phys, active_clip)) return;
        out_quads[count.*] = .{
            .pos_size = .{ phys.x, phys.y, phys.w, phys.h },
            .color = core.sanitizeColor(color),
            .border_color = core.sanitizeColor(border_color),
            .params = .{
                @max(0.0, corner_radius_dp) * scale_factor,
                @max(0.0, border_width_px),
                0.0,
                0.0,
            },
            .clip_rect = active_clip,
        };
        count.* += 1;
    }

    fn emitTreeHud(
        self: *const ShowcaseApp,
        arena: *const core.LayoutArena,
        idx: u16,
        out_quads: []core.QuadInstance,
        count: *usize,
        limit: usize,
        scale_factor: f32,
        active_clip: [4]f32,
    ) void {
        if (count.* >= limit or count.* >= out_quads.len or isClipEmpty(active_clip)) return;
        const slice = arena.nodes.slice();
        const rect = slice.items(.rect)[idx];

        if (self.hud_bounds) {
            appendPostQuad(
                out_quads,
                count,
                limit,
                rect,
                scale_factor,
                core.Nord.transparent,
                core.Nord.frost_1,
                0.0,
                1.0 * scale_factor,
                active_clip,
            );
        }

        if (self.hud_targets and isInteractiveNode(arena, idx) and isPositiveFiniteRect(rect)) {
            const meets = (rect.w >= MIN_TOUCH_TARGET_DP and rect.h >= MIN_TOUCH_TARGET_DP);
            const col = if (meets) core.Nord.aurora_green else core.Nord.aurora_red;
            const min_dim = @min(rect.w, rect.h);
            const inset_x = @min(2.0, rect.w * 0.2);
            const inset_y = @min(2.0, rect.h * 0.2);
            const corner_sz = @min(8.0, @max(0.0, min_dim - @max(inset_x, inset_y) * 2.0));
            if (corner_sz > 0.0) {
                const corner_rect = core.Rect{
                    .x = rect.x + inset_x,
                    .y = rect.y + inset_y,
                    .w = corner_sz,
                    .h = corner_sz,
                };
                appendPostQuad(
                    out_quads,
                    count,
                    limit,
                    corner_rect,
                    scale_factor,
                    col,
                    core.Nord.polar_night_0,
                    2.0,
                    1.0 * scale_factor,
                    active_clip,
                );
            }
        }

        var child_clip = active_clip;
        if (slice.items(.scroll_props)[idx].clip_children) {
            if (!isPositiveFiniteRect(rect)) return;
            const phys = core.snapRectToPhysical(rect, scale_factor);
            child_clip = .{
                @max(active_clip[0], phys.x),
                @max(active_clip[1], phys.y),
                @min(active_clip[2], phys.x + phys.w),
                @min(active_clip[3], phys.y + phys.h),
            };
            if (isClipEmpty(child_clip)) return;
        }

        const next_siblings = slice.items(.next_sibling);
        var cur: ?u16 = slice.items(.first_child)[idx];
        while (cur) |c| : (cur = next_siblings[c]) {
            self.emitTreeHud(arena, c, out_quads, count, limit, scale_factor, child_clip);
            if (count.* >= limit or count.* >= out_quads.len) break;
        }
    }

    pub fn emitPostQuads(
        self: *ShowcaseApp,
        arena: *const core.LayoutArena,
        out_quads: []core.QuadInstance,
        start_idx: usize,
        logical_w: f32,
        logical_h: f32,
        scale_factor: f32,
        atlas: ?*glyph_atlas.GlyphAtlas,
        frame_idx: u64,
    ) usize {
        const safe_start = @min(start_idx, out_quads.len);
        if (!std.math.isFinite(logical_w) or !std.math.isFinite(logical_h) or
            logical_w <= 0.0 or logical_h <= 0.0 or
            !std.math.isFinite(scale_factor) or scale_factor <= 0.0)
        {
            return safe_start;
        }
        const vw_px = logical_w * scale_factor;
        const vh_px = logical_h * scale_factor;
        if (!std.math.isFinite(vw_px) or !std.math.isFinite(vh_px) or vw_px <= 0.0 or vh_px <= 0.0) {
            return safe_start;
        }

        // Transform Wear OS watch preview quads into OLED ambient wireframe in-place,
        // strictly bounded to quads clipped within showcase.body so scrolled quads cannot affect header/tabs.
        if (self.active_tab == .widgets and self.wear_ambient) {
            if (arena.findByTestId("wear_bezel")) |bezel_id| {
                if (arena.getRect(bezel_id)) |bezel_rect| {
                    const phys_bezel = core.snapRectToPhysical(bezel_rect, scale_factor);
                    var clip_min_x = phys_bezel.x;
                    var clip_min_y = phys_bezel.y;
                    var clip_max_x = phys_bezel.x + phys_bezel.w;
                    var clip_max_y = phys_bezel.y + phys_bezel.h;
                    var body_bounds: ?core.Rect = null;
                    if (self.scroll_container) |sc| {
                        if (arena.getRect(sc)) |body_rect| {
                            const phys_body = core.snapRectToPhysical(body_rect, scale_factor);
                            body_bounds = phys_body;
                            clip_min_x = @max(clip_min_x, phys_body.x);
                            clip_min_y = @max(clip_min_y, phys_body.y);
                            clip_max_x = @min(clip_max_x, phys_body.x + phys_body.w);
                            clip_max_y = @min(clip_max_y, phys_body.y + phys_body.h);
                        }
                    }
                    if (clip_max_x > clip_min_x and clip_max_y > clip_min_y) {
                        var i: usize = 0;
                        while (i < safe_start) : (i += 1) {
                            const q = out_quads[i];
                            if (body_bounds) |pb| {
                                if (q.clip_rect[1] < pb.y - 0.5 or q.clip_rect[3] > pb.y + pb.h + 0.5) {
                                    continue;
                                }
                            }
                            const qcx = q.pos_size[0] + q.pos_size[2] * 0.5;
                            const qcy = q.pos_size[1] + q.pos_size[3] * 0.5;
                            if (qcx >= clip_min_x and qcx <= clip_max_x and
                                qcy >= clip_min_y and qcy <= clip_max_y and
                                q.pos_size[2] <= phys_bezel.w + 2.0 and
                                q.pos_size[3] <= phys_bezel.h + 2.0)
                            {
                                wearos.transformQuadsForAmbient(out_quads[i .. i + 1], false);
                            }
                        }
                    }
                }
            }
        }

        var count: usize = safe_start;
        const full_clip = [4]f32{ 0.0, 0.0, vw_px, vh_px };

        // Reserve 2 atomic slots for hud_budget so tab indicator / hud_bounds / hud_targets cannot starve it.
        const margin = @min(8.0, @min(logical_w, logical_h) * 0.1);
        const pill_w = @min(108.0, @max(0.0, logical_w - margin * 2.0));
        const pill_h: f32 = 8.0;
        const pill_y: f32 = 2.0;
        const can_draw_budget = self.hud_budget and pill_w > 4.0 and logical_h >= pill_y + pill_h + margin;
        const budget_reserve: usize = if (can_draw_budget and out_quads.len >= count + 2) 2 else 0;
        const hud_limit = out_quads.len - budget_reserve;

        // 0. Gliding active tab underline indicator pill (snappy spring across the 4 tabs)
        const cur_accent = self.anims.animateColor(
            animation.hashKey("theme", "accent"),
            self.accent(),
            animation.SpringConfig.gentle,
        );
        const active_tab_id = switch (self.active_tab) {
            .scroll => "tab_scroll",
            .widgets => "tab_widgets",
            .popups => "tab_popups",
            .hud => "tab_hud",
        };
        if (arena.findByTestId(active_tab_id)) |tab_nid| {
            if (arena.getRect(tab_nid)) |tab_r| {
                if (isPositiveFiniteRect(tab_r)) {
                    const ind_w = @min(@max(16.0, tab_r.w * 0.56), tab_r.w);
                    const target_tab_x = tab_r.x + (tab_r.w - ind_w) * 0.5;
                    const tab_key = animation.hashKey("tabs", "indicator_x");
                    if (self.last_tab_vw > 0.0 and @abs(logical_w - self.last_tab_vw) > 0.5) {
                        self.anims.snapSpring(tab_key, target_tab_x);
                    }
                    self.last_tab_vw = logical_w;
                    const ind_x = self.anims.animateSpring(
                        tab_key,
                        target_tab_x,
                        animation.SpringConfig.snappy,
                    );
                    const ind_h: f32 = 3.0;
                    const ind_y = tab_r.y + tab_r.h - 1.5;
                    if (count < hud_limit and count < out_quads.len) {
                        const ind_rect = core.Rect{ .x = ind_x, .y = ind_y, .w = ind_w, .h = ind_h };
                        const phys_ind = core.snapRectToPhysical(ind_rect, scale_factor);
                        if (rectsIntersectClip(phys_ind, full_clip)) {
                            out_quads[count] = .{
                                .pos_size = .{ phys_ind.x, phys_ind.y, phys_ind.w, phys_ind.h },
                                .color = core.sanitizeColor(cur_accent),
                                .border_color = withAlpha(core.Nord.snow_storm_2, 0.45),
                                .params = .{ (ind_h * 0.5) * scale_factor, 0.5 * scale_factor, 6.0 * scale_factor, 0.0 },
                                .clip_rect = full_clip,
                            };
                            count += 1;
                        }
                    }
                }
            }
        }

        // 1. Active overlays (escaping all parent scissors) + bouncy scale-in + popup title text
        if (self.overlays.activeCount() > 0 and count < hud_limit) {
            const ov_start = count;
            const ov_n = self.overlays.emitOverlayQuadsScaled(logical_w, logical_h, scale_factor, out_quads[count..hud_limit]);
            count += ov_n;
            const pop_scale = @max(0.1, self.anims.animateSpring(
                animation.hashKey("popup", "scale"),
                1.0,
                animation.SpringConfig.bouncy,
            ));
            if (ov_n > 0) {
                const pq = &out_quads[ov_start + ov_n - 1];
                pq.border_color = core.sanitizeColor(cur_accent);
                if (@abs(pop_scale - 1.0) > 1.0e-4) {
                    const cx = pq.pos_size[0] + pq.pos_size[2] * 0.5;
                    const cy = pq.pos_size[1] + pq.pos_size[3] * 0.5;
                    const nw = pq.pos_size[2] * pop_scale;
                    const nh = pq.pos_size[3] * pop_scale;
                    pq.pos_size = .{ cx - nw * 0.5, cy - nh * 0.5, nw, nh };
                    pq.params[0] *= pop_scale;
                }
                if (atlas) |a| {
                    if (self.overlays.top()) |top| {
                        if (self.popup_title.len > 0 and count < hud_limit and top.rect.w > 24.0 and top.rect.h >= 34.0) {
                            const phys_pop = core.snapRectToPhysical(top.rect, scale_factor);
                            const pop_clip = [4]f32{
                                @max(full_clip[0], phys_pop.x),
                                @max(full_clip[1], phys_pop.y),
                                @min(full_clip[2], phys_pop.x + phys_pop.w),
                                @min(full_clip[3], phys_pop.y + phys_pop.h),
                            };
                            if (!isClipEmpty(pop_clip)) {
                                count += a.emitTextQuadsClipped(
                                    self.popup_title,
                                    top.rect.x + 14.0,
                                    top.rect.y + 10.0,
                                    16.0,
                                    scale_factor,
                                    core.Nord.snow_storm_2,
                                    pop_clip,
                                    out_quads[count..hud_limit],
                                    frame_idx,
                                );
                                if (top.rect.h >= 64.0 and count < hud_limit) {
                                    count += a.emitTextQuadsClipped(
                                        "Tap outside to dismiss",
                                        top.rect.x + 14.0,
                                        top.rect.y + 38.0,
                                        12.0,
                                        scale_factor,
                                        core.Nord.snow_storm_0,
                                        pop_clip,
                                        out_quads[count..hud_limit],
                                        frame_idx,
                                    );
                                }
                            }
                        }
                    }
                }
            }
        }

        // 2 & 3. HUD Layout Bounds & 44dp Hit Targets
        if ((self.hud_bounds or self.hud_targets) and count < hud_limit) {
            if (arena.root_index) |root| {
                self.emitTreeHud(arena, root, out_quads, &count, hud_limit, scale_factor, full_clip);
            }
        }

        // 4. Sleek top-right frame-budget bar (last_frame_ms / 16.67 ms)
        if (can_draw_budget and count + 2 <= out_quads.len) {
            const pill_x = logical_w - pill_w - margin;
            const safe_ms = sanitizeFrameMs(self.last_frame_ms);
            const over_budget = safe_ms > FRAME_BUDGET_MS;
            const status_col = if (over_budget) core.Nord.aurora_red else core.Nord.aurora_green;

            appendPostQuad(
                out_quads,
                &count,
                out_quads.len,
                .{ .x = pill_x, .y = pill_y, .w = pill_w, .h = pill_h },
                scale_factor,
                withAlpha(core.Nord.polar_night_0, 0.92),
                status_col,
                pill_h * 0.5,
                1.0 * scale_factor,
                full_clip,
            );

            const pad_x: f32 = 2.0;
            const bar_max_w = @max(0.0, pill_w - pad_x * 2.0);
            const bar_h = @max(2.0, pill_h - 4.0);
            const ratio = std.math.clamp(safe_ms / FRAME_BUDGET_MS, 0.05, 1.0);
            appendPostQuad(
                out_quads,
                &count,
                out_quads.len,
                .{ .x = pill_x + pad_x, .y = pill_y + 2.0, .w = bar_max_w * ratio, .h = bar_h },
                scale_factor,
                status_col,
                core.Nord.transparent,
                bar_h * 0.5,
                0.0,
                full_clip,
            );
        }

        return count;
    }
};
