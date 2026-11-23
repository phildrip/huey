const std = @import("std");

pub const NodeId = packed struct(u32) {
    index: u16,
    gen: u16,
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

pub const Color = [4]f32;

pub const QuadInstance = extern struct {
    pos_size: [4]f32,
    uv_rect: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    color: [4]f32,
    border_color: [4]f32,
    params: [4]f32, // [corner_radius, border_width, shadow_blur, mode (0=SDF, 1=glyph)]
};

fn hexColor(comptime rgb: u24) Color {
    const r: f32 = @floatFromInt((rgb >> 16) & 0xFF);
    const g: f32 = @floatFromInt((rgb >> 8) & 0xFF);
    const b: f32 = @floatFromInt(rgb & 0xFF);
    return .{ r / 255.0, g / 255.0, b / 255.0, 1.0 };
}

pub const Nord = struct {
    // Polar Night
    pub const polar_night_0: Color = hexColor(0x2E3440);
    pub const polar_night_1: Color = hexColor(0x3B4252);
    pub const polar_night_2: Color = hexColor(0x434C5E);
    pub const polar_night_3: Color = hexColor(0x4C566A);

    // Snow Storm
    pub const snow_storm_0: Color = hexColor(0xD8DEE9);
    pub const snow_storm_1: Color = hexColor(0xE5E9F0);
    pub const snow_storm_2: Color = hexColor(0xECEFF4);

    // Frost
    pub const frost_0: Color = hexColor(0x8FBCBB);
    pub const frost_1: Color = hexColor(0x88C0D0);
    pub const frost_2: Color = hexColor(0x81A1C1);
    pub const frost_3: Color = hexColor(0x5E81AC);

    // Aurora
    pub const aurora_red: Color = hexColor(0xBF616A);
    pub const aurora_orange: Color = hexColor(0xD08770);
    pub const aurora_yellow: Color = hexColor(0xEBCB8B);
    pub const aurora_green: Color = hexColor(0xA3BE8C);
    pub const aurora_purple: Color = hexColor(0xB48EAD);

    pub const transparent: Color = .{ 0.0, 0.0, 0.0, 0.0 };
};

pub const MAX_GRID_COLS: u16 = 64;

fn sanitizeFinite(v: f32) f32 {
    if (!std.math.isFinite(v)) return 0.0;
    return v;
}

fn sanitizeNonNeg(v: f32) f32 {
    if (!std.math.isFinite(v) or v < 0.0) return 0.0;
    return v;
}

fn clampF32(v: f64) f32 {
    if (!std.math.isFinite(v)) return 0.0;
    const max_f: f64 = std.math.floatMax(f32);
    const clamped = std.math.clamp(v, -max_f, max_f);
    const f: f32 = @floatCast(clamped);
    return if (std.math.isFinite(f)) f else 0.0;
}

fn clampDim(val: f32, min_v_raw: f32, max_v_raw: f32) f32 {
    const min_v = sanitizeNonNeg(min_v_raw);
    const max_v_san = sanitizeNonNeg(max_v_raw);
    var v = sanitizeNonNeg(val);
    if (max_v_san > 0.0) {
        const eff_max = @max(min_v, max_v_san);
        v = @min(v, eff_max);
    }
    return @max(v, min_v);
}

fn sanitizeUnit(v: f32) f32 {
    if (!std.math.isFinite(v)) return 0.0;
    return std.math.clamp(v, 0.0, 1.0);
}

fn sanitizeFontSize(v: f32) f32 {
    if (!std.math.isFinite(v) or v <= 0.0) return 16.0;
    return v;
}

fn linearToSrgb(c: f32) f32 {
    const x = sanitizeUnit(c);
    if (x <= 0.0031308) {
        return 12.92 * x;
    }
    return 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
}

fn srgbToLinear(c: f32) f32 {
    const x = sanitizeUnit(c);
    if (x <= 0.04045) {
        return x / 12.92;
    }
    return std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

pub fn srgbToOklabL(color: Color) f32 {
    const r = srgbToLinear(color[0]);
    const g = srgbToLinear(color[1]);
    const b = srgbToLinear(color[2]);

    const l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
    const m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
    const s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;

    const l_ = std.math.cbrt(@max(0.0, l));
    const m_ = std.math.cbrt(@max(0.0, m));
    const s_ = std.math.cbrt(@max(0.0, s));

    const l_ok = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    return sanitizeUnit(l_ok);
}

pub fn oklabToSrgb(l_ok: f32, a_ok: f32, b_ok: f32, alpha: f32) Color {
    const l_ = l_ok + 0.3963377774 * a_ok + 0.2158037573 * b_ok;
    const m_ = l_ok - 0.1055613458 * a_ok - 0.0638541728 * b_ok;
    const s_ = l_ok - 0.0894841775 * a_ok - 1.2914855480 * b_ok;

    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;

    const r_lin = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    const g_lin = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    const b_lin = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;

    return .{
        linearToSrgb(r_lin),
        linearToSrgb(g_lin),
        linearToSrgb(b_lin),
        sanitizeUnit(alpha),
    };
}

pub fn snapRectToPhysical(r: Rect, scale: f32) Rect {
    if (!std.math.isFinite(scale) or scale <= 0.0) return .{};
    if (!std.math.isFinite(r.x) or !std.math.isFinite(r.y) or
        !std.math.isFinite(r.w) or !std.math.isFinite(r.h))
    {
        return .{};
    }
    const w = sanitizeNonNeg(r.w);
    const h = sanitizeNonNeg(r.h);
    const x0 = @round(r.x * scale);
    const y0 = @round(r.y * scale);
    const x1 = @round((r.x + w) * scale);
    const y1 = @round((r.y + h) * scale);
    if (!std.math.isFinite(x0) or !std.math.isFinite(y0) or
        !std.math.isFinite(x1) or !std.math.isFinite(y1))
    {
        return .{};
    }
    const pw = x1 - x0;
    const ph = y1 - y0;
    if (!std.math.isFinite(pw) or !std.math.isFinite(ph)) {
        return .{};
    }
    return .{
        .x = x0,
        .y = y0,
        .w = @max(0.0, pw),
        .h = @max(0.0, ph),
    };
}

pub const Justify = enum {
    start,
    center,
    end,
    space_between,
    space_around,
    space_evenly,
};

pub const Align = enum {
    start,
    center,
    end,
    stretch,
};

pub const NodeKind = enum {
    vstack,
    hstack,
    zstack,
    grid,
    card,
    toggle,
    slider,
    bar,
};

pub const SemanticRole = enum {
    container,
    panel,
    switch_control,
    slider,
    progress_bar,
    swatch,
};

pub const NodeDesc = struct {
    kind: NodeKind = .vstack,
    role: SemanticRole = .container,
    test_id: []const u8 = "",
    label: []const u8 = "",
    sublabel: []const u8 = "",
    font_size: f32 = 16.0,
    text_color: Color = Nord.snow_storm_1,
    width: f32 = 0,
    height: f32 = 0,
    flex: f32 = 1.0,
    flex_shrink: f32 = 0.0,
    min_width: f32 = 0.0,
    max_width: f32 = 0.0,
    min_height: f32 = 0.0,
    max_height: f32 = 0.0,
    justify: Justify = .start,
    align_items: Align = .stretch,
    flex_wrap: bool = false,
    grid_cols: u16 = 0,
    grid_col_gap: f32 = -1.0,
    grid_row_gap: f32 = -1.0,
    col_span: u16 = 1,
    row_span: u16 = 1,
    padding: f32 = 0,
    gap: f32 = 0,
    corner_radius: f32 = 0,
    border_width: f32 = 0,
    shadow_blur: f32 = 0,
    fill: Color = Nord.transparent,
    border: Color = Nord.transparent,
    accent: Color = Nord.frost_1,
    checked: bool = false,
    slider_val: f32 = 0.0,
    disabled: bool = false,
    focusable: ?bool = null,
    roving_group: bool = false,
    roving_active_child: ?NodeId = null,
};

pub const FlexProps = struct {
    flex_shrink: f32 = 0.0,
    min_width: f32 = 0.0,
    max_width: f32 = 0.0,
    min_height: f32 = 0.0,
    max_height: f32 = 0.0,
    justify: Justify = .start,
    align_items: Align = .stretch,
    flex_wrap: bool = false,
};

pub const GridProps = struct {
    grid_cols: u16 = 0,
    grid_col_gap: f32 = -1.0,
    grid_row_gap: f32 = -1.0,
    col_span: u16 = 1,
    row_span: u16 = 1,
};

pub const Node = struct {
    gen: u16 = 1,
    kind: NodeKind = .vstack,
    role: SemanticRole = .container,
    test_id: []const u8 = "",
    label: []const u8 = "",
    sublabel: []const u8 = "",
    font_size: f32 = 16.0,
    text_color: Color = Nord.snow_storm_1,
    parent: ?u16 = null,
    first_child: ?u16 = null,
    next_sibling: ?u16 = null,
    last_child: ?u16 = null,
    width: f32 = 0,
    height: f32 = 0,
    flex: f32 = 1.0,
    flex_props: FlexProps = .{},
    grid_props: GridProps = .{},
    padding: f32 = 0,
    gap: f32 = 0,
    corner_radius: f32 = 0,
    border_width: f32 = 0,
    shadow_blur: f32 = 0,
    fill: Color = Nord.transparent,
    border: Color = Nord.transparent,
    accent: Color = Nord.frost_1,
    checked: bool = false,
    slider_val: f32 = 0.0,
    disabled: bool = false,
    focusable: ?bool = null,
    roving_group: bool = false,
    roving_active_child: ?NodeId = null,
    rect: Rect = .{},
};

pub const TrackBounds = struct {
    x: f32,
    w: f32,
};

pub fn sliderTrackBounds(rect: Rect) TrackBounds {
    const rw = sanitizeNonNeg(rect.w);
    const inset = @min(16.0, rw * 0.25);
    return .{
        .x = rect.x + inset,
        .w = @max(0.0, rw - inset * 2.0),
    };
}

const HitResult = union(enum) {
    hit: NodeId,
    occluded,
};

pub const LayoutArena = struct {
    allocator: std.mem.Allocator,
    nodes: std.MultiArrayList(Node) = .{},
    current_gen: u16 = 1,
    root_index: ?u16 = null,
    active_slider: ?NodeId = null,
    redraw_needed: bool = true,
    layout_dirty: bool = true,
    layout_eval_count: u64 = 0,
    viewport_w: f32 = 0,
    viewport_h: f32 = 0,

    pub fn init(allocator: std.mem.Allocator) LayoutArena {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LayoutArena) void {
        self.nodes.deinit(self.allocator);
        self.root_index = null;
        self.active_slider = null;
    }

    pub fn reset(self: *LayoutArena) void {
        self.nodes.shrinkRetainingCapacity(0);
        self.current_gen +%= 1;
        if (self.current_gen == 0) self.current_gen = 1;
        self.root_index = null;
        self.active_slider = null;
        self.redraw_needed = true;
        self.layout_dirty = true;
    }

    pub fn addNode(self: *LayoutArena, desc: NodeDesc) !NodeId {
        if (self.nodes.len >= std.math.maxInt(u16)) return error.OutOfMemory;
        const idx: u16 = @intCast(self.nodes.len);
        const gen: u16 = self.current_gen;
        try self.nodes.append(self.allocator, .{
            .gen = gen,
            .kind = desc.kind,
            .role = desc.role,
            .test_id = desc.test_id,
            .label = desc.label,
            .sublabel = desc.sublabel,
            .font_size = sanitizeFontSize(desc.font_size),
            .text_color = desc.text_color,
            .width = sanitizeNonNeg(desc.width),
            .height = sanitizeNonNeg(desc.height),
            .flex = sanitizeNonNeg(desc.flex),
            .flex_props = .{
                .flex_shrink = sanitizeNonNeg(desc.flex_shrink),
                .min_width = sanitizeNonNeg(desc.min_width),
                .max_width = sanitizeNonNeg(desc.max_width),
                .min_height = sanitizeNonNeg(desc.min_height),
                .max_height = sanitizeNonNeg(desc.max_height),
                .justify = desc.justify,
                .align_items = desc.align_items,
                .flex_wrap = desc.flex_wrap,
            },
            .grid_props = .{
                .grid_cols = desc.grid_cols,
                .grid_col_gap = if (std.math.isFinite(desc.grid_col_gap)) desc.grid_col_gap else -1.0,
                .grid_row_gap = if (std.math.isFinite(desc.grid_row_gap)) desc.grid_row_gap else -1.0,
                .col_span = desc.col_span,
                .row_span = desc.row_span,
            },
            .padding = sanitizeNonNeg(desc.padding),
            .gap = sanitizeNonNeg(desc.gap),
            .corner_radius = sanitizeNonNeg(desc.corner_radius),
            .border_width = sanitizeNonNeg(desc.border_width),
            .shadow_blur = sanitizeNonNeg(desc.shadow_blur),
            .fill = desc.fill,
            .border = desc.border,
            .accent = desc.accent,
            .checked = desc.checked,
            .slider_val = sanitizeUnit(desc.slider_val),
            .disabled = desc.disabled,
            .focusable = desc.focusable,
            .roving_group = desc.roving_group,
            .roving_active_child = desc.roving_active_child,
        });
        if (self.root_index == null) {
            self.root_index = idx;
        }
        self.redraw_needed = true;
        self.layout_dirty = true;
        return .{ .index = idx, .gen = gen };
    }

    pub fn addChild(self: *LayoutArena, parent: NodeId, desc: NodeDesc) !NodeId {
        const p_idx = self.resolveIndex(parent) orelse return error.InvalidNodeId;
        const child_id = try self.addNode(desc);
        const c_idx = child_id.index;

        const parents = self.nodes.items(.parent);
        const first_children = self.nodes.items(.first_child);
        const last_children = self.nodes.items(.last_child);
        const next_siblings = self.nodes.items(.next_sibling);

        parents[c_idx] = p_idx;
        if (last_children[p_idx]) |tail| {
            next_siblings[tail] = c_idx;
            last_children[p_idx] = c_idx;
        } else {
            first_children[p_idx] = c_idx;
            last_children[p_idx] = c_idx;
        }
        self.redraw_needed = true;
        self.layout_dirty = true;
        return child_id;
    }

    fn resolveIndex(self: *const LayoutArena, id: NodeId) ?u16 {
        if (id.index >= self.nodes.len) return null;
        if (self.nodes.items(.gen)[id.index] != id.gen) return null;
        return id.index;
    }

    pub fn layout(self: *LayoutArena, viewport_w: f32, viewport_h: f32) void {
        const vw = sanitizeNonNeg(viewport_w);
        const vh = sanitizeNonNeg(viewport_h);
        if (!self.layout_dirty and self.viewport_w == vw and self.viewport_h == vh) {
            return;
        }
        self.viewport_w = vw;
        self.viewport_h = vh;
        self.layout_eval_count += 1;
        self.layout_dirty = false;
        const root = self.root_index orelse return;
        self.nodes.items(.rect)[root] = .{
            .x = 0,
            .y = 0,
            .w = vw,
            .h = vh,
        };
        self.layoutChildren(root);
    }

    fn layoutChildren(self: *LayoutArena, idx: u16) void {
        const slice = self.nodes.slice();
        const kind = slice.items(.kind)[idx];
        const parent_rect = slice.items(.rect)[idx];
        const padding = sanitizeNonNeg(slice.items(.padding)[idx]);
        const gap = sanitizeNonNeg(slice.items(.gap)[idx]);

        const first_child = slice.items(.first_child)[idx] orelse return;

        const pad_x = @min(padding, parent_rect.w * 0.5);
        const pad_y = @min(padding, parent_rect.h * 0.5);
        const inner_x = parent_rect.x + pad_x;
        const inner_y = parent_rect.y + pad_y;
        const inner_w = @max(0.0, parent_rect.w - pad_x * 2.0);
        const inner_h = @max(0.0, parent_rect.h - pad_y * 2.0);

        switch (kind) {
            .zstack => self.layoutZStack(first_child, inner_x, inner_y, inner_w, inner_h),
            .grid => self.layoutGrid(idx, first_child, inner_x, inner_y, inner_w, inner_h, gap),
            else => self.layoutFlex(idx, first_child, kind == .hstack, inner_x, inner_y, inner_w, inner_h, gap),
        }
    }

    fn layoutZStack(
        self: *LayoutArena,
        first_child: u16,
        inner_x: f32,
        inner_y: f32,
        inner_w: f32,
        inner_h: f32,
    ) void {
        const slice = self.nodes.slice();
        const next_siblings = slice.items(.next_sibling);
        const widths = slice.items(.width);
        const heights = slice.items(.height);
        const flex_props = slice.items(.flex_props);
        const rects = slice.items(.rect);

        var cur: ?u16 = first_child;
        while (cur) |c| : (cur = next_siblings[c]) {
            const w = sanitizeNonNeg(widths[c]);
            const h = sanitizeNonNeg(heights[c]);
            const fp = flex_props[c];
            const cw = clampDim(if (w > 0.0) w else inner_w, fp.min_width, fp.max_width);
            const ch = clampDim(if (h > 0.0) h else inner_h, fp.min_height, fp.max_height);
            rects[c] = .{ .x = inner_x, .y = inner_y, .w = cw, .h = ch };
            self.layoutChildren(c);
        }
    }

    fn layoutFlex(
        self: *LayoutArena,
        idx: u16,
        first_child: u16,
        is_horizontal: bool,
        inner_x: f32,
        inner_y: f32,
        inner_w: f32,
        inner_h: f32,
        gap: f32,
    ) void {
        const slice = self.nodes.slice();
        const flex_props = slice.items(.flex_props);
        const parent_fp = flex_props[idx];
        const justify = parent_fp.justify;
        const align_items = parent_fp.align_items;
        const flex_wrap = parent_fp.flex_wrap;

        const avail_main = if (is_horizontal) inner_w else inner_h;
        const avail_cross = if (is_horizontal) inner_h else inner_w;
        const inner_main = if (is_horizontal) inner_x else inner_y;
        const inner_cross = if (is_horizontal) inner_y else inner_x;

        if (!flex_wrap) {
            self.layoutFlexLine(
                first_child,
                null,
                is_horizontal,
                justify,
                align_items,
                inner_main,
                avail_main,
                inner_cross,
                avail_cross,
                gap,
            );
            return;
        }

        const next_siblings = slice.items(.next_sibling);
        const widths = slice.items(.width);
        const heights = slice.items(.height);

        // Pass 1: discover wrapped lines and track fixed vs auto-cross lines (zero heap alloc)
        var line_count_total: usize = 0;
        var auto_line_count: usize = 0;
        var total_fixed_cross: f64 = 0.0;
        var cur_opt: ?u16 = first_child;
        while (cur_opt) |line_start| {
            const s_fp = flex_props[line_start];
            const s_raw_m = sanitizeNonNeg(if (is_horizontal) widths[line_start] else heights[line_start]);
            const s_min_m = sanitizeNonNeg(if (is_horizontal) s_fp.min_width else s_fp.min_height);
            const s_max_m = sanitizeNonNeg(if (is_horizontal) s_fp.max_width else s_fp.max_height);
            var used_main: f64 = if (s_raw_m > 0.0)
                clampDim(s_raw_m, s_min_m, s_max_m)
            else
                clampDim(0.0, s_min_m, s_max_m);

            const s_raw_c = sanitizeNonNeg(if (is_horizontal) heights[line_start] else widths[line_start]);
            const s_min_c = sanitizeNonNeg(if (is_horizontal) s_fp.min_height else s_fp.min_width);
            const s_max_c = sanitizeNonNeg(if (is_horizontal) s_fp.max_height else s_fp.max_width);
            var line_cross_size: f32 = clampDim(s_raw_c, s_min_c, s_max_c);

            var line_end: ?u16 = null;
            var scan = next_siblings[line_start];
            while (scan) |c| {
                const c_fp = flex_props[c];
                const c_raw_m = sanitizeNonNeg(if (is_horizontal) widths[c] else heights[c]);
                const c_min_m = sanitizeNonNeg(if (is_horizontal) c_fp.min_width else c_fp.min_height);
                const c_max_m = sanitizeNonNeg(if (is_horizontal) c_fp.max_width else c_fp.max_height);
                const c_hyp_m: f64 = if (c_raw_m > 0.0)
                    clampDim(c_raw_m, c_min_m, c_max_m)
                else
                    clampDim(0.0, c_min_m, c_max_m);

                if (used_main + @as(f64, gap) + c_hyp_m > @as(f64, avail_main) + 1e-4) {
                    line_end = c;
                    break;
                }
                used_main += @as(f64, gap) + c_hyp_m;

                const c_raw_c = sanitizeNonNeg(if (is_horizontal) heights[c] else widths[c]);
                const c_min_c = sanitizeNonNeg(if (is_horizontal) c_fp.min_height else c_fp.min_width);
                const c_max_c = sanitizeNonNeg(if (is_horizontal) c_fp.max_height else c_fp.max_width);
                line_cross_size = @max(line_cross_size, clampDim(c_raw_c, c_min_c, c_max_c));
                scan = next_siblings[c];
            }

            line_count_total += 1;
            if (line_cross_size > 0.0) {
                total_fixed_cross += @as(f64, line_cross_size);
            } else {
                auto_line_count += 1;
            }
            cur_opt = line_end;
        }

        const total_line_gap: f64 = if (line_count_total > 1)
            @as(f64, gap) * @as(f64, @floatFromInt(line_count_total - 1))
        else
            0.0;
        const rem_cross: f64 = @max(0.0, @as(f64, avail_cross) - total_fixed_cross - total_line_gap);
        const auto_line_cross: f32 = if (auto_line_count > 0)
            clampF32(rem_cross / @as(f64, @floatFromInt(auto_line_count)))
        else
            0.0;

        // Pass 2: lay out each wrapped line
        var line_cross_pos: f64 = @as(f64, inner_cross);
        cur_opt = first_child;
        while (cur_opt) |line_start| {
            const s_fp = flex_props[line_start];
            const s_raw_m = sanitizeNonNeg(if (is_horizontal) widths[line_start] else heights[line_start]);
            const s_min_m = sanitizeNonNeg(if (is_horizontal) s_fp.min_width else s_fp.min_height);
            const s_max_m = sanitizeNonNeg(if (is_horizontal) s_fp.max_width else s_fp.max_height);
            var used_main: f64 = if (s_raw_m > 0.0)
                clampDim(s_raw_m, s_min_m, s_max_m)
            else
                clampDim(0.0, s_min_m, s_max_m);

            const s_raw_c = sanitizeNonNeg(if (is_horizontal) heights[line_start] else widths[line_start]);
            const s_min_c = sanitizeNonNeg(if (is_horizontal) s_fp.min_height else s_fp.min_width);
            const s_max_c = sanitizeNonNeg(if (is_horizontal) s_fp.max_height else s_fp.max_width);
            var line_cross_size: f32 = clampDim(s_raw_c, s_min_c, s_max_c);

            var line_end: ?u16 = null;
            var scan = next_siblings[line_start];
            while (scan) |c| {
                const c_fp = flex_props[c];
                const c_raw_m = sanitizeNonNeg(if (is_horizontal) widths[c] else heights[c]);
                const c_min_m = sanitizeNonNeg(if (is_horizontal) c_fp.min_width else c_fp.min_height);
                const c_max_m = sanitizeNonNeg(if (is_horizontal) c_fp.max_width else c_fp.max_height);
                const c_hyp_m: f64 = if (c_raw_m > 0.0)
                    clampDim(c_raw_m, c_min_m, c_max_m)
                else
                    clampDim(0.0, c_min_m, c_max_m);

                if (used_main + @as(f64, gap) + c_hyp_m > @as(f64, avail_main) + 1e-4) {
                    line_end = c;
                    break;
                }
                used_main += @as(f64, gap) + c_hyp_m;

                const c_raw_c = sanitizeNonNeg(if (is_horizontal) heights[c] else widths[c]);
                const c_min_c = sanitizeNonNeg(if (is_horizontal) c_fp.min_height else c_fp.min_width);
                const c_max_c = sanitizeNonNeg(if (is_horizontal) c_fp.max_height else c_fp.max_width);
                line_cross_size = @max(line_cross_size, clampDim(c_raw_c, c_min_c, c_max_c));
                scan = next_siblings[c];
            }

            const eff_line_cross = if (line_cross_size > 0.0)
                line_cross_size
            else if (align_items == .stretch)
                auto_line_cross
            else
                0.0;

            self.layoutFlexLine(
                line_start,
                line_end,
                is_horizontal,
                justify,
                align_items,
                inner_main,
                avail_main,
                clampF32(line_cross_pos),
                eff_line_cross,
                gap,
            );
            line_cross_pos += @as(f64, eff_line_cross) + @as(f64, gap);
            cur_opt = line_end;
        }
    }

    fn layoutFlexLine(
        self: *LayoutArena,
        line_start: u16,
        line_end: ?u16,
        is_horizontal: bool,
        justify: Justify,
        align_items: Align,
        inner_main: f32,
        avail_main: f32,
        line_cross_pos: f32,
        line_cross_size: f32,
        gap: f32,
    ) void {
        const slice = self.nodes.slice();
        const next_siblings = slice.items(.next_sibling);
        const widths = slice.items(.width);
        const heights = slice.items(.height);
        const flexes = slice.items(.flex);
        const flex_props = slice.items(.flex_props);
        const rects = slice.items(.rect);

        var line_count: usize = 0;
        var fixed_main: f64 = 0.0;
        var total_flex: f64 = 0.0;
        var cur: ?u16 = line_start;
        while (cur != line_end) : (cur = next_siblings[cur.?]) {
            const c = cur.?;
            line_count += 1;
            const fp = flex_props[c];
            const raw_m = sanitizeNonNeg(if (is_horizontal) widths[c] else heights[c]);
            if (raw_m > 0.0) {
                const min_m = sanitizeNonNeg(if (is_horizontal) fp.min_width else fp.min_height);
                const max_m = sanitizeNonNeg(if (is_horizontal) fp.max_width else fp.max_height);
                fixed_main += @as(f64, clampDim(raw_m, min_m, max_m));
            } else {
                total_flex += @as(f64, sanitizeNonNeg(flexes[c]));
            }
        }
        if (line_count == 0) return;

        const avail_main_64: f64 = @as(f64, sanitizeNonNeg(avail_main));
        const gap_64: f64 = @as(f64, sanitizeNonNeg(gap));
        const total_gap: f64 = if (line_count > 1) gap_64 * @as(f64, @floatFromInt(line_count - 1)) else 0.0;
        const rem_for_flex: f64 = @max(0.0, avail_main_64 - fixed_main - total_gap);
        const valid_flex = std.math.isFinite(total_flex) and total_flex > 0.0;

        var total_used: f64 = 0.0;
        cur = line_start;
        while (cur != line_end) : (cur = next_siblings[cur.?]) {
            const c = cur.?;
            const fp = flex_props[c];
            const raw_m = sanitizeNonNeg(if (is_horizontal) widths[c] else heights[c]);
            const min_m = sanitizeNonNeg(if (is_horizontal) fp.min_width else fp.min_height);
            const max_m = sanitizeNonNeg(if (is_horizontal) fp.max_width else fp.max_height);
            const fl: f64 = @as(f64, sanitizeNonNeg(flexes[c]));
            const target: f64 = if (raw_m > 0.0)
                @as(f64, raw_m)
            else if (valid_flex)
                rem_for_flex * (fl / total_flex)
            else
                0.0;
            const m = clampDim(clampF32(target), min_m, max_m);
            if (is_horizontal) rects[c].w = m else rects[c].h = m;
            total_used += @as(f64, m);
        }

        // Freeze min-clamped flex children and redistribute remaining space
        if (valid_flex) {
            var min_iter: usize = 0;
            while (min_iter < line_count and std.math.isFinite(total_used) and total_used + total_gap > avail_main_64 + 1e-4) : (min_iter += 1) {
                var frozen_main: f64 = fixed_main;
                var active_flex: f64 = 0.0;
                var any_frozen = false;
                cur = line_start;
                while (cur != line_end) : (cur = next_siblings[cur.?]) {
                    const c = cur.?;
                    const raw_m = sanitizeNonNeg(if (is_horizontal) widths[c] else heights[c]);
                    if (raw_m > 0.0) continue;
                    const fp = flex_props[c];
                    const min_m = sanitizeNonNeg(if (is_horizontal) fp.min_width else fp.min_height);
                    const cur_m = if (is_horizontal) rects[c].w else rects[c].h;
                    if (min_m > 0.0 and cur_m <= min_m + 1e-5) {
                        frozen_main += @as(f64, cur_m);
                        any_frozen = true;
                    } else {
                        active_flex += @as(f64, sanitizeNonNeg(flexes[c]));
                    }
                }
                if (!any_frozen or !std.math.isFinite(active_flex) or active_flex <= 0.0) break;
                const rem_after: f64 = @max(0.0, avail_main_64 - frozen_main - total_gap);
                var new_total: f64 = 0.0;
                cur = line_start;
                while (cur != line_end) : (cur = next_siblings[cur.?]) {
                    const c = cur.?;
                    var cur_m = if (is_horizontal) rects[c].w else rects[c].h;
                    const raw_m = sanitizeNonNeg(if (is_horizontal) widths[c] else heights[c]);
                    if (raw_m == 0.0) {
                        const fp = flex_props[c];
                        const min_m = sanitizeNonNeg(if (is_horizontal) fp.min_width else fp.min_height);
                        const max_m = sanitizeNonNeg(if (is_horizontal) fp.max_width else fp.max_height);
                        const fl: f64 = @as(f64, sanitizeNonNeg(flexes[c]));
                        if (!(min_m > 0.0 and cur_m <= min_m + 1e-5)) {
                            cur_m = clampDim(clampF32(rem_after * (fl / active_flex)), min_m, max_m);
                            if (is_horizontal) rects[c].w = cur_m else rects[c].h = cur_m;
                        }
                    }
                    new_total += @as(f64, cur_m);
                }
                if (@abs(new_total - total_used) <= 1e-6) break;
                total_used = new_total;
            }
        }

        // Redistribute remaining space if any flex child was capped by max_main
        // Skip items frozen at min_m unless their uncapped share of the non-max budget exceeds min_m.
        if (valid_flex) {
            var grow_iter: usize = 0;
            while (grow_iter < line_count and std.math.isFinite(total_used) and total_used + total_gap + 1e-4 < avail_main_64) : (grow_iter += 1) {
                const free: f64 = avail_main_64 - total_gap - total_used;
                var non_max_budget: f64 = avail_main_64 - total_gap - fixed_main;
                var non_max_flex: f64 = 0.0;
                cur = line_start;
                while (cur != line_end) : (cur = next_siblings[cur.?]) {
                    const c = cur.?;
                    const raw_m = sanitizeNonNeg(if (is_horizontal) widths[c] else heights[c]);
                    if (raw_m > 0.0) continue;
                    const fl: f64 = @as(f64, sanitizeNonNeg(flexes[c]));
                    if (fl <= 0.0) continue;
                    const fp = flex_props[c];
                    const min_m = sanitizeNonNeg(if (is_horizontal) fp.min_width else fp.min_height);
                    const max_m = sanitizeNonNeg(if (is_horizontal) fp.max_width else fp.max_height);
                    const cur_m = if (is_horizontal) rects[c].w else rects[c].h;
                    if (max_m > 0.0 and cur_m >= @max(min_m, max_m) - 1e-5) {
                        non_max_budget -= @as(f64, cur_m);
                    } else {
                        non_max_flex += fl;
                    }
                }

                var active_flex: f64 = 0.0;
                cur = line_start;
                while (cur != line_end) : (cur = next_siblings[cur.?]) {
                    const c = cur.?;
                    const raw_m = sanitizeNonNeg(if (is_horizontal) widths[c] else heights[c]);
                    if (raw_m > 0.0) continue;
                    const fl: f64 = @as(f64, sanitizeNonNeg(flexes[c]));
                    if (fl <= 0.0) continue;
                    const fp = flex_props[c];
                    const min_m = sanitizeNonNeg(if (is_horizontal) fp.min_width else fp.min_height);
                    const max_m = sanitizeNonNeg(if (is_horizontal) fp.max_width else fp.max_height);
                    const cur_m = if (is_horizontal) rects[c].w else rects[c].h;
                    if (max_m > 0.0 and cur_m >= @max(min_m, max_m) - 1e-5) continue;
                    if (min_m > 0.0 and cur_m <= min_m + 1e-5) {
                        const uncapped: f64 = if (std.math.isFinite(non_max_flex) and non_max_flex > 0.0)
                            @max(0.0, non_max_budget) * (fl / non_max_flex)
                        else
                            0.0;
                        if (uncapped <= @as(f64, min_m) + 1e-5) continue;
                    }
                    active_flex += fl;
                }
                if (!std.math.isFinite(active_flex) or active_flex <= 0.0) break;

                var new_total: f64 = 0.0;
                cur = line_start;
                while (cur != line_end) : (cur = next_siblings[cur.?]) {
                    const c = cur.?;
                    var cur_m = if (is_horizontal) rects[c].w else rects[c].h;
                    const raw_m = sanitizeNonNeg(if (is_horizontal) widths[c] else heights[c]);
                    const fl: f64 = @as(f64, sanitizeNonNeg(flexes[c]));
                    if (raw_m == 0.0 and fl > 0.0) {
                        const fp = flex_props[c];
                        const min_m = sanitizeNonNeg(if (is_horizontal) fp.min_width else fp.min_height);
                        const max_m = sanitizeNonNeg(if (is_horizontal) fp.max_width else fp.max_height);
                        const at_max = (max_m > 0.0 and cur_m >= @max(min_m, max_m) - 1e-5);
                        var min_frozen = false;
                        if (min_m > 0.0 and cur_m <= min_m + 1e-5) {
                            const uncapped: f64 = if (std.math.isFinite(non_max_flex) and non_max_flex > 0.0)
                                @max(0.0, non_max_budget) * (fl / non_max_flex)
                            else
                                0.0;
                            min_frozen = (uncapped <= @as(f64, min_m) + 1e-5);
                        }
                        if (!at_max and !min_frozen) {
                            const next_m = @as(f64, cur_m) + free * (fl / active_flex);
                            cur_m = clampDim(clampF32(next_m), min_m, max_m);
                            if (is_horizontal) rects[c].w = cur_m else rects[c].h = cur_m;
                        }
                    }
                    new_total += @as(f64, cur_m);
                }
                if (@abs(new_total - total_used) <= 1e-6) break;
                total_used = new_total;
            }
        }

        // Shrink proportionally to flex_shrink when demand exceeds avail_main (in f64 to prevent f32 Inf/NaN)
        var shrink_iter: usize = 0;
        while (shrink_iter <= line_count and std.math.isFinite(total_used) and std.math.isFinite(total_gap) and total_used + total_gap > avail_main_64 + 1e-4) : (shrink_iter += 1) {
            const overflow: f64 = (total_used + total_gap) - avail_main_64;
            if (!std.math.isFinite(overflow) or overflow <= 0.0) break;
            var active_shrink: f64 = 0.0;
            cur = line_start;
            while (cur != line_end) : (cur = next_siblings[cur.?]) {
                const c = cur.?;
                const fp = flex_props[c];
                const sh: f64 = @as(f64, sanitizeNonNeg(fp.flex_shrink));
                if (sh <= 0.0) continue;
                const min_m = sanitizeNonNeg(if (is_horizontal) fp.min_width else fp.min_height);
                const cur_m = if (is_horizontal) rects[c].w else rects[c].h;
                if (cur_m > min_m + 1e-5) {
                    active_shrink += sh;
                }
            }
            if (!std.math.isFinite(active_shrink) or active_shrink <= 0.0) break;

            var new_total: f64 = 0.0;
            cur = line_start;
            while (cur != line_end) : (cur = next_siblings[cur.?]) {
                const c = cur.?;
                var cur_m = if (is_horizontal) rects[c].w else rects[c].h;
                const fp = flex_props[c];
                const sh: f64 = @as(f64, sanitizeNonNeg(fp.flex_shrink));
                const min_m = sanitizeNonNeg(if (is_horizontal) fp.min_width else fp.min_height);
                const max_m = sanitizeNonNeg(if (is_horizontal) fp.max_width else fp.max_height);
                if (sh > 0.0 and cur_m > min_m + 1e-5) {
                    const delta: f64 = overflow * (sh / active_shrink);
                    const reduced: f64 = @max(0.0, @as(f64, cur_m) - delta);
                    cur_m = clampDim(clampF32(reduced), min_m, max_m);
                    if (is_horizontal) rects[c].w = cur_m else rects[c].h = cur_m;
                }
                new_total += @as(f64, cur_m);
            }
            if (@abs(new_total - total_used) <= 1e-6) break;
            total_used = new_total;
        }

        const rem_justify: f64 = @max(0.0, avail_main_64 - total_used - total_gap);
        var main_cursor: f64 = @as(f64, sanitizeFinite(inner_main));
        var extra_gap: f64 = 0.0;
        const n_f: f64 = @floatFromInt(line_count);
        switch (justify) {
            .start => {},
            .center => main_cursor += rem_justify * 0.5,
            .end => main_cursor += rem_justify,
            .space_between => {
                if (line_count > 1) {
                    extra_gap = rem_justify / @as(f64, @floatFromInt(line_count - 1));
                }
            },
            .space_around => {
                const slot = rem_justify / n_f;
                main_cursor += slot * 0.5;
                extra_gap = slot;
            },
            .space_evenly => {
                const slot = rem_justify / (n_f + 1.0);
                main_cursor += slot;
                extra_gap = slot;
            },
        }

        cur = line_start;
        while (cur != line_end) : (cur = next_siblings[cur.?]) {
            const c = cur.?;
            const fp = flex_props[c];
            const child_main = sanitizeNonNeg(if (is_horizontal) rects[c].w else rects[c].h);
            const raw_c = sanitizeNonNeg(if (is_horizontal) heights[c] else widths[c]);
            const min_c = sanitizeNonNeg(if (is_horizontal) fp.min_height else fp.min_width);
            const max_c = sanitizeNonNeg(if (is_horizontal) fp.max_height else fp.max_width);

            const child_cross = if (raw_c > 0.0)
                clampDim(raw_c, min_c, max_c)
            else if (align_items == .stretch)
                clampDim(line_cross_size, min_c, max_c)
            else
                clampDim(0.0, min_c, max_c);

            const cross_offset: f64 = switch (align_items) {
                .start, .stretch => 0.0,
                .center => (@as(f64, line_cross_size) - @as(f64, child_cross)) * 0.5,
                .end => @as(f64, line_cross_size) - @as(f64, child_cross),
            };

            const main_pos_f32 = clampF32(main_cursor);
            const cross_pos_f32 = clampF32(@as(f64, sanitizeFinite(line_cross_pos)) + cross_offset);

            if (is_horizontal) {
                rects[c] = .{
                    .x = main_pos_f32,
                    .y = cross_pos_f32,
                    .w = child_main,
                    .h = child_cross,
                };
            } else {
                rects[c] = .{
                    .x = cross_pos_f32,
                    .y = main_pos_f32,
                    .w = child_cross,
                    .h = child_main,
                };
            }
            main_cursor += @as(f64, child_main) + gap_64 + extra_gap;
            self.layoutChildren(c);
        }
    }

    const GridPlacement = struct {
        col: u16,
        row: usize,
        span: u16,
        r_span: u16,
    };

    const GridCursor = struct {
        cols: u16,
        col: u16 = 0,
        row: usize = 0,
        busy: [MAX_GRID_COLS]u16 = [_]u16{0} ** MAX_GRID_COLS,

        fn nextRow(self: *GridCursor) void {
            self.row += 1;
            self.col = 0;
            const lim = @min(self.cols, MAX_GRID_COLS);
            for (0..lim) |k| {
                if (self.busy[k] > 0) self.busy[k] -= 1;
            }
        }

        fn canFitAt(self: *const GridCursor, start_col: u16, span: u16) bool {
            if (start_col >= self.cols or span > self.cols - start_col) return false;
            var k: u16 = 0;
            while (k < span) : (k += 1) {
                const c = start_col + k;
                if (c < MAX_GRID_COLS and self.busy[c] > 0) return false;
            }
            return true;
        }

        fn place(self: *GridCursor, c_span_raw: u16, r_span_raw: u16) GridPlacement {
            const span = @min(@max(1, c_span_raw), self.cols);
            const r_span = @max(1, r_span_raw);
            while (true) {
                while (self.col < self.cols and self.col < MAX_GRID_COLS and self.busy[self.col] > 0) {
                    self.col += 1;
                }
                if (self.col >= self.cols or span > self.cols - self.col) {
                    self.nextRow();
                    continue;
                }
                if (self.canFitAt(self.col, span)) {
                    const placed_col = self.col;
                    const placed_row = self.row;
                    if (r_span > 1) {
                        var k: u16 = 0;
                        while (k < span) : (k += 1) {
                            const idx_k = placed_col + k;
                            if (idx_k < MAX_GRID_COLS) {
                                self.busy[idx_k] = r_span;
                            }
                        }
                    }
                    self.col += span;
                    return .{ .col = placed_col, .row = placed_row, .span = span, .r_span = r_span };
                }
                self.col += 1;
            }
        }
    };

    fn scanGridRowHeight(
        gc: *GridCursor,
        cur_opt: *?u16,
        row_idx: usize,
        auto_row_h: f32,
        next_siblings: []const ?u16,
        heights: []const f32,
        flex_props: []const FlexProps,
        grid_props: []const GridProps,
    ) struct { row_h: f32, row_end: ?u16 } {
        var row_has_fixed = false;
        var row_fixed_h: f32 = 0.0;
        var row_min_h: f32 = 0.0;
        var row_end: ?u16 = null;
        var scan_opt = cur_opt.*;
        while (scan_opt) |sc| : (scan_opt = next_siblings[sc]) {
            var gc_peek = gc.*;
            const p_peek = gc_peek.place(grid_props[sc].col_span, grid_props[sc].row_span);
            if (p_peek.row > row_idx) {
                row_end = sc;
                break;
            }
            gc.* = gc_peek;
            if (p_peek.r_span == 1) {
                const raw_h = sanitizeNonNeg(heights[sc]);
                const fp = flex_props[sc];
                if (raw_h > 0.0) {
                    row_has_fixed = true;
                    row_fixed_h = @max(row_fixed_h, clampDim(raw_h, fp.min_height, fp.max_height));
                } else {
                    row_min_h = @max(row_min_h, clampDim(0.0, fp.min_height, fp.max_height));
                }
            }
        }
        cur_opt.* = row_end;
        const base_h = if (row_has_fixed) row_fixed_h else auto_row_h;
        return .{ .row_h = @max(base_h, row_min_h), .row_end = row_end };
    }

    fn layoutGrid(
        self: *LayoutArena,
        idx: u16,
        first_child: u16,
        inner_x: f32,
        inner_y: f32,
        inner_w: f32,
        inner_h: f32,
        gap: f32,
    ) void {
        const slice = self.nodes.slice();
        const flex_props = slice.items(.flex_props);
        const grid_props = slice.items(.grid_props);
        const parent_gp = grid_props[idx];
        const cols: u16 = std.math.clamp(parent_gp.grid_cols, 1, MAX_GRID_COLS);
        const col_gap = if (std.math.isFinite(parent_gp.grid_col_gap) and parent_gp.grid_col_gap >= 0.0) parent_gp.grid_col_gap else gap;
        const row_gap = if (std.math.isFinite(parent_gp.grid_row_gap) and parent_gp.grid_row_gap >= 0.0) parent_gp.grid_row_gap else gap;
        const align_items = flex_props[idx].align_items;

        const cols_f: f64 = @floatFromInt(cols);
        const col_w_64: f64 = @max(0.0, (@as(f64, inner_w) - @as(f64, col_gap) * (cols_f - 1.0)) / cols_f);
        const col_w: f32 = clampF32(col_w_64);

        const next_siblings = slice.items(.next_sibling);
        const heights = slice.items(.height);
        const rects = slice.items(.rect);

        // Pass 1: discover row count, fixed row heights (raw_h > 0), and auto row count (zero heap alloc)
        var gc1 = GridCursor{ .cols = cols };
        var cur_row: usize = 0;
        var cur_row_has_fixed = false;
        var cur_row_fixed_h: f32 = 0.0;
        var total_fixed_row_h: f64 = 0.0;
        var auto_row_count: usize = 0;
        var total_rows: usize = 0;

        var cur: ?u16 = first_child;
        while (cur) |c| : (cur = next_siblings[c]) {
            const gp = grid_props[c];
            const fp = flex_props[c];
            const p = gc1.place(gp.col_span, gp.row_span);
            while (cur_row < p.row) {
                if (cur_row_has_fixed) {
                    total_fixed_row_h += @as(f64, cur_row_fixed_h);
                } else {
                    auto_row_count += 1;
                }
                cur_row += 1;
                cur_row_has_fixed = false;
                cur_row_fixed_h = 0.0;
            }
            total_rows = @max(total_rows, p.row + p.r_span);
            if (p.r_span == 1) {
                const raw_h = sanitizeNonNeg(heights[c]);
                if (raw_h > 0.0) {
                    cur_row_has_fixed = true;
                    cur_row_fixed_h = @max(cur_row_fixed_h, clampDim(raw_h, fp.min_height, fp.max_height));
                }
            }
        }
        if (total_rows > 0) {
            if (cur_row_has_fixed) {
                total_fixed_row_h += @as(f64, cur_row_fixed_h);
            } else {
                auto_row_count += 1;
            }
            cur_row += 1;
            while (cur_row < total_rows) : (cur_row += 1) {
                auto_row_count += 1;
            }
        }

        const total_row_gap: f64 = if (total_rows > 1)
            @as(f64, row_gap) * @as(f64, @floatFromInt(total_rows - 1))
        else
            0.0;
        const rem_h: f64 = @max(0.0, @as(f64, inner_h) - total_fixed_row_h - total_row_gap);
        const auto_row_h: f32 = if (auto_row_count > 0)
            clampF32(rem_h / @as(f64, @floatFromInt(auto_row_count)))
        else
            0.0;

        // Pass 2: place children row by row, summing actual spanned row heights for row_span > 1
        var gc = GridCursor{ .cols = cols };
        var row_y: f64 = @as(f64, sanitizeFinite(inner_y));
        var cur_opt: ?u16 = first_child;
        var row_idx: usize = 0;
        while (cur_opt != null) {
            var gc_scan = gc;
            var scan_after_row = cur_opt;
            const row_info = scanGridRowHeight(
                &gc_scan,
                &scan_after_row,
                row_idx,
                auto_row_h,
                next_siblings,
                heights,
                flex_props,
                grid_props,
            );
            const row_h = row_info.row_h;
            const row_end = row_info.row_end;

            while (cur_opt != row_end) {
                const c = cur_opt.?;
                const gp = grid_props[c];
                const fp = flex_props[c];
                const p = gc.place(gp.col_span, gp.row_span);
                const span_f: f64 = @floatFromInt(p.span);
                const col_f: f64 = @floatFromInt(p.col);
                const raw_w: f64 = @as(f64, col_w) * span_f + @as(f64, col_gap) * (span_f - 1.0);
                const cw = clampDim(clampF32(raw_w), fp.min_width, fp.max_width);

                var avail_cell_h_64: f64 = @as(f64, row_h);
                if (p.r_span > 1) {
                    var gc_fwd = gc_scan;
                    var fwd_opt = scan_after_row;
                    var r_off: u16 = 1;
                    while (r_off < p.r_span) : (r_off += 1) {
                        gc_fwd.nextRow();
                        const next_info = scanGridRowHeight(
                            &gc_fwd,
                            &fwd_opt,
                            row_idx + r_off,
                            auto_row_h,
                            next_siblings,
                            heights,
                            flex_props,
                            grid_props,
                        );
                        avail_cell_h_64 += @as(f64, row_gap) + @as(f64, next_info.row_h);
                    }
                }
                const avail_cell_h = clampF32(avail_cell_h_64);

                const raw_h = sanitizeNonNeg(heights[c]);
                const ch = if (raw_h > 0.0)
                    clampDim(raw_h, fp.min_height, fp.max_height)
                else if (align_items == .stretch)
                    clampDim(avail_cell_h, fp.min_height, fp.max_height)
                else
                    clampDim(0.0, fp.min_height, fp.max_height);

                const cross_offset: f64 = switch (align_items) {
                    .start, .stretch => 0.0,
                    .center => (@as(f64, avail_cell_h) - @as(f64, ch)) * 0.5,
                    .end => @as(f64, avail_cell_h) - @as(f64, ch),
                };

                rects[c] = .{
                    .x = clampF32(@as(f64, sanitizeFinite(inner_x)) + col_f * (@as(f64, col_w) + @as(f64, col_gap))),
                    .y = clampF32(row_y + cross_offset),
                    .w = cw,
                    .h = ch,
                };
                self.layoutChildren(c);
                cur_opt = next_siblings[c];
            }

            row_y += @as(f64, row_h) + @as(f64, row_gap);
            row_idx += 1;
            gc.nextRow();
        }
    }

    pub fn getRect(self: *const LayoutArena, id: NodeId) ?Rect {
        const idx = self.resolveIndex(id) orelse return null;
        return self.nodes.items(.rect)[idx];
    }

    pub fn getKind(self: *const LayoutArena, id: NodeId) ?NodeKind {
        const idx = self.resolveIndex(id) orelse return null;
        return self.nodes.items(.kind)[idx];
    }

    pub fn getTestId(self: *const LayoutArena, id: NodeId) ?[]const u8 {
        const idx = self.resolveIndex(id) orelse return null;
        return self.nodes.items(.test_id)[idx];
    }

    pub fn findByTestId(self: *const LayoutArena, test_id: []const u8) ?NodeId {
        if (test_id.len == 0) return null;
        const slice = self.nodes.slice();
        const test_ids = slice.items(.test_id);
        const gens = slice.items(.gen);
        for (test_ids, 0..) |tid, i| {
            if (std.mem.eql(u8, tid, test_id)) {
                return .{ .index = @intCast(i), .gen = gens[i] };
            }
        }
        return null;
    }

    pub fn getParent(self: *const LayoutArena, id: NodeId) ?NodeId {
        const idx = self.resolveIndex(id) orelse return null;
        const p_idx = self.nodes.items(.parent)[idx] orelse return null;
        return .{ .index = p_idx, .gen = self.nodes.items(.gen)[p_idx] };
    }

    pub fn getFirstChild(self: *const LayoutArena, id: NodeId) ?NodeId {
        const idx = self.resolveIndex(id) orelse return null;
        const c_idx = self.nodes.items(.first_child)[idx] orelse return null;
        return .{ .index = c_idx, .gen = self.nodes.items(.gen)[c_idx] };
    }

    pub fn getNextSibling(self: *const LayoutArena, id: NodeId) ?NodeId {
        const idx = self.resolveIndex(id) orelse return null;
        const n_idx = self.nodes.items(.next_sibling)[idx] orelse return null;
        return .{ .index = n_idx, .gen = self.nodes.items(.gen)[n_idx] };
    }

    pub fn getRoot(self: *const LayoutArena) ?NodeId {
        const r_idx = self.root_index orelse return null;
        return .{ .index = r_idx, .gen = self.nodes.items(.gen)[r_idx] };
    }

    pub fn isDescendantOrSelf(self: *const LayoutArena, ancestor: NodeId, node: NodeId) bool {
        const anc_idx = self.resolveIndex(ancestor) orelse return false;
        var cur_opt: ?u16 = self.resolveIndex(node) orelse return false;
        const parents = self.nodes.items(.parent);
        var steps: usize = 0;
        while (cur_opt) |cur| : (steps += 1) {
            if (cur == anc_idx) return true;
            if (steps >= self.nodes.len) break;
            cur_opt = parents[cur];
        }
        return false;
    }

    pub fn isEnabledTree(self: *const LayoutArena, id: NodeId) bool {
        var cur_opt: ?u16 = self.resolveIndex(id) orelse return false;
        const disabled_items = self.nodes.items(.disabled);
        const parents = self.nodes.items(.parent);
        const limit = self.nodes.len;
        var steps: usize = 0;
        while (cur_opt) |cur| : (steps += 1) {
            if (steps >= limit) return false;
            if (disabled_items[cur]) return false;
            cur_opt = parents[cur];
        }
        return true;
    }

    pub fn isDisabled(self: *const LayoutArena, id: NodeId) bool {
        const idx = self.resolveIndex(id) orelse return false;
        _ = idx;
        return !self.isEnabledTree(id);
    }

    pub fn isFocusable(self: *const LayoutArena, id: NodeId) bool {
        const idx = self.resolveIndex(id) orelse return false;
        if (!self.isEnabledTree(id)) return false;
        const slice = self.nodes.slice();
        if (slice.items(.focusable)[idx]) |f| return f;
        const kind = slice.items(.kind)[idx];
        return kind == .toggle or kind == .slider;
    }

    pub fn isRovingGroup(self: *const LayoutArena, id: NodeId) bool {
        const idx = self.resolveIndex(id) orelse return false;
        return self.nodes.items(.roving_group)[idx];
    }

    pub fn getRovingActiveChild(self: *const LayoutArena, id: NodeId) ?NodeId {
        const idx = self.resolveIndex(id) orelse return null;
        return self.nodes.items(.roving_active_child)[idx];
    }

    pub fn setRovingActiveChild(self: *LayoutArena, id: NodeId, child: ?NodeId) void {
        const idx = self.resolveIndex(id) orelse return;
        self.nodes.items(.roving_active_child)[idx] = child;
    }

    pub fn isChecked(self: *const LayoutArena, id: NodeId) ?bool {
        const idx = self.resolveIndex(id) orelse return null;
        return self.nodes.items(.checked)[idx];
    }

    pub fn getSliderValue(self: *const LayoutArena, id: NodeId) ?f32 {
        const idx = self.resolveIndex(id) orelse return null;
        return self.nodes.items(.slider_val)[idx];
    }

    pub fn toggleNode(self: *LayoutArena, id: NodeId) ?bool {
        const idx = self.resolveIndex(id) orelse return null;
        if (self.nodes.items(.kind)[idx] != .toggle) return null;
        if (!self.isEnabledTree(id)) return null;
        const checked_items = self.nodes.items(.checked);
        checked_items[idx] = !checked_items[idx];
        self.redraw_needed = true;
        return checked_items[idx];
    }

    pub fn setSliderValue(self: *LayoutArena, id: NodeId, value: f32) ?f32 {
        if (!std.math.isFinite(value)) return null;
        const idx = self.resolveIndex(id) orelse return null;
        if (self.nodes.items(.kind)[idx] != .slider) return null;
        if (!self.isEnabledTree(id)) return null;
        const t = sanitizeUnit(value);
        const slider_items = self.nodes.items(.slider_val);
        const is_endpoint = (t == 0.0 or t == 1.0) and slider_items[idx] != t;
        if (is_endpoint or @abs(slider_items[idx] - t) > 0.0005) {
            slider_items[idx] = t;
            self.redraw_needed = true;
        }
        return slider_items[idx];
    }

    pub fn setSliderFromX(self: *LayoutArena, id: NodeId, x: f32) ?f32 {
        if (!std.math.isFinite(x)) return null;
        const idx = self.resolveIndex(id) orelse return null;
        if (self.nodes.items(.kind)[idx] != .slider) return null;
        if (!self.isEnabledTree(id)) return null;
        const r = self.nodes.items(.rect)[idx];
        return self.setSliderValue(id, sliderValueFromX(r, x));
    }

    pub fn needsRedraw(self: *const LayoutArena) bool {
        return self.redraw_needed;
    }

    pub fn requestRedraw(self: *LayoutArena) void {
        self.redraw_needed = true;
    }

    pub fn consumeRedraw(self: *LayoutArena) void {
        self.redraw_needed = false;
    }

    fn pushQuad(out_buf: []QuadInstance, count: *usize, quad: QuadInstance) void {
        if (count.* >= out_buf.len) return;
        if (quad.pos_size[2] <= 0.0 or quad.pos_size[3] <= 0.0) return;
        var q = quad;
        q.params[0] = sanitizeNonNeg(q.params[0]);
        q.params[1] = sanitizeNonNeg(q.params[1]);
        q.params[2] = sanitizeNonNeg(q.params[2]);
        out_buf[count.*] = q;
        count.* += 1;
    }

    pub fn emitQuads(self: *const LayoutArena, out_buf: []QuadInstance, scale_factor: f32) usize {
        return self.emitQuadsWithAtlas(out_buf, scale_factor, null, 0);
    }

    pub fn emitQuadsWithAtlas(
        self: *const LayoutArena,
        out_buf: []QuadInstance,
        scale_factor: f32,
        atlas_opt: anytype,
        frame_idx: u64,
    ) usize {
        if (!std.math.isFinite(scale_factor) or scale_factor <= 0.0) return 0;
        var count: usize = 0;
        const root = self.root_index orelse return 0;
        const maybe_atlas = asOptionalAtlas(atlas_opt);
        if (@TypeOf(maybe_atlas) != ?noreturn) {
            if (maybe_atlas) |atlas| {
                const epoch_before = atlas.repack_epoch;
                self.emitNodeQuads(root, out_buf, &count, scale_factor, atlas_opt, frame_idx);
                if (atlas.repack_epoch != epoch_before) {
                    count = 0;
                    self.emitNodeQuads(root, out_buf, &count, scale_factor, atlas_opt, frame_idx);
                }
                return count;
            }
        }
        self.emitNodeQuads(root, out_buf, &count, scale_factor, atlas_opt, frame_idx);
        return count;
    }

    fn asOptionalAtlas(atlas_opt: anytype) switch (@typeInfo(@TypeOf(atlas_opt))) {
        .null => ?noreturn,
        .optional => @TypeOf(atlas_opt),
        .pointer => ?@TypeOf(atlas_opt),
        else => @compileError("atlas_opt must be null, optional pointer, or pointer to GlyphAtlas"),
    } {
        return switch (@typeInfo(@TypeOf(atlas_opt))) {
            .null => null,
            .optional => atlas_opt,
            .pointer => atlas_opt,
            else => unreachable,
        };
    }

    fn emitNodeQuads(
        self: *const LayoutArena,
        idx: u16,
        out_buf: []QuadInstance,
        count: *usize,
        scale: f32,
        atlas_opt: anytype,
        frame_idx: u64,
    ) void {
        if (count.* >= out_buf.len) return;
        const maybe_atlas = asOptionalAtlas(atlas_opt);

        const slice = self.nodes.slice();
        const kind = slice.items(.kind)[idx];
        const role = slice.items(.role)[idx];
        const label = slice.items(.label)[idx];
        const sublabel = slice.items(.sublabel)[idx];
        const font_size = sanitizeFontSize(slice.items(.font_size)[idx]);
        const text_color = slice.items(.text_color)[idx];
        const rect = slice.items(.rect)[idx];
        const fill = slice.items(.fill)[idx];
        const border = slice.items(.border)[idx];
        const accent = slice.items(.accent)[idx];
        const radius = sanitizeNonNeg(slice.items(.corner_radius)[idx]);
        const bw = sanitizeNonNeg(slice.items(.border_width)[idx]);
        const blur = sanitizeNonNeg(slice.items(.shadow_blur)[idx]);
        const checked = slice.items(.checked)[idx];
        const slider_val = sanitizeUnit(slice.items(.slider_val)[idx]);

        if (rect.w > 0.0 and rect.h > 0.0) {
            switch (kind) {
                .vstack, .hstack, .zstack, .grid, .card => {
                    if (fill[3] > 0.0 or bw > 0.0) {
                        const phys = snapRectToPhysical(rect, scale);
                        pushQuad(out_buf, count, .{
                            .pos_size = .{ phys.x, phys.y, phys.w, phys.h },
                            .color = fill,
                            .border_color = border,
                            .params = .{ radius * scale, bw * scale, blur * scale, 0.0 },
                        });
                    }
                    if (@TypeOf(maybe_atlas) != ?noreturn) {
                        if (maybe_atlas) |atlas| {
                            if (label.len > 0 and rect.w >= 24.0 and rect.h >= 12.0 and count.* < out_buf.len) {
                                const m = atlas.measureText(label, font_size, scale);
                                if (sublabel.len > 0) {
                                    const sub_fs = font_size * 0.82;
                                    const m_sub = atlas.measureText(sublabel, sub_fs, scale);
                                    const total_h = m.height + 2.0 + m_sub.height;
                                    const ly = rect.y + (rect.h - total_h) * 0.5;
                                    const lx = rect.x + @min(12.0, rect.w * 0.1);
                                    count.* += atlas.emitTextQuads(label, lx, ly, font_size, scale, text_color, out_buf[count.*..], frame_idx);
                                    if (count.* < out_buf.len) {
                                        count.* += atlas.emitTextQuads(sublabel, lx, ly + m.height + 2.0, sub_fs, scale, Nord.snow_storm_0, out_buf[count.*..], frame_idx);
                                    }
                                } else {
                                    const ly = rect.y + (rect.h - m.height) * 0.5;
                                    const lx = if (rect.w < 260.0 and m.width < rect.w)
                                        rect.x + (rect.w - m.width) * 0.5
                                    else
                                        rect.x + @min(8.0, rect.w * 0.1);
                                    count.* += atlas.emitTextQuads(label, lx, ly, font_size, scale, text_color, out_buf[count.*..], frame_idx);
                                }
                            }
                        }
                    }
                },
                .toggle => {
                    if (role == .swatch) {
                        const phys = snapRectToPhysical(rect, scale);
                        const eff_border = if (checked) Nord.snow_storm_2 else border;
                        const eff_bw = if (checked) @max(bw, 2.5) else bw;
                        const eff_blur = if (checked) @max(blur, 8.0) else blur;
                        pushQuad(out_buf, count, .{
                            .pos_size = .{ phys.x, phys.y, phys.w, phys.h },
                            .color = fill,
                            .border_color = eff_border,
                            .params = .{ radius * scale, eff_bw * scale, eff_blur * scale, 0.0 },
                        });
                        if (checked) {
                            const dot_s = @min(rect.w, rect.h) * 0.28;
                            const dot_rect = Rect{
                                .x = rect.x + (rect.w - dot_s) * 0.5,
                                .y = rect.y + (rect.h - dot_s) * 0.5,
                                .w = dot_s,
                                .h = dot_s,
                            };
                            const phys_dot = snapRectToPhysical(dot_rect, scale);
                            pushQuad(out_buf, count, .{
                                .pos_size = .{ phys_dot.x, phys_dot.y, phys_dot.w, phys_dot.h },
                                .color = Nord.snow_storm_2,
                                .border_color = Nord.polar_night_0,
                                .params = .{ (dot_s * 0.5) * scale, 1.0 * scale, 2.0 * scale, 0.0 },
                            });
                        }
                    } else {
                        const phys = snapRectToPhysical(rect, scale);
                        const eff_border = if (checked) accent else border;
                        pushQuad(out_buf, count, .{
                            .pos_size = .{ phys.x, phys.y, phys.w, phys.h },
                            .color = fill,
                            .border_color = eff_border,
                            .params = .{ radius * scale, bw * scale, blur * scale, 0.0 },
                        });

                        // Leading accent indicator strip on left (only if wide enough)
                        if (rect.w >= 28.0) {
                            const ind_pad = @min(12.0, rect.w * 0.15);
                            const ind_w = @min(4.0, @max(0.0, rect.w - ind_pad * 2.0));
                            const ind_h = @min(rect.h, @max(4.0, rect.h * 0.45));
                            const ind_rect = Rect{
                                .x = rect.x + ind_pad,
                                .y = rect.y + (rect.h - ind_h) * 0.5,
                                .w = ind_w,
                                .h = ind_h,
                            };
                            const phys_ind = snapRectToPhysical(ind_rect, scale);
                            pushQuad(out_buf, count, .{
                                .pos_size = .{ phys_ind.x, phys_ind.y, phys_ind.w, phys_ind.h },
                                .color = if (checked) accent else Nord.polar_night_3,
                                .border_color = Nord.transparent,
                                .params = .{ 2.0 * scale, 0.0, 0.0, 0.0 },
                            });
                        }

                        // Pill switch track clamped strictly inside rect bounds
                        const pill_margin = @min(16.0, rect.w * 0.12);
                        const avail_pill_w = @max(0.0, rect.w - pill_margin * 2.0);
                        const pill_w = @min(52.0, @min(rect.w * 0.45, avail_pill_w));
                        const pill_h = @min(28.0, @min(rect.h * 0.54, @max(0.0, rect.h - 4.0)));
                        if (pill_w > 0.0 and pill_h > 0.0) {
                            const pill_x = std.math.clamp(
                                rect.x + rect.w - pill_w - pill_margin,
                                rect.x,
                                rect.x + rect.w - pill_w,
                            );
                            const pill_y = rect.y + (rect.h - pill_h) * 0.5;
                            const phys_pill = snapRectToPhysical(.{ .x = pill_x, .y = pill_y, .w = pill_w, .h = pill_h }, scale);
                            pushQuad(out_buf, count, .{
                                .pos_size = .{ phys_pill.x, phys_pill.y, phys_pill.w, phys_pill.h },
                                .color = if (checked) accent else Nord.polar_night_3,
                                .border_color = if (checked) accent else Nord.polar_night_2,
                                .params = .{ (pill_h * 0.5) * scale, 1.0 * scale, 0.0, 0.0 },
                            });

                            const pad = @min(3.0, @min(pill_w, pill_h) * 0.2);
                            const knob_d = @max(0.0, @min(pill_h, pill_w) - pad * 2.0);
                            if (knob_d > 0.0) {
                                const raw_knob_x = if (checked) (pill_x + pill_w - knob_d - pad) else (pill_x + pad);
                                const knob_x = std.math.clamp(raw_knob_x, pill_x, pill_x + pill_w - knob_d);
                                const knob_y = pill_y + (pill_h - knob_d) * 0.5;
                                const phys_knob = snapRectToPhysical(.{ .x = knob_x, .y = knob_y, .w = knob_d, .h = knob_d }, scale);
                                pushQuad(out_buf, count, .{
                                    .pos_size = .{ phys_knob.x, phys_knob.y, phys_knob.w, phys_knob.h },
                                    .color = Nord.snow_storm_2,
                                    .border_color = Nord.transparent,
                                    .params = .{ (knob_d * 0.5) * scale, 0.0, 2.0 * scale, 0.0 },
                                });
                            }
                        }

                        if (@TypeOf(maybe_atlas) != ?noreturn) {
                            if (maybe_atlas) |atlas| {
                                if (label.len > 0 and rect.w >= 120.0 and rect.h >= 16.0 and count.* < out_buf.len) {
                                    const m = atlas.measureText(label, font_size, scale);
                                    const lx = rect.x + 28.0;
                                    const ly = rect.y + (rect.h - m.height) * 0.5;
                                    count.* += atlas.emitTextQuads(label, lx, ly, font_size, scale, text_color, out_buf[count.*..], frame_idx);
                                }
                            }
                        }
                    }
                },
                .slider => {
                    const phys = snapRectToPhysical(rect, scale);
                    pushQuad(out_buf, count, .{
                        .pos_size = .{ phys.x, phys.y, phys.w, phys.h },
                        .color = fill,
                        .border_color = border,
                        .params = .{ radius * scale, bw * scale, blur * scale, 0.0 },
                    });

                    const has_label = (label.len > 0 and rect.w >= 100.0 and rect.h >= 40.0);
                    const track_center_y = if (has_label) rect.y + rect.h * 0.68 else rect.y + rect.h * 0.5;

                    const tb = sliderTrackBounds(rect);
                    const track_h = @min(8.0, rect.h * 0.5);
                    const track_y = track_center_y - track_h * 0.5;
                    if (tb.w > 0.0 and track_h > 0.0) {
                        const phys_track = snapRectToPhysical(.{ .x = tb.x, .y = track_y, .w = tb.w, .h = track_h }, scale);
                        pushQuad(out_buf, count, .{
                            .pos_size = .{ phys_track.x, phys_track.y, phys_track.w, phys_track.h },
                            .color = Nord.polar_night_0,
                            .border_color = Nord.polar_night_3,
                            .params = .{ (track_h * 0.5) * scale, 1.0 * scale, 0.0, 0.0 },
                        });

                        const raw_fill_w = tb.w * slider_val;
                        const fill_w = if (slider_val > 0.001)
                            @min(tb.w, @max(@min(track_h, tb.w), raw_fill_w))
                        else
                            0.0;
                        if (fill_w > 0.0) {
                            const phys_fill = snapRectToPhysical(.{ .x = tb.x, .y = track_y, .w = fill_w, .h = track_h }, scale);
                            pushQuad(out_buf, count, .{
                                .pos_size = .{ phys_fill.x, phys_fill.y, phys_fill.w, phys_fill.h },
                                .color = accent,
                                .border_color = Nord.transparent,
                                .params = .{ (track_h * 0.5) * scale, 0.0, 0.0, 0.0 },
                            });
                        }
                    }

                    const knob_d = @min(22.0, @min(rect.w, rect.h));
                    if (knob_d > 0.0) {
                        const knob_cx = std.math.clamp(
                            tb.x + tb.w * slider_val,
                            rect.x + knob_d * 0.5,
                            rect.x + rect.w - knob_d * 0.5,
                        );
                        const knob_y = std.math.clamp(
                            track_center_y - knob_d * 0.5,
                            rect.y,
                            rect.y + rect.h - knob_d,
                        );
                        const knob_rect = Rect{
                            .x = knob_cx - knob_d * 0.5,
                            .y = knob_y,
                            .w = knob_d,
                            .h = knob_d,
                        };
                        const phys_knob = snapRectToPhysical(knob_rect, scale);
                        pushQuad(out_buf, count, .{
                            .pos_size = .{ phys_knob.x, phys_knob.y, phys_knob.w, phys_knob.h },
                            .color = Nord.snow_storm_2,
                            .border_color = accent,
                            .params = .{ (knob_d * 0.5) * scale, 2.0 * scale, 4.0 * scale, 0.0 },
                        });
                    }

                    if (@TypeOf(maybe_atlas) != ?noreturn) {
                        if (maybe_atlas) |atlas| {
                            if (has_label and count.* < out_buf.len) {
                                const lx = tb.x;
                                const ly = rect.y + 8.0;
                                count.* += atlas.emitTextQuads(label, lx, ly, font_size, scale, text_color, out_buf[count.*..], frame_idx);
                            }
                        }
                    }
                },
                .bar => {
                    const phys = snapRectToPhysical(rect, scale);
                    pushQuad(out_buf, count, .{
                        .pos_size = .{ phys.x, phys.y, phys.w, phys.h },
                        .color = fill,
                        .border_color = border,
                        .params = .{ radius * scale, bw * scale, blur * scale, 0.0 },
                    });

                    if (slider_val > 0.001) {
                        const inner_pad_x = @min(3.0, rect.w * 0.25);
                        const inner_pad_y = @min(3.0, rect.h * 0.25);
                        const inner_w = @max(0.0, rect.w - inner_pad_x * 2.0) * slider_val;
                        const inner_h = @max(0.0, rect.h - inner_pad_y * 2.0);
                        if (inner_w > 0.0 and inner_h > 0.0) {
                            const bar_rect = Rect{
                                .x = rect.x + inner_pad_x,
                                .y = rect.y + inner_pad_y,
                                .w = inner_w,
                                .h = inner_h,
                            };
                            const phys_bar = snapRectToPhysical(bar_rect, scale);
                            const inner_r = @max(0.0, radius - @min(inner_pad_x, inner_pad_y));
                            pushQuad(out_buf, count, .{
                                .pos_size = .{ phys_bar.x, phys_bar.y, phys_bar.w, phys_bar.h },
                                .color = accent,
                                .border_color = Nord.transparent,
                                .params = .{ inner_r * scale, 0.0, 0.0, 0.0 },
                            });
                        }
                    }

                    if (@TypeOf(maybe_atlas) != ?noreturn) {
                        if (maybe_atlas) |atlas| {
                            if (label.len > 0 and rect.w >= 32.0 and rect.h >= 12.0 and count.* < out_buf.len) {
                                const m = atlas.measureText(label, font_size, scale);
                                const lx = rect.x + @max(4.0, (rect.w - m.width) * 0.5);
                                const ly = rect.y + (rect.h - m.height) * 0.5;
                                count.* += atlas.emitTextQuads(label, lx, ly, font_size, scale, text_color, out_buf[count.*..], frame_idx);
                            }
                        }
                    }
                },
            }
        }

        const next_siblings = slice.items(.next_sibling);
        var cur: ?u16 = slice.items(.first_child)[idx];
        while (cur) |c| : (cur = next_siblings[c]) {
            self.emitNodeQuads(c, out_buf, count, scale, atlas_opt, frame_idx);
            if (count.* >= out_buf.len) break;
        }
    }

    fn sliderValueFromX(rect: Rect, x: f32) f32 {
        const tb = sliderTrackBounds(rect);
        if (tb.w <= 0.0) return 0.0;
        return std.math.clamp((x - tb.x) / tb.w, 0.0, 1.0);
    }

    fn rectContains(r: Rect, x: f32, y: f32) bool {
        return r.w > 0.0 and r.h > 0.0 and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h;
    }

    fn hitTestChildrenReversePure(self: *const LayoutArena, child_opt: ?u16, x: f32, y: f32) ?NodeId {
        const c = child_opt orelse return null;
        const next = self.nodes.items(.next_sibling)[c];
        if (next) |n| {
            if (self.hitTestChildrenReversePure(n, x, y)) |res| return res;
        }
        return self.hitTestNodePure(c, x, y);
    }

    fn hitTestNodePure(self: *const LayoutArena, idx: u16, x: f32, y: f32) ?NodeId {
        const first_child = self.nodes.items(.first_child)[idx];
        if (self.hitTestChildrenReversePure(first_child, x, y)) |res| {
            return res;
        }

        const slice = self.nodes.slice();
        const r = slice.items(.rect)[idx];
        if (!rectContains(r, x, y)) return null;

        const kind = slice.items(.kind)[idx];
        const gen = slice.items(.gen)[idx];
        const fill = slice.items(.fill)[idx];
        const bw = sanitizeNonNeg(slice.items(.border_width)[idx]);
        const border = slice.items(.border)[idx];
        const is_bordered_card = (kind == .card and bw > 0.0 and border[3] > 0.0);
        if (kind == .toggle or kind == .slider or fill[3] > 0.0 or is_bordered_card) {
            return .{ .index = idx, .gen = gen };
        }
        return null;
    }

    pub fn hitTest(self: *const LayoutArena, x: f32, y: f32) ?NodeId {
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;
        const root = self.root_index orelse return null;
        return self.hitTestNodePure(root, x, y);
    }

    fn hitTestChildrenReverse(self: *LayoutArena, child_opt: ?u16, x: f32, y: f32) ?HitResult {
        const c = child_opt orelse return null;
        const next = self.nodes.items(.next_sibling)[c];
        if (next) |n| {
            if (self.hitTestChildrenReverse(n, x, y)) |res| return res;
        }
        return self.hitTestNode(c, x, y);
    }

    fn hitTestNode(self: *LayoutArena, idx: u16, x: f32, y: f32) ?HitResult {
        const first_child = self.nodes.items(.first_child)[idx];
        if (self.hitTestChildrenReverse(first_child, x, y)) |res| {
            return res;
        }

        const slice = self.nodes.slice();
        const r = slice.items(.rect)[idx];
        if (!rectContains(r, x, y)) return null;

        const kind = slice.items(.kind)[idx];
        const gen = slice.items(.gen)[idx];
        const enabled = self.isEnabledTree(.{ .index = idx, .gen = gen });
        if (kind == .toggle and enabled) {
            const checked_items = slice.items(.checked);
            checked_items[idx] = !checked_items[idx];
            self.redraw_needed = true;
            return .{ .hit = .{ .index = idx, .gen = gen } };
        }
        if (kind == .slider and enabled) {
            const id = NodeId{ .index = idx, .gen = gen };
            slice.items(.slider_val)[idx] = sliderValueFromX(r, x);
            self.active_slider = id;
            self.redraw_needed = true;
            return .{ .hit = id };
        }
        if (slice.items(.fill)[idx][3] > 0.0) {
            return .occluded;
        }
        return null;
    }

    pub fn handlePointerDown(self: *LayoutArena, x: f32, y: f32) ?NodeId {
        self.active_slider = null;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;
        const root = self.root_index orelse return null;
        return switch (self.hitTestNode(root, x, y) orelse return null) {
            .hit => |id| id,
            .occluded => null,
        };
    }

    pub fn handlePointerMove(self: *LayoutArena, x: f32, y: f32) ?NodeId {
        _ = y;
        if (!std.math.isFinite(x)) return self.active_slider;
        const id = self.active_slider orelse return null;
        const idx = self.resolveIndex(id) orelse {
            self.active_slider = null;
            return null;
        };
        const r = self.nodes.items(.rect)[idx];
        const t = sliderValueFromX(r, x);
        const slider_items = self.nodes.items(.slider_val);
        if (@abs(slider_items[idx] - t) > 0.0005) {
            slider_items[idx] = t;
            self.redraw_needed = true;
        }
        return id;
    }

    pub fn handlePointerUp(self: *LayoutArena) void {
        self.active_slider = null;
    }

    pub fn dumpSemanticTree(self: *const LayoutArena, writer: anytype) !void {
        const root = self.root_index orelse return;
        try self.dumpNode(root, 0, writer);
    }

    fn dumpNode(self: *const LayoutArena, idx: u16, depth: usize, writer: anytype) !void {
        var d: usize = 0;
        while (d < depth) : (d += 1) {
            try writer.writeAll("  ");
        }
        const slice = self.nodes.slice();
        const kind = slice.items(.kind)[idx];
        const role = slice.items(.role)[idx];
        const test_id = slice.items(.test_id)[idx];
        const r = slice.items(.rect)[idx];

        try writer.print(
            "{s} role={s} id=\"{s}\" rect=({d:.1},{d:.1},{d:.1},{d:.1})",
            .{ @tagName(kind), @tagName(role), test_id, r.x, r.y, r.w, r.h },
        );
        switch (kind) {
            .toggle => try writer.print(" checked={}", .{slice.items(.checked)[idx]}),
            .slider, .bar => try writer.print(" value={d:.3}", .{slice.items(.slider_val)[idx]}),
            else => {},
        }
        try writer.writeAll("\n");

        const next_siblings = slice.items(.next_sibling);
        var cur: ?u16 = slice.items(.first_child)[idx];
        while (cur) |c| : (cur = next_siblings[c]) {
            try self.dumpNode(c, depth + 1, writer);
        }
    }
};

pub fn buildDemoScene(arena: *LayoutArena) !void {
    arena.reset();

    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .test_id = "dashboard.root",
        .padding = 24.0,
        .gap = 14.0,
        .fill = Nord.polar_night_0,
    });

    // Header card
    const header = try arena.addChild(root, .{
        .kind = .card,
        .role = .panel,
        .test_id = "dashboard.header",
        .height = 88.0,
        .padding = 12.0,
        .gap = 12.0,
        .corner_radius = 16.0,
        .border_width = 1.5,
        .shadow_blur = 10.0,
        .fill = Nord.polar_night_1,
        .border = Nord.frost_3,
    });
    const header_row = try arena.addChild(header, .{
        .kind = .hstack,
        .role = .container,
        .test_id = "dashboard.header_row",
        .gap = 12.0,
    });
    _ = try arena.addChild(header_row, .{
        .kind = .bar,
        .role = .progress_bar,
        .test_id = "header.accent_badge",
        .width = 48.0,
        .corner_radius = 12.0,
        .border_width = 1.0,
        .fill = Nord.polar_night_0,
        .border = Nord.frost_1,
        .accent = Nord.frost_1,
        .slider_val = 1.0,
    });
    const header_bars = try arena.addChild(header_row, .{
        .kind = .vstack,
        .role = .container,
        .test_id = "header.metrics",
        .gap = 6.0,
    });
    _ = try arena.addChild(header_bars, .{
        .kind = .card,
        .role = .panel,
        .test_id = "header.title",
        .label = "ZIG GUI // UBERQUAD",
        .font_size = 18.0,
        .text_color = Nord.snow_storm_2,
        .height = 24.0,
        .fill = Nord.transparent,
    });
    _ = try arena.addChild(header_bars, .{
        .kind = .bar,
        .role = .progress_bar,
        .test_id = "header.gpu_budget",
        .height = 14.0,
        .corner_radius = 7.0,
        .fill = Nord.polar_night_0,
        .accent = Nord.aurora_green,
        .slider_val = 0.88,
    });
    _ = try arena.addChild(header_bars, .{
        .kind = .bar,
        .role = .progress_bar,
        .test_id = "header.frame_headroom",
        .height = 14.0,
        .corner_radius = 7.0,
        .fill = Nord.polar_night_0,
        .accent = Nord.frost_2,
        .slider_val = 0.64,
    });

    // 3 Interactive Toggles
    _ = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "settings.gpu_cache",
        .label = "GPU Glyph Atlas",
        .font_size = 16.0,
        .text_color = Nord.snow_storm_2,
        .height = 60.0,
        .corner_radius = 14.0,
        .border_width = 1.5,
        .shadow_blur = 6.0,
        .fill = Nord.polar_night_1,
        .border = Nord.polar_night_3,
        .accent = Nord.frost_1,
        .checked = true,
    });
    _ = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "settings.zero_tick_sleep",
        .label = "Zero-Tick Sleep",
        .font_size = 16.0,
        .text_color = Nord.snow_storm_2,
        .height = 60.0,
        .corner_radius = 14.0,
        .border_width = 1.5,
        .shadow_blur = 6.0,
        .fill = Nord.polar_night_1,
        .border = Nord.polar_night_3,
        .accent = Nord.aurora_green,
        .checked = true,
    });
    _ = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "settings.oklab_palette",
        .label = "Oklab Palette",
        .font_size = 16.0,
        .text_color = Nord.snow_storm_2,
        .height = 60.0,
        .corner_radius = 14.0,
        .border_width = 1.5,
        .shadow_blur = 6.0,
        .fill = Nord.polar_night_1,
        .border = Nord.polar_night_3,
        .accent = Nord.aurora_purple,
        .checked = false,
    });

    // 2 Interactive Sliders
    _ = try arena.addChild(root, .{
        .kind = .slider,
        .role = .slider,
        .test_id = "settings.sdf_aa_width",
        .label = "SDF AA Width",
        .font_size = 14.0,
        .text_color = Nord.snow_storm_1,
        .height = 64.0,
        .corner_radius = 14.0,
        .border_width = 1.5,
        .shadow_blur = 6.0,
        .fill = Nord.polar_night_1,
        .border = Nord.polar_night_3,
        .accent = Nord.frost_2,
        .slider_val = 0.72,
    });
    _ = try arena.addChild(root, .{
        .kind = .slider,
        .role = .slider,
        .test_id = "settings.shadow_softness",
        .label = "Shadow Softness",
        .font_size = 14.0,
        .text_color = Nord.snow_storm_1,
        .height = 64.0,
        .corner_radius = 14.0,
        .border_width = 1.5,
        .shadow_blur = 6.0,
        .fill = Nord.polar_night_1,
        .border = Nord.polar_night_3,
        .accent = Nord.aurora_yellow,
        .slider_val = 0.42,
    });

    // Status Cards + Bars Row
    const status_row = try arena.addChild(root, .{
        .kind = .hstack,
        .role = .container,
        .test_id = "dashboard.status_row",
        .height = 84.0,
        .gap = 12.0,
    });
    const status_specs = [_]struct {
        card_id: []const u8,
        label_id: []const u8,
        bar_id: []const u8,
        label: []const u8,
        accent: Color,
        val: f32,
    }{
        .{
            .card_id = "status.cpu_idle.card",
            .label_id = "status.cpu_idle.label",
            .bar_id = "status.cpu_idle.bar",
            .label = "CPU 0% IDLE",
            .accent = Nord.aurora_green,
            .val = 0.96,
        },
        .{
            .card_id = "status.batch_eff.card",
            .label_id = "status.batch_eff.label",
            .bar_id = "status.batch_eff.bar",
            .label = "1-PASS SDF",
            .accent = Nord.frost_1,
            .val = 0.85,
        },
        .{
            .card_id = "status.zero_alloc.card",
            .label_id = "status.zero_alloc.label",
            .bar_id = "status.zero_alloc.bar",
            .label = "0 ALLOC",
            .accent = Nord.aurora_orange,
            .val = 0.74,
        },
    };
    for (status_specs) |spec| {
        const card = try arena.addChild(status_row, .{
            .kind = .card,
            .role = .panel,
            .test_id = spec.card_id,
            .padding = 12.0,
            .gap = 8.0,
            .corner_radius = 14.0,
            .border_width = 1.5,
            .shadow_blur = 6.0,
            .fill = Nord.polar_night_1,
            .border = Nord.polar_night_3,
        });
        _ = try arena.addChild(card, .{
            .kind = .card,
            .role = .panel,
            .test_id = spec.label_id,
            .label = spec.label,
            .font_size = 13.0,
            .text_color = Nord.snow_storm_1,
            .height = 20.0,
            .fill = Nord.transparent,
        });
        _ = try arena.addChild(card, .{
            .kind = .bar,
            .role = .progress_bar,
            .test_id = spec.bar_id,
            .corner_radius = 8.0,
            .border_width = 1.0,
            .fill = Nord.polar_night_0,
            .border = Nord.polar_night_2,
            .accent = spec.accent,
            .slider_val = spec.val,
        });
    }

    // 6x4 Interactive Nord + Oklab Swatch Grid (24 swatches)
    const swatch_grid = try arena.addChild(root, .{
        .kind = .card,
        .role = .panel,
        .test_id = "dashboard.swatch_grid",
        .padding = 14.0,
        .gap = 10.0,
        .corner_radius = 16.0,
        .border_width = 1.5,
        .shadow_blur = 8.0,
        .fill = Nord.polar_night_1,
        .border = Nord.polar_night_2,
    });

    const palette = [4][6]Color{
        .{
            Nord.polar_night_0,
            Nord.polar_night_1,
            Nord.polar_night_2,
            Nord.polar_night_3,
            Nord.snow_storm_0,
            Nord.snow_storm_2,
        },
        .{
            Nord.frost_0,
            Nord.frost_1,
            Nord.frost_2,
            Nord.frost_3,
            Nord.aurora_green,
            Nord.aurora_purple,
        },
        .{
            Nord.aurora_red,
            Nord.aurora_orange,
            Nord.aurora_yellow,
            oklabToSrgb(0.68, -0.10, 0.08, 1.0),
            oklabToSrgb(0.65, -0.08, -0.09, 1.0),
            oklabToSrgb(0.62, 0.09, -0.09, 1.0),
        },
        .{
            oklabToSrgb(0.55, 0.14, 0.04, 1.0),
            oklabToSrgb(0.64, 0.08, 0.11, 1.0),
            oklabToSrgb(0.75, -0.03, 0.12, 1.0),
            oklabToSrgb(0.70, -0.11, -0.03, 1.0),
            oklabToSrgb(0.58, -0.04, -0.12, 1.0),
            oklabToSrgb(0.60, 0.10, -0.06, 1.0),
        },
    };

    const swatch_ids = [4][6][]const u8{
        .{ "swatch.0_0", "swatch.0_1", "swatch.0_2", "swatch.0_3", "swatch.0_4", "swatch.0_5" },
        .{ "swatch.1_0", "swatch.1_1", "swatch.1_2", "swatch.1_3", "swatch.1_4", "swatch.1_5" },
        .{ "swatch.2_0", "swatch.2_1", "swatch.2_2", "swatch.2_3", "swatch.2_4", "swatch.2_5" },
        .{ "swatch.3_0", "swatch.3_1", "swatch.3_2", "swatch.3_3", "swatch.3_4", "swatch.3_5" },
    };

    const swatch_row_ids = [4][]const u8{
        "swatch.row_0",
        "swatch.row_1",
        "swatch.row_2",
        "swatch.row_3",
    };

    for (0..4) |row_i| {
        const row = try arena.addChild(swatch_grid, .{
            .kind = .hstack,
            .role = .container,
            .test_id = swatch_row_ids[row_i],
            .gap = 10.0,
        });
        for (0..6) |col_i| {
            _ = try arena.addChild(row, .{
                .kind = .toggle,
                .role = .swatch,
                .test_id = swatch_ids[row_i][col_i],
                .corner_radius = 12.0,
                .border_width = 1.5,
                .shadow_blur = 4.0,
                .fill = palette[row_i][col_i],
                .border = Nord.polar_night_3,
                .checked = (row_i == 1 and col_i == 1),
            });
        }
    }
}
