const std = @import("std");
const core = @import("core.zig");
const tokens = @import("tokens.zig");
const declarative = @import("declarative.zig");

pub const DPI_PRESETS = [_]f32{ 1.0, 1.25, 1.5, 2.0 };
pub const MIN_TOUCH_TARGET_DP: f32 = 44.0;
pub const FRAME_HISTORY_CAP: usize = 32;

pub const HudFlags = struct {
    show_layout_bounds: bool = false,
    show_hit_targets: bool = false,
    show_frame_budget: bool = false,
};

const SceneSource = enum {
    none,
    builtin_gallery,
    json,
};

const BuiltScene = struct {
    arena: core.LayoutArena,
    strings: std.heap.ArenaAllocator,
    json_copy: ?[]u8,
    source: SceneSource,

    fn deinit(self: *BuiltScene, allocator: std.mem.Allocator) void {
        if (self.json_copy) |buf| {
            allocator.free(buf);
        }
        self.strings.deinit();
        self.arena.deinit();
    }
};

fn withAlpha(c: core.Color, alpha: f32) core.Color {
    return .{ c[0], c[1], c[2], alpha };
}

fn sanitizeNonNeg(v: f32) f32 {
    if (!std.math.isFinite(v) or v < 0.0) return 0.0;
    return v;
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

pub const Workbench = struct {
    allocator: std.mem.Allocator,
    arena: core.LayoutArena,
    string_arena: std.heap.ArenaAllocator,
    quads: std.ArrayList(core.QuadInstance) = .empty,
    token_table: tokens.TokenTable,
    mmap_tokens: ?tokens.MmapTokenBuffer = null,
    token_generation: u32,
    width: f32,
    height: f32,
    scale_factor: f32 = DPI_PRESETS[0],
    dpi_index: usize = 0,
    hud_flags: HudFlags = .{},
    last_quad_count: usize = 0,
    hud_quad_count: usize = 0,
    last_frame_us: u32 = 0,
    budget_us: u32 = 16_666,
    frame_history: [FRAME_HISTORY_CAP]u32 = @splat(0),
    frame_history_count: usize = 0,
    frame_history_head: usize = 0,
    dirty: bool = true,
    scene_source: SceneSource = .none,
    last_json: ?[]u8 = null,
    deinitialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32) !Workbench {
        if (!std.math.isFinite(width) or !std.math.isFinite(height) or width <= 0.0 or height <= 0.0) {
            return error.InvalidViewport;
        }
        const tbl = tokens.TokenTable.nordDefault();
        return .{
            .allocator = allocator,
            .arena = core.LayoutArena.init(allocator),
            .string_arena = std.heap.ArenaAllocator.init(allocator),
            .token_table = tbl,
            .token_generation = tbl.version,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Workbench) void {
        if (self.deinitialized) return;
        self.deinitialized = true;
        if (self.mmap_tokens) |*buf| {
            buf.close();
            self.mmap_tokens = null;
        }
        if (self.last_json) |buf| {
            self.allocator.free(buf);
            self.last_json = null;
        }
        self.quads.deinit(self.allocator);
        self.string_arena.deinit();
        self.arena.deinit();
    }

    pub fn setViewport(self: *Workbench, width: f32, height: f32) !void {
        if (!std.math.isFinite(width) or !std.math.isFinite(height) or width <= 0.0 or height <= 0.0) {
            return error.InvalidViewport;
        }
        self.width = width;
        self.height = height;
        self.dirty = true;
    }

    pub fn loadSceneJson(self: *Workbench, json_bytes: []const u8) !void {
        if (json_bytes.len > declarative.MAX_JSON_BYTES) {
            return error.JsonTooLarge;
        }

        var next_arena = core.LayoutArena.init(self.allocator);
        errdefer next_arena.deinit();

        var next_strings = std.heap.ArenaAllocator.init(self.allocator);
        errdefer next_strings.deinit();

        _ = try declarative.loadJsonIntoArena(
            self.allocator,
            next_strings.allocator(),
            &next_arena,
            &self.token_table,
            json_bytes,
        );

        const json_copy = try self.allocator.dupe(u8, json_bytes);
        errdefer self.allocator.free(json_copy);

        self.commitScene(.{
            .arena = next_arena,
            .strings = next_strings,
            .json_copy = json_copy,
            .source = .json,
        });
        self.dirty = true;
    }

    pub fn loadBuiltinGallery(self: *Workbench) !void {
        var next_arena = core.LayoutArena.init(self.allocator);
        errdefer next_arena.deinit();

        try populateGallery(&next_arena, &self.token_table);

        self.commitScene(.{
            .arena = next_arena,
            .strings = std.heap.ArenaAllocator.init(self.allocator),
            .json_copy = null,
            .source = .builtin_gallery,
        });
        self.dirty = true;
    }

    pub fn attachTokenFile(self: *Workbench, path: []const u8) !void {
        if (path.len == 0 or path.len >= 4096 or std.mem.indexOfScalar(u8, path, 0) != null) {
            return error.InvalidPath;
        }
        var path_z_buf: [4096]u8 = undefined;
        @memcpy(path_z_buf[0..path.len], path);
        path_z_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_z_buf);

        var next_buf = try tokens.MmapTokenBuffer.open(path_z);
        var committed = false;
        errdefer if (!committed) next_buf.close();

        const next_table = next_buf.current().*;
        var next_scene_opt = try self.buildSceneForTable(&next_table);
        errdefer if (next_scene_opt) |*s| s.deinit(self.allocator);

        if (self.mmap_tokens) |*old_buf| {
            old_buf.close();
        }
        self.mmap_tokens = next_buf;
        committed = true;

        if (next_scene_opt) |next_scene| {
            self.commitScene(next_scene);
        }
        self.token_table = next_table;
        self.token_generation = next_table.version;
        self.dirty = true;
    }

    pub fn pollTokenReload(self: *Workbench) !bool {
        const buf = if (self.mmap_tokens) |*b| b else return false;
        const disk_changed = buf.pollReload();
        const cur_table = buf.current();
        const out_of_sync = (cur_table.version != self.token_generation) or
            (cur_table.checksum != self.token_table.checksum);
        if (!disk_changed and !out_of_sync) return false;

        var next_scene_opt = try self.buildSceneForTable(cur_table);
        errdefer if (next_scene_opt) |*s| s.deinit(self.allocator);

        if (next_scene_opt) |next_scene| {
            self.commitScene(next_scene);
        }
        self.token_table = cur_table.*;
        self.token_generation = self.token_table.version;
        self.dirty = true;
        return true;
    }

    pub fn setDpiPreset(self: *Workbench, idx: usize) void {
        if (idx >= DPI_PRESETS.len) return;
        self.dpi_index = idx;
        self.scale_factor = DPI_PRESETS[idx];
        self.dirty = true;
    }

    pub fn cycleDpiPreset(self: *Workbench) void {
        self.setDpiPreset((self.dpi_index + 1) % DPI_PRESETS.len);
    }

    pub fn stepFrame(self: *Workbench, frame_us: u32) !void {
        self.arena.layout(self.width, self.height);

        const max_scene_quads = @max(@as(usize, 64), self.arena.nodes.len * 8);
        const max_hud_quads: usize =
            (if (self.hud_flags.show_layout_bounds) self.arena.nodes.len else 0) +
            (if (self.hud_flags.show_hit_targets) self.arena.nodes.len else 0) +
            (if (self.hud_flags.show_frame_budget) @as(usize, 2) else 0);
        try self.quads.ensureTotalCapacity(self.allocator, max_scene_quads + max_hud_quads);

        self.last_frame_us = frame_us;
        self.frame_history[self.frame_history_head] = frame_us;
        self.frame_history_head = (self.frame_history_head + 1) % FRAME_HISTORY_CAP;
        if (self.frame_history_count < FRAME_HISTORY_CAP) {
            self.frame_history_count += 1;
        }

        const buf_all = self.quads.allocatedSlice();
        const scene_count = self.arena.emitQuads(buf_all[0..max_scene_quads], self.scale_factor);
        self.quads.items.len = scene_count;

        self.hud_quad_count = 0;
        const viewport_clip = [4]f32{
            0.0,
            0.0,
            self.width * self.scale_factor,
            self.height * self.scale_factor,
        };
        if (self.hud_flags.show_layout_bounds or self.hud_flags.show_hit_targets) {
            if (self.arena.root_index) |root| {
                self.appendTreeHudNode(root, viewport_clip);
            }
        }
        if (self.hud_flags.show_frame_budget) {
            self.appendFrameBudgetHud(viewport_clip);
        }

        self.last_quad_count = self.quads.items.len;
        self.dirty = false;
    }

    pub fn avgFrameUs(self: *const Workbench) u32 {
        if (self.frame_history_count == 0) return 0;
        var sum: u64 = 0;
        for (0..self.frame_history_count) |i| {
            sum += self.frame_history[i];
        }
        return @intCast(sum / self.frame_history_count);
    }

    pub fn isOverBudget(self: *const Workbench) bool {
        return self.last_frame_us > self.budget_us;
    }

    fn buildSceneForTable(self: *Workbench, table: *const tokens.TokenTable) !?BuiltScene {
        switch (self.scene_source) {
            .none => return null,
            .builtin_gallery => {
                var next_arena = core.LayoutArena.init(self.allocator);
                errdefer next_arena.deinit();
                try populateGallery(&next_arena, table);
                return .{
                    .arena = next_arena,
                    .strings = std.heap.ArenaAllocator.init(self.allocator),
                    .json_copy = null,
                    .source = .builtin_gallery,
                };
            },
            .json => {
                const json_bytes = self.last_json orelse return null;
                var next_arena = core.LayoutArena.init(self.allocator);
                errdefer next_arena.deinit();
                var next_strings = std.heap.ArenaAllocator.init(self.allocator);
                errdefer next_strings.deinit();
                _ = try declarative.loadJsonIntoArena(
                    self.allocator,
                    next_strings.allocator(),
                    &next_arena,
                    table,
                    json_bytes,
                );
                const json_copy = try self.allocator.dupe(u8, json_bytes);
                errdefer self.allocator.free(json_copy);
                return .{
                    .arena = next_arena,
                    .strings = next_strings,
                    .json_copy = json_copy,
                    .source = .json,
                };
            },
        }
    }

    fn commitScene(self: *Workbench, scene: BuiltScene) void {
        if (self.last_json) |old_json| {
            self.allocator.free(old_json);
        }
        self.string_arena.deinit();
        self.arena.deinit();

        self.arena = scene.arena;
        self.string_arena = scene.strings;
        self.last_json = scene.json_copy;
        self.scene_source = scene.source;
    }

    fn appendPhysicalQuadAssumeCapacity(
        self: *Workbench,
        rect: core.Rect,
        color: core.Color,
        border_color: core.Color,
        corner_radius_dp: f32,
        border_width_px: f32,
        active_clip: [4]f32,
    ) bool {
        if (!isPositiveFiniteRect(rect) or isClipEmpty(active_clip)) return false;
        const phys = core.snapRectToPhysical(rect, self.scale_factor);
        if (!rectsIntersectClip(phys, active_clip)) return false;
        self.quads.appendAssumeCapacity(.{
            .pos_size = .{ phys.x, phys.y, phys.w, phys.h },
            .color = core.sanitizeColor(color),
            .border_color = core.sanitizeColor(border_color),
            .params = .{
                sanitizeNonNeg(corner_radius_dp) * self.scale_factor,
                sanitizeNonNeg(border_width_px),
                0.0,
                0.0,
            },
            .clip_rect = active_clip,
        });
        return true;
    }

    fn appendTreeHudNode(self: *Workbench, idx: u16, active_clip: [4]f32) void {
        if (isClipEmpty(active_clip)) return;
        const slice = self.arena.nodes.slice();
        const rect = slice.items(.rect)[idx];
        const kind = slice.items(.kind)[idx];
        const radius = slice.items(.corner_radius)[idx];

        if (self.hud_flags.show_layout_bounds) {
            const border_col = switch (kind) {
                .vstack, .hstack, .zstack, .grid => core.Nord.frost_1,
                else => core.Nord.aurora_purple,
            };
            if (self.appendPhysicalQuadAssumeCapacity(rect, core.Nord.transparent, border_col, 0.0, 1.0, active_clip)) {
                self.hud_quad_count += 1;
            }
        }

        if (self.hud_flags.show_hit_targets and isInteractiveNode(&self.arena, idx)) {
            const ok_border = self.token_table.accent_success.toSrgb();
            const warn_border = self.token_table.accent_danger.toSrgb();
            const too_small = rect.w < MIN_TOUCH_TARGET_DP or rect.h < MIN_TOUCH_TARGET_DP;
            const border_col = if (too_small) warn_border else ok_border;
            const fill_col = withAlpha(border_col, if (too_small) 0.28 else 0.18);
            if (self.appendPhysicalQuadAssumeCapacity(rect, fill_col, border_col, radius, 1.5 * self.scale_factor, active_clip)) {
                self.hud_quad_count += 1;
            }
        }

        var child_clip = active_clip;
        if (slice.items(.scroll_props)[idx].clip_children) {
            if (!isPositiveFiniteRect(rect)) return;
            const phys = core.snapRectToPhysical(rect, self.scale_factor);
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
            self.appendTreeHudNode(c, child_clip);
        }
    }

    fn appendFrameBudgetHud(self: *Workbench, viewport_clip: [4]f32) void {
        const margin = @min(8.0, @min(self.width, self.height) * 0.1);
        const avail_w = @max(0.0, self.width - margin * 2.0);
        const avail_h = @max(0.0, self.height - margin * 2.0);
        const pill_w = @min(160.0, avail_w);
        const pill_h = @min(24.0, avail_h);
        if (pill_w <= 0.0 or pill_h <= 0.0) return;

        const pill_x = self.width - pill_w - margin;
        const pill_y = margin;

        const status_col = if (self.isOverBudget())
            self.token_table.accent_danger.toSrgb()
        else
            self.token_table.accent_success.toSrgb();
        const pill_bg = withAlpha(self.token_table.bg_elevated.toSrgb(), 0.92);

        if (self.appendPhysicalQuadAssumeCapacity(
            .{ .x = pill_x, .y = pill_y, .w = pill_w, .h = pill_h },
            pill_bg,
            status_col,
            pill_h * 0.5,
            1.5 * self.scale_factor,
            viewport_clip,
        )) {
            self.hud_quad_count += 1;
        }

        const pad_x = @min(6.0, pill_w * 0.15);
        const bar_max_w = @max(0.0, pill_w - pad_x * 2.0);
        const bar_h = @min(8.0, @max(0.0, pill_h - 4.0));
        if (bar_max_w <= 0.0 or bar_h <= 0.0) return;

        const ratio: f32 = if (self.budget_us > 0)
            std.math.clamp(
                @as(f32, @floatFromInt(self.last_frame_us)) / @as(f32, @floatFromInt(self.budget_us)),
                0.05,
                1.0,
            )
        else
            1.0;
        const bar_w = bar_max_w * ratio;
        const bar_x = pill_x + pad_x;
        const bar_y = pill_y + (pill_h - bar_h) * 0.5;

        if (self.appendPhysicalQuadAssumeCapacity(
            .{ .x = bar_x, .y = bar_y, .w = bar_w, .h = bar_h },
            status_col,
            core.Nord.transparent,
            bar_h * 0.5,
            0.0,
            viewport_clip,
        )) {
            self.hud_quad_count += 1;
        }
    }
};

fn populateGallery(arena: *core.LayoutArena, tbl: *const tokens.TokenTable) !void {
    const surface_s = tbl.resolve(.surface, .{});
    const card_s = tbl.resolve(.card, .{});
    const btn_s = tbl.resolve(.button, .{});
    const btn_hover_s = tbl.resolve(.button, .{ .hover = true });
    const btn_active_s = tbl.resolve(.button, .{ .checked = true });
    const toggle_off_s = tbl.resolve(.toggle, .{});
    const toggle_on_s = tbl.resolve(.toggle, .{ .checked = true });
    const slider_s = tbl.resolve(.slider, .{});
    const bar_s = tbl.resolve(.bar, .{});
    const input_s = tbl.resolve(.input, .{ .focus_visible = true });

    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .test_id = "gallery.root",
        .padding = tbl.space_md,
        .gap = tbl.space_sm,
        .fill = surface_s.fill,
        .clip_children = true,
    });

    // Header
    _ = try arena.addChild(root, .{
        .kind = .card,
        .role = .panel,
        .test_id = "gallery.header",
        .label = "Nord Widget Gallery",
        .sublabel = "Live Oklab Tokens + UberQuad SDF",
        .font_size = 18.0,
        .text_color = card_s.text,
        .height = 64.0,
        .padding = tbl.space_sm,
        .corner_radius = card_s.corner_radius,
        .border_width = card_s.border_width,
        .shadow_blur = card_s.shadow_blur,
        .fill = card_s.fill,
        .border = tbl.border_focus.toSrgb(),
        .accent = card_s.accent,
    });

    // Buttons row (includes >= 44dp buttons + 1 compact < 44dp target for hit-target HUD audit)
    const btn_row = try arena.addChild(root, .{
        .kind = .hstack,
        .role = .container,
        .test_id = "gallery.buttons",
        .height = 48.0,
        .gap = tbl.space_sm,
    });
    _ = try arena.addChild(btn_row, .{
        .kind = .card,
        .role = .panel,
        .test_id = "gallery.btn_primary",
        .label = "Primary Action",
        .text_color = btn_active_s.text,
        .width = 148.0,
        .height = 48.0,
        .corner_radius = btn_active_s.corner_radius,
        .border_width = btn_active_s.border_width,
        .shadow_blur = btn_active_s.shadow_blur,
        .fill = btn_active_s.fill,
        .border = btn_active_s.border,
        .focusable = true,
    });
    _ = try arena.addChild(btn_row, .{
        .kind = .card,
        .role = .panel,
        .test_id = "gallery.btn_secondary",
        .label = "Secondary",
        .text_color = btn_s.text,
        .width = 128.0,
        .height = 48.0,
        .corner_radius = btn_s.corner_radius,
        .border_width = btn_s.border_width,
        .shadow_blur = btn_s.shadow_blur,
        .fill = btn_hover_s.fill,
        .border = btn_s.border,
        .focusable = true,
    });
    _ = try arena.addChild(btn_row, .{
        .kind = .card,
        .role = .panel,
        .test_id = "gallery.btn_compact",
        .label = "+",
        .text_color = btn_s.text,
        .width = 32.0,
        .height = 32.0,
        .corner_radius = tbl.corner_radius_sm,
        .border_width = btn_s.border_width,
        .fill = btn_s.fill,
        .border = btn_s.border,
        .focusable = true,
    });

    // Status pills row
    const pills_row = try arena.addChild(root, .{
        .kind = .hstack,
        .role = .container,
        .test_id = "gallery.status_pills",
        .height = 32.0,
        .gap = tbl.space_sm,
    });
    _ = try arena.addChild(pills_row, .{
        .kind = .bar,
        .role = .progress_bar,
        .test_id = "gallery.pill_ok",
        .label = "OK",
        .text_color = bar_s.text,
        .corner_radius = tbl.corner_radius_lg,
        .border_width = bar_s.border_width,
        .fill = bar_s.fill,
        .border = tbl.accent_success.toSrgb(),
        .accent = tbl.accent_success.toSrgb(),
        .slider_val = 0.92,
    });
    _ = try arena.addChild(pills_row, .{
        .kind = .bar,
        .role = .progress_bar,
        .test_id = "gallery.pill_warn",
        .label = "WARN",
        .text_color = bar_s.text,
        .corner_radius = tbl.corner_radius_lg,
        .border_width = bar_s.border_width,
        .fill = bar_s.fill,
        .border = tbl.accent_warn.toSrgb(),
        .accent = tbl.accent_warn.toSrgb(),
        .slider_val = 0.65,
    });
    _ = try arena.addChild(pills_row, .{
        .kind = .bar,
        .role = .progress_bar,
        .test_id = "gallery.pill_danger",
        .label = "ERR",
        .text_color = bar_s.text,
        .corner_radius = tbl.corner_radius_lg,
        .border_width = bar_s.border_width,
        .fill = bar_s.fill,
        .border = tbl.accent_danger.toSrgb(),
        .accent = tbl.accent_danger.toSrgb(),
        .slider_val = 0.35,
    });

    // Cards row
    const cards_row = try arena.addChild(root, .{
        .kind = .hstack,
        .role = .container,
        .test_id = "gallery.cards",
        .height = 76.0,
        .gap = tbl.space_sm,
    });
    _ = try arena.addChild(cards_row, .{
        .kind = .card,
        .role = .panel,
        .test_id = "gallery.card_surface",
        .label = "Surface Card",
        .sublabel = "Oklab LCH",
        .text_color = card_s.text,
        .padding = tbl.space_sm,
        .corner_radius = card_s.corner_radius,
        .border_width = card_s.border_width,
        .shadow_blur = card_s.shadow_blur,
        .fill = card_s.fill,
        .border = card_s.border,
    });
    _ = try arena.addChild(cards_row, .{
        .kind = .card,
        .role = .panel,
        .test_id = "gallery.card_elevated",
        .label = "Elevated Card",
        .sublabel = "Zero Alloc",
        .text_color = card_s.text,
        .padding = tbl.space_sm,
        .corner_radius = card_s.corner_radius,
        .border_width = card_s.border_width,
        .shadow_blur = tbl.shadow_md,
        .fill = tbl.bg_elevated.toSrgb(),
        .border = tbl.border_default.toSrgb(),
    });

    // Toggles, Slider & Input
    _ = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "gallery.toggle_on",
        .label = "Hot Reload",
        .text_color = toggle_on_s.text,
        .height = 48.0,
        .corner_radius = toggle_on_s.corner_radius,
        .border_width = toggle_on_s.border_width,
        .fill = toggle_on_s.fill,
        .border = toggle_on_s.border,
        .accent = toggle_on_s.accent,
        .checked = true,
    });
    _ = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "gallery.toggle_off",
        .label = "Debug HUD",
        .text_color = toggle_off_s.text,
        .height = 48.0,
        .corner_radius = toggle_off_s.corner_radius,
        .border_width = toggle_off_s.border_width,
        .fill = toggle_off_s.fill,
        .border = toggle_off_s.border,
        .accent = toggle_off_s.accent,
        .checked = false,
    });
    _ = try arena.addChild(root, .{
        .kind = .slider,
        .role = .slider,
        .test_id = "gallery.slider_scale",
        .label = "Corner Radius",
        .text_color = slider_s.text,
        .height = 56.0,
        .corner_radius = slider_s.corner_radius,
        .border_width = slider_s.border_width,
        .fill = slider_s.fill,
        .border = slider_s.border,
        .accent = slider_s.accent,
        .slider_val = 0.65,
    });
    _ = try arena.addChild(root, .{
        .kind = .card,
        .role = .panel,
        .test_id = "gallery.input_filter",
        .label = "Filter tokens...",
        .text_color = input_s.text,
        .height = 44.0,
        .corner_radius = input_s.corner_radius,
        .border_width = input_s.border_width,
        .fill = input_s.fill,
        .border = input_s.border,
        .focusable = true,
    });
}
