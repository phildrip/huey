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

fn sanitizeNonNeg(v: f32) f32 {
    if (!std.math.isFinite(v) or v < 0.0) return 0.0;
    return v;
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
    return .{
        .x = x0,
        .y = y0,
        .w = @max(0.0, x1 - x0),
        .h = @max(0.0, y1 - y0),
    };
}

pub const NodeKind = enum {
    vstack,
    hstack,
    zstack,
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
    rect: Rect = .{},
};

const TrackBounds = struct {
    x: f32,
    w: f32,
};

fn sliderTrackBounds(rect: Rect) TrackBounds {
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
        });
        if (self.root_index == null) {
            self.root_index = idx;
        }
        self.redraw_needed = true;
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
        self.viewport_w = vw;
        self.viewport_h = vh;
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

        const next_siblings = slice.items(.next_sibling);
        const widths = slice.items(.width);
        const heights = slice.items(.height);
        const flexes = slice.items(.flex);
        const rects = slice.items(.rect);

        if (kind == .zstack) {
            var cur: ?u16 = first_child;
            while (cur) |c| : (cur = next_siblings[c]) {
                const w = sanitizeNonNeg(widths[c]);
                const h = sanitizeNonNeg(heights[c]);
                const cw = if (w > 0.0) @min(w, inner_w) else inner_w;
                const ch = if (h > 0.0) @min(h, inner_h) else inner_h;
                rects[c] = .{ .x = inner_x, .y = inner_y, .w = cw, .h = ch };
                self.layoutChildren(c);
            }
            return;
        }

        const is_horizontal = (kind == .hstack);

        var count: usize = 0;
        var fixed_main: f32 = 0;
        var total_flex: f32 = 0;

        var cur: ?u16 = first_child;
        while (cur) |c| : (cur = next_siblings[c]) {
            count += 1;
            const main_dim = sanitizeNonNeg(if (is_horizontal) widths[c] else heights[c]);
            if (main_dim > 0.0) {
                fixed_main += main_dim;
            } else {
                total_flex += sanitizeNonNeg(flexes[c]);
            }
        }

        const total_gap = if (count > 1) gap * @as(f32, @floatFromInt(count - 1)) else 0.0;
        const avail_main = if (is_horizontal) inner_w else inner_h;
        const rem_main = @max(0.0, avail_main - fixed_main - total_gap);
        const valid_flex = std.math.isFinite(total_flex) and total_flex > 0.0;

        var cursor = if (is_horizontal) inner_x else inner_y;
        cur = first_child;
        while (cur) |c| : (cur = next_siblings[c]) {
            const w = sanitizeNonNeg(widths[c]);
            const h = sanitizeNonNeg(heights[c]);
            const fl = sanitizeNonNeg(flexes[c]);
            if (is_horizontal) {
                const cw = if (w > 0.0)
                    w
                else if (valid_flex)
                    rem_main * (fl / total_flex)
                else
                    0.0;
                const ch = if (h > 0.0) @min(h, inner_h) else inner_h;
                rects[c] = .{ .x = cursor, .y = inner_y, .w = cw, .h = ch };
                cursor += cw + gap;
            } else {
                const cw = if (w > 0.0) @min(w, inner_w) else inner_w;
                const ch = if (h > 0.0)
                    h
                else if (valid_flex)
                    rem_main * (fl / total_flex)
                else
                    0.0;
                rects[c] = .{ .x = inner_x, .y = cursor, .w = cw, .h = ch };
                cursor += ch + gap;
            }
            self.layoutChildren(c);
        }
    }

    pub fn getRect(self: *const LayoutArena, id: NodeId) ?Rect {
        const idx = self.resolveIndex(id) orelse return null;
        return self.nodes.items(.rect)[idx];
    }

    pub fn isChecked(self: *const LayoutArena, id: NodeId) ?bool {
        const idx = self.resolveIndex(id) orelse return null;
        return self.nodes.items(.checked)[idx];
    }

    pub fn getSliderValue(self: *const LayoutArena, id: NodeId) ?f32 {
        const idx = self.resolveIndex(id) orelse return null;
        return self.nodes.items(.slider_val)[idx];
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
                .vstack, .hstack, .zstack, .card => {
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
        if (kind == .toggle) {
            const checked_items = slice.items(.checked);
            checked_items[idx] = !checked_items[idx];
            self.redraw_needed = true;
            return .{ .hit = .{ .index = idx, .gen = gen } };
        }
        if (kind == .slider) {
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

    for (0..4) |row_i| {
        const row = try arena.addChild(swatch_grid, .{
            .kind = .hstack,
            .role = .container,
            .test_id = "swatch.row",
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
